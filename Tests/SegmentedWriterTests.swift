import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import ScreenForge

/// Exercises the real capture writer: fragmented segments, manifest bookkeeping, and
/// readable output. This is the code path that starts the instant recording begins.
@Suite("Segmented writer")
struct SegmentedWriterTests {
    private func makeSample(
        pixelBuffer: CVPixelBuffer,
        format: CMVideoFormatDescription,
        presentationTime: CMTime,
        frameDuration: CMTime
    ) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(
            duration: frameDuration,
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: format,
            sampleTiming: &timing,
            sampleBufferOut: &sample
        )
        return status == noErr ? sample : nil
    }

    @Test("Recording start writes a readable fragmented segment")
    func writesSegment() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenForgeWriter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let size = 160
        let fps = 30
        let writer = try SegmentedVideoWriter(
            outputURL: directory.appendingPathComponent("screen.mov"),
            width: size,
            height: size,
            fps: fps,
            codec: .h264,
            segmentDuration: 5,
            includesAudio: false
        )

        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: size,
            kCVPixelBufferHeightKey as String: size,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]

        // Segments are anchored to the host clock, exactly like ScreenCaptureKit frames.
        let anchor = CMTime(seconds: 12_000, preferredTimescale: 600)
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))

        // Burst two seconds of frames with no pacing: backpressure must keep every one.
        for frame in 0..<(fps * 2) {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                size,
                size,
                kCVPixelFormatType_32BGRA,
                attributes as CFDictionary,
                &buffer
            )
            let pixelBuffer = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
                let bytes = base.assumingMemoryBound(to: UInt8.self)
                for index in stride(from: 0, to: CVPixelBufferGetDataSize(pixelBuffer), by: 4) {
                    bytes[index] = UInt8((frame * 7) % 255)
                    bytes[index + 3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

            var format: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescriptionOut: &format
            )
            let description = try #require(format)
            let sample = try #require(makeSample(
                pixelBuffer: pixelBuffer,
                format: description,
                presentationTime: CMTimeAdd(anchor, CMTimeMultiply(frameDuration, multiplier: Int32(frame))),
                frameDuration: frameDuration
            ))
            writer.appendVideo(sample)
        }

        await writer.finish()

        let manifest = writer.manifestSnapshot()
        #expect(manifest.state == .finished)
        #expect(manifest.segments.count == 1, "no segment recorded")

        let segmentName = try #require(manifest.segments.first?.fileName)
        let segmentURL = directory.appendingPathComponent(segmentName)
        #expect(FileManager.default.fileExists(atPath: segmentURL.path))

        let asset = AVURLAsset(url: segmentURL)
        let duration = try await asset.load(.duration)
        #expect(CMTimeGetSeconds(duration) > 1.85, "dropped frames: \(CMTimeGetSeconds(duration)) s")
        #expect(CMTimeGetSeconds(duration) < 2.15)

        // The manifest on disk decodes (recovery depends on it).
        let manifestURL = directory.appendingPathComponent("screen.manifest.json")
        let data = try Data(contentsOf: manifestURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(RecordingManifest.self, from: data)
        #expect(decoded.segments.count == 1)
    }
}
