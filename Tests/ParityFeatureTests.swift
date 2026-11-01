import Foundation
import Testing
@testable import ScreenForge

// MARK: - Schema compatibility

@Suite("Schema compatibility")
struct SchemaCompatibilityTests {
    /// A v1 project written before audio, analysis, markers, and clips existed.
    private let legacyJSON = """
    {
      "schemaVersion": 1,
      "id": "8F0A5E2C-3B7B-4A8A-9C1D-2E3F4A5B6C7D",
      "createdAt": "2026-01-02T03:04:05.000Z",
      "updatedAt": "2026-01-02T03:04:05.000Z",
      "source": {
        "screenPath": "media/screen.mov",
        "durationMs": 5000,
        "pixelWidth": 1920,
        "pixelHeight": 1080,
        "scale": 2,
        "displayName": "Legacy",
        "cursorCaptureMode": "syntheticOverlay"
      },
      "canvas": {
        "aspect": "wide",
        "background": {
          "kind": "gradient",
          "identifier": "midnight",
          "colors": ["#141E30", "#243B55"],
          "blurRadius": 0
        },
        "padding": 0.06,
        "inset": 0,
        "cornerRadius": 0.02,
        "shadow": {"angle": 90, "distance": 0.03, "blur": 0.06, "opacity": 0.35}
      },
      "camera": {"enabled": false, "mirrored": true, "sizeFraction": 0.22, "mask": "rounded", "reactiveZoom": true, "faceTracking": true, "hideDuringSilence": false, "shadowOpacity": 0.25},
      "timeline": {
        "zooms": [],
        "trims": [],
        "speeds": [],
        "annotations": [],
        "layouts": [],
        "transcriptEdits": [],
        "autoZoomEnabled": true,
        "autoFocusEnabled": false
      },
      "cursor": {"visible": true, "scale": 1.6, "smoothing": 0.65, "motionBlur": 0.3, "theme": "filledArrow", "clickEffect": "ripple", "clickEffectScale": 1, "hideWhenIdleMs": 2500, "loopToStart": false, "clipToBounds": false},
      "captions": {"enabled": false, "style": "pill", "position": "bottom", "wordsPerLine": 5, "fontScale": 1, "uppercase": false, "language": "en-US"},
      "export": {"resolution": "p1080", "fps": 60, "codec": "hevc", "quality": 0.8, "includeAudio": true, "audioBitrateKbps": 192}
    }
    """

    @Test("A schema v1 project decodes with defaults for new fields")
    func decodesLegacyProject() throws {
        let project = try ProjectCodec.decode(Data(legacyJSON.utf8))

        #expect(project.schemaVersion == ScreenForgeProject.currentSchemaVersion)
        #expect(project.audio == .default)
        #expect(project.analysis == .empty)
        #expect(project.timeline.markers.isEmpty)
        #expect(project.timeline.audioClips.isEmpty)
        #expect(project.source.durationMs == 5_000)
    }

    @Test("New fields survive an encode/decode round trip")
    func roundTripsNewFields() throws {
        var project = try ProjectCodec.decode(Data(legacyJSON.utf8))
        project.audio.musicVolume = 0.55
        project.audio.duckMusicUnderVoice = false
        project.analysis.silenceRanges = [SilenceRange(startMs: 1_000, endMs: 2_000)]
        project.analysis.faceSamples = [FaceSample(timeMs: 500, x: 0.4, y: 0.3, confidence: 0.9)]
        project.timeline.markers = [TimelineMarker(timeMs: 1_500, label: "Intro", kind: .chapter)]
        project.timeline.audioClips = [
            AudioClip(kind: .music, path: "media/music.m4a", startMs: 0, durationMs: 4_000, fadeInMs: 300)
        ]

        let decoded = try ProjectCodec.decode(ProjectCodec.encode(project))
        #expect(decoded.audio.musicVolume == 0.55)
        #expect(decoded.audio.duckMusicUnderVoice == false)
        #expect(decoded.analysis.silenceRanges.count == 1)
        #expect(decoded.analysis.faceSamples.first?.confidence == 0.9)
        #expect(decoded.timeline.markers.first?.kind == .chapter)
        #expect(decoded.timeline.audioClips.first?.fadeInMs == 300)
    }
}

// MARK: - Analysis

@Suite("Audio and face analysis")
struct AnalysisTests {
    @Test("Silent windows become padded, merged ranges")
    func silenceWindows() {
        var windows: [(startMs: Int, endMs: Int, silent: Bool)] = []
        for index in 0..<60 {
            windows.append((index * 50, index * 50 + 50, index >= 20 && index < 40))
        }
        let ranges = SilenceDetector.ranges(
            from: windows,
            durationMs: 3_000,
            minimumDurationMs: 400,
            edgePaddingMs: 100
        )
        #expect(ranges.count == 1)
        #expect(ranges[0].startMs == 1_100)
        #expect(ranges[0].endMs == 1_900)
    }

    @Test("Short blips are ignored")
    func shortBlipIgnored() {
        let windows: [(startMs: Int, endMs: Int, silent: Bool)] = [
            (0, 50, true),
            (50, 100, false)
        ]
        let ranges = SilenceDetector.ranges(
            from: windows,
            durationMs: 1_000,
            minimumDurationMs: 400,
            edgePaddingMs: 10
        )
        #expect(ranges.isEmpty)
    }

    @Test("Camera opacity fades at the edges of a silence")
    func cameraOpacity() {
        let analysis = ProjectAnalysis(
            silenceRanges: [SilenceRange(startMs: 1_000, endMs: 2_000)]
        )
        #expect(analysis.cameraOpacity(atSourceMs: 0) == 1)
        #expect(analysis.cameraOpacity(atSourceMs: 1_000) == 1)
        // 90 ms into a 180 ms fade: roughly half faded out.
        let midFade = analysis.cameraOpacity(atSourceMs: 1_090)
        #expect(midFade > 0.4 && midFade < 0.6)
        #expect(analysis.cameraOpacity(atSourceMs: 1_180) == 0)
        #expect(analysis.cameraOpacity(atSourceMs: 1_500) == 0)
        #expect(analysis.cameraOpacity(atSourceMs: 2_000) == 1)
        #expect(analysis.cameraOpacity(atSourceMs: 2_500) == 1)
    }

    @Test("Face samples are smoothed without drifting")
    func faceSmoothing() {
        let samples = [
            FaceSample(timeMs: 0, x: 0.2, y: 0.5),
            FaceSample(timeMs: 500, x: 0.5, y: 0.5),
            FaceSample(timeMs: 1_000, x: 0.8, y: 0.5)
        ]
        let smoothed = FaceDetector.smoothed(samples)
        #expect(abs(smoothed[1].x - 0.5) < 0.0001)
        #expect(abs(smoothed[0].x - 0.2) < 0.0001)
        #expect(abs(smoothed[2].x - 0.8) < 0.0001)
    }
}

// MARK: - Markers and clips

@Suite("Markers and audio clips")
struct MarkerAndClipTests {
    @Test("Markers clamp to the output timeline, not the source duration")
    func markerClamping() {
        let project = ScreenForgeProject(
            source: SourceInfo(
                screenPath: "media/screen.mov",
                durationMs: 10_000,
                pixelWidth: 1920,
                pixelHeight: 1080
            ),
            timeline: Timeline(
                trims: [TrimRegion(startMs: 2_000, endMs: 4_000)],
                markers: [
                    TimelineMarker(timeMs: 7_000),
                    TimelineMarker(timeMs: 3_000),
                    TimelineMarker(timeMs: 99_000)
                ]
            )
        )
        let normalized = project.normalized()
        // Markers are already output time: they sort and clamp to the 8 s edit.
        #expect(normalized.timeline.markers.count == 3)
        #expect(normalized.timeline.markers.map(\.timeMs) == [3_000, 7_000, 8_000])
    }

    @Test("Markers recorded during pauses are dropped and later ones shifted")
    func markerRebase() {
        let pauses = [PauseInterval(startMs: 1_000, endMs: 3_000)]
        let markers = [
            TimelineMarker(timeMs: 500, label: "before"),
            TimelineMarker(timeMs: 2_000, label: "inside"),
            TimelineMarker(timeMs: 4_000, label: "after")
        ]
        let rebased = RecordingFinalizer.rebaseMarkers(markers, pauses: pauses)
        #expect(rebased.count == 2)
        #expect(rebased.map(\.label) == ["before", "after"])
        #expect(rebased.map(\.timeMs) == [500, 2_000])
    }

    @Test("Clip fades stay inside the clip after normalization")
    func clipFadeClamping() {
        let clip = AudioClip(
            kind: .music,
            path: "media/music.m4a",
            startMs: 500,
            durationMs: 1_000,
            fadeInMs: 900,
            fadeOutMs: 900
        )
        let clamped = clip.clamped(toDuration: 10_000)
        #expect(clamped.fadeInMs == 900)
        #expect(clamped.fadeOutMs == 100)
        #expect(clamped.volume == 1)
    }

    @Test("Clips past the end of the edit are trimmed away")
    func clipOutsideTimeline() {
        let clip = AudioClip(kind: .music, path: "media/music.m4a", startMs: 2_000, durationMs: 5_000)
        #expect(clip.clamped(toDuration: 3_000).durationMs == 1_000)
    }
}

// MARK: - Rendering parity

@Suite("Parity rendering")
struct ParityRenderingTests {
    private func project(
        zooms: [ZoomRegion] = [],
        analysis: ProjectAnalysis = .empty,
        camera: CameraSettings = CameraSettings(enabled: true)
    ) -> ScreenForgeProject {
        ScreenForgeProject(
            source: SourceInfo(
                screenPath: "media/screen.mov",
                webcamPath: "media/webcam.mov",
                durationMs: 10_000,
                pixelWidth: 1920,
                pixelHeight: 1080
            ),
            camera: camera,
            timeline: Timeline(zooms: zooms),
            analysis: analysis
        )
    }

    @Test("Loupe zooms keep their kind in the render state")
    func loupeKind() {
        let region = ZoomRegion(startMs: 0, endMs: 5_000, scale: 2, kind: .loupe)
        let renderer = FrameRenderer(project: project(zooms: [region]))
        let state = renderer.state(atOutputMs: 2_500, canvasSize: CGSize(width: 1920, height: 1080))
        #expect(state.zoomKind == .loupe)
        #expect(state.zoomScale > 1.9)
    }

    @Test("Classic zooms remain the default")
    func classicKind() {
        let region = ZoomRegion(startMs: 0, endMs: 5_000, scale: 2)
        let renderer = FrameRenderer(project: project(zooms: [region]))
        let state = renderer.state(atOutputMs: 2_500, canvasSize: CGSize(width: 1920, height: 1080))
        #expect(state.zoomKind == .classic)
    }

    @Test("Hide during silence fades the camera layer only")
    func cameraFade() {
        let settings = CameraSettings(enabled: true, hideDuringSilence: true)
        let analysis = ProjectAnalysis(silenceRanges: [SilenceRange(startMs: 0, endMs: 2_000)])
        let renderer = FrameRenderer(project: project(analysis: analysis, camera: settings))

        let silent = renderer.state(atOutputMs: 1_000, canvasSize: CGSize(width: 1920, height: 1080))
        #expect(silent.cameraOpacity == 0)
        #expect(silent.screenRect != nil)

        let speaking = renderer.state(atOutputMs: 5_000, canvasSize: CGSize(width: 1920, height: 1080))
        #expect(speaking.cameraOpacity == 1)
    }

    @Test("Face samples reframe the camera")
    func faceReframe() {
        let analysis = ProjectAnalysis(faceSamples: [
            FaceSample(timeMs: 1_000, x: 0.2, y: 0.3, confidence: 0.9)
        ])
        let renderer = FrameRenderer(project: project(analysis: analysis))
        let state = renderer.state(atOutputMs: 1_100, canvasSize: CGSize(width: 1920, height: 1080))
        #expect(abs(state.cameraFocus.x - 0.2) < 0.001)
        #expect(abs(state.cameraFocus.y - 0.3) < 0.001)
        #expect(state.cameraZoom > 1)
    }
}

// MARK: - Export presets

@Suite("Export presets")
struct ExportPresetTests {
    @Test("Every Screen Studio preset is available")
    func builtIns() {
        let names = ExportPreset.builtIn.map(\.name)
        #expect(names.contains("MP4 4K Studio 60"))
        #expect(names.contains("MP4 4K Social 60"))
        #expect(names.contains("MP4 720p Web Low 10"))
        #expect(names.contains("MP4 720p Web High 60"))
        #expect(names.contains("MP4 1080p Social 60"))
        #expect(names.contains("MP4 1080p Studio 30"))
        #expect(names.contains("ProRes 4K 422 HQ 60"))
        #expect(names.contains("ProRes 1080p 4444 30"))
    }

    @Test("ProRes presets deliver .mov and H.264 presets deliver .mp4")
    func extensions() {
        for preset in ExportPreset.builtIn {
            let expected = preset.settings.codec.isProRes ? "mov" : "mp4"
            #expect(preset.settings.fileExtension == expected)
        }
    }

    @Test("Preset matching ignores quality but tracks codec and fps")
    func matching() {
        let preset = ExportPreset.builtIn[0]
        #expect(preset.matches(preset.settings))
        var changed = preset.settings
        changed.quality = 1
        #expect(preset.matches(changed))
        changed.fps = 30
        #expect(!preset.matches(changed))
    }

    @Test("Long edge uses the canvas aspect ratio")
    func canvasSize() {
        var project = ScreenForgeProject(
            source: SourceInfo(
                screenPath: "media/screen.mov",
                durationMs: 1_000,
                pixelWidth: 1920,
                pixelHeight: 1080
            )
        )
        let wide = Exporter.canvasSize(
            project: project,
            settings: ExportSettings(resolution: .p4k, codec: .proRes422HQ)
        )
        #expect(wide.width == 3_840)
        #expect(wide.height == 2_160)

        project.canvas.aspect = .vertical
        let vertical = Exporter.canvasSize(
            project: project,
            settings: ExportSettings(resolution: .p1080, codec: .proRes4444)
        )
        #expect(vertical.height == 1_920)
        #expect(vertical.width == 1_080)
    }
}
