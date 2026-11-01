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
    @Published public var selectedMarkerID: String?
    @Published public var selectedAudioClipID: String?
    @Published public private(set) var isDirty = false
    @Published public private(set) var canUndo = false
    @Published public private(set) var canRedo = false
    @Published public private(set) var lastSavedAt: Date?
    @Published public private(set) var isTranscribing = false
    @Published public private(set) var transcriptionStatus: String?
    @Published public private(set) var isAnalyzing = false
    @Published public private(set) var analysisStatus: String?
    @Published public private(set) var isRecordingVoiceover = false
    @Published public private(set) var voiceoverLevel: Float = 0
    @Published public private(set) var presets: [ProjectPreset] = []
    @Published public private(set) var isScanningSensitiveData = false
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
    private var voiceoverRecorder: MicrophoneRecorder?
    private var voiceoverStartOutputMs: Double = 0
    private var voiceoverScratchURL: URL?

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
        Task { await self.refreshPresets() }
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

    public var selectedMarker: TimelineMarker? {
        guard let selectedMarkerID else { return nil }
        return project.timeline.markers.first { $0.id == selectedMarkerID }
    }

    public var selectedAudioClip: AudioClip? {
        guard let selectedAudioClipID else { return nil }
        return project.timeline.audioClips.first { $0.id == selectedAudioClipID }
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

    // MARK: - Markers

    @discardableResult
    public func addMarker(
        atOutputMs outputMs: Double,
        label: String = "Marker",
        kind: TimelineMarkerKind = .marker
    ) -> TimelineMarker? {
        let duration = max(outputDurationMs, 0)
        guard duration > 0 else { return nil }
        let time = Int(min(max(outputMs, 0), duration))
        let marker = TimelineMarker(timeMs: time, label: label, kind: kind)
        apply { $0.timeline.markers.append(marker) }
        selectedMarkerID = marker.id
        return marker
    }

    public func deleteSelectedMarker() {
        guard let selectedMarkerID else { return }
        apply { $0.timeline.markers.removeAll { $0.id == selectedMarkerID } }
        self.selectedMarkerID = nil
    }

    public func deleteMarker(id: String) {
        apply { $0.timeline.markers.removeAll { $0.id == id } }
        if selectedMarkerID == id { selectedMarkerID = nil }
    }

    /// Converts every plain marker into a chapter cue. Chapters are exported as
    /// metadata by tools that understand chapters; the editor still shows them on
    /// the marker lane.
    public func promoteMarkersToChapters() {
        guard !project.timeline.markers.isEmpty else { return }
        apply { project in
            project.timeline.markers = project.timeline.markers.map { marker in
                var copy = marker
                copy.kind = .chapter
                return copy
            }
        }
    }

    // MARK: - Audio clips

    /// Copies an audio file into the project bundle and places it at output time.
    @discardableResult
    public func importAudio(
        from url: URL,
        kind: AudioClipKind,
        atOutputMs outputMs: Double = 0
    ) async -> AudioClip? {
        do {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            let assetMs = max(Int((CMTimeGetSeconds(duration) * 1000).rounded()), 0)
            guard assetMs > 50 else {
                errorMessage = "That audio file is empty."
                return nil
            }

            let existing = Set(project.timeline.audioClips.map { ($0.path as NSString).lastPathComponent })
            let base = url.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: " ", with: "-")
                .lowercased()
            var candidate = "\(kind.rawValue)-\(base).\(url.pathExtension.lowercased())"
            var counter = 2
            while existing.contains(candidate) {
                candidate = "\(kind.rawValue)-\(base)-\(counter).\(url.pathExtension.lowercased())"
                counter += 1
            }

            let storedPath = try await ProjectStore.shared.importMedia(
                from: url,
                into: bundleURL,
                preferredName: candidate
            )
            let start = Int(min(max(outputMs, 0), max(outputDurationMs, 0)))
            let available = max(Int(outputDurationMs) - start, assetMs)
            let length = min(assetMs, max(available, 50))
            let clip = AudioClip(
                kind: kind,
                path: storedPath,
                label: base.replacingOccurrences(of: "-", with: " ").capitalized,
                startMs: start,
                durationMs: length,
                volume: kind == .music ? 0.8 : 1,
                fadeInMs: kind == .music ? 800 : 0,
                fadeOutMs: kind == .music ? 1_200 : 0,
                loops: false
            )
            apply { $0.timeline.audioClips.append(clip) }
            selectedAudioClipID = clip.id
            errorMessage = nil
            return clip
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    public func addGeneratedTone(
        kind: AudioClipKind = .soundEffect,
        atOutputMs outputMs: Double,
        durationMs: Int = 600
    ) async -> AudioClip? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenForge-tone-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }

        let sampleRate = 48_000.0
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let file = try? AVAudioFile(
                forWriting: url,
                settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: sampleRate,
                    AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true
                ],
                commonFormat: .pcmFormatFloat32,
                interleaved: false
              ) else {
            return nil
        }

        let frames = AVAudioFrameCount(Double(durationMs) / 1000 * sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        if let channel = buffer.floatChannelData?[0] {
            for index in 0..<Int(frames) {
                let t = Double(index) / sampleRate
                let envelope = max(0, 1 - t / max(Double(durationMs) / 1000, 0.01))
                channel[index] = Float(sin(2 * .pi * 660 * t) * 0.18 * envelope)
            }
        }
        try? file.write(from: buffer)
        return await importAudio(from: url, kind: kind, atOutputMs: outputMs)
    }

    public func deleteSelectedAudioClip() {
        guard let selectedAudioClipID else { return }
        apply { $0.timeline.audioClips.removeAll { $0.id == selectedAudioClipID } }
        self.selectedAudioClipID = nil
    }

    public func deleteAudioClip(id: String) {
        apply { $0.timeline.audioClips.removeAll { $0.id == id } }
        if selectedAudioClipID == id { selectedAudioClipID = nil }
    }

    // MARK: - Analysis

    /// Detects speech gaps in the microphone track and stores the ranges with the
    /// project. The camera can then fade out while nobody is speaking.
    public func detectSilence() async {
        guard !isAnalyzing else { return }
        guard let micPath = project.source.microphonePath else {
            notice = "Silence detection needs a microphone track. This project has none."
            return
        }
        isAnalyzing = true
        analysisStatus = "Listening for silence…"
        defer { isAnalyzing = false }

        do {
            let url = bundleURL.appendingPathComponent(micPath)
            let ranges = try await SilenceDetector.detect(in: url)
            apply { project in
                project.analysis.silenceRanges = ranges
                if !ranges.isEmpty {
                    project.camera.hideDuringSilence = true
                }
            }
            analysisStatus = ranges.isEmpty
                ? "No silence found"
                : "\(ranges.count) silent range\(ranges.count == 1 ? "" : "s")"
        } catch {
            analysisStatus = nil
            errorMessage = error.localizedDescription
        }
    }

    /// Samples the webcam with Vision and stores face centers for reframing.
    public func analyzeFaces() async {
        guard !isAnalyzing else { return }
        guard let webcamPath = project.source.webcamPath else {
            notice = "Face tracking needs a camera track. This project has none."
            return
        }
        isAnalyzing = true
        analysisStatus = "Finding faces…"
        defer { isAnalyzing = false }

        do {
            let url = bundleURL.appendingPathComponent(webcamPath)
            let samples = try await FaceDetector.detect(in: url)
            apply { project in
                project.analysis.faceSamples = samples
                if !samples.isEmpty {
                    project.camera.faceTracking = true
                }
            }
            analysisStatus = samples.isEmpty
                ? "No face found"
                : "\(samples.count) face samples"
        } catch {
            analysisStatus = nil
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Voiceover

    /// Starts recording a voiceover from the microphone at the current output time.
    /// Call `stopVoiceover` to convert it and place it on the audio lane.
    public func startVoiceover(atOutputMs outputMs: Double) async {
        guard !isRecordingVoiceover else { return }
        let granted = await MicrophoneRecorder.requestPermission()
        guard granted else {
            errorMessage = MicrophoneError.permissionDenied.errorDescription
            return
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenForge-voiceover-\(UUID().uuidString).caf")
        let recorder = MicrophoneRecorder()
        do {
            try recorder.start(url: url, enableVoiceProcessing: true)
            voiceoverRecorder = recorder
            voiceoverScratchURL = url
            voiceoverStartOutputMs = min(max(outputMs, 0), max(outputDurationMs, 0))
            isRecordingVoiceover = true
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    public func stopVoiceover() async -> AudioClip? {
        guard let recorder = voiceoverRecorder else { return nil }
        recorder.stop()
        voiceoverRecorder = nil
        isRecordingVoiceover = false
        voiceoverLevel = 0

        guard let scratch = voiceoverScratchURL else { return nil }
        voiceoverScratchURL = nil
        defer { try? FileManager.default.removeItem(at: scratch) }

        let converted = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenForge-voiceover-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: converted) }

        do {
            try await AudioTranscoder.toM4A(input: scratch, output: converted)
            return await importAudio(
                from: converted,
                kind: .voiceover,
                atOutputMs: voiceoverStartOutputMs
            )
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    public func cancelVoiceover() {
        voiceoverRecorder?.stop()
        voiceoverRecorder = nil
        isRecordingVoiceover = false
        voiceoverLevel = 0
        if let scratch = voiceoverScratchURL {
            try? FileManager.default.removeItem(at: scratch)
        }
        voiceoverScratchURL = nil
    }

    // MARK: - Background image

    /// Imports a custom background image and switches the canvas to it.
    public func importBackgroundImage(from url: URL) async {
        do {
            let name = "background-\(UUID().uuidString.prefix(8)).\(url.pathExtension.lowercased())"
            let path = try await ProjectStore.shared.importMedia(
                from: url,
                into: bundleURL,
                preferredName: name
            )
            apply { project in
                project.canvas.background = BackgroundStyle(
                    kind: .image,
                    identifier: "custom",
                    colors: project.canvas.background.colors,
                    imagePath: path
                )
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Advanced analysis / looks

    /// Segments the camera track and stores person-matte PNGs with the project.
    public func generatePersonMatte() async {
        guard !isAnalyzing else { return }
        guard let webcamPath = project.source.webcamPath else {
            notice = "Person cutout needs a camera track. This project has none."
            return
        }
        isAnalyzing = true
        analysisStatus = "Building person matte…"
        defer { isAnalyzing = false }

        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenForge-matte-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        do {
            let url = bundleURL.appendingPathComponent(webcamPath)
            let result = try await PersonMatteDetector.detect(in: url, outputDirectory: temp)
            guard !result.frames.isEmpty else {
                analysisStatus = "No person found in the camera track"
                return
            }

            var frames: [PersonMaskFrame] = []
            for frame in result.frames {
                let source = temp.appendingPathComponent(frame.fileName)
                let stored = try await ProjectStore.shared.importMedia(
                    from: source,
                    into: bundleURL,
                    preferredName: "person-mask-\(frame.fileName)"
                )
                frames.append(PersonMaskFrame(timeMs: frame.timeMs, path: stored))
            }

            apply { project in
                project.analysis.personMasks = frames
                project.camera.enabled = true
                project.camera.cutout = true
            }
            analysisStatus = "\(frames.count) matte frames"
            errorMessage = nil
        } catch {
            analysisStatus = nil
            errorMessage = error.localizedDescription
        }
    }

    /// Scans the screen recording for faces and sensitive text, then adds masks.
    public func scanForSensitiveData(
        detectText: Bool = true,
        detectFaces: Bool = true,
        customPhrases: [String] = [],
        expandPoints: Double = 8
    ) async {
        guard !isScanningSensitiveData else { return }
        isScanningSensitiveData = true
        analysisStatus = "Scanning for sensitive data…"
        defer { isScanningSensitiveData = false }

        do {
            let url = bundleURL.appendingPathComponent(project.source.screenPath)
            var options = SensitiveDataScanner.Options()
            options.detectText = detectText
            options.detectFaces = detectFaces
            options.customPhrases = customPhrases
            options.expandPoints = expandPoints
            let detections = try await SensitiveDataScanner.scan(in: url, options: options)

            apply { project in
                project.timeline.annotations.removeAll { $0.generated == true }
                var z = (project.timeline.annotations.map(\.zIndex).max() ?? 0)
                for detection in detections {
                    z += 1
                    let rect = NormalizedRect(
                        x: Double(detection.rect.minX),
                        y: Double(detection.rect.minY),
                        width: Double(detection.rect.width),
                        height: Double(detection.rect.height)
                    ).clamped()
                    let mask = MaskSettings(
                        kind: .blur,
                        intensity: detection.kind == .face ? 26 : 20,
                        blockSize: 14,
                        cornerRadius: 6
                    )
                    let style = AnnotationStyle(
                        colorHex: detection.kind == .face ? "#64D2FF" : "#FFD60A",
                        backgroundHex: "#00000000"
                    )
                    project.timeline.annotations.append(
                        AnnotationRegion(
                            type: .blur,
                            startMs: detection.startMs,
                            endMs: detection.endMs,
                            text: detection.text,
                            rect: rect,
                            style: style,
                            zIndex: z,
                            mask: mask,
                            generated: true
                        )
                    )
                }
            }
            analysisStatus = detections.isEmpty
                ? "No sensitive regions found"
                : "\(detections.count) masks added"
            errorMessage = nil
        } catch {
            analysisStatus = nil
            errorMessage = error.localizedDescription
        }
    }

    public func clearGeneratedMasks() {
        apply { $0.timeline.annotations.removeAll { $0.generated == true } }
        analysisStatus = nil
    }

    // MARK: - Wallpapers / LUTs / clicks

    /// Renders a built-in wallpaper and switches the canvas to it.
    public func applyWallpaper(_ preset: WallpaperPreset) async {
        do {
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("ScreenForge-wallpapers", isDirectory: true)
            let rendered = try WallpaperLibrary.write(preset, to: temp)
            let path = try await ProjectStore.shared.importMedia(
                from: rendered,
                into: bundleURL,
                preferredName: "wallpaper-\(preset.id).png"
            )
            apply { project in
                project.canvas.background = BackgroundStyle(
                    kind: .image,
                    identifier: preset.id,
                    colors: preset.colors,
                    imagePath: path
                )
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Imports a `.cube` LUT and applies it to the screen layer.
    public func importLUT(from url: URL) async {
        do {
            _ = try CubeLUT(contentsOf: url)
            let path = try await ProjectStore.shared.importMedia(
                from: url,
                into: bundleURL,
                preferredName: "grade-\(UUID().uuidString.prefix(8)).cube"
            )
            apply { project in
                project.canvas.grade.lutPath = path
                project.canvas.grade.preset = .none
                project.canvas.grade.intensity = 1
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func clearLUT() {
        apply { project in
            project.canvas.grade.lutPath = nil
            project.canvas.grade.preset = .none
        }
    }

    /// Builds a click-sound track from cursor telemetry and adds it as an audio clip.
    public func addClickSounds(packID: String) async {
        guard !cursorSamples.isEmpty else {
            notice = "Click sounds need cursor telemetry in this recording."
            return
        }
        let pack = ClickSoundLibrary.pack(id: packID) ?? ClickSoundLibrary.packs[0]
        do {
            let result = try ClickTrackBuilder.build(
                cursorSamples: cursorSamples,
                map: map,
                outputDurationMs: Int(outputDurationMs),
                pack: pack
            )
            defer { try? FileManager.default.removeItem(at: result.url) }
            let path = try await ProjectStore.shared.importMedia(
                from: result.url,
                into: bundleURL,
                preferredName: "clicks-\(pack.id).caf"
            )
            let clip = AudioClip(
                kind: .soundEffect,
                path: path,
                label: "Click sounds",
                startMs: 0,
                durationMs: Int(outputDurationMs),
                volume: project.audio.clickSoundVolume,
                muted: false
            )
            apply { project in
                project.timeline.audioClips.removeAll { $0.label == "Click sounds" }
                project.timeline.audioClips.append(clip)
                project.cursor.clickSound = pack.id
            }
            selectedAudioClipID = clip.id
            notice = "Added \(result.clickCount) click sounds"
            errorMessage = nil
        } catch {
            errorMessage = "Could not build click sounds from this recording."
        }
    }

    // MARK: - Presets

    public func refreshPresets() async {
        presets = await ProjectPresetStore.shared.list()
    }

    public func savePreset(named name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let preset = ProjectPreset(name: trimmed, project: project)
        do {
            try await ProjectPresetStore.shared.save(preset)
            await refreshPresets()
            notice = "Saved preset “\(trimmed)”"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func applyPreset(_ preset: ProjectPreset) {
        apply { preset.apply(to: &$0) }
        notice = "Applied preset “\(preset.name)”"
    }

    public func deletePreset(_ preset: ProjectPreset) async {
        await ProjectPresetStore.shared.delete(id: preset.id)
        await refreshPresets()
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
