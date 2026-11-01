import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import Vision

/// Offline person segmentation for camera cutouts.
///
/// Vision's person-segmentation request produces a soft alpha matte per sampled
/// frame. Masks are written as grayscale PNGs beside the project media so the
/// compositor can apply them at playback and export time without running a model.
public enum PersonMatteDetector {
    public struct Options: Sendable {
        public var sampleIntervalMs: Int
        public var maximumSamples: Int
        public var quality: VNGeneratePersonSegmentationRequest.QualityLevel

        public init(
            sampleIntervalMs: Int = 500,
            maximumSamples: Int = 900,
            quality: VNGeneratePersonSegmentationRequest.QualityLevel = .accurate
        ) {
            self.sampleIntervalMs = max(sampleIntervalMs, 200)
            self.maximumSamples = max(maximumSamples, 1)
            self.quality = quality
        }

        public static let `default` = Options()
    }

    public struct Result: Sendable {
        /// Mask file names in temporal order (not yet copied into a project bundle).
        public var frames: [(timeMs: Int, fileName: String)]
        public var maskCount: Int
    }

    /// Samples `url` and writes `mask-0001.png` files into `directory`.
    public static func detect(
        in url: URL,
        outputDirectory: URL,
        options: Options = .default
    ) async throws -> Result {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return Result(frames: [], maskCount: 0)
        }
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)
        guard durationSeconds.isFinite, durationSeconds > 0.1 else {
            return Result(frames: [], maskCount: 0)
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.05, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.05, preferredTimescale: 600)

        let step = Double(options.sampleIntervalMs) / 1000
        let count = min(Int((durationSeconds / step).rounded(.down)) + 1, options.maximumSamples)
        var frames: [(timeMs: Int, fileName: String)] = []

        for index in 0..<count {
            try Task.checkCancellation()
            let seconds = min(Double(index) * step, max(durationSeconds - 0.05, 0))
            guard let image = try? await generator.image(
                at: CMTime(seconds: seconds, preferredTimescale: 600)
            ).image else {
                continue
            }

            let request = VNGeneratePersonSegmentationRequest()
            request.qualityLevel = options.quality
            request.outputPixelFormat = kCVPixelFormatType_OneComponent8
            let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
            guard (try? handler.perform([request])) != nil,
                  let maskBuffer = request.results?.first?.pixelBuffer,
                  let maskImage = makeMaskImage(maskBuffer) else {
                continue
            }

            let fileName = String(format: "mask-%04d.png", index)
            let destination = outputDirectory.appendingPathComponent(fileName)
            guard writePNG(maskImage, to: destination) else { continue }
            frames.append((timeMs: Int((seconds * 1000).rounded()), fileName: fileName))
        }

        return Result(frames: frames, maskCount: frames.count)
    }

    // MARK: - Mask conversion

    private static func makeMaskImage(_ pixelBuffer: CVPixelBuffer) -> CGImage? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard width > 1, height > 1, let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return nil
        }

        // Copy into a tightly packed buffer so the provider owns its bytes.
        var bytes = [UInt8](repeating: 0, count: width * height)
        for row in 0..<height {
            let source = base.advanced(by: row * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for column in 0..<width {
                bytes[row * width + column] = source[column]
            }
        }

        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: 0),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    private static func writePNG(_ image: CGImage, to url: URL) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            "public.png" as CFString,
            1,
            nil
        ) else {
            return false
        }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }
}
