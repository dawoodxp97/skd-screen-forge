import CoreGraphics
import Foundation
import Testing
@testable import ScreenForge

@Suite("Frame rendering")
struct FrameRendererTests {
    private func project(
        durationMs: Int = 10_000,
        aspect: AspectRatio = .wide,
        camera: CameraSettings = .default,
        timeline: Timeline = .empty,
        cursor: CursorSettings = CursorSettings(visible: false)
    ) -> ScreenForgeProject {
        ScreenForgeProject(
            source: SourceInfo(
                screenPath: "media/screen.mov",
                durationMs: durationMs,
                pixelWidth: 3024,
                pixelHeight: 1_964
            ),
            canvas: CanvasSettings(aspect: aspect),
            camera: camera,
            timeline: timeline,
            cursor: cursor
        )
    }

    private let canvas = CGSize(width: 1_920, height: 1_080)

    @Test("Screen-only frame is centered, padded, and keeps the source aspect")
    func screenOnly() {
        let renderer = FrameRenderer(project: project())
        let state = renderer.state(atOutputMs: 0, canvasSize: canvas)

        let rect = try! #require(state.screenRect)
        #expect(state.layout == .screenOnly)
        #expect(state.cameraRect == nil)

        // Padded inside the canvas on all sides.
        let padding = 0.06 * 1_080
        #expect(rect.minX >= padding - 0.01)
        #expect(rect.minY >= padding - 0.01)
        #expect(rect.maxX <= 1_920 - padding + 0.01)
        #expect(rect.maxY <= 1_080 - padding + 0.01)

        // Centered.
        #expect(abs(rect.midX - 960) < 0.01)
        #expect(abs(rect.midY - 540) < 0.01)

        // Aspect matches the recording.
        #expect(abs(rect.width / rect.height - 3_024.0 / 1_964.0) < 0.01)
    }

    @Test("Zoom ramps up inside the region and is neutral outside it")
    func zoomEnvelope() {
        let timeline = Timeline(
            zooms: [ZoomRegion(startMs: 2_000, endMs: 6_000, scale: 2.4, focus: ZoomFocus(x: 0.5, y: 0.5))]
        )
        let renderer = FrameRenderer(project: project(timeline: timeline))

        #expect(renderer.state(atOutputMs: 1_000, canvasSize: canvas).zoomScale == 1)
        #expect(renderer.state(atOutputMs: 8_000, canvasSize: canvas).zoomScale == 1)
        #expect(abs(renderer.state(atOutputMs: 4_000, canvasSize: canvas).zoomScale - 2.4) < 0.001)

        // Envelope is monotonic on the way in.
        let quarter = renderer.state(atOutputMs: 2_100, canvasSize: canvas).zoomScale
        let half = renderer.state(atOutputMs: 2_210, canvasSize: canvas).zoomScale
        #expect(quarter < half)

        // The studio curve is a slight ease-out-back, so it may overshoot the target
        // by a few percent before settling — but only a few percent.
        #expect(half <= 2.4 * 1.12)

        // Overshoot never escapes the supported zoom range.
        let peak = (0..<220).map {
            renderer.state(atOutputMs: 2_000 + Double($0) * 4, canvasSize: canvas).zoomScale
        }.max() ?? 1
        #expect(peak <= 5.0)
    }

    @Test("Cursor at the zoom focus lands in the middle of the screen frame")
    func cursorMapping() {
        let timeline = Timeline(
            zooms: [ZoomRegion(startMs: 0, endMs: 10_000, scale: 2, focus: ZoomFocus(x: 0.5, y: 0.5))]
        )
        let settings = CursorSettings(visible: true, smoothing: 0, hideWhenIdleMs: 0)
        let samples = [CursorSample(timeMs: 0, x: 0.5, y: 0.5)]
        let renderer = FrameRenderer(
            project: project(timeline: timeline, cursor: settings),
            cursorSamples: samples
        )

        let state = renderer.state(atOutputMs: 4_000, canvasSize: canvas)
        let rect = try! #require(state.screenRect)
        #expect(state.cursorVisible)
        #expect(abs(state.cursorCanvasPoint.x - rect.midX) < 1)
        #expect(abs(state.cursorCanvasPoint.y - rect.midY) < 1)
        #expect(state.cursorCanvasSize > 10)
    }

    @Test("Off-screen cursor is hidden rather than clamped")
    func cursorOutsideViewport() {
        let timeline = Timeline(
            zooms: [ZoomRegion(startMs: 0, endMs: 10_000, scale: 2, focus: ZoomFocus(x: 0.25, y: 0.25))]
        )
        let settings = CursorSettings(visible: true, smoothing: 0, hideWhenIdleMs: 0)
        let samples = [CursorSample(timeMs: 0, x: 0.95, y: 0.95)]
        let renderer = FrameRenderer(
            project: project(timeline: timeline, cursor: settings),
            cursorSamples: samples
        )

        let state = renderer.state(atOutputMs: 4_000, canvasSize: canvas)
        #expect(!state.cursorVisible)
    }

    @Test("Split layout keeps both panes inside the padded content box")
    func splitLayout() {
        let timeline = Timeline(
            layouts: [LayoutRegion(startMs: 0, endMs: 10_000, kind: .split)]
        )
        let renderer = FrameRenderer(
            project: project(camera: CameraSettings(enabled: true), timeline: timeline)
        )
        let state = renderer.state(atOutputMs: 5_000, canvasSize: canvas)

        let screen = try! #require(state.screenRect)
        let camera = try! #require(state.cameraRect)
        #expect(state.layout == .split)
        #expect(!screen.intersects(camera))
        #expect(screen.maxX <= 1_920 - 64.8 + 0.01)
        #expect(camera.minX >= 64.8 - 0.01)
        #expect(screen.minY >= 64.8 - 0.01)
    }

    @Test("Camera overlay stays inside the canvas and near the configured size")
    func cameraOverlay() {
        let camera = CameraSettings(enabled: true, sizeFraction: 0.22)
        let renderer = FrameRenderer(project: project(camera: camera))
        let state = renderer.state(atOutputMs: 1_000, canvasSize: canvas)
        let rect = try! #require(state.cameraRect)

        #expect(state.cameraOpacity == 1)
        #expect(rect.minX >= 0)
        #expect(rect.minY >= 0)
        #expect(rect.maxX <= canvas.width + 0.01)
        #expect(rect.maxY <= canvas.height + 0.01)
        #expect(abs(rect.width - 0.22 * 1_080) < 1)
    }

    @Test("Vertical canvas reflows the screen frame")
    func verticalCanvas() {
        let renderer = FrameRenderer(project: project(aspect: .vertical))
        let state = renderer.state(atOutputMs: 1_000, canvasSize: CGSize(width: 1_080, height: 1_920))
        let rect = try! #require(state.screenRect)

        #expect(rect.width <= 1_080)
        #expect(rect.height <= 1_920)
        #expect(abs(rect.width / rect.height - 3_024.0 / 1_964.0) < 0.01)
        #expect(abs(rect.midX - 540) < 0.01)
    }

    @Test("Output time follows trims and speed regions")
    func outputTimeMapping() {
        let timeline = Timeline(
            trims: [TrimRegion(startMs: 0, endMs: 2_000)],
            speeds: [SpeedRegion(startMs: 4_000, endMs: 8_000, rate: 2)]
        )
        let renderer = FrameRenderer(project: project(timeline: timeline))

        // 8s of media remains after the trim, and the speed region halves 4s.
        #expect(abs(Double(renderer.outputDurationMs) - 6_000) < 0.001)

        // Output 0 starts after the cut, not at the trimmed head.
        let state = renderer.state(atOutputMs: 0, canvasSize: canvas)
        #expect(abs(state.sourceTimeMs - 2_000) < 0.001)
    }

    @Test("Normalization clamps user-editable values")
    func normalization() {
        var bad = project()
        bad.canvas.padding = 0.9
        bad.canvas.cornerRadius = -1
        bad.cursor.scale = 99
        bad.export.fps = 47

        let clean = bad.normalized()
        #expect(clean.canvas.padding == 0.45)
        #expect(clean.canvas.cornerRadius == 0)
        #expect(clean.cursor.scale == 5)
        #expect(clean.export.fps == 60)
    }
}

@Suite("Export settings")
struct ExportSettingsTests {
    @Test("Canvas size respects the requested long edge and aspect")
    func canvasSize() {
        let project = ScreenForgeProject(
            source: SourceInfo(
                screenPath: "media/screen.mov",
                durationMs: 1_000,
                pixelWidth: 1920,
                pixelHeight: 1080
            )
        )

        let wide = Exporter.canvasSize(project: project, settings: ExportSettings(resolution: .p1080))
        #expect(wide == CGSize(width: 1_920, height: 1_080))

        var vertical = project
        vertical.canvas.aspect = .vertical
        let reel = Exporter.canvasSize(project: vertical, settings: ExportSettings(resolution: .p1080))
        #expect(reel == CGSize(width: 1_080, height: 1_920))
    }

    @Test("Custom long edge is honored and clamped")
    func customLongEdge() {
        let project = ScreenForgeProject(
            source: SourceInfo(
                screenPath: "media/screen.mov",
                durationMs: 1_000,
                pixelWidth: 1920,
                pixelHeight: 1080
            )
        )
        let settings = ExportSettings(resolution: .custom, customLongEdge: 12_000).normalized()
        #expect(settings.customLongEdge == 7_680)

        let size = Exporter.canvasSize(project: project, settings: settings)
        #expect(size.width == 7_680)
        #expect(abs(size.height - 4_320) < 0.5)
    }
}
