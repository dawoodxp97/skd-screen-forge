import AVFoundation
import Foundation
import Testing
@testable import ScreenForge

@Suite("Audio transcoding")
struct AudioTranscoderTests {
    private func writeCAF(to url: URL, seconds: Double) throws {
        let sampleRate = 48_000.0
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        if let channel = buffer.floatChannelData?[0] {
            for index in 0..<Int(frames) {
                channel[index] = Float(sin(2 * .pi * 220 * Double(index) / sampleRate) * 0.3)
            }
        }
        try file.write(from: buffer)
    }

    @Test("A PCM capture converts to a playable AAC track")
    func transcode() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenForgeAudio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let input = directory.appendingPathComponent("mic.caf")
        let output = directory.appendingPathComponent("mic.m4a")
        try writeCAF(to: input, seconds: 1.0)

        try await AudioTranscoder.toM4A(input: input, output: output)

        #expect(FileManager.default.fileExists(atPath: output.path))
        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration)
        #expect(abs(CMTimeGetSeconds(duration) - 1.0) < 0.1)

        let tracks = try await asset.loadTracks(withMediaType: .audio)
        #expect(tracks.count == 1)
    }

    @Test("An empty capture is rejected instead of producing a silent asset")
    func rejectsEmpty() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenForgeAudio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let input = directory.appendingPathComponent("empty.caf")
        let output = directory.appendingPathComponent("empty.m4a")
        FileManager.default.createFile(atPath: input.path, contents: Data())

        await #expect(throws: (any Error).self) {
            try await AudioTranscoder.toM4A(input: input, output: output)
        }
    }
}
