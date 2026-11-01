import AVFoundation
import Foundation
import Vision

/// Samples the webcam track with Vision so the editor can keep the speaker
/// centered without doing model work during playback. Only face rectangles are
/// collected; no image leaves the machine.
public enum FaceDetector {
    public struct Options: Sendable {
        public var sampleIntervalMs: Int
        public var maximumSamples: Int

        public init(sampleIntervalMs: Int = 500, maximumSamples: Int = 600) {
            self.sampleIntervalMs = max(sampleIntervalMs, 100)
            self.maximumSamples = max(maximumSamples, 1)
        }

        public static let `default` = Options()
    }

    public static func detect(
        in url: URL,
        options: Options = .default
    ) async throws -> [FaceSample] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)
        guard durationSeconds.isFinite, durationSeconds > 0.1 else { return [] }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.08, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.08, preferredTimescale: 600)

        let step = Double(options.sampleIntervalMs) / 1000
        let count = min(Int((durationSeconds / step).rounded(.down)) + 1, options.maximumSamples)
        var samples: [FaceSample] = []
        samples.reserveCapacity(count)

        for index in 0..<count {
            try Task.checkCancellation()
            let seconds = min(Double(index) * step, max(durationSeconds - 0.05, 0))
            guard let image = try? await generator.image(
                at: CMTime(seconds: seconds, preferredTimescale: 600)
            ).image else { continue }

            let request = VNDetectFaceRectanglesRequest()
            request.revision = VNDetectFaceRectanglesRequestRevision3
            let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
            guard (try? handler.perform([request])) != nil,
                  let observation = request.results?.max(by: {
                      $0.boundingBox.width * $0.boundingBox.height <
                      $1.boundingBox.width * $1.boundingBox.height
                  }) else {
                continue
            }

            let box = observation.boundingBox
            // Vision uses a bottom-left origin; the renderer uses top-left.
            samples.append(FaceSample(
                timeMs: min(Int((seconds * 1000).rounded()), Int(durationSeconds * 1000)),
                x: min(max(box.midX, 0), 1),
                y: min(max(1 - box.midY, 0), 1),
                confidence: Double(observation.confidence)
            ))
        }

        return smoothed(samples)
    }

    /// A light triangular filter removes detector jitter without lagging a real
    /// head movement by more than one sample.
    static func smoothed(_ samples: [FaceSample]) -> [FaceSample] {
        guard samples.count > 2 else { return samples }
        var result = samples
        for index in 1..<(samples.count - 1) {
            let previous = samples[index - 1]
            let current = samples[index]
            let next = samples[index + 1]
            result[index].x = previous.x * 0.25 + current.x * 0.5 + next.x * 0.25
            result[index].y = previous.y * 0.25 + current.y * 0.5 + next.y * 0.25
        }
        return result
    }
}
