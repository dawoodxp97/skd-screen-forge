import AVFoundation
import Foundation

/// Programmatic click sound effects, matching the packs Screen Studio ships
/// (`apple-magic-mouse`, `logitech-mx-master`, plus soft/mechanical variants).
public enum ClickSoundLibrary {
    public struct Pack: Identifiable, Sendable, Equatable {
        public var id: String
        public var name: String
        public var brightness: Double
        public var decayMs: Double
        public var noise: Double

        public init(id: String, name: String, brightness: Double, decayMs: Double, noise: Double) {
            self.id = id
            self.name = name
            self.brightness = brightness
            self.decayMs = decayMs
            self.noise = noise
        }
    }

    public static let packs: [Pack] = [
        Pack(id: "apple-magic-mouse", name: "Apple Magic Mouse", brightness: 2_600, decayMs: 55, noise: 0.22),
        Pack(id: "logitech-mx-master", name: "Logitech MX Master", brightness: 1_900, decayMs: 75, noise: 0.35),
        Pack(id: "soft", name: "Soft", brightness: 1_200, decayMs: 95, noise: 0.10),
        Pack(id: "mechanical", name: "Mechanical", brightness: 3_400, decayMs: 45, noise: 0.55)
    ]

    public static func pack(id: String?) -> Pack? {
        guard let id else { return nil }
        return packs.first { $0.id == id }
    }

    /// Renders a single click to a PCM `.caf`.
    public static func render(pack: Pack, to url: URL) throws {
        let sampleRate = 44_100.0
        let duration = pack.decayMs / 1000
        let frameCount = Int(sampleRate * duration)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(max(frameCount, 1))
              ),
              let channel = buffer.floatChannelData?[0] else {
            throw CocoaError(.fileWriteUnknown)
        }
        buffer.frameLength = AVAudioFrameCount(max(frameCount, 1))

        var noiseState: UInt64 = 0x9E3779B97F4A7C15
        for index in 0..<max(frameCount, 1) {
            let t = Double(index) / sampleRate
            noiseState = noiseState &* 6_364_136_223_846_793_005 &+ 1
            let white = Double((noiseState >> 33) & 0xFFFF) / 32_768.0 - 1
            let envelope = exp(-t / (duration * 0.32))
            let tone = sin(2 * .pi * pack.brightness * t) * 0.4
            let body = sin(2 * .pi * (pack.brightness * 0.5) * t) * 0.3
            channel[index] = Float((tone + body + white * pack.noise) * envelope * 0.7)
        }

        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try file.write(from: buffer)
    }
}

/// Builds one sound-effect clip containing every click in the recording.
public enum ClickTrackBuilder {
    public struct Result: Sendable {
        public var url: URL
        public var clickCount: Int
    }

    /// Renders clicks at their output times into a temporary `.caf`.
    public static func build(
        cursorSamples: [CursorSample],
        map: TimelineMap,
        outputDurationMs: Int,
        pack: ClickSoundLibrary.Pack
    ) throws -> Result {
        let clicks = cursorSamples.filter { $0.interaction == .click || $0.interaction == .rightClick }
        guard !clicks.isEmpty, outputDurationMs > 50 else {
            throw CocoaError(.fileWriteUnknown)
        }

        let sampleRate = 48_000.0
        let totalFrames = Int(sampleRate * Double(outputDurationMs) / 1000)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(max(totalFrames, 1))
              ),
              let channel = buffer.floatChannelData?[0] else {
            throw CocoaError(.fileWriteUnknown)
        }
        buffer.frameLength = AVAudioFrameCount(max(totalFrames, 1))
        for index in 0..<max(totalFrames, 1) {
            channel[index] = 0
        }

        var noiseState: UInt64 = 0x9E3779B97F4A7C15
        let duration = pack.decayMs / 1000
        let clickFrames = Int(sampleRate * duration)
        var placed = 0

        for sample in clicks {
            guard let outputMs = map.outputTime(forSourceMs: Double(sample.timeMs)) else { continue }
            let startFrame = Int(outputMs / 1000 * sampleRate)
            guard startFrame >= 0, startFrame < totalFrames else { continue }
            placed += 1
            for offset in 0..<clickFrames {
                let frame = startFrame + offset
                guard frame < totalFrames else { break }
                let t = Double(offset) / sampleRate
                noiseState = noiseState &* 6_364_136_223_846_793_005 &+ 1
                let white = Double((noiseState >> 33) & 0xFFFF) / 32_768.0 - 1
                let envelope = exp(-t / (duration * 0.32))
                let tone = sin(2 * .pi * pack.brightness * t) * 0.4
                let body = sin(2 * .pi * (pack.brightness * 0.5) * t) * 0.3
                channel[frame] += Float((tone + body + white * pack.noise) * envelope * 0.55)
            }
        }

        guard placed > 0 else { throw CocoaError(.fileWriteUnknown) }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenForge-clicks-\(UUID().uuidString).caf")
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try file.write(from: buffer)
        return Result(url: url, clickCount: placed)
    }
}
