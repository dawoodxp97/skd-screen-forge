import AVFoundation
import CryptoKit
import Foundation

/// Offline microphone cleanup that mirrors Screen Studio's "improve voice" chain:
/// high-pass, noise gate, presence EQ, compression, and a soft limiter.
///
/// The original ships MLX MossFormer2 / TF-Restormer weights. ScreenForge runs a
/// deterministic DSP chain with the same controls (standard / podcast / strong
/// denoise) so it works offline, at any length, with no model download.
public enum VoiceEnhancer {
    public struct Options: Sendable {
        public var mode: VoiceEnhancementMode
        /// 0...1 gate depth.
        public var noiseReduction: Double

        public init(mode: VoiceEnhancementMode = .standard, noiseReduction: Double = 0.35) {
            self.mode = mode
            self.noiseReduction = min(max(noiseReduction, 0), 1)
        }

        public static let `default` = Options()
    }

    public enum EnhanceError: LocalizedError, Sendable {
        case unreadable(String)
        case noAudioTrack
        case empty
        case writeFailed(String)

        public var errorDescription: String? {
            switch self {
            case .unreadable(let reason): "Could not read the microphone track: \(reason)"
            case .noAudioTrack: "The microphone file has no audio track."
            case .empty: "The microphone track is empty."
            case .writeFailed(let reason): "Could not write the enhanced track: \(reason)"
            }
        }
    }

    public static func enhance(
        input: URL,
        output: URL,
        options: Options = .default
    ) async throws {
        guard options.mode != .off else {
            if FileManager.default.fileExists(atPath: output.path) {
                try? FileManager.default.removeItem(at: output)
            }
            try FileManager.default.copyItem(at: input, to: output)
            return
        }

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: input)
        } catch {
            throw EnhanceError.unreadable(error.localizedDescription)
        }
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0 else { throw EnhanceError.empty }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw EnhanceError.unreadable("Could not allocate a buffer")
        }
        do {
            try file.read(into: buffer)
        } catch {
            throw EnhanceError.unreadable(error.localizedDescription)
        }
        guard let channels = buffer.floatChannelData else { throw EnhanceError.noAudioTrack }

        let sampleRate = format.sampleRate
        let length = Int(buffer.frameLength)
        let channelCount = Int(format.channelCount)
        let gate = options.mode == .denoise ? max(options.noiseReduction, 0.6) : options.noiseReduction

        for channel in 0..<channelCount {
            process(
                samples: channels[channel],
                count: length,
                sampleRate: sampleRate,
                mode: options.mode,
                noiseReduction: gate
            )
        }

        if FileManager.default.fileExists(atPath: output.path) {
            try? FileManager.default.removeItem(at: output)
        }
        do {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channelCount,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false
            ]
            let outputFile = try AVAudioFile(
                forWriting: output,
                settings: settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            try outputFile.write(from: buffer)
        } catch {
            throw EnhanceError.writeFailed(error.localizedDescription)
        }
    }

    // MARK: - Cache

    /// Returns a processed copy from the local cache, creating it on first use.
    /// Cache keys include the source modification date and the chain settings.
    public static func cachedEnhanced(
        input: URL,
        options: Options = .default
    ) async throws -> URL {
        guard options.mode != .off else { return input }

        let attributes = try? FileManager.default.attributesOfItem(atPath: input.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(input.path)|\(size)|\(Int(modified))|\(options.mode.rawValue)|\(Int(options.noiseReduction * 100))"
        let digest = SHA256.hash(data: Data(key.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
            .prefix(24)

        let cacheDirectory = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first?
            .appendingPathComponent("ScreenForge", isDirectory: true)
            .appendingPathComponent("Voice", isDirectory: true)
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("ScreenForgeVoice", isDirectory: true)

        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let destination = cacheDirectory.appendingPathComponent("voice-\(digest).caf")
        if FileManager.default.fileExists(atPath: destination.path) {
            return destination
        }

        try await enhance(input: input, output: destination, options: options)
        return destination
    }

    // MARK: - DSP

    static func process(
        samples: UnsafeMutablePointer<Float>,
        count: Int,
        sampleRate: Double,
        mode: VoiceEnhancementMode,
        noiseReduction: Double
    ) {
        guard count > 1 else { return }

        // 1. DC blocker + 80 Hz high-pass.
        var highPass = Biquad.highPass(cutoff: 80, sampleRate: sampleRate, q: 0.707)
        for index in 0..<count {
            samples[index] = highPass.process(samples[index])
        }

        // 2. Adaptive gate driven by a smoothed envelope and a measured noise floor.
        let frameLength = max(Int(sampleRate * 0.02), 32)
        var frameRMS: [Float] = []
        frameRMS.reserveCapacity(count / frameLength + 1)
        var frameIndex = 0
        while frameIndex < count {
            let end = min(frameIndex + frameLength, count)
            var sum: Float = 0
            for index in frameIndex..<end {
                sum += samples[index] * samples[index]
            }
            frameRMS.append(sqrt(sum / Float(max(end - frameIndex, 1))))
            frameIndex = end
        }
        let sorted = frameRMS.sorted()
        let floorIndex = min(max(Int(Double(sorted.count) * 0.15), 0), max(sorted.count - 1, 0))
        let noiseFloor = max(sorted[safe: floorIndex] ?? 0.001, 0.0005)
        let threshold = noiseFloor * (mode == .denoise ? 2.6 : 1.8)

        let attack = 1 - exp(-1 / (sampleRate * 0.004))
        let release = 1 - exp(-1 / (sampleRate * 0.090))
        let minimumGain = Float(1 - noiseReduction * 0.96)
        var envelope: Float = 0
        var gateGain: Float = 1
        for index in 0..<count {
            let magnitude = abs(samples[index])
            envelope += (magnitude - envelope) * (magnitude > envelope ? Float(attack) : Float(release))

            let target: Float
            if envelope <= threshold {
                target = minimumGain
            } else if envelope >= threshold * 2.2 {
                target = 1
            } else {
                let t = (envelope - threshold) / max(threshold * 1.2, 0.0001)
                target = minimumGain + (1 - minimumGain) * min(max(t, 0), 1)
            }
            gateGain += (target - gateGain) * 0.004
            samples[index] *= gateGain
        }

        if mode == .podcast || mode == .standard {
            // 3. Presence lift around 3 kHz.
            var presence = Biquad.peaking(
                frequency: 3_000,
                sampleRate: sampleRate,
                q: 0.9,
                gainDB: mode == .podcast ? 4.0 : 2.0
            )
            for index in 0..<count {
                samples[index] = presence.process(samples[index])
            }

            // 4. Gentle low-mid control to remove boxiness.
            var mud = Biquad.peaking(
                frequency: 260,
                sampleRate: sampleRate,
                q: 0.8,
                gainDB: -2.0
            )
            for index in 0..<count {
                samples[index] = mud.process(samples[index])
            }
        }

        if mode == .podcast {
            // 5. Compressor: 3:1 above -22 dBFS, with makeup gain.
            let threshold: Float = 0.08
            let ratio: Float = 3
            let attackCoefficient = Float(1 - exp(-1 / (sampleRate * 0.008)))
            let releaseCoefficient = Float(1 - exp(-1 / (sampleRate * 0.120)))
            var compressorEnvelope: Float = 0
            for index in 0..<count {
                let magnitude = abs(samples[index])
                compressorEnvelope += (magnitude - compressorEnvelope) *
                    (magnitude > compressorEnvelope ? attackCoefficient : releaseCoefficient)
                if compressorEnvelope > threshold {
                    let over = compressorEnvelope - threshold
                    let compressed = threshold + over / ratio
                    let reduction = compressed / max(compressorEnvelope, 0.0001)
                    samples[index] *= reduction
                }
                samples[index] *= 1.25
            }
        }

        // 6. Soft limiter.
        for index in 0..<count {
            let value = samples[index]
            samples[index] = tanh(value * 1.1) / tanh(1.1)
        }
    }
}

/// Direct-form biquad used by the voice chain.
struct Biquad {
    var b0: Float
    var b1: Float
    var b2: Float
    var a1: Float
    var a2: Float
    private var x1: Float = 0
    private var x2: Float = 0
    private var y1: Float = 0
    private var y2: Float = 0

    mutating func process(_ input: Float) -> Float {
        let output = b0 * input + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1
        x1 = input
        y2 = y1
        y1 = output
        return output
    }

    static func highPass(cutoff: Double, sampleRate: Double, q: Double) -> Biquad {
        let omega = 2 * Double.pi * cutoff / sampleRate
        let alpha = sin(omega) / (2 * q)
        let cosOmega = cos(omega)
        let a0 = 1 + alpha
        return Biquad(
            b0: Float((1 + cosOmega) / 2 / a0),
            b1: Float(-(1 + cosOmega) / a0),
            b2: Float((1 + cosOmega) / 2 / a0),
            a1: Float(-2 * cosOmega / a0),
            a2: Float((1 - alpha) / a0)
        )
    }

    static func peaking(
        frequency: Double,
        sampleRate: Double,
        q: Double,
        gainDB: Double
    ) -> Biquad {
        let A = pow(10, gainDB / 40)
        let omega = 2 * Double.pi * frequency / sampleRate
        let alpha = sin(omega) / (2 * q)
        let cosOmega = cos(omega)
        let a0 = 1 + alpha / A
        return Biquad(
            b0: Float((1 + alpha * A) / a0),
            b1: Float(-2 * cosOmega / a0),
            b2: Float((1 - alpha * A) / a0),
            a1: Float(-2 * cosOmega / a0),
            a2: Float((1 - alpha / A) / a0)
        )
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
