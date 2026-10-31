import AVFoundation
import Combine
import Foundation

/// The open project: editing state, undo history, autosave, cached cursor and caption
/// tracks, and the export entry point.
@MainActor
public final class ProjectDocument: ObservableObject, Identifiable {
    public let id = UUID()
    public let bundleURL: URL
    /// Metal is optional so projects stay openable (and testable) without a GPU.
    public let compositor: Compositor?

    @Published public var project: ScreenForgeProject {
        didSet {
            if oldValue.cursor != project.cursor ||
                oldValue.source.durationMs != project.source.durationMs {
                cursorTrack = nil
                trackKey = nil
            }
            if oldValue.captions != project.captions {
                captionTrack = nil
                captionKey = nil
            }
            isDirty = true
            scheduleSave()
        }
    }

    @Published public private(set) var cursorSamples: [CursorSample]
    @Published public private(set) var transcript: TranscriptDocument?
    @Published public var selectedZoomID: String?
    @Published public var selectedTrimID: String?
    @Published public var selectedSpeedID: String?
    @Published public var selectedAnnotationID: String?
    @Published public var selectedLayoutID: String?
    @Published public private(set) var isDirty = false
    @Published public private(set) var canUndo = false
    @Published public private(set) var canRedo = false
    @Published public private(set) var lastSavedAt: Date?
    @Published public private(set) var isTranscribing = false
    @Published public private(set) var transcriptionStatus: String?
    @Published public var errorMessage: String?
    /// Non-blocking message shown in the editor (e.g. "nothing to suggest").
    @Published public var notice: String?

    private var undoStack: [ScreenForgeProject] = []
    private var redoStack: [ScreenForgeProject] = []
    private var cursorTrack: CursorTrack?
    private var trackKey: TrackKey?
    private var captionTrack: CaptionTrack?
    private var captionKey: CaptionKey?
    private var saveTask: Task<Void, Never>?

    private struct TrackKey: Equatable {
        var settings: CursorSettings
        var durationMs: Int
        var sampleCount: Int
        var firstSampleMs: Int
        var lastSampleMs: Int
    }

    private struct CaptionKey: Equatable {
        var settings: CaptionSettings
        var wordCount: Int
        var firstWordMs: Int
        var lastWordMs: Int
    }

    public init(
        bundleURL: URL,
        project: ScreenForgeProject,
        cursorSamples: [CursorSample],
        compositor: Compositor?,
        transcript: TranscriptDocument? = nil
    ) {
        self.bundleURL = bundleURL
        self.project = project
        self.cursorSamples = cursorSamples
        self.compositor = compositor
        self.transcript = transcript
        self.isDirty = false
    }

    // MARK: - Derived state

    public var map: TimelineMap {
        project.timeline.map(sourceDurationMs: project.source.durationMs)
    }

    public var outputDurationMs: Double {
        map.outputDurationMs
    }

    /// Renderer with cached cursor and caption tracks. Cheap enough to call per frame.
    public var renderer: FrameRenderer {
        rebuildCursorTrackIfNeeded()
        rebuildCaptionTrackIfNeeded()
        return FrameRenderer(
            project: project,
            bundleURL: bundleURL,
            cursorTrack: cursorTrack,
            captionTrack: captionTrack
        )
    }

    /// Caption lines derived from the transcript, for the inspector and timeline.
    public var hasCursorTelemetry: Bool { !cursorSamples.isEmpty }

    public var captionCues: [CaptionCue] {
        guard let transcript else { return [] }
        return CaptionLayoutBuilder.cues(
            from: transcript.words,
            options: .init(settings: project.captions)
        )
    }

    public var selectedZoom: ZoomRegion? {
        guard let selectedZoomID else { return nil }
        return project.timeline.zooms.first { $0.id == selectedZoomID }
    }

    public var selectedTrim: TrimRegion? {
        guard let selectedTrimID else { return nil }
        return project.timeline.trims.first { $0.id == selectedTrimID }
    }

    public var selectedSpeed: SpeedRegion? {
        guard let selectedSpeedID else { return nil }
        return project.timeline.speeds.first { $0.id == selectedSpeedID }
    }

    public var selectedAnnotation: AnnotationRegion? {
        guard let selectedAnnotationID else { return nil }
        return project.timeline.annotations.first { $0.id == selectedAnnotationID }
    }

    public var selectedLayout: LayoutRegion? {
        guard let selectedLayoutID else { return nil }
        return project.timeline.layouts.first { $0.id == selectedLayoutID }
    }

    // MARK: - Editing

    /// Applies a discrete edit with undo support.
    public func apply(_ mutation: (inout ScreenForgeProject) -> Void) {
        pushUndo(project)
        var copy = project
        mutation(&copy)
        project = copy.normalized()
        redoStack.removeAll()
        refreshUndoFlags()
        scheduleSave()
    }

    public func replaceProject(_ newValue: ScreenForgeProject, undoable: Bool = true) {
        if undoable {
            pushUndo(project)
            redoStack.removeAll()
            refreshUndoFlags()
        }
        project = newValue.normalized()
        scheduleSave()
    }

    public func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(project)
        project = previous
        refreshUndoFlags()
        scheduleSave()
    }

    public func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(project)
        project = next
        refreshUndoFlags()
        scheduleSave()
    }

    private func pushUndo(_ snapshot: ScreenForgeProject) {
        if undoStack.last != snapshot {
            undoStack.append(snapshot)
            if undoStack.count > 100 { undoStack.removeFirst() }
        }
    }

    private func refreshUndoFlags() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    // MARK: - Zoom

    @discardableResult
    public func addZoomAtPlayhead(outputMs: Double, durationMs: Int = 1_800) -> ZoomRegion? {
        let sourceMs = map.sourceTime(forOutputMs: outputMs) ?? 0
        guard sourceMs < Double(project.source.durationMs) else { return nil }

        let sample = cursorSamples.last { $0.timeMs <= Int(sourceMs) } ?? cursorSamples.first
        let focus = sample.map { ZoomFocus(x: $0.x, y: $0.y) } ?? .center
        let start = max(Int(sourceMs) - 280, 0)
        let region = ZoomRegion(
            startMs: start,
            endMs: min(start + durationMs, project.source.durationMs),
            scale: 1.8,
            focus: focus,
            kind: .classic,
            easing: .screenStudio,
            source: .manual,
            generated: false
        )

        apply { project in
            project.timeline.zooms.append(region)
        }
        selectedZoomID = region.id
        return region
    }

    public func deleteSelectedZoom() {
        guard let selectedZoomID else { return }
        apply { $0.timeline.zooms.removeAll { $0.id == selectedZoomID } }
        self.selectedZoomID = nil
    }

    @discardableResult
    public func runAutoZoom() -> Int {
        guard !cursorSamples.isEmpty else {
            notice = "Magic zoom needs cursor telemetry. This recording has none — add zooms manually with ⌘-click on the timeline or the Add zoom button."
            return 0
        }

        let engine = ZoomSuggestionEngine()
        let manual = project.timeline.zooms.filter { !$0.generated }
        let suggestions = engine.suggest(
            samples: cursorSamples,
            durationMs: project.source.durationMs,
            existingRegions: manual
        )

        guard !suggestions.isEmpty else {
            notice = "No zoom-worthy activity found. Click or dwell while recording, or add zooms manually."
            return 0
        }

        apply { project in
            let manual = project.timeline.zooms.filter { !$0.generated }
            project.timeline.zooms = (manual + suggestions).sorted { $0.startMs < $1.startMs }
            project.timeline.autoZoomEnabled = true
        }
        notice = "Added \(suggestions.count) zoom\(suggestions.count == 1 ? "" : "s") from cursor activity."
        return suggestions.count
    }

    public func clearGeneratedZooms() {
        apply { project in
            project.timeline.zooms.removeAll { $0.generated }
            project.timeline.autoZoomEnabled = false
        }
    }

    // MARK: - Trims / speed

    @discardableResult
    public func addTrim(fromOutputMs startMs: Double, toOutputMs endMs: Double) -> TrimRegion? {
        let start = map.sourceTime(forOutputMs: min(startMs, endMs)) ?? 0
        let end = map.sourceTime(forOutputMs: max(startMs, endMs)) ?? 0
        guard end - start > 100 else { return nil }
        let trim = TrimRegion(startMs: Int(start), endMs: Int(end))
        apply { $0.timeline.trims.append(trim) }
        selectedTrimID = trim.id
        return trim
    }

    public func trimStart(atOutputMs outputMs: Double) {
        guard let source = map.sourceTime(forOutputMs: outputMs), source > 100 else { return }
        let trim = TrimRegion(startMs: 0, endMs: Int(source))
        apply { $0.timeline.trims.append(trim) }
        selectedTrimID = trim.id
    }

    public func trimEnd(atOutputMs outputMs: Double) {
        guard let source = map.sourceTime(forOutputMs: outputMs),
              source < Double(project.source.durationMs) - 100 else { return }
        let trim = TrimRegion(startMs: Int(source), endMs: project.source.durationMs)
        apply { $0.timeline.trims.append(trim) }
        selectedTrimID = trim.id
    }

    public func deleteTrim(id: String) {
        apply { $0.timeline.trims.removeAll { $0.id == id } }
        if selectedTrimID == id { selectedTrimID = nil }
    }

    public func addSpeedRegion(fromOutputMs startMs: Double, toOutputMs endMs: Double, rate: Double) {
        let start = map.sourceTime(forOutputMs: min(startMs, endMs)) ?? 0
        let end = map.sourceTime(forOutputMs: max(startMs, endMs)) ?? 0
        guard end - start > 100 else { return }
        apply {
            $0.timeline.speeds.append(
                SpeedRegion(startMs: Int(start), endMs: Int(end), rate: rate)
            )
        }
    }

    public func removeAllTrimsAndSpeeds() {
        apply {
            $0.timeline.trims.removeAll()
            $0.timeline.speeds.removeAll()
        }
    }

    // MARK: - Annotations / layouts

    @discardableResult
    public func addTextAnnotation(atOutputMs outputMs: Double, text: String = "Your text") -> AnnotationRegion? {
        let source = map.sourceTime(forOutputMs: outputMs) ?? 0
        guard source < Double(project.source.durationMs) else { return nil }
        let start = min(Int(source), max(project.source.durationMs - 500, 0))
        let annotation = AnnotationRegion(
            type: .text,
            startMs: start,
            endMs: min(start + 3_000, project.source.durationMs),
            text: text,
            rect: NormalizedRect(x: 0.2, y: 0.74, width: 0.6, height: 0.16),
            style: AnnotationStyle(
                colorHex: "#FFFFFF",
                backgroundHex: "#00000099",
                fontSize: 36,
                isBold: true,
                alignment: "center"
            ),
            zIndex: (project.timeline.annotations.map(\.zIndex).max() ?? 0) + 1
        )
        apply { $0.timeline.annotations.append(annotation) }
        selectedAnnotationID = annotation.id
        return annotation
    }

    @discardableResult
    public func addCalloutAnnotation(
        type: AnnotationType,
        atOutputMs outputMs: Double
    ) -> AnnotationRegion? {
        guard type == .highlight || type == .blur || type == .figure else { return nil }
        let source = map.sourceTime(forOutputMs: outputMs) ?? 0
        guard source < Double(project.source.durationMs) else { return nil }
        let start = min(Int(source), max(project.source.durationMs - 500, 0))
        let annotation = AnnotationRegion(
            type: type,
            startMs: start,
            endMs: min(start + 2_500, project.source.durationMs),
            rect: NormalizedRect(x: 0.3, y: 0.36, width: 0.4, height: 0.24),
            style: AnnotationStyle(
                colorHex: type == .highlight ? "#FFD60A" : "#00C6FF",
                backgroundHex: "#00000000"
            ),
            zIndex: (project.timeline.annotations.map(\.zIndex).max() ?? 0) + 1
        )
        apply { $0.timeline.annotations.append(annotation) }
        selectedAnnotationID = annotation.id
        return annotation
    }

    public func deleteSelectedAnnotation() {
        guard let selectedAnnotationID else { return }
        apply { $0.timeline.annotations.removeAll { $0.id == selectedAnnotationID } }
        self.selectedAnnotationID = nil
    }

    public func deleteSelectedSpeed() {
        guard let selectedSpeedID else { return }
        apply { $0.timeline.speeds.removeAll { $0.id == selectedSpeedID } }
        self.selectedSpeedID = nil
    }

    public func deleteSelectedLayout() {
        guard let selectedLayoutID else { return }
        apply { $0.timeline.layouts.removeAll { $0.id == selectedLayoutID } }
        self.selectedLayoutID = nil
    }

    // MARK: - Transcript

    public func setTranscript(_ transcript: TranscriptDocument?) {
        self.transcript = transcript
        captionTrack = nil
        captionKey = nil
    }

    /// Runs on-device speech recognition over the recording's voice track and stores
    /// the result beside the project.
    public func generateTranscript(language: String? = nil) async {
        guard !isTranscribing else { return }
        isTranscribing = true
        transcriptionStatus = "Listening…"
        defer { isTranscribing = false }

        let audioPath = project.source.microphonePath ?? project.source.systemAudioPath ?? project.source.screenPath
        let audioURL = bundleURL.appendingPathComponent(audioPath)

        do {
            let document = try await TranscriptionEngine().transcribe(
                audioURL: audioURL,
                language: language
            )
            try await ProjectStore.shared.writeTranscript(document, to: bundleURL)
            setTranscript(document)
            transcriptionStatus = "\(document.words.count) words"
            errorMessage = nil

            if !project.timeline.transcriptEdits.isEmpty {
                rebuildTranscriptTrims()
            }
        } catch {
            transcriptionStatus = nil
            errorMessage = error.localizedDescription
        }
    }

    /// Turns filler-word cleanup on or off for the whole project.
    public func setRemoveFillers(_ enabled: Bool) {
        toggleTranscriptEdit(kind: .removeFiller, enabled: enabled)
    }

    /// Turns long-pause compression on or off for the whole project.
    public func setRemovePauses(_ enabled: Bool) {
        toggleTranscriptEdit(kind: .removePause, enabled: enabled)
    }

    /// Deletes one caption line's worth of speech (a sentence) from the timeline.
    public func deleteSentence(_ cue: CaptionCue) {
        guard let transcript, !transcript.words.isEmpty else { return }
        apply {
            $0.timeline.transcriptEdits.append(
                TranscriptEdit(kind: .deleteSentence, startMs: cue.startMs, endMs: cue.endMs, text: cue.text)
            )
        }
        rebuildTranscriptTrims()
    }

    public func undoTranscriptEdits() {
        apply { $0.timeline.transcriptEdits.removeAll() }
        rebuildTranscriptTrims()
    }

    /// Rebuilds generated trims from the recorded intents, preserving manual cuts.
    public func rebuildTranscriptTrims() {
        guard let transcript else { return }
        let timeline = TranscriptEditor().apply(to: project, transcript: transcript)
        apply { $0.timeline.trims = timeline.trims }
    }

    private func toggleTranscriptEdit(kind: TranscriptEditKind, enabled: Bool) {
        apply { project in
            let exists = project.timeline.transcriptEdits.contains { $0.kind == kind }
            guard enabled != exists else { return }
            if enabled {
                project.timeline.transcriptEdits.append(
                    TranscriptEdit(
                        kind: kind,
                        startMs: 0,
                        endMs: transcript?.words.last?.endMs ?? project.source.durationMs
                    )
                )
            } else {
                project.timeline.transcriptEdits.removeAll { $0.kind == kind }
            }
        }
        rebuildTranscriptTrims()
    }

    // MARK: - Saving

    public func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            await self?.saveNow()
        }
    }

    public func saveNow() async {
        do {
            try await ProjectStore.shared.save(project, to: bundleURL)
            isDirty = false
            lastSavedAt = Date()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Export

    public func export(
        to url: URL,
        format: ExportFormat,
        progress: @escaping @Sendable (ExportProgress) -> Void
    ) async throws -> URL {
        guard let compositor else { throw ExportError.metalUnavailable }
        let exporter = Exporter(compositor: compositor)
        let job = ExportJob(
            project: project,
            bundleURL: bundleURL,
            outputURL: url,
            format: format
        )
        return try await exporter.export(job: job, progress: progress)
    }

    // MARK: - Cursor track cache

    private func rebuildCursorTrackIfNeeded() {
        guard project.cursor.visible else {
            cursorTrack = nil
            return
        }
        let key = TrackKey(
            settings: project.cursor,
            durationMs: project.source.durationMs,
            sampleCount: cursorSamples.count,
            firstSampleMs: cursorSamples.first?.timeMs ?? -1,
            lastSampleMs: cursorSamples.last?.timeMs ?? -1
        )
        if key == trackKey, cursorTrack != nil { return }
        cursorTrack = CursorTrack(
            samples: cursorSamples,
            settings: project.cursor,
            durationMs: project.source.durationMs
        )
        trackKey = key
    }

    // MARK: - Caption track cache

    private func rebuildCaptionTrackIfNeeded() {
        guard project.captions.enabled,
              let transcript,
              !transcript.words.isEmpty else {
            captionTrack = nil
            captionKey = nil
            return
        }

        let key = CaptionKey(
            settings: project.captions,
            wordCount: transcript.words.count,
            firstWordMs: transcript.words.first?.startMs ?? -1,
            lastWordMs: transcript.words.last?.endMs ?? -1
        )
        if key == captionKey, captionTrack != nil { return }

        captionTrack = CaptionTrack(words: transcript.words, settings: project.captions)
        captionKey = key
    }
}
