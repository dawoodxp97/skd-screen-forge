import AVFoundation
import Combine
import CoreVideo
import Foundation

/// Owns the preview player and exposes output-timeline time plus the current frame.
///
/// The player consumes an edited composition (trims, speed regions, audio mix), so
/// `outputTimeMs` is directly the editor's timeline position.
@MainActor
public final class PlaybackEngine: ObservableObject {
    @Published public private(set) var outputTimeMs: Double = 0
    @Published public private(set) var isPlaying = false
    @Published public private(set) var durationMs: Double = 0
    @Published public private(set) var isLoading = false
    @Published public var errorMessage: String?

    public let player = AVPlayer()
    /// Second player that keeps the webcam asset at the same source time as the screen.
    /// A separate player lets the compositor sample the camera as its own texture.
    public let cameraPlayer = AVPlayer()

    private var videoOutput: AVPlayerItemVideoOutput?
    private var cameraOutput: AVPlayerItemVideoOutput?
    private var timelineMap: TimelineMap?
    private var cameraPath: String?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var loadGeneration = 0

    public init() {
        player.actionAtItemEnd = .pause
        player.volume = 1

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                self?.handleTick(time)
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isPlaying = false
                self?.outputTimeMs = self?.durationMs ?? 0
            }
        }
    }

    // MARK: - Loading

    public func load(project: ScreenForgeProject, bundleURL: URL) async {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        errorMessage = nil
        pause()

        let map = project.timeline.map(sourceDurationMs: project.source.durationMs)
        durationMs = map.outputDurationMs
        timelineMap = map
        cameraPath = project.source.webcamPath
        outputTimeMs = min(outputTimeMs, durationMs)

        do {
            let preview = try await PreviewCompositionBuilder.makePreview(
                project: project,
                bundleURL: bundleURL
            )
            guard generation == loadGeneration else { return }

            let item = AVPlayerItem(asset: preview.composition)
            item.audioTimePitchAlgorithm = .spectral
            item.audioMix = preview.audioMix

            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ])
            item.add(output)
            videoOutput = output

            player.replaceCurrentItem(with: item)
            loadCamera(project: project, bundleURL: bundleURL)
            isLoading = false
            seek(toOutputMs: 0)
        } catch {
            guard generation == loadGeneration else { return }
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }

    /// Attaches the camera asset when the project has one. Missing or unreadable
    /// camera media degrades to a screen-only preview instead of failing the load.
    private func loadCamera(project: ScreenForgeProject, bundleURL: URL) {
        cameraPlayer.pause()
        cameraPlayer.replaceCurrentItem(with: nil)
        cameraOutput = nil

        guard project.camera.enabled, let path = project.source.webcamPath else { return }
        let url = bundleURL.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        let item = AVPlayerItem(url: url)
        item.audioTimePitchAlgorithm = .spectral
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        item.add(output)
        cameraOutput = output
        cameraPlayer.replaceCurrentItem(with: item)
        cameraPlayer.isMuted = true
        cameraPlayer.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: - Transport

    public func play() {
        guard player.currentItem != nil, durationMs > 0 else { return }
        if outputTimeMs >= durationMs - 150 {
            seek(toOutputMs: 0)
        }
        player.play()
        cameraPlayer.play()
        isPlaying = true
    }

    public func pause() {
        player.pause()
        cameraPlayer.pause()
        isPlaying = false
    }

    public func toggle() {
        isPlaying ? pause() : play()
    }

    public func seek(toOutputMs value: Double) {
        guard durationMs > 0 else { return }
        let clamped = min(max(value, 0), durationMs)
        outputTimeMs = clamped
        let time = CMTime(seconds: clamped / 1000, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        seekCamera(toOutputMs: clamped)
    }

    private func seekCamera(toOutputMs outputMs: Double) {
        guard cameraOutput != nil, let timelineMap else { return }
        let sourceMs = timelineMap.sourceTime(forOutputMs: outputMs) ?? 0
        let time = CMTime(seconds: sourceMs / 1000, preferredTimescale: 600)
        cameraPlayer.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    public var currentSourceTimeMs: Double {
        outputTimeMs
    }

    // MARK: - Frames

    public func currentPixelBuffer() -> CVPixelBuffer? {
        guard let videoOutput, let item = player.currentItem else { return nil }
        let time = player.currentTime()
        if let buffer = videoOutput.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
            return buffer
        }
        return videoOutput.copyPixelBuffer(forItemTime: item.currentTime(), itemTimeForDisplay: nil)
    }

    /// Newest webcam frame at the camera player's current time, if a camera is loaded.
    public func currentCameraPixelBuffer() -> CVPixelBuffer? {
        guard let cameraOutput, cameraPlayer.currentItem != nil else { return nil }
        return cameraOutput.copyPixelBuffer(forItemTime: cameraPlayer.currentTime(), itemTimeForDisplay: nil)
    }

    public var hasCamera: Bool {
        cameraOutput != nil
    }

    // MARK: - Internals

    private func handleTick(_ time: CMTime) {
        guard isPlaying else { return }
        let seconds = CMTimeGetSeconds(time)
        guard seconds.isFinite else { return }
        outputTimeMs = min(max(seconds * 1000, 0), durationMs)
    }
}
