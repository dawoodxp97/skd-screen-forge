import AVFoundation
import CoreVideo
import Foundation
import Testing
@testable import ScreenForge

@MainActor
@Suite("Playback")
struct PlaybackTests {
    private func writeMovie(to url: URL, seconds: Double, size: Int = 160, fps: Int = 30) throws {
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
        writer.startSession(atSourceTime: .zero)

        let pool = try #require(adaptor.pixelBufferPool)
        let frames = max(Int(seconds * Double(fps)), 1)
        for frame in 0..<frames {
            var buffer: CVPixelBuffer?
            #expect(CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer) == kCVReturnSuccess)
            let pixelBuffer = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
                let bytes = base.assumingMemoryBound(to: UInt8.self)
                for index in stride(from: 0, to: CVPixelBufferGetDataSize(pixelBuffer), by: 4) {
                    bytes[index] = UInt8((frame * 5) % 255)
                    bytes[index + 3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            while !input.isReadyForMoreMediaData { usleep(500) }
            #expect(adaptor.append(
                pixelBuffer,
                withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps))
            ))
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        #expect(writer.status == .completed)
    }

    private func makeBundle(seconds: Double = 2.0) async throws -> (URL, ScreenForgeProject) {
        let bundle = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenForgePreview-\(UUID().uuidString).sforge", isDirectory: true)
        let store = ProjectStore.shared
        try await store.createBundle(at: bundle)
        let media = bundle.appendingPathComponent(ProjectBundleLayout.mediaDirectory, isDirectory: true)
        try writeMovie(to: media.appendingPathComponent("screen.mov"), seconds: seconds)

        let project = ScreenForgeProject(
            source: SourceInfo(
                screenPath: "media/screen.mov",
                durationMs: Int(seconds * 1000),
                pixelWidth: 160,
                pixelHeight: 160
            )
        )
        try await store.save(project, to: bundle)
        return (bundle, project)
    }

    @Test("Preview composition follows trims and speed regions")
    func compositionDuration() async throws {
        let (bundle, base) = try await makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle) }

        var project = base
        project.timeline.trims = [TrimRegion(startMs: 0, endMs: 500)]
        project.timeline.speeds = [SpeedRegion(startMs: 1_000, endMs: 1_500, rate: 2)]
        project = project.normalized()

        let composition = try await PreviewCompositionBuilder.makeComposition(
            project: project,
            bundleURL: bundle
        )
        // 2.0 − 0.5 trimmed − 0.25 saved by 2× = 1.25 s.
        #expect(abs(CMTimeGetSeconds(composition.duration) - 1.25) < 0.08)

        let map = project.timeline.map(sourceDurationMs: project.source.durationMs)
        #expect(abs(map.outputDurationMs - 1_250) < 1)
    }

    @Test("Playback engine loads the edited timeline and seeks")
    func playbackLoad() async throws {
        let (bundle, base) = try await makeBundle()
        defer { try? FileManager.default.removeItem(at: bundle) }

        var project = base
        project.timeline.trims = [TrimRegion(startMs: 0, endMs: 500)]
        project.cursor.visible = true

        let engine = PlaybackEngine()
        await engine.load(project: project.normalized(), bundleURL: bundle)

        #expect(engine.errorMessage == nil)
        #expect(abs(engine.durationMs - 1_500) < 80)
        #expect(!engine.isPlaying)

        engine.seek(toOutputMs: 600)
        #expect(engine.outputTimeMs == 600)

        engine.play()
        #expect(engine.isPlaying)
        engine.pause()
        #expect(!engine.isPlaying)
    }
}
