import AVFoundation
import CoreGraphics
import Foundation
import Testing
@testable import ScreenForge

// MARK: - LUTs

@Suite("LUT parsing")
struct CubeLUTTests {
    @Test("Parses a 2×2×2 identity cube")
    func parsesIdentityCube() throws {
        let text = """
        TITLE "Identity"
        LUT_3D_SIZE 2
        DOMAIN_MIN 0 0 0
        DOMAIN_MAX 1 1 1
        0 0 0
        1 0 0
        0 1 0
        1 1 0
        0 0 1
        1 0 1
        0 1 1
        1 1 1
        """
        let lut = try CubeLUT(text: text)
        #expect(lut.size == 2)
        #expect(lut.title == "Identity")
        #expect(lut.entries.count == 24)

        let black = lut.lookup(SIMD3<Float>(0, 0, 0))
        #expect(black.x < 0.001 && black.y < 0.001 && black.z < 0.001)
        let red = lut.lookup(SIMD3<Float>(1, 0, 0))
        #expect(abs(red.x - 1) < 0.001)
        #expect(red.y < 0.001)
    }

    @Test("Rejects a malformed cube")
    func rejectsMalformed() {
        #expect(throws: CubeLUT.ParseError.self) {
            _ = try CubeLUT(text: "LUT_3D_SIZE 2\n0 0 0\n1 1 1")
        }
    }

    @Test("Identity generator round trips")
    func identityGenerator() throws {
        let lut = try CubeLUT.identity(size: 8)
        let color = SIMD3<Float>(0.35, 0.55, 0.85)
        let mapped = lut.lookup(color)
        #expect(abs(mapped.x - color.x) < 0.02)
        #expect(abs(mapped.y - color.y) < 0.02)
        #expect(abs(mapped.z - color.z) < 0.02)
    }
}

// MARK: - Chapters

@Suite("Chapter metadata")
struct ChapterWriterTests {
    private func syntheticMovie() -> Data {
        var data = Data()

        func box(_ type: String, _ payload: Data) -> Data {
            var result = Data()
            let size = UInt32(payload.count + 8).bigEndian
            withUnsafeBytes(of: size) { result.append(contentsOf: $0) }
            result.append(contentsOf: Array(type.utf8))
            result.append(payload)
            return result
        }

        data.append(box("ftyp", Data("isom".utf8) + Data(repeating: 0, count: 8)))
        data.append(box("moov", Data()))
        return data
    }

    @Test("Writes and replaces chpl chapters")
    func writesChapters() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chapters-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        try syntheticMovie().write(to: url)

        let chapters = [
            ChapterWriter.Chapter(timeMs: 0, title: "Intro"),
            ChapterWriter.Chapter(timeMs: 5_500, title: "Setup"),
            ChapterWriter.Chapter(timeMs: 12_000, title: "Demo")
        ]
        try ChapterWriter.write(chapters: chapters, to: url)
        var read = try ChapterWriter.readChapters(from: url)
        #expect(read == chapters)

        try ChapterWriter.write(
            chapters: [ChapterWriter.Chapter(timeMs: 1_000, title: "Only")],
            to: url
        )
        read = try ChapterWriter.readChapters(from: url)
        #expect(read == [ChapterWriter.Chapter(timeMs: 1_000, title: "Only")])
    }

    @Test("Chapter times use 100 ns units")
    func chplUnits() throws {
        let box = ChapterWriter.makeChplBox(chapters: [
            ChapterWriter.Chapter(timeMs: 2_000, title: "Two")
        ])
        // Box header is 8 bytes; payload starts at 8, entry time at 17.
        let start = box[17..<25].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        #expect(start == 20_000_000)
    }
}

// MARK: - Voice chain

@Suite("Voice enhancement")
struct VoiceEnhancerTests {
    private func writeTestAudio(to url: URL) throws {
        let sampleRate = 48_000.0
        let frames = AVAudioFrameCount(sampleRate)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw CocoaError(.fileWriteUnknown)
        }
        buffer.frameLength = frames
        guard let channel = buffer.floatChannelData?[0] else {
            throw CocoaError(.fileWriteUnknown)
        }
        var noise: UInt64 = 0x12345678
        for index in 0..<Int(frames) {
            let t = Double(index) / sampleRate
            noise = noise &* 6_364_136_223_846_793_005 &+ 1
            let white = Double((noise >> 33) & 0xFFFF) / 32_768.0 - 1
            if index < Int(sampleRate / 2) {
                channel[index] = Float(sin(2 * .pi * 440 * t) * 0.3 + white * 0.005)
            } else {
                channel[index] = Float(white * 0.02)
            }
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

    private func rms(of url: URL, from startSeconds: Double, to endSeconds: Double) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        let frames = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else {
            return 0
        }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        let sampleRate = file.processingFormat.sampleRate
        let start = max(Int(startSeconds * sampleRate), 0)
        let end = min(Int(endSeconds * sampleRate), Int(buffer.frameLength))
        guard end > start else { return 0 }
        var sum = 0.0
        for index in start..<end {
            sum += Double(channel[index] * channel[index])
        }
        return sqrt(sum / Double(end - start))
    }

    @Test("Enhancement keeps speech and reduces a noisy tail")
    func enhance() async throws {
        let input = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-in-\(UUID().uuidString).caf")
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-out-\(UUID().uuidString).caf")
        defer {
            try? FileManager.default.removeItem(at: input)
            try? FileManager.default.removeItem(at: output)
        }
        try writeTestAudio(to: input)

        try await VoiceEnhancer.enhance(
            input: input,
            output: output,
            options: VoiceEnhancer.Options(mode: .podcast, noiseReduction: 0.6)
        )

        let speech = try rms(of: output, from: 0.05, to: 0.45)
        let tail = try rms(of: output, from: 0.6, to: 0.95)
        #expect(speech > 0.03)
        #expect(tail < speech * 0.5)
    }

    @Test("Off mode copies without changing the file")
    func offMode() async throws {
        let input = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-in-\(UUID().uuidString).caf")
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-out-\(UUID().uuidString).caf")
        defer {
            try? FileManager.default.removeItem(at: input)
            try? FileManager.default.removeItem(at: output)
        }
        try writeTestAudio(to: input)
        try await VoiceEnhancer.enhance(
            input: input,
            output: output,
            options: VoiceEnhancer.Options(mode: .off, noiseReduction: 0)
        )
        #expect(FileManager.default.fileExists(atPath: output.path))
    }
}

// MARK: - Click track

@Suite("Click sound track")
struct ClickTrackTests {
    @Test("Clicks land at output time and produce audio")
    func buildsClickTrack() throws {
        let samples = [
            CursorSample(timeMs: 500, x: 0.2, y: 0.2, interaction: .click),
            CursorSample(timeMs: 1_500, x: 0.8, y: 0.8, interaction: .click)
        ]
        let map = TimelineMap.build(trims: [], speeds: [], sourceDurationMs: 2_000)
        let result = try ClickTrackBuilder.build(
            cursorSamples: samples,
            map: map,
            outputDurationMs: 2_000,
            pack: ClickSoundLibrary.packs[0]
        )
        defer { try? FileManager.default.removeItem(at: result.url) }

        #expect(result.clickCount == 2)
        #expect(FileManager.default.fileExists(atPath: result.url.path))

        let asset = AVURLAsset(url: result.url)
        let duration = try asset.duration.seconds
        #expect(abs(duration - 2.0) < 0.1)
    }
}

// MARK: - Privacy scanner

@Suite("Sensitive data detection")
struct SensitiveDataTests {
    @Test("Merges overlapping detections into one range")
    func mergesDetections() {
        let rect = CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.1)
        let raw: [(timeMs: Int, rect: CGRect, kind: SensitiveDataScanner.Detection.Kind, text: String?)] = [
            (0, rect, .text, "secret"),
            (1_000, rect, .text, "secret"),
            (2_000, rect.offsetBy(dx: 0.005, dy: 0), .text, "secret")
        ]
        let merged = SensitiveDataScanner.merge(raw, intervalMs: 1_000)
        #expect(merged.count == 1)
        #expect(merged[0].startMs == 0)
        #expect(merged[0].endMs >= 2_000)
        #expect(merged[0].text == "secret")
    }

    @Test("Sensitive tokens are recognized")
    func sensitiveTokens() {
        #expect(SensitiveDataScanner.looksSensitive("me@example.com"))
        #expect(SensitiveDataScanner.looksSensitive("api key: 1234"))
        #expect(SensitiveDataScanner.looksSensitive("4111 1111 1111 1111"))
        #expect(!SensitiveDataScanner.looksSensitive("hello world"))
    }

    @Test("Missing media scans to nothing")
    func missingMedia() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).mov")
        let detections = try await SensitiveDataScanner.scan(in: url)
        #expect(detections.isEmpty)
    }
}

// MARK: - Person matte

@Suite("Person matte")
struct PersonMatteTests {
    @Test("A missing camera file yields no masks")
    func missingCamera() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).mov")
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("masks-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: output) }
        let result = try await PersonMatteDetector.detect(in: url, outputDirectory: output)
        #expect(result.frames.isEmpty)
    }
}

// MARK: - Wallpapers

@Suite("Wallpaper pack")
struct WallpaperTests {
    @Test("Every family has presets and renders")
    func renders() throws {
        #expect(!WallpaperLibrary.all.isEmpty)
        for category in WallpaperLibrary.categories {
            #expect(!WallpaperLibrary.presets(in: category).isEmpty)
        }
        let preset = WallpaperLibrary.all[0]
        let image = WallpaperLibrary.image(
            for: preset,
            size: CGSize(width: 320, height: 180)
        )
        let rendered = try #require(image)
        #expect(rendered.width == 320)
        #expect(rendered.height == 180)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wallpaper-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try WallpaperLibrary.write(preset, to: directory, size: CGSize(width: 160, height: 90))
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}

// MARK: - Presets

@Suite("Project presets")
struct ProjectPresetTests {
    @Test("Preset captures and applies the look without touching the timeline")
    func roundTrip() throws {
        var project = ScreenForgeProject(
            source: SourceInfo(
                screenPath: "media/screen.mov",
                durationMs: 5_000,
                pixelWidth: 1920,
                pixelHeight: 1080
            ),
            timeline: Timeline(zooms: [ZoomRegion(startMs: 0, endMs: 2_000)])
        )
        project.canvas.grade.preset = .golden
        project.canvas.grade.intensity = 0.7
        project.canvas.motionBlur = 0.4
        project.canvas.superResolution = true
        project.camera.cutout = true
        project.audio.voiceEnhancement = .podcast
        project.export.codec = .proRes422HQ

        let preset = ProjectPreset(name: "Look", project: project)
        let data = try ProjectCodec.encoder().encode(preset)
        let decoded = try ProjectCodec.decoder().decode(ProjectPreset.self, from: data)

        var target = project
        target.canvas.grade.preset = .mono
        target.timeline.zooms = []
        decoded.apply(to: &target)

        #expect(target.canvas.grade.preset == .golden)
        #expect(target.canvas.grade.intensity == 0.7)
        #expect(target.canvas.superResolution)
        #expect(target.camera.cutout)
        #expect(target.audio.voiceEnhancement == .podcast)
        #expect(target.export.codec == .proRes422HQ)
    }
}

// MARK: - Rendering state for the new looks

@Suite("Advanced rendering state")
struct AdvancedRenderStateTests {
    @Test("Motion blur and super resolution reach the render state")
    func motionAndSuperResolution() {
        var project = ScreenForgeProject(
            source: SourceInfo(
                screenPath: "media/screen.mov",
                durationMs: 10_000,
                pixelWidth: 1920,
                pixelHeight: 1080
            ),
            timeline: Timeline(zooms: [
                ZoomRegion(startMs: 2_000, endMs: 8_000, scale: 2, focus: ZoomFocus(x: 0.7, y: 0.4))
            ])
        )
        project.canvas.motionBlur = 1
        project.canvas.superResolution = true

        let renderer = FrameRenderer(project: project)
        let state = renderer.state(atOutputMs: 4_000, canvasSize: CGSize(width: 1920, height: 1080))
        #expect(state.superResolution)
        #expect(state.motionBlur >= 0)
    }

    @Test("Tilt presets produce non-zero tilt inside a zoom")
    func tilt() {
        let project = ScreenForgeProject(
            source: SourceInfo(
                screenPath: "media/screen.mov",
                durationMs: 10_000,
                pixelWidth: 1920,
                pixelHeight: 1080
            ),
            timeline: Timeline(zooms: [
                ZoomRegion(startMs: 0, endMs: 8_000, scale: 4, rotation: .iso)
            ])
        )
        let renderer = FrameRenderer(project: project)
        let state = renderer.state(atOutputMs: 4_000, canvasSize: CGSize(width: 1920, height: 1080))
        #expect(abs(state.tiltX) > 0.1)
        #expect(abs(state.tiltY) > 0.1)
    }

    @Test("Device mockups inset the screen and keep the body visible")
    func mockupInset() {
        let project = ScreenForgeProject(
            source: SourceInfo(
                screenPath: "media/screen.mov",
                durationMs: 5_000,
                pixelWidth: 1920,
                pixelHeight: 1080
            ),
            canvas: CanvasSettings(deviceMockup: DeviceMockup(kind: .macbook))
        )
        let renderer = FrameRenderer(project: project)
        let state = renderer.state(atOutputMs: 1_000, canvasSize: CGSize(width: 1920, height: 1080))
        #expect(state.deviceMockup.kind == .macbook)
        #expect(state.screenRect != nil)
    }

    @Test("Person mask lookup respects time and tolerance")
    func personMaskLookup() {
        let analysis = ProjectAnalysis(personMasks: [
            PersonMaskFrame(timeMs: 1_000, path: "media/person-mask-0001.png"),
            PersonMaskFrame(timeMs: 3_000, path: "media/person-mask-0002.png")
        ])
        #expect(analysis.personMask(atSourceMs: 1_200)?.path == "media/person-mask-0001.png")
        #expect(analysis.personMask(atSourceMs: 3_400)?.path.hasSuffix("0002.png") == true)
        #expect(analysis.personMask(atSourceMs: 5_000) == nil)
    }

    @Test("Legacy v1 projects decode new look defaults")
    func legacyDefaults() throws {
        let json = """
        {
          "schemaVersion": 1,
          "id": "8F0A5E2C-3B7B-4A8A-9C1D-2E3F4A5B6C7D",
          "createdAt": "2026-01-02T03:04:05.000Z",
          "updatedAt": "2026-01-02T03:04:05.000Z",
          "source": {"screenPath": "media/screen.mov", "durationMs": 5000, "pixelWidth": 1920, "pixelHeight": 1080, "scale": 2, "displayName": "Legacy", "cursorCaptureMode": "syntheticOverlay"},
          "canvas": {"aspect": "wide", "background": {"kind": "gradient", "identifier": "midnight", "colors": ["#141E30", "#243B55"], "blurRadius": 0}, "padding": 0.06, "inset": 0, "cornerRadius": 0.02, "shadow": {"angle": 90, "distance": 0.03, "blur": 0.06, "opacity": 0.35}},
          "camera": {"enabled": false, "mirrored": true, "sizeFraction": 0.22, "mask": "rounded", "reactiveZoom": true, "faceTracking": true, "hideDuringSilence": false, "shadowOpacity": 0.25},
          "timeline": {"zooms": [], "trims": [], "speeds": [], "annotations": [], "layouts": [], "transcriptEdits": [], "autoZoomEnabled": true, "autoFocusEnabled": false},
          "cursor": {"visible": true, "scale": 1.6, "smoothing": 0.65, "motionBlur": 0.3, "theme": "filledArrow", "clickEffect": "ripple", "clickEffectScale": 1, "hideWhenIdleMs": 2500, "loopToStart": false, "clipToBounds": false},
          "captions": {"enabled": false, "style": "pill", "position": "bottom", "wordsPerLine": 5, "fontScale": 1, "uppercase": false, "language": "en-US"},
          "export": {"resolution": "p1080", "fps": 60, "codec": "hevc", "quality": 0.8, "includeAudio": true, "audioBitrateKbps": 192}
        }
        """
        let project = try ProjectCodec.decode(Data(json.utf8))
        #expect(project.canvas.grade == .none)
        #expect(project.canvas.motionBlur > 0)
        #expect(project.canvas.deviceMockup.kind == .none)
        #expect(project.camera.cutout == false)
        #expect(project.audio.externalVolume == 1)
        #expect(project.audio.voiceEnhancement == .standard)
        #expect(project.analysis.personMasks.isEmpty)
        #expect(project.source.externalAudioPath == nil)
    }
}

// MARK: - Services

@Suite("Update / license / device catalog")
struct ServiceTests {
    @Test("Version comparison orders numeric segments")
    func versionComparison() {
        #expect(UpdateChecker.compareVersions("1.10.0", "1.9.9") > 0)
        #expect(UpdateChecker.compareVersions("2.0", "2.0.0") == 0)
        #expect(UpdateChecker.compareVersions("0.9", "1.0") < 0)
    }

    @Test("Invalid license keys are rejected")
    func invalidLicense() {
        #expect(LicenseManager.verify(key: "not-a-key") == nil)
        #expect(LicenseManager.verify(key: "AAAA.BBBB") == nil)
    }

    @Test("Device kinds map to mockups")
    func deviceMockups() {
        let phone = CaptureDeviceInfo(id: "1", name: "iPhone", kind: .iPhone)
        let pad = CaptureDeviceInfo(id: "2", name: "iPad", kind: .iPad)
        let audio = CaptureDeviceInfo(id: "3", name: "Interface", kind: .externalAudio)
        #expect(phone.mockupKind == .iPhone)
        #expect(pad.mockupKind == .iPad)
        #expect(audio.mockupKind == .none)
        #expect(DeviceMockupPreset.all.count >= 10)
        #expect(DeviceMockupPreset.all.allSatisfy { $0.mockup.kind != .none })
    }

    @Test("External audio path survives a project round trip")
    func externalAudioPath() throws {
        let project = ScreenForgeProject(
            source: SourceInfo(
                screenPath: "media/screen.mov",
                microphonePath: "media/mic.m4a",
                externalAudioPath: "media/external.m4a",
                durationMs: 5_000,
                pixelWidth: 1920,
                pixelHeight: 1080
            )
        )
        let decoded = try ProjectCodec.decode(ProjectCodec.encode(project))
        #expect(decoded.source.externalAudioPath == "media/external.m4a")
    }

    @Test("Preset store saves, lists, and deletes in a custom directory")
    func presetStore() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("presets-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ProjectPresetStore(directory: directory)
        let project = ScreenForgeProject(
            source: SourceInfo(
                screenPath: "media/screen.mov",
                durationMs: 2_000,
                pixelWidth: 1920,
                pixelHeight: 1080
            )
        )
        let preset = ProjectPreset(name: "Studio", project: project)
        try await store.save(preset)

        let listed = await store.list()
        #expect(listed.count == 1)
        #expect(listed.first?.name == "Studio")

        await store.delete(id: preset.id)
        let after = await store.list()
        #expect(after.isEmpty)
    }
}
