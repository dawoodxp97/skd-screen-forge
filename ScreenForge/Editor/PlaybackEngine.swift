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

    private var videoOutput: AVPlayerItemVideoOutput?
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
        outputTimeMs = min(outputTimeMs, durationMs)

        do {
            let composition = try await PreviewCompositionBuilder.makeComposition(
                project: project,
                bundleURL: bundleURL
            )
            guard generation == loadGeneration else { return }

            let item = AVPlayerItem(asset: composition)
            item.audioTimePitchAlgorithm = .spectral

            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ])
            item.add(output)
            videoOutput = output

            player.replaceCurrentItem(with: item)
            isLoading = false
            seek(toOutputMs: 0)
        } catch {
            guard generation == loadGeneration else { return }
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Transport

    public func play() {
        guard player.currentItem != nil, durationMs > 0 else { return }
        if outputTimeMs >= durationMs - 150 {
            seek(toOutputMs: 0)
        }
        player.play()
        isPlaying = true
    }

    public func pause() {
        player.pause()
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

    // MARK: - Internals

    private func handleTick(_ time: CMTime) {
        guard isPlaying else { return }
        let seconds = CMTimeGetSeconds(time)
        guard seconds.isFinite else { return }
        outputTimeMs = min(max(seconds * 1000, 0), durationMs)
    }
}
