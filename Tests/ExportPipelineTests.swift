import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import Metal
import Testing
@testable import ScreenForge

/// End-to-end: synthetic recording → edit → real Metal compositing → encoded MP4.
@Suite("Export pipeline")
struct ExportPipelineTests {
    private var isHosted: Bool {
        Bundle.main.bundleIdentifier == "studio.screenforge.app"
    }

    private func writeScreenMovie(to url: URL, seconds: Double, size: Int = 320) throws {
        let fps = 30
        let frames = max(Int(seconds * Double(fps)), 1)
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
        for frame in 0..<frames {
            var buffer: CVPixelBuffer?
            #expect(CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer) == kCVReturnSuccess)
            let pixelBuffer = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
                let bytes = base.assumingMemoryBound(to: UInt8.self)
                let count = CVPixelBufferGetDataSize(pixelBuffer)
                for index in stride(from: 0, to: count, by: 4) {
                    bytes[index] = UInt8((frame * 8) % 255)       // B
                    bytes[index + 1] = UInt8((frame * 4) % 255)   // G
                    bytes[index + 2] = 200                        // R
                    bytes[index + 3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

            while !input.isReadyForMoreMediaData {
                usleep(500)
            }
            let pts = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps))
            #expect(adaptor.append(pixelBuffer, withPresentationTime: pts))
        }

        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        #expect(writer.status == .completed)
    }

    private final class PhaseRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var phases: [ExportProgress.Phase] = []

        func record(_ phase: ExportProgress.Phase) {
            lock.lock()
            phases.append(phase)
            lock.unlock()
        }

        var snapshot: [ExportProgress.Phase] {
            lock.lock()
            defer { lock.unlock() }
            return phases
        }
    }

    @Test("Export produces a playable MP4 with the edited duration")
    func exportMovie() async throws {
        guard isHosted, let device = MTLCreateSystemDefaultDevice() else { return }
        let compositor = try Compositor(device: device)

        let bundle = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenForgeExport-\(UUID().uuidString).sforge", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: bundle) }

        let store = ProjectStore.shared
        try await store.createBundle(at: bundle)

        let sourceURL = bundle
            .appendingPathComponent(ProjectBundleLayout.mediaDirectory, isDirectory: true)
            .appendingPathComponent("screen.mov")
        try writeScreenMovie(to: sourceURL, seconds: 1.0)

        var project = ScreenForgeProject(
            source: SourceInfo(
                screenPath: "media/screen.mov",
                durationMs: 1_000,
                pixelWidth: 320,
                pixelHeight: 320,
                displayName: "Export test"
            ),
            timeline: Timeline(
                zooms: [ZoomRegion(startMs: 200, endMs: 800, scale: 2)],
                annotations: [
                    AnnotationRegion(
                        type: .text,
                        startMs: 100,
                        endMs: 900,
                        text: "Hello",
                        rect: NormalizedRect(x: 0.2, y: 0.7, width: 0.6, height: 0.2)
                    )
                ]
            )
        )
        project.captions = CaptionSettings(enabled: true, style: .pill)
        project.export = ExportSettings(resolution: .p720, fps: 30, codec: .h264, quality: 0.5)

        try await store.save(project, to: bundle)
        try await store.writeCursor(
            [
                CursorSample(timeMs: 0, x: 0.3, y: 0.3),
                CursorSample(timeMs: 500, x: 0.6, y: 0.6, interaction: .click),
                CursorSample(timeMs: 900, x: 0.6, y: 0.6)
            ],
            to: bundle
        )
        try await store.writeTranscript(
            TranscriptDocument(words: [
                TranscriptWord(text: "Hello", startMs: 100, endMs: 500),
                TranscriptWord(text: "there", startMs: 550, endMs: 900)
            ]),
            to: bundle
        )

        let output = bundle.deletingLastPathComponent()
            .appendingPathComponent("ScreenForgeExport-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: output) }

        let exporter = Exporter(compositor: compositor)
        let job = ExportJob(
            project: project,
            bundleURL: bundle,
            outputURL: output,
            format: .mp4
        )

        let recorder = PhaseRecorder()
        let result = try await exporter.export(job: job) { progress in
            recorder.record(progress.phase)
        }

        #expect(result == output)
        #expect(FileManager.default.fileExists(atPath: output.path))

        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration)
        #expect(abs(CMTimeGetSeconds(duration) - 1.0) < 0.15)

        let video = try await asset.loadTracks(withMediaType: .video).first
        let track = try #require(video)
        let natural = try await track.load(.naturalSize)
        #expect(natural.width == 1_280)
        #expect(natural.height == 720)

        let frameRate = try await track.load(.nominalFrameRate)
        #expect(frameRate >= 29 && frameRate <= 31)

        #expect(recorder.snapshot.contains(.rendering))
        #expect(recorder.snapshot.last == .finishing)
    }

    @Test("Captions are burned into the exported video")
    func captionsBurnIn() async throws {
        guard isHosted, let device = MTLCreateSystemDefaultDevice() else { return }
        let compositor = try Compositor(device: device)

        let bundle = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenForgeBurn-\(UUID().uuidString).sforge", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: bundle) }

        let store = ProjectStore.shared
        try await store.createBundle(at: bundle)
        let media = bundle.appendingPathComponent(ProjectBundleLayout.mediaDirectory, isDirectory: true)
        try writeScreenMovie(to: media.appendingPathComponent("screen.mov"), seconds: 1.0)

        var project = ScreenForgeProject(
            source: SourceInfo(
                screenPath: "media/screen.mov",
                durationMs: 1_000,
                pixelWidth: 320,
                pixelHeight: 320
            )
        )
        project.export = ExportSettings(resolution: .p720, fps: 30, codec: .h264, quality: 0.7)
        project.captions = CaptionSettings(enabled: true, style: .pill, position: .bottom)

        try await store.save(project, to: bundle)
        try await store.writeTranscript(
            TranscriptDocument(words: [
                TranscriptWord(text: "Caption", startMs: 0, endMs: 600),
                TranscriptWord(text: "check", startMs: 620, endMs: 980)
            ]),
            to: bundle
        )

        let withCaptions = bundle.deletingLastPathComponent()
            .appendingPathComponent("burn-\(UUID().uuidString).mp4")
        let withoutCaptions = bundle.deletingLastPathComponent()
            .appendingPathComponent("burn-\(UUID().uuidString).mp4")
        defer {
            try? FileManager.default.removeItem(at: withCaptions)
            try? FileManager.default.removeItem(at: withoutCaptions)
        }

        let exporter = Exporter(compositor: compositor)
        _ = try await exporter.export(
            job: ExportJob(project: project, bundleURL: bundle, outputURL: withCaptions)
        ) { _ in }

        project.captions.enabled = false
        try await store.save(project, to: bundle)
        _ = try await exporter.export(
            job: ExportJob(project: project, bundleURL: bundle, outputURL: withoutCaptions)
        ) { _ in }

        let captionPixels = try frameData(at: 0.3, from: withCaptions)
        let plainPixels = try frameData(at: 0.3, from: withoutCaptions)
        #expect(captionPixels.count == plainPixels.count)

        var differing = 0
        for index in 0..<min(captionPixels.count, plainPixels.count) where captionPixels[index] != plainPixels[index] {
            differing += 1
        }
        #expect(differing > 2_000, "Only \(differing) bytes differ; captions may not be rendered")
    }

    private func frameData(at seconds: Double, from url: URL) throws -> [UInt8] {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try generator.copyCGImage(
            at: CMTime(seconds: seconds, preferredTimescale: 600),
            actualTime: nil
        )
        guard let provider = image.dataProvider, let data = provider.data as Data? else {
            return []
        }
        return [UInt8](data)
    }

    // MARK: - Helpers

    private func writeTone(to url: URL, seconds: Double) throws {
        let sampleRate = 48_000.0
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 96_000
        ]
        let file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let frameCount = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        if let channel = buffer.floatChannelData?[0] {
            for index in 0..<Int(frameCount) {
                let t = Double(index) / sampleRate
                channel[index] = Float(sin(2 * .pi * 440 * t) * 0.2)
            }
        }
        try file.write(from: buffer)
    }

    @Test("Export mixes a microphone track into the movie")
    func exportWithMicrophone() async throws {
        guard isHosted, let device = MTLCreateSystemDefaultDevice() else { return }
        let compositor = try Compositor(device: device)

        let bundle = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenForgeAudio-\(UUID().uuidString).sforge", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: bundle) }

        let store = ProjectStore.shared
        try await store.createBundle(at: bundle)

        let media = bundle.appendingPathComponent(ProjectBundleLayout.mediaDirectory, isDirectory: true)
        try writeScreenMovie(to: media.appendingPathComponent("screen.mov"), seconds: 1.0)

        let micSource = bundle.deletingLastPathComponent()
            .appendingPathComponent("mic-\(UUID().uuidString).m4a")
        try writeTone(to: micSource, seconds: 1.0)
        defer { try? FileManager.default.removeItem(at: micSource) }

        var project = ScreenForgeProject(
            source: SourceInfo(
                screenPath: "media/screen.mov",
                microphonePath: "media/mic.m4a",
                durationMs: 1_000,
                pixelWidth: 320,
                pixelHeight: 320
            )
        )
        project.export = ExportSettings(resolution: .p720, fps: 30, codec: .h264, quality: 0.4)
        try await store.save(project, to: bundle)
        try await store.importMedia(from: micSource, into: bundle, preferredName: "mic.m4a")

        let output = bundle.deletingLastPathComponent()
            .appendingPathComponent("ScreenForgeAudio-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: output) }

        let exporter = Exporter(compositor: compositor)
        _ = try await exporter.export(
            job: ExportJob(project: project, bundleURL: bundle, outputURL: output)
        ) { _ in }

        let asset = AVURLAsset(url: output)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        #expect(audio.count == 1)

        let duration = try await asset.load(.duration)
        #expect(abs(CMTimeGetSeconds(duration) - 1.0) < 0.15)
    }

    @Test("An external audio track is mixed with the microphone")
    func exportWithExternalAudio() async throws {
        guard isHosted, let device = MTLCreateSystemDefaultDevice() else { return }
        let compositor = try Compositor(device: device)

        let bundle = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenForgeExternal-\(UUID().uuidString).sforge", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: bundle) }

        let store = ProjectStore.shared
        try await store.createBundle(at: bundle)
        let media = bundle.appendingPathComponent(ProjectBundleLayout.mediaDirectory, isDirectory: true)
        try writeScreenMovie(to: media.appendingPathComponent("screen.mov"), seconds: 1.0)

        let toneSource = bundle.deletingLastPathComponent()
            .appendingPathComponent("external-\(UUID().uuidString).m4a")
        try writeTone(to: toneSource, seconds: 1.0)
        defer { try? FileManager.default.removeItem(at: toneSource) }

        var project = ScreenForgeProject(
            source: SourceInfo(
                screenPath: "media/screen.mov",
                externalAudioPath: "media/external.m4a",
                durationMs: 1_000,
                pixelWidth: 320,
                pixelHeight: 320
            )
        )
        project.export = ExportSettings(resolution: .p720, fps: 30, codec: .h264, quality: 0.4)
        project.audio.externalVolume = 0.7
        try await store.save(project, to: bundle)
        try await store.importMedia(from: toneSource, into: bundle, preferredName: "external.m4a")

        let output = bundle.deletingLastPathComponent()
            .appendingPathComponent("ScreenForgeExternal-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: output) }

        let exporter = Exporter(compositor: compositor)
        _ = try await exporter.export(
            job: ExportJob(project: project, bundleURL: bundle, outputURL: output)
        ) { _ in }

        let asset = AVURLAsset(url: output)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        #expect(audio.count >= 1)
    }

    @Test("ProRes export writes a .mov with the requested profile")
    func exportProRes() async throws {
        guard isHosted, let device = MTLCreateSystemDefaultDevice() else { return }
        let compositor = try Compositor(device: device)

        let bundle = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenForgeProRes-\(UUID().uuidString).sforge", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: bundle) }

        let store = ProjectStore.shared
        try await store.createBundle(at: bundle)
        let media = bundle.appendingPathComponent(ProjectBundleLayout.mediaDirectory, isDirectory: true)
        try writeScreenMovie(to: media.appendingPathComponent("screen.mov"), seconds: 0.6)

        var project = ScreenForgeProject(
            source: SourceInfo(
                screenPath: "media/screen.mov",
                durationMs: 600,
                pixelWidth: 320,
                pixelHeight: 320
            )
        )
        project.export = ExportSettings(
            resolution: .p720,
            fps: 30,
            codec: .proRes422LT,
            quality: 1
        )
        try await store.save(project, to: bundle)

        let output = bundle.deletingLastPathComponent()
            .appendingPathComponent("ScreenForgeProRes-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: output) }

        let exporter = Exporter(compositor: compositor)
        _ = try await exporter.export(
            job: ExportJob(project: project, bundleURL: bundle, outputURL: output)
        ) { _ in }

        #expect(output.pathExtension == "mov")
        let asset = AVURLAsset(url: output)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let formats = try await track.load(.formatDescriptions)
        let subtype = formats.first.map { CMFormatDescriptionGetMediaSubType($0) }
        #expect(subtype == kCMVideoCodecType_AppleProRes422LT)
        let natural = try await track.load(.naturalSize)
        #expect(natural.width == 1_280)
    }

    @Test("An imported music clip is mixed into the exported movie")
    func exportWithMusicClip() async throws {
        guard isHosted, let device = MTLCreateSystemDefaultDevice() else { return }
        let compositor = try Compositor(device: device)

        let bundle = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenForgeMusic-\(UUID().uuidString).sforge", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: bundle) }

        let store = ProjectStore.shared
        try await store.createBundle(at: bundle)
        let media = bundle.appendingPathComponent(ProjectBundleLayout.mediaDirectory, isDirectory: true)
        try writeScreenMovie(to: media.appendingPathComponent("screen.mov"), seconds: 1.0)

        let toneSource = bundle.deletingLastPathComponent()
            .appendingPathComponent("music-\(UUID().uuidString).m4a")
        try writeTone(to: toneSource, seconds: 1.0)
        defer { try? FileManager.default.removeItem(at: toneSource) }

        var project = ScreenForgeProject(
            source: SourceInfo(
                screenPath: "media/screen.mov",
                durationMs: 1_000,
                pixelWidth: 320,
                pixelHeight: 320
            ),
            timeline: Timeline(
                audioClips: [
                    AudioClip(
                        kind: .music,
                        path: "media/music.m4a",
                        startMs: 100,
                        durationMs: 700,
                        fadeInMs: 200,
                        fadeOutMs: 200
                    )
                ]
            )
        )
        project.export = ExportSettings(resolution: .p720, fps: 30, codec: .h264, quality: 0.4)
        project.audio.musicVolume = 0.6
        try await store.save(project, to: bundle)
        try await store.importMedia(from: toneSource, into: bundle, preferredName: "music.m4a")

        let output = bundle.deletingLastPathComponent()
            .appendingPathComponent("ScreenForgeMusic-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: output) }

        let exporter = Exporter(compositor: compositor)
        _ = try await exporter.export(
            job: ExportJob(project: project, bundleURL: bundle, outputURL: output)
        ) { _ in }

        let asset = AVURLAsset(url: output)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        #expect(audio.count >= 1)
        let duration = try await asset.load(.duration)
        #expect(abs(CMTimeGetSeconds(duration) - 1.0) < 0.15)
    }

    @Test("Preview composition carries the same clip mix as export")
    func previewAudioMix() async throws {
        guard isHosted else { return }

        let bundle = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenForgePreview-\(UUID().uuidString).sforge", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: bundle) }

        let store = ProjectStore.shared
        try await store.createBundle(at: bundle)
        let media = bundle.appendingPathComponent(ProjectBundleLayout.mediaDirectory, isDirectory: true)
        try writeScreenMovie(to: media.appendingPathComponent("screen.mov"), seconds: 1.0)

        let toneSource = bundle.deletingLastPathComponent()
            .appendingPathComponent("preview-\(UUID().uuidString).m4a")
        try writeTone(to: toneSource, seconds: 1.0)
        defer { try? FileManager.default.removeItem(at: toneSource) }

        let project = ScreenForgeProject(
            source: SourceInfo(
                screenPath: "media/screen.mov",
                durationMs: 1_000,
                pixelWidth: 320,
                pixelHeight: 320
            ),
            timeline: Timeline(
                audioClips: [
                    AudioClip(
                        kind: .music,
                        path: "media/music.m4a",
                        startMs: 200,
                        durationMs: 600,
                        fadeInMs: 100,
                        fadeOutMs: 100
                    )
                ]
            )
        )
        try await store.save(project, to: bundle)
        try await store.importMedia(from: toneSource, into: bundle, preferredName: "music.m4a")

        let preview = try await PreviewCompositionBuilder.makePreview(
            project: project,
            bundleURL: bundle
        )
        #expect(preview.composition.tracks(withMediaType: .video).count == 1)
        #expect(preview.composition.tracks(withMediaType: .audio).count >= 1)
        #expect(preview.audioMix?.inputParameters.count == preview.composition.tracks(withMediaType: .audio).count)
    }

    @Test("Chapter markers are written into the exported container")
    func exportChapters() async throws {
        guard isHosted, let device = MTLCreateSystemDefaultDevice() else { return }
        let compositor = try Compositor(device: device)

        let bundle = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenForgeChapters-\(UUID().uuidString).sforge", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: bundle) }

        let store = ProjectStore.shared
        try await store.createBundle(at: bundle)
        let media = bundle.appendingPathComponent(ProjectBundleLayout.mediaDirectory, isDirectory: true)
        try writeScreenMovie(to: media.appendingPathComponent("screen.mov"), seconds: 1.0)

        var project = ScreenForgeProject(
            source: SourceInfo(
                screenPath: "media/screen.mov",
                durationMs: 1_000,
                pixelWidth: 320,
                pixelHeight: 320
            ),
            timeline: Timeline(markers: [
                TimelineMarker(timeMs: 0, label: "Intro", kind: .chapter),
                TimelineMarker(timeMs: 500, label: "Demo", kind: .chapter)
            ])
        )
        project.export = ExportSettings(resolution: .p720, fps: 30, codec: .h264, quality: 0.4)
        try await store.save(project, to: bundle)

        let output = bundle.deletingLastPathComponent()
            .appendingPathComponent("ScreenForgeChapters-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: output) }

        let exporter = Exporter(compositor: compositor)
        _ = try await exporter.export(
            job: ExportJob(project: project, bundleURL: bundle, outputURL: output)
        ) { _ in }

        let chapters = try ChapterWriter.readChapters(from: output)
        #expect(chapters.count == 2)
        #expect(chapters.map(\.title) == ["Intro", "Demo"])
        #expect(chapters.map(\.timeMs) == [0, 500])

        // Fast-start files put moov before mdat; chapter insertion must rebase
        // chunk offsets or every frame after the edit point fails to decode.
        let assetAfterChapters = AVURLAsset(url: output)
        let generator = AVAssetImageGenerator(asset: assetAfterChapters)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let frame = try generator.copyCGImage(at: CMTime(seconds: 0.25, preferredTimescale: 600), actualTime: nil)
        #expect(frame.width == 1_280)
    }

    @Test("GIF export writes animatable frames")
    func exportGIF() async throws {
        guard isHosted, let device = MTLCreateSystemDefaultDevice() else { return }
        let compositor = try Compositor(device: device)

        let bundle = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenForgeGIF-\(UUID().uuidString).sforge", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: bundle) }

        let store = ProjectStore.shared
        try await store.createBundle(at: bundle)
        let media = bundle.appendingPathComponent(ProjectBundleLayout.mediaDirectory, isDirectory: true)
        try writeScreenMovie(to: media.appendingPathComponent("screen.mov"), seconds: 0.6)

        var project = ScreenForgeProject(
            source: SourceInfo(
                screenPath: "media/screen.mov",
                durationMs: 600,
                pixelWidth: 320,
                pixelHeight: 320
            )
        )
        project.export = ExportSettings(resolution: .p720, fps: 30, codec: .h264, quality: 0.4)
        try await store.save(project, to: bundle)

        let output = bundle.deletingLastPathComponent()
            .appendingPathComponent("ScreenForgeGIF-\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: output) }

        let exporter = Exporter(compositor: compositor)
        let job = ExportJob(
            project: project,
            bundleURL: bundle,
            outputURL: output,
            format: .gif,
            gifFPS: 10,
            gifMaxWidth: 480
        )
        _ = try await exporter.export(job: job) { _ in }

        #expect(FileManager.default.fileExists(atPath: output.path))

        guard let source = CGImageSourceCreateWithURL(output as CFURL, nil) else {
            Issue.record("GIF could not be read")
            return
        }
        #expect(CGImageSourceGetCount(source) >= 4)

        if let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            #expect(image.width <= 480)
        }
    }

    @Test("Missing recording fails with a descriptive error")
    func missingMedia() async throws {
        guard isHosted, let device = MTLCreateSystemDefaultDevice() else { return }
        let compositor = try Compositor(device: device)

        let bundle = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenForgeMissing-\(UUID().uuidString).sforge", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: bundle) }

        let store = ProjectStore.shared
        try await store.createBundle(at: bundle)
        let project = ScreenForgeProject(
            source: SourceInfo(
                screenPath: "media/missing.mov",
                durationMs: 1_000,
                pixelWidth: 320,
                pixelHeight: 320
            )
        )

        let exporter = Exporter(compositor: compositor)
        let job = ExportJob(
            project: project,
            bundleURL: bundle,
            outputURL: bundle.appendingPathComponent("out.mp4")
        )

        await #expect(throws: ExportError.self) {
            _ = try await exporter.export(job: job) { _ in }
        }
    }
}
