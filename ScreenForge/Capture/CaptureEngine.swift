import AVFoundation
import CoreMedia
import CoreGraphics
import Foundation
import ScreenCaptureKit
import VideoToolbox

// MARK: - Configuration

public struct CaptureConfiguration: Sendable, Equatable {
    public var displayID: CGDirectDisplayID
    public var windowID: CGWindowID?
    public var fps: Int
    public var capturesSystemAudio: Bool
    public var capturesMicrophone: Bool
    public var showsCursor: Bool
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// Screen-space rectangle used to normalize cursor telemetry. Defaults to the display.
    public var cursorBounds: CGRect?
    /// Seconds per crash-safe segment.
    public var segmentDuration: TimeInterval
    public var codec: VideoCodec

    public init(
        displayID: CGDirectDisplayID,
        windowID: CGWindowID? = nil,
        fps: Int = 60,
        capturesSystemAudio: Bool = true,
        capturesMicrophone: Bool = false,
        showsCursor: Bool = false,
        pixelWidth: Int,
        pixelHeight: Int,
        cursorBounds: CGRect? = nil,
        segmentDuration: TimeInterval = 10,
        codec: VideoCodec = .hevc
    ) {
        self.displayID = displayID
        self.windowID = windowID
        self.fps = fps
        self.capturesSystemAudio = capturesSystemAudio
        self.capturesMicrophone = capturesMicrophone
        self.showsCursor = showsCursor
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.cursorBounds = cursorBounds
        self.segmentDuration = segmentDuration
        self.codec = codec
    }
}

public enum CaptureError: LocalizedError, Sendable {
    case screenRecordingDenied
    case displayNotFound(CGDirectDisplayID)
    case windowNotFound(CGWindowID)
    case writerSetupFailed(String)
    case streamFailed(String)
    case alreadyRunning

    public var errorDescription: String? {
        switch self {
        case .screenRecordingDenied:
            "Screen Recording permission is required. Enable ScreenForge in System Settings → Privacy & Security → Screen & System Audio Recording."
        case .displayNotFound(let id):
            "Display \(id) is no longer available."
        case .windowNotFound(let id):
            "Window \(id) is no longer available."
        case .writerSetupFailed(let reason):
            "Could not start recording: \(reason)"
        case .streamFailed(let reason):
            "Capture stopped: \(reason)"
        case .alreadyRunning:
            "A recording is already in progress."
        }
    }
}

// MARK: - Capture engine

/// Owns the ScreenCaptureKit stream and the segmented writer.
///
/// Preview is intentionally a separate, lower-cost `SCStream` in the UI layer; this
/// engine is optimized for lossless recording and crash safety.
public final class CaptureEngine: NSObject, SCStreamOutput, @unchecked Sendable {
    public typealias StopHandler = @Sendable (Error?) -> Void

    private let sampleQueue = DispatchQueue(label: "studio.screenforge.capture.samples", qos: .userInitiated)
    private let stateLock = NSLock()

    private var stream: SCStream?
    private var writer: SegmentedVideoWriter?
    private var configuration: CaptureConfiguration?
    private var isRunning = false
    private var onStop: StopHandler?
    private var firstPresentationTime: CMTime?

    public override init() {
        super.init()
    }

    // MARK: Permissions

    public static func hasScreenRecordingPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    public static func requestScreenRecordingPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    // MARK: Content

    public static func availableDisplays() async throws -> [SCDisplay] {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true).displays
    }

    public static func availableWindows() async throws -> [SCWindow] {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true).windows
    }

    public static func makeDisplayFilter(displayID: CGDirectDisplayID) async throws -> SCContentFilter {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.displayNotFound(displayID)
        }
        let excluded = content.applications.filter {
            $0.bundleIdentifier == Bundle.main.bundleIdentifier
        }
        return SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
    }

    public static func makeWindowFilter(windowID: CGWindowID) async throws -> SCContentFilter {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw CaptureError.windowNotFound(windowID)
        }
        return SCContentFilter(desktopIndependentWindow: window)
    }

    // MARK: Lifecycle

    /// Runs a short critical section. Kept synchronous so `NSLock` remains usable
    /// from the async lifecycle methods above it.
    private func withState<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    /// Starts capture to `url` (a `.mov`). Segments are written beside it using the
    /// same basename with `-0001` suffixes; a manifest is maintained by the writer.
    public func start(
        filter: SCContentFilter,
        configuration: CaptureConfiguration,
        outputURL: URL,
        onStop: @escaping StopHandler
    ) async throws {
        let alreadyRunning = withState { isRunning }
        guard !alreadyRunning else {
            throw CaptureError.alreadyRunning
        }
        withState {
            isRunning = true
            self.configuration = configuration
            self.onStop = onStop
        }

        let writer: SegmentedVideoWriter
        do {
            writer = try SegmentedVideoWriter(
                outputURL: outputURL,
                width: configuration.pixelWidth,
                height: configuration.pixelHeight,
                fps: configuration.fps,
                codec: configuration.codec,
                segmentDuration: configuration.segmentDuration,
                includesAudio: configuration.capturesSystemAudio
            )
        } catch {
            withState { isRunning = false }
            throw error
        }
        withState { self.writer = writer }

        let streamConfig = SCStreamConfiguration()
        streamConfig.width = configuration.pixelWidth
        streamConfig.height = configuration.pixelHeight
        streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(configuration.fps))
        streamConfig.pixelFormat = kCVPixelFormatType_32BGRA
        streamConfig.queueDepth = 6
        streamConfig.showsCursor = configuration.showsCursor
        streamConfig.capturesAudio = configuration.capturesSystemAudio
        streamConfig.excludesCurrentProcessAudio = true
        streamConfig.colorSpaceName = CGColorSpace.sRGB
        if configuration.capturesSystemAudio {
            streamConfig.sampleRate = 48_000
            streamConfig.channelCount = 2
        }
        if #available(macOS 15.0, *), configuration.capturesMicrophone {
            streamConfig.captureMicrophone = true
        }

        let stream = SCStream(filter: filter, configuration: streamConfig, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        if configuration.capturesSystemAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        }

        do {
            try await stream.startCapture()
        } catch {
            withState { isRunning = false }
            await writer.finish()
            throw CaptureError.streamFailed(error.localizedDescription)
        }

        withState { self.stream = stream }
    }

    public func stop() async {
        let snapshot = withState { () -> (SCStream?, SegmentedVideoWriter?, Bool) in
            let result = (self.stream, self.writer, isRunning)
            self.stream = nil
            self.writer = nil
            isRunning = false
            return result
        }
        let (stream, writer, wasRunning) = snapshot

        guard wasRunning else { return }
        do {
            try await stream?.stopCapture()
        } catch {
            // Stream may already be stopped; writer finalization is what matters.
        }
        await writer?.finish()
        withState { self.onStop }?(nil)
    }

    /// Pauses without ending the recording: rotates to a new segment and marks the gap.
    public func pause(at hostTime: CMTime) async {
        let writer = withState { self.writer }
        writer?.rotate(at: hostTime, reason: .pause)
    }

    public func resume() {
        // Segments are created lazily on the next sample; no explicit work needed.
    }

    public var segments: [RecordingSegment] {
        withState { self.writer }?.manifestSnapshot().segments ?? []
    }

    // MARK: SCStreamOutput

    @objc public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid, let writer = withState({ self.writer }) else { return }
        switch type {
        case .screen:
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let statusRaw = attachments.first?[.status] as? Int,
                  statusRaw == SCFrameStatus.complete.rawValue
            else { return }

            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            withState {
                if firstPresentationTime == nil {
                    firstPresentationTime = pts
                }
            }
            writer.appendVideo(sampleBuffer)
        case .audio:
            writer.appendAudio(sampleBuffer)
        default:
            break
        }
    }
}

// MARK: - SCStreamDelegate

extension CaptureEngine: SCStreamDelegate {
    @objc public func stream(_ stream: SCStream, didStopWithError error: Error) {
        let handler = withState { () -> StopHandler? in
            let handler = onStop
            isRunning = false
            self.stream = nil
            return handler
        }

        Task {
            let writer = withState { self.writer }
            await writer?.finish()
            handler?(error)
        }
    }
}

// MARK: - Segmented writer

/// Writes crash-safe segments of `segmentDuration` seconds.
///
/// Each segment is a standalone, finalized `.mov`; a crash loses at most the current
/// segment. A manifest lists completed segments and pause markers so the session can
/// be rebuilt on next launch.
public final class SegmentedVideoWriter: @unchecked Sendable {
    struct SegmentInfo {
        var url: URL
        var startMs: Int
    }

    private let outputURL: URL
    private let width: Int
    private let height: Int
    private let fps: Int
    private let codec: AVVideoCodecType
    private let segmentDuration: TimeInterval
    private let includesAudio: Bool
    private let queue = DispatchQueue(label: "studio.screenforge.writer", qos: .userInitiated)

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var segmentStartTime: CMTime?
    private var lastPresentationTime: CMTime?
    private var segmentIndex = 0
    private var currentSegmentURL: URL?
    private var pendingPauseStartMs: Int?
    private var manifest: RecordingManifest
    private var pendingRotations: [AVAssetWriter] = []
    /// Samples held while the hardware encoder catches up. Bounded so a stalled encoder
    /// cannot grow memory without limit.
    private var pendingVideo: [CMSampleBuffer] = []
    private var pendingAudio: [CMSampleBuffer] = []
    private var drainScheduled = false
    private let maximumPendingSamples = 240

    init(
        outputURL: URL,
        width: Int,
        height: Int,
        fps: Int,
        codec: VideoCodec,
        segmentDuration: TimeInterval,
        includesAudio: Bool
    ) throws {
        self.outputURL = outputURL
        self.width = width
        self.height = height
        self.fps = fps
        self.codec = codec == .hevc ? .hevc : .h264
        self.segmentDuration = max(segmentDuration, 2)
        self.includesAudio = includesAudio
        self.manifest = RecordingManifest(
            sessionID: UUID(),
            displayName: outputURL.deletingPathExtension().lastPathComponent,
            pixelWidth: width,
            pixelHeight: height,
            scale: 2,
            fps: fps,
            hasSystemAudio: includesAudio,
            hasMicrophone: false,
            segments: [],
            pauses: [],
            state: .recording
        )

        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try writeManifest()
    }

    // MARK: Appending

    func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        nonisolated(unsafe) let buffer = sampleBuffer
        queue.async { [weak self] in
            guard let self else { return }
            let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
            self.lastPresentationTime = pts
            self.ensureWriter(at: pts)
            self.rotateIfNeeded(at: pts)

            self.pendingVideo.append(buffer)
            if self.pendingVideo.count > self.maximumPendingSamples {
                self.pendingVideo.removeFirst()
            }
            self.drainPending()
        }
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        nonisolated(unsafe) let buffer = sampleBuffer
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingAudio.append(buffer)
            if self.pendingAudio.count > self.maximumPendingSamples {
                self.pendingAudio.removeFirst()
            }
            self.drainPending()
        }
    }

    /// Drains buffered samples as the encoder accepts them. Frames are no longer dropped
    /// the instant `isReadyForMoreMediaData` is false, which matters at 4K60.
    private func drainPending() {
        if let video = videoInput {
            while video.isReadyForMoreMediaData, !pendingVideo.isEmpty {
                video.append(pendingVideo.removeFirst())
            }
        }
        if let audio = audioInput {
            while audio.isReadyForMoreMediaData, !pendingAudio.isEmpty {
                audio.append(pendingAudio.removeFirst())
            }
        }
        guard !pendingVideo.isEmpty || !pendingAudio.isEmpty else { return }
        guard !drainScheduled else { return }
        drainScheduled = true
        queue.asyncAfter(deadline: .now() + .milliseconds(4)) { [weak self] in
            guard let self else { return }
            self.drainScheduled = false
            self.drainPending()
        }
    }

    /// Blocks briefly so the current segment is not closed with buffered frames pending.
    private func flushPending(deadlineMs: Int = 250) {
        let deadline = DispatchTime.now() + .milliseconds(deadlineMs)
        while !pendingVideo.isEmpty || !pendingAudio.isEmpty {
            drainPending()
            if DispatchTime.now() > deadline { break }
            usleep(2_000)
        }
        pendingVideo.removeAll()
        pendingAudio.removeAll()
    }

    // MARK: Rotation

    enum RotationReason {
        case duration
        case pause
    }

    func rotateIfNeeded(at pts: CMTime) {
        guard let start = segmentStartTime else { return }
        let elapsed = CMTimeGetSeconds(CMTimeSubtract(pts, start))
        if elapsed >= segmentDuration {
            rotate(at: pts, reason: .duration)
        }
    }

    func rotate(at pts: CMTime, reason: RotationReason) {
        queue.async { [weak self] in
            self?.performRotation(at: pts, reason: reason)
        }
    }

    private func performRotation(at pts: CMTime, reason: RotationReason) {
        guard let oldWriter = writer, let oldURL = currentSegmentURL else { return }

        // Close the current segment.
        flushPending()
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        let startMs = Int((CMTimeGetSeconds(segmentStartTime ?? .zero) * 1000).rounded())
        let endMs = Int((CMTimeGetSeconds(pts) * 1000).rounded())
        manifest.segments.append(RecordingSegment(
            fileName: oldURL.lastPathComponent,
            startMs: startMs,
            durationMs: max(0, endMs - startMs)
        ))
        if reason == .pause {
            // Closed when the next segment starts; the gap between the two is the pause.
            pendingPauseStartMs = endMs
        }
        try? writeManifest()

        let writerToFinish = oldWriter
        pendingRotations.append(writerToFinish)
        nonisolated(unsafe) let retainedWriter = writerToFinish
        writerToFinish.finishWriting { [weak self] in
            guard let self else { return }
            self.queue.async {
                self.pendingRotations.removeAll { $0 === retainedWriter }
            }
        }

        writer = nil
        videoInput = nil
        audioInput = nil
        segmentStartTime = nil
        currentSegmentURL = nil
    }

    // MARK: Writer creation

    private func ensureWriter(at pts: CMTime) {
        guard writer == nil else { return }

        segmentIndex += 1
        let segmentURL = outputURL
            .deletingPathExtension()
            .appendingPathExtension(String(format: "seg-%04d", segmentIndex))
            .appendingPathExtension("mov")
        currentSegmentURL = segmentURL

        do {
            let writer = try AVAssetWriter(outputURL: segmentURL, fileType: .mov)

            let videoSettings: [String: Any] = [
                AVVideoCodecKey: codec,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: estimatedBitrate(),
                    AVVideoMaxKeyFrameIntervalKey: fps * 2,
                    AVVideoAllowFrameReorderingKey: true,
                    AVVideoProfileLevelKey: codec == .hevc
                        ? kVTProfileLevel_HEVC_Main_AutoLevel
                        : kVTProfileLevel_H264_High_AutoLevel
                ]
            ]
            let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            videoInput.expectsMediaDataInRealTime = true
            guard writer.canAdd(videoInput) else {
                throw CaptureError.writerSetupFailed("Video input rejected")
            }
            writer.add(videoInput)

            var audioInput: AVAssetWriterInput?
            if includesAudio {
                let audioSettings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: 192_000
                ]
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                input.expectsMediaDataInRealTime = true
                if writer.canAdd(input) {
                    writer.add(input)
                    audioInput = input
                }
            }

            // Must be set before writing starts; setting it later raises.
            // Fragmentation keeps a crashed recording readable.
            writer.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)

            guard writer.startWriting() else {
                throw CaptureError.writerSetupFailed(writer.error?.localizedDescription ?? "startWriting failed")
            }
            writer.startSession(atSourceTime: pts)

            if let pauseStart = pendingPauseStartMs {
                let resumeMs = Int((CMTimeGetSeconds(pts) * 1000).rounded())
                if resumeMs > pauseStart {
                    manifest.pauses.append(PauseInterval(startMs: pauseStart, endMs: resumeMs))
                    pendingPauseStartMs = nil
                }
            }

            self.writer = writer
            self.videoInput = videoInput
            self.audioInput = audioInput
            self.segmentStartTime = pts
        } catch {
            assertionFailure("Segment writer setup failed: \(error)")
        }
    }

    private func estimatedBitrate() -> Int {
        // ~0.11 bits/pixel for HEVC, 0.16 for H.264, scaled by quality.
        let pixels = Double(width) * Double(height) * Double(fps)
        let bitsPerPixel = codec == .hevc ? 0.11 : 0.16
        return max(Int(pixels * bitsPerPixel), 8_000_000)
    }

    // MARK: Manifest

    func manifestSnapshot() -> RecordingManifest {
        queue.sync { manifest }
    }

    private func writeManifest() throws {
        let url = outputURL
            .deletingPathExtension()
            .appendingPathExtension("manifest.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: url, options: .atomic)
    }

    func finish() async {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume()
                    return
                }
                if let writer = self.writer, let url = self.currentSegmentURL {
                    self.flushPending()
                    self.videoInput?.markAsFinished()
                    self.audioInput?.markAsFinished()
                    let startMs = Int((CMTimeGetSeconds(self.segmentStartTime ?? .zero) * 1000).rounded())
                    let endPts = self.lastPresentationTime ?? self.segmentStartTime ?? .zero
                    let endMs = Int((CMTimeGetSeconds(endPts) * 1000).rounded())
                    self.manifest.segments.append(RecordingSegment(
                        fileName: url.lastPathComponent,
                        startMs: startMs,
                        durationMs: max(0, endMs - startMs)
                    ))
                    writer.finishWriting {
                        self.queue.async {
                            self.manifest.state = .finished
                            self.manifest.completedAt = Date()
                            try? self.writeManifest()
                            continuation.resume()
                        }
                    }
                } else {
                    self.manifest.state = .finished
                    self.manifest.completedAt = Date()
                    try? self.writeManifest()
                    continuation.resume()
                }
                self.writer = nil
                self.videoInput = nil
                self.audioInput = nil
                self.segmentStartTime = nil
                self.currentSegmentURL = nil
            }
        }
    }
}
