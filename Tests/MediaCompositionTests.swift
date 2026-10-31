import AVFoundation
import CoreVideo
import Foundation
import Testing
@testable import ScreenForge

/// Segments are written with `startSession(atSourceTime:)` anchored to the host clock.
/// Concatenation must insert each track's own time range, not `asset.duration`.
@Suite("Media composition")
struct MediaCompositionTests {
    private func makeSegment(
        at url: URL,
        frames: Int,
        anchorSeconds: Double,
        fps: Int = 30,
        size: Int = 64
    ) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: size,
                AVVideoHeightKey: size
            ]
        )
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: size,
                kCVPixelBufferHeightKey as String: size
            ]
        )
        #expect(writer.canAdd(input))
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: CMTime(seconds: anchorSeconds, preferredTimescale: 600))

        let pool = try #require(adaptor.pixelBufferPool)
        for frame in 0..<frames {
            var buffer: CVPixelBuffer?
            #expect(CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer) == kCVReturnSuccess)
            let pixelBuffer = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
                let bytes = base.assumingMemoryBound(to: UInt8.self)
                let count = CVPixelBufferGetDataSize(pixelBuffer)
                for index in stride(from: 0, to: count, by: 4) {
                    bytes[index] = UInt8(frame * 4 % 256)
                    bytes[index + 3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

            let time = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps))
            let pts = CMTimeAdd(
                CMTime(seconds: anchorSeconds, preferredTimescale: 600),
                time
            )
            while !input.isReadyForMoreMediaData {
                usleep(1_000)
            }
            #expect(adaptor.append(pixelBuffer, withPresentationTime: pts))
        }

        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        #expect(writer.status == .completed)
    }

    @Test("Concatenation ignores the host-clock anchor of each segment")
    func concatenateAnchoredSegments() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenForgeComp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // Anchors differ per segment, as they would after a pause/restart.
        try makeSegment(
            at: directory.appendingPathComponent("screen.seg-0001.mov"),
            frames: 30,
            anchorSeconds: 1_000
        )
        try makeSegment(
            at: directory.appendingPathComponent("screen.seg-0002.mov"),
            frames: 15,
            anchorSeconds: 1_030
        )

        let segments = [
            RecordingSegment(fileName: "screen.seg-0001.mov", startMs: 1_000_000, durationMs: 1_000),
            RecordingSegment(fileName: "screen.seg-0002.mov", startMs: 1_030_000, durationMs: 500)
        ]

        let destination = directory.appendingPathComponent("screen.mov")
        let duration = try await MediaComposition.concatenate(
            segments: segments,
            directory: directory,
            destination: destination
        )

        // 1.0 s + 0.5 s of media, not 1030 s of host uptime.
        #expect(abs(duration - 1.5) < 0.1)

        let asset = AVURLAsset(url: destination)
        let assetDuration = try await asset.load(.duration)
        #expect(abs(CMTimeGetSeconds(assetDuration) - 1.5) < 0.1)

        let video = try await asset.loadTracks(withMediaType: .video).first
        let trackDuration = try await video?.load(.timeRange).duration ?? .zero
        #expect(abs(CMTimeGetSeconds(trackDuration) - 1.5) < 0.1)

        #expect(FileManager.default.fileExists(atPath: destination.path))
    }

    @Test("Empty segment list is rejected")
    func emptySegments() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenForgeComp-\(UUID().uuidString)", isDirectory: true)
        await #expect(throws: MediaComposition.CompositionError.self) {
            _ = try await MediaComposition.concatenate(
                segments: [],
                directory: directory,
                destination: directory.appendingPathComponent("screen.mov")
            )
        }
    }
}
