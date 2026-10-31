import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

// MARK: - Manifest

public struct RecordingSegment: Codable, Sendable, Equatable, Identifiable {
    public var fileName: String
    public var startMs: Int
    public var durationMs: Int

    public var id: String { fileName }

    public init(fileName: String, startMs: Int, durationMs: Int) {
        self.fileName = fileName
        self.startMs = startMs
        self.durationMs = durationMs
    }
}

public struct PauseInterval: Codable, Sendable, Equatable {
    public var startMs: Int
    public var endMs: Int

    public init(startMs: Int, endMs: Int) {
        self.startMs = startMs
        self.endMs = endMs
    }

    public var durationMs: Int { max(0, endMs - startMs) }
}

public struct RecordingManifest: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        case recording
        case finished
        case failed
    }

    public var version: Int
    public var sessionID: UUID
    public var displayName: String
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var scale: Double
    public var fps: Int
    public var hasSystemAudio: Bool
    public var hasMicrophone: Bool
    public var segments: [RecordingSegment]
    public var pauses: [PauseInterval]
    public var state: State
    public var completedAt: Date?

    public init(
        sessionID: UUID,
        displayName: String,
        pixelWidth: Int,
        pixelHeight: Int,
        scale: Double,
        fps: Int,
        hasSystemAudio: Bool,
        hasMicrophone: Bool,
        segments: [RecordingSegment] = [],
        pauses: [PauseInterval] = [],
        state: State = .recording,
        completedAt: Date? = nil
    ) {
        self.version = 1
        self.sessionID = sessionID
        self.displayName = displayName
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.scale = scale
        self.fps = fps
        self.hasSystemAudio = hasSystemAudio
        self.hasMicrophone = hasMicrophone
        self.segments = segments
        self.pauses = pauses
        self.state = state
        self.completedAt = completedAt
    }

    public var durationMs: Int {
        segments.reduce(0) { $0 + max(0, $1.durationMs) }
    }
}

// MARK: - State

public enum RecordingState: Sendable, Equatable {
    case idle
    case recording
    case paused
    case finishing
    case finished(URL)
    case failed(String)
}

public struct RecordingResult: Sendable {
    public var projectBundleURL: URL
    public var manifest: RecordingManifest
    public var durationMs: Int

    public init(projectBundleURL: URL, manifest: RecordingManifest, durationMs: Int) {
        self.projectBundleURL = projectBundleURL
        self.manifest = manifest
        self.durationMs = durationMs
    }
}

public enum RecordingError: LocalizedError, Sendable {
    case notRecording
    case noVideoSegments
    case exportFailed(String)
    case projectCreationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notRecording:
            "There is no active recording to stop."
        case .noVideoSegments:
            "The recording did not produce any video."
        case .exportFailed(let reason):
            "Could not finalize the recording: \(reason)"
        case .projectCreationFailed(let reason):
            "Could not create the project: \(reason)"
        }
    }
}

// MARK: - Session

/// Coordinates capture, cursor logging, microphone, and project creation.
///
/// The session directory is self-describing: segments + `screen.manifest.json` +
/// `cursor.jsonl` + `mic.m4a`. If the app crashes, `RecordingRecovery` can rebuild
/// a project from exactly these files.
public actor RecordingSession {
    public struct Configuration: Sendable {
        public var displayName: String
        public var capture: CaptureConfiguration
        public var recordsMicrophone: Bool
        public var recordsCamera: Bool
        public var cameraDeviceID: String?
        public var hideSystemCursor: Bool
        public var recordsCursor: Bool
        public var outputDirectory: URL
        public var enableVoiceProcessing: Bool

        public init(
            displayName: String,
            capture: CaptureConfiguration,
            recordsMicrophone: Bool = true,
            recordsCamera: Bool = false,
            cameraDeviceID: String? = nil,
            hideSystemCursor: Bool = true,
            recordsCursor: Bool = true,
            outputDirectory: URL = RecordingSession.defaultOutputDirectory,
            enableVoiceProcessing: Bool = true
        ) {
            self.displayName = displayName
            self.capture = capture
            self.recordsMicrophone = recordsMicrophone
            self.recordsCamera = recordsCamera
            self.cameraDeviceID = cameraDeviceID
            self.hideSystemCursor = hideSystemCursor
            self.recordsCursor = recordsCursor
            self.outputDirectory = outputDirectory
            self.enableVoiceProcessing = enableVoiceProcessing
        }
    }

    public static var defaultOutputDirectory: URL {
        if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            return support
                .appendingPathComponent("ScreenForge", isDirectory: true)
                .appendingPathComponent("Recordings", isDirectory: true)
        }
        return FileManager.default.temporaryDirectory.appendingPathComponent("ScreenForge", isDirectory: true)
    }

    public let sessionID = UUID()
    public let sessionDirectory: URL

    private let configuration: Configuration
    private var capture: CaptureEngine?
    private var cursor: CursorRecorder?
    private var microphone: MicrophoneRecorder?
    private var camera: CameraRecorder?
    private var cameraFailure: String?
    private var startedHostSeconds: Double = 0
    private var pauseWallIntervals: [PauseInterval] = []
    private var currentPauseStartMs: Int?
    private var _state: RecordingState = .idle

    public init(configuration: Configuration) throws {
        self.configuration = configuration
        let stamp = Self.timestamp()
        let safeName = Self.sanitize(configuration.displayName)
        self.sessionDirectory = configuration.outputDirectory
            .appendingPathComponent("Sessions", isDirectory: true)
            .appendingPathComponent("\(stamp) \(safeName)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sessionDirectory,
            withIntermediateDirectories: true
        )
    }

    public var state: RecordingState { _state }

    // MARK: Lifecycle

    public func start() async throws {
        guard case .idle = _state else { return }

        let filter: SCContentFilter
        if let windowID = configuration.capture.windowID {
            filter = try await CaptureEngine.makeWindowFilter(windowID: windowID)
        } else {
            filter = try await CaptureEngine.makeDisplayFilter(displayID: configuration.capture.displayID)
        }

        startedHostSeconds = CACurrentMediaTime()

        // Cursor first: it must cover the entire take, including the first frames.
        if configuration.recordsCursor {
            let cursorRecorder = CursorRecorder()
            do {
                try cursorRecorder.start(
                    configuration: CursorRecorder.Configuration(
                        displayID: configuration.capture.displayID,
                        hideSystemCursor: configuration.hideSystemCursor,
                        normalizedBounds: configuration.capture.cursorBounds
                    ),
                    outputURL: sessionDirectory.appendingPathComponent(ProjectBundleLayout.cursorFileName)
                )
                cursor = cursorRecorder
            } catch {
                throw error
            }
        }

        if configuration.recordsMicrophone {
            let mic = MicrophoneRecorder()
            do {
                try mic.start(
                    url: sessionDirectory.appendingPathComponent("mic.m4a"),
                    enableVoiceProcessing: configuration.enableVoiceProcessing
                )
                microphone = mic
            } catch {
                _ = cursor?.stop()
                cursor = nil
                throw error
            }
        }

        // Camera capture is best effort: a busy camera must not lose the screen take.
        if configuration.recordsCamera, CameraRecorder.isAuthorized {
            let recorder = CameraRecorder()
            do {
                try recorder.start(
                    deviceID: configuration.cameraDeviceID,
                    url: sessionDirectory.appendingPathComponent("webcam.mov")
                )
                camera = recorder
            } catch {
                cameraFailure = error.localizedDescription
                NSLog("Camera capture unavailable: \(error.localizedDescription)")
            }
        }

        let engine = CaptureEngine()
        capture = engine
        do {
            try await engine.start(
                filter: filter,
                configuration: configuration.capture,
                outputURL: sessionDirectory.appendingPathComponent("screen.mov")
            ) { [weak self] error in
                guard let error else { return }
                Task { await self?.handleUnexpectedStop(error) }
            }
        } catch {
            microphone?.stop()
            microphone = nil
            _ = cursor?.stop()
            cursor = nil
            throw error
        }

        _state = .recording
    }

    public func pause() async {
        guard case .recording = _state else { return }
        currentPauseStartMs = elapsedMs()
        await capture?.pause(at: CMTime(seconds: CACurrentMediaTime(), preferredTimescale: 600))
        _state = .paused
    }

    public func resume() async {
        guard case .paused = _state, let start = currentPauseStartMs else { return }
        pauseWallIntervals.append(PauseInterval(startMs: start, endMs: elapsedMs()))
        currentPauseStartMs = nil
        _state = .recording
    }

    public func stop() async throws -> RecordingResult {
        guard _state == .recording || _state == .paused else {
            throw RecordingError.notRecording
        }
        _state = .finishing

        let captureEngine = capture
        let cursorRecorder = cursor
        let micRecorder = microphone
        let cameraRecorder = camera

        await captureEngine?.stop()
        let cursorSamples = cursorRecorder?.stop() ?? []
        micRecorder?.stop()
        // Must finish before the finalizer reads webcam.mov.
        await cameraRecorder?.stop()

        if let start = currentPauseStartMs {
            pauseWallIntervals.append(PauseInterval(startMs: start, endMs: elapsedMs()))
            currentPauseStartMs = nil
        }

        let manifest = loadManifest() ?? captureEngine.map { engine in
            RecordingManifest(
                sessionID: sessionID,
                displayName: configuration.displayName,
                pixelWidth: configuration.capture.pixelWidth,
                pixelHeight: configuration.capture.pixelHeight,
                scale: 2,
                fps: configuration.capture.fps,
                hasSystemAudio: configuration.capture.capturesSystemAudio,
                hasMicrophone: configuration.recordsMicrophone,
                segments: engine.segments,
                state: .finished
            )
        }

        guard let manifest else {
            _state = .failed("Missing recording manifest")
            throw RecordingError.noVideoSegments
        }

        do {
            let result = try await RecordingFinalizer.makeProject(
                sessionDirectory: sessionDirectory,
                manifest: manifest,
                cursorSamples: cursorSamples,
                pauses: pauseWallIntervals,
                outputDirectory: configuration.outputDirectory,
                projectName: configuration.displayName
            )
            _state = .finished(result.projectBundleURL)
            return result
        } catch {
            _state = .failed(error.localizedDescription)
            throw error
        }
    }

    public func cancel() async {
        _state = .finishing
        await capture?.stop()
        _ = cursor?.stop()
        microphone?.stop()
        await camera?.stop()
        capture = nil
        cursor = nil
        microphone = nil
        camera = nil
        try? FileManager.default.removeItem(at: sessionDirectory)
        _state = .idle
    }

    // MARK: Internals

    private func elapsedMs() -> Int {
        Int((CACurrentMediaTime() - startedHostSeconds) * 1000)
    }

    private func handleUnexpectedStop(_ error: Error) async {
        if case .finishing = _state { return }
        _state = .failed(error.localizedDescription)
        _ = cursor?.stop()
        cursor = nil
        microphone?.stop()
        microphone = nil
    }

    private func loadManifest() -> RecordingManifest? {
        let url = sessionDirectory.appendingPathComponent("screen.manifest.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(RecordingManifest.self, from: data)
    }

    // MARK: Naming

    static func sanitize(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        let cleaned = name.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "-" }
        let result = String(cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? "Recording" : String(result.prefix(60))
    }

    static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter.string(from: Date())
    }
}

// MARK: - Finalizer

/// Concatenates segments and writes a portable `.sforge` project.
public enum RecordingFinalizer {
    public static func makeProject(
        sessionDirectory: URL,
        manifest: RecordingManifest,
        cursorSamples: [CursorSample],
        pauses: [PauseInterval],
        outputDirectory: URL,
        projectName: String
    ) async throws -> RecordingResult {
        let mediaDirectory = sessionDirectory
        let destination = outputDirectory
            .appendingPathComponent(
                "\(RecordingSession.sanitize(projectName)) \(RecordingSession.timestamp()).\(ProjectBundleLayout.fileExtension)",
                isDirectory: true
            )

        let store = ProjectStore.shared
        try await store.createBundle(at: destination)

        let composedURL = destination
            .appendingPathComponent(ProjectBundleLayout.mediaDirectory, isDirectory: true)
            .appendingPathComponent("screen.mov")

        let durationSeconds = try await MediaComposition.concatenate(
            segments: manifest.segments,
            directory: mediaDirectory,
            destination: composedURL
        )

        var microphonePath: String?
        let micURL = mediaDirectory.appendingPathComponent("mic.m4a")
        if FileManager.default.fileExists(atPath: micURL.path) {
            microphonePath = try await store.importMedia(
                from: micURL,
                into: destination,
                preferredName: "mic.m4a"
            )
        }

        var webcamPath: String?
        let webcamURL = mediaDirectory.appendingPathComponent("webcam.mov")
        if FileManager.default.fileExists(atPath: webcamURL.path) {
            webcamPath = try await store.importMedia(
                from: webcamURL,
                into: destination,
                preferredName: "webcam.mov"
            )
        }

        let rebased = rebaseCursor(samples: cursorSamples, pauses: pauses)
        try await store.writeCursor(rebased, to: destination)

        let source = SourceInfo(
            screenPath: "\(ProjectBundleLayout.mediaDirectory)/screen.mov",
            webcamPath: webcamPath,
            systemAudioPath: nil,
            microphonePath: microphonePath,
            durationMs: Int((durationSeconds * 1000).rounded()),
            pixelWidth: manifest.pixelWidth,
            pixelHeight: manifest.pixelHeight,
            scale: manifest.scale,
            displayName: manifest.displayName,
            cursorCaptureMode: .syntheticOverlay
        )

        let project = ScreenForgeProject(
            source: source,
            canvas: .default,
            camera: CameraSettings(enabled: webcamPath != nil),
            timeline: .empty,
            cursor: .default,
            captions: .default,
            export: .default
        )
        try await store.save(project, to: destination)

        // The finished project owns copies of everything it needs; drop the session so
        // recording scratch space does not accumulate.
        try? FileManager.default.removeItem(at: sessionDirectory)

        return RecordingResult(
            projectBundleURL: destination,
            manifest: manifest,
            durationMs: source.durationMs
        )
    }

    /// Drops samples recorded during pauses and shifts later samples left.
    static func rebaseCursor(samples: [CursorSample], pauses: [PauseInterval]) -> [CursorSample] {
        guard !pauses.isEmpty else { return samples }
        let sorted = pauses.sorted { $0.startMs < $1.startMs }
        var result: [CursorSample] = []
        result.reserveCapacity(samples.count)

        for var sample in samples {
            var shift = 0
            var insidePause = false
            for pause in sorted {
                if sample.timeMs >= pause.endMs {
                    shift += pause.durationMs
                } else if sample.timeMs >= pause.startMs {
                    insidePause = true
                    break
                }
            }
            guard !insidePause else { continue }
            sample.timeMs = max(0, sample.timeMs - shift)
            result.append(sample)
        }
        return result
    }
}

// MARK: - Composition

public enum MediaComposition {
    public enum CompositionError: LocalizedError {
        case noSegments
        case exportFailed(String)

        public var errorDescription: String? {
            switch self {
            case .noSegments: "The recording has no usable video segments."
            case .exportFailed(let reason): "Video composition failed: \(reason)"
            }
        }
    }

    /// Concatenates standalone `.mov` segments into one file. Returns its duration.
    ///
    /// Each segment was written with `startSession(atSourceTime:)` anchored to the host
    /// clock, so its tracks start at that anchor rather than at zero. Insert the track's
    /// own time range (not `asset.duration`, which is an absolute end time) to avoid
    /// writing minutes of empty time per segment.
    public static func concatenate(
        segments: [RecordingSegment],
        directory: URL,
        destination: URL
    ) async throws -> Double {
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw CompositionError.exportFailed("Could not create a video track")
        }

        var audioTrack: AVMutableCompositionTrack?
        var cursor = CMTime.zero
        var inserted = 0

        for segment in segments {
            let url = directory.appendingPathComponent(segment.fileName)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let asset = AVURLAsset(url: url)

            guard let video = try? await asset.loadTracks(withMediaType: .video).first else {
                continue
            }
            let videoRange = try? await video.load(.timeRange)
            guard let videoRange, videoRange.duration > .zero else { continue }

            do {
                try videoTrack.insertTimeRange(videoRange, of: video, at: cursor)
                inserted += 1
            } catch {
                NSLog("Skipping segment \(segment.fileName): \(error.localizedDescription)")
                continue
            }

            if let audio = try? await asset.loadTracks(withMediaType: .audio).first,
               let audioRange = try? await audio.load(.timeRange),
               audioRange.duration > .zero {
                if audioTrack == nil {
                    audioTrack = composition.addMutableTrack(
                        withMediaType: .audio,
                        preferredTrackID: kCMPersistentTrackID_Invalid
                    )
                }
                // Keep the segment's internal audio/video offset, then clip to the video.
                let offset = CMTimeSubtract(audioRange.start, videoRange.start)
                let audioStart = CMTimeMaximum(.zero, CMTimeAdd(cursor, offset))
                let available = CMTimeSubtract(
                    CMTimeAdd(cursor, videoRange.duration),
                    audioStart
                )
                let audioDuration = CMTimeMinimum(audioRange.duration, available)
                if audioDuration > .zero {
                    try? audioTrack?.insertTimeRange(
                        CMTimeRange(start: audioRange.start, duration: audioDuration),
                        of: audio,
                        at: audioStart
                    )
                }
            }

            cursor = CMTimeAdd(cursor, videoRange.duration)
        }

        guard inserted > 0 else { throw CompositionError.noSegments }
        let totalDuration = cursor

        guard let exporter = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetPassthrough
        ) else {
            throw CompositionError.exportFailed("Could not create an export session")
        }

        if FileManager.default.fileExists(atPath: destination.path) {
            try? FileManager.default.removeItem(at: destination)
        }
        exporter.outputURL = destination
        exporter.outputFileType = .mov
        exporter.shouldOptimizeForNetworkUse = false

        do {
            try await export(exporter)
        } catch {
            // Passthrough can reject segments whose encoder parameters differ; fall back
            // to a re-encode instead of losing the recording.
            guard let fallback = AVAssetExportSession(
                asset: composition,
                presetName: AVAssetExportPresetHEVCHighestQuality
            ) else {
                throw error
            }
            if FileManager.default.fileExists(atPath: destination.path) {
                try? FileManager.default.removeItem(at: destination)
            }
            fallback.outputURL = destination
            fallback.outputFileType = .mov
            fallback.shouldOptimizeForNetworkUse = false
            try await export(fallback)
        }

        return CMTimeGetSeconds(totalDuration)
    }

    private static func export(_ session: AVAssetExportSession) async throws {
        nonisolated(unsafe) let session = session
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            session.exportAsynchronously {
                switch session.status {
                case .completed:
                    continuation.resume()
                case .cancelled:
                    continuation.resume(throwing: CompositionError.exportFailed("Export cancelled"))
                default:
                    continuation.resume(
                        throwing: CompositionError.exportFailed(
                            session.error?.localizedDescription ?? "Unknown export error"
                        )
                    )
                }
            }
        }
    }
}
