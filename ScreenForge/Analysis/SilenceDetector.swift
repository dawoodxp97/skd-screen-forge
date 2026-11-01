import AVFoundation
import Foundation

/// Offline voice-activity analysis for the microphone track. The resulting
/// ranges are stored in the project so the camera can hide while nobody is
/// speaking without running audio analysis during playback or export.
public enum SilenceDetector {
    public struct Options: Sendable {
        public var thresholdDB: Double
        public var minimumDurationMs: Int
        /// Skip this much at both ends of a run so breaths do not pop the camera.
        public var edgePaddingMs: Int

        public init(
            thresholdDB: Double = -38,
            minimumDurationMs: Int = 450,
            edgePaddingMs: Int = 100
        ) {
            self.thresholdDB = thresholdDB
            self.minimumDurationMs = minimumDurationMs
            self.edgePaddingMs = edgePaddingMs
        }

        public static let `default` = Options()
    }

    /// Reads a compressed or PCM audio file and returns merged silence ranges.
    public static func detect(
        in url: URL,
        options: Options = .default
    ) async throws -> [SilenceRange] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }

        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            return []
        }
        let duration = try await asset.load(.duration)
        let durationMs = Int((CMTimeGetSeconds(duration) * 1000).rounded())
        guard durationMs > 0 else { return [] }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? SilenceDetectorError.readerFailed
        }

        let windowSeconds = 0.05
        var sampleRate = 48_000.0
        var channelCount = 1
        var windowSamples = Int(sampleRate * windowSeconds)
        var energy = 0.0
        var count = 0
        var windows: [(startMs: Int, endMs: Int, silent: Bool)] = []
        var processedSamples = 0

        while let sampleBuffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            if let description = CMSampleBufferGetFormatDescription(sampleBuffer),
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
                sampleRate = max(asbd.mSampleRate, 1)
                channelCount = max(Int(asbd.mChannelsPerFrame), 1)
                windowSamples = max(Int(sampleRate * windowSeconds), 1)
            }

            let length = CMBlockBufferGetDataLength(block)
            guard length > 0 else { continue }
            var data = [Int16](repeating: 0, count: length / MemoryLayout<Int16>.size)
            let status = data.withUnsafeMutableBytes { bytes -> OSStatus in
                guard let base = bytes.baseAddress else { return -1 }
                return CMBlockBufferCopyDataBytes(
                    block,
                    atOffset: 0,
                    dataLength: length,
                    destination: base
                )
            }
            guard status == noErr else { continue }

            var index = 0
            while index < data.count {
                let remaining = windowSamples - count
                let take = min(remaining, data.count - index)
                for offset in 0..<take {
                    let value = Double(data[index + offset]) / 32_768.0
                    energy += value * value
                }
                index += take
                count += take
                processedSamples += take

                if count >= windowSamples {
                    let rms = sqrt(energy / Double(max(count * channelCount, 1)))
                    let db = 20 * log10(max(rms, 1e-7))
                    let startMs = Int(Double(processedSamples - count) / sampleRate * 1000)
                    let endMs = Int(Double(processedSamples) / sampleRate * 1000)
                    windows.append((startMs, endMs, db < options.thresholdDB))
                    energy = 0
                    count = 0
                }
            }
        }
        reader.cancelReading()
        if reader.status == .failed { throw reader.error ?? SilenceDetectorError.readerFailed }

        return ranges(
            from: windows,
            durationMs: durationMs,
            minimumDurationMs: options.minimumDurationMs,
            edgePaddingMs: options.edgePaddingMs
        )
    }

    static func ranges(
        from windows: [(startMs: Int, endMs: Int, silent: Bool)],
        durationMs: Int,
        minimumDurationMs: Int,
        edgePaddingMs: Int
    ) -> [SilenceRange] {
        var result: [SilenceRange] = []
        var currentStart: Int?
        var currentEnd: Int?

        func closeCurrent() {
            guard let start = currentStart, let end = currentEnd else { return }
            var range = SilenceRange(startMs: start, endMs: end)
            if edgePaddingMs > 0 {
                range.startMs += edgePaddingMs
                range.endMs -= edgePaddingMs
            }
            if range.durationMs >= minimumDurationMs {
                result.append(range)
            }
            currentStart = nil
            currentEnd = nil
        }

        for window in windows.sorted(by: { $0.startMs < $1.startMs }) {
            if window.silent {
                if currentStart == nil { currentStart = window.startMs }
                currentEnd = window.endMs
            } else {
                closeCurrent()
            }
        }
        closeCurrent()

        return SilenceRange.merged(result).filter { $0.durationMs > 0 && $0.endMs <= durationMs }
    }
}

public enum SilenceDetectorError: LocalizedError {
    case readerFailed

    public var errorDescription: String? {
        "The microphone audio could not be analyzed."
    }
}
