import AVFoundation
import CoreGraphics
import Foundation
import Vision

/// Finds faces and on-screen text (OCR) in a recording and turns each stable
/// detection into a timed mask region.
///
/// This mirrors Screen Studio's `autoMaskSensitiveData` / `autoMaskFaces`: text
/// recognition catches tokens, emails, keys, and user phrases, while face detection
/// catches people. Results are stored as ordinary timeline annotations, so they
/// remain editable and removable.
public enum SensitiveDataScanner {
    public struct Options: Sendable {
        public var sampleIntervalMs: Int
        public var maximumSamples: Int
        public var detectFaces: Bool
        public var detectText: Bool
        public var customPhrases: [String]
        /// Padding, in points of the source, added around each detection.
        public var expandPoints: Double
        public var minimumConfidence: Float

        public init(
            sampleIntervalMs: Int = 1_000,
            maximumSamples: Int = 900,
            detectFaces: Bool = true,
            detectText: Bool = true,
            customPhrases: [String] = [],
            expandPoints: Double = 8,
            minimumConfidence: Float = 0.4
        ) {
            self.sampleIntervalMs = max(sampleIntervalMs, 250)
            self.maximumSamples = max(maximumSamples, 1)
            self.detectFaces = detectFaces
            self.detectText = detectText
            self.customPhrases = customPhrases
            self.expandPoints = max(expandPoints, 0)
            self.minimumConfidence = min(max(minimumConfidence, 0), 1)
        }

        public static let `default` = Options()
    }

    public struct Detection: Sendable, Equatable {
        public var startMs: Int
        public var endMs: Int
        /// Normalized top-left rect in the source frame.
        public var rect: CGRect
        public var kind: Kind
        public var text: String?

        public enum Kind: String, Sendable {
            case face
            case text
        }
    }

    public static func scan(
        in url: URL,
        options: Options = .default
    ) async throws -> [Detection] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)
        guard durationSeconds.isFinite, durationSeconds > 0.1 else { return [] }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.05, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.05, preferredTimescale: 600)

        let step = Double(options.sampleIntervalMs) / 1000
        let count = min(Int((durationSeconds / step).rounded(.down)) + 1, options.maximumSamples)
        var raw: [(timeMs: Int, rect: CGRect, kind: Detection.Kind, text: String?)] = []
        let phrases = options.customPhrases.map { $0.lowercased() }.filter { !$0.isEmpty }

        for index in 0..<count {
            try Task.checkCancellation()
            let seconds = min(Double(index) * step, max(durationSeconds - 0.05, 0))
            guard let image = try? await generator.image(
                at: CMTime(seconds: seconds, preferredTimescale: 600)
            ).image else {
                continue
            }
            let timeMs = Int((seconds * 1000).rounded())
            let size = CGSize(width: image.width, height: image.height)
            let padX = options.expandPoints / max(size.width, 1)
            let padY = options.expandPoints / max(size.height, 1)

            if options.detectFaces {
                let request = VNDetectFaceRectanglesRequest()
                request.revision = VNDetectFaceRectanglesRequestRevision3
                let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
                if (try? handler.perform([request])) != nil {
                    for observation in request.results ?? [] where observation.confidence >= options.minimumConfidence {
                        let box = observation.boundingBox
                        // Vision is bottom-left; annotations are top-left.
                        let rect = CGRect(
                            x: box.minX,
                            y: 1 - box.maxY,
                            width: box.width,
                            height: box.height
                        ).insetBy(dx: -padX, dy: -padY)
                        raw.append((timeMs, rect, .face, nil))
                    }
                }
            }

            if options.detectText {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
                if (try? handler.perform([request])) != nil {
                    for observation in request.results ?? [] {
                        guard let candidate = observation.topCandidates(1).first,
                              candidate.confidence >= options.minimumConfidence else { continue }
                        let text = candidate.string
                        let matchesPhrase = phrases.contains { text.lowercased().contains($0) }
                        if !matchesPhrase && !looksSensitive(text) {
                            continue
                        }
                        let box = try? perspectiveRect(observation, imageSize: size)
                        guard let box else { continue }
                        let rect = box.insetBy(dx: -padX, dy: -padY)
                        raw.append((timeMs, rect, .text, text))
                    }
                }
            }
        }

        return merge(raw, intervalMs: options.sampleIntervalMs)
    }

    /// Groups detections that overlap across adjacent samples into stable ranges.
    static func merge(
        _ raw: [(timeMs: Int, rect: CGRect, kind: Detection.Kind, text: String?)],
        intervalMs: Int
    ) -> [Detection] {
        struct Bucket {
            var rect: CGRect
            var kind: Detection.Kind
            var text: String?
            var startMs: Int
            var endMs: Int
            var hits: Int
        }

        var buckets: [Bucket] = []
        for detection in raw.sorted(by: { $0.timeMs < $1.timeMs }) {
            let tolerance = CGRect(
                x: detection.rect.minX - 0.015,
                y: detection.rect.minY - 0.015,
                width: detection.rect.width + 0.03,
                height: detection.rect.height + 0.03
            )
            if let index = buckets.firstIndex(where: {
                $0.kind == detection.kind &&
                $0.endMs + intervalMs * 2 >= detection.timeMs &&
                $0.rect.intersects(tolerance)
            }) {
                let union = buckets[index].rect.union(detection.rect)
                buckets[index].rect = union
                buckets[index].endMs = detection.timeMs
                buckets[index].hits += 1
                if buckets[index].text == nil {
                    buckets[index].text = detection.text
                }
            } else {
                buckets.append(Bucket(
                    rect: detection.rect,
                    kind: detection.kind,
                    text: detection.text,
                    startMs: detection.timeMs,
                    endMs: detection.timeMs,
                    hits: 1
                ))
            }
        }

        return buckets
            .filter { $0.hits >= 1 }
            .map { bucket in
                Detection(
                    startMs: max(bucket.startMs - 120, 0),
                    endMs: bucket.endMs + 160,
                    rect: bucket.rect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1)),
                    kind: bucket.kind,
                    text: bucket.text
                )
            }
            .filter { $0.rect.width > 0.004 && $0.rect.height > 0.004 }
    }

    private static func perspectiveRect(_ observation: VNRecognizedTextObservation, imageSize: CGSize) -> CGRect? {
        let box = observation.boundingBox
        return CGRect(
            x: box.minX,
            y: 1 - box.maxY,
            width: box.width,
            height: box.height
        )
    }

    /// Tokens that usually indicate private data even when no custom phrase is set.
    static func looksSensitive(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.contains("@") || lower.contains("http") || lower.contains("www.") {
            return true
        }
        if lower.contains("password") || lower.contains("secret") || lower.contains("token") ||
            lower.contains("api key") || lower.contains("apikey") || lower.contains("private key") ||
            lower.contains("ssn") || lower.contains("iban") || lower.contains("routing") {
            return true
        }
        // Long digit runs: phone numbers, card numbers, account IDs.
        let digits = lower.filter(\.isNumber)
        if digits.count >= 9, digits.count >= lower.filter { !$0.isWhitespace }.count / 2 {
            return true
        }
        return false
    }
}
