import CoreGraphics
import Foundation
import Testing
@testable import ScreenForgeCore

@Suite("Captions")
struct CaptionTests {
    private let canvas = CGSize(width: 1_920, height: 1_080)

    private func words() -> [TranscriptWord] {
        [
            TranscriptWord(text: "Hello", startMs: 500, endMs: 800),
            TranscriptWord(text: "there", startMs: 850, endMs: 1_100),
            TranscriptWord(text: "friend.", startMs: 1_150, endMs: 1_500)
        ]
    }

    private func settings(
        position: CaptionPosition = .bottom,
        style: CaptionStyle = .pill
    ) -> CaptionSettings {
        CaptionSettings(enabled: true, style: style, position: position, wordsPerLine: 5)
    }

    @Test("Track resolves the active cue and word")
    func activeCue() {
        let track = CaptionTrack(words: words(), settings: settings())
        #expect(track.cues.count == 1)

        #expect(track.activeCue(at: 0) == nil)

        let first = try! #require(track.activeCue(at: 500))
        #expect(first.activeWord == 0)

        let middle = try! #require(track.activeCue(at: 900))
        #expect(middle.activeWord == 1)

        // A cue ends after its hold time; later frames have no caption.
        #expect(track.activeCue(at: 60_000) == nil)
    }

    @Test("Gaps between cues hide the caption")
    func gapHidesCaption() {
        let settings = CaptionSettings(enabled: true, wordsPerLine: 2)
        let cues = [
            CaptionCue(
                id: "a",
                text: "first",
                startMs: 0,
                endMs: 1_000,
                wordTimings: [.init(text: "first", startMs: 0, endMs: 500)]
            ),
            CaptionCue(
                id: "b",
                text: "later",
                startMs: 4_000,
                endMs: 5_000,
                wordTimings: [.init(text: "later", startMs: 4_000, endMs: 4_500)]
            )
        ]
        let track = CaptionTrack(cues: cues, settings: settings)
        #expect(track.activeCue(at: 500)?.cue.id == "a")
        #expect(track.activeCue(at: 2_500) == nil)
        #expect(track.activeCue(at: 4_200)?.cue.id == "b")
    }

    @Test("Overlay geometry stays inside the canvas for every position")
    func geometry() {
        for position in CaptionPosition.allCases {
            let rect = CaptionGeometry.overlayRect(canvas: canvas, position: position)
            #expect(rect.minX >= 0)
            #expect(rect.minY >= 0)
            #expect(rect.maxX <= canvas.width)
            #expect(rect.maxY <= canvas.height)
            #expect(abs(rect.midX - canvas.width / 2) < 1)
        }

        let bottom = CaptionGeometry.overlayRect(canvas: canvas, position: .bottom)
        let middle = CaptionGeometry.overlayRect(canvas: canvas, position: .middle)
        let top = CaptionGeometry.overlayRect(canvas: canvas, position: .top)
        #expect(top.minY < middle.minY)
        #expect(middle.minY < bottom.minY)
    }

    @Test("Rasterized captions contain visible pixels")
    func rasterize() throws {
        let cue = try #require(CaptionTrack(words: words(), settings: settings()).cues.first)

        for style in CaptionStyle.allCases {
            let image = try #require(CaptionRasterizer.makeImage(
                cue: cue,
                activeWordIndex: style == .karaoke ? 1 : nil,
                settings: CaptionSettings(enabled: true, style: style, wordsPerLine: 5),
                canvasSize: canvas
            ), "\(style.rawValue) produced no image")

            #expect(image.width > 100)
            #expect(image.height > 30)
            #expect(CaptionRasterizer.opaquePixelCount(in: image) > 100, "\(style.rawValue) has no ink")
        }
    }

    @Test("Uppercase and font scale change the rendered pixels")
    func rasterVariants() throws {
        let cue = try #require(CaptionTrack(words: words(), settings: settings()).cues.first)
        let base = try #require(CaptionRasterizer.makeImage(
            cue: cue,
            activeWordIndex: nil,
            settings: settings(style: .plain),
            canvasSize: canvas
        ))
        let large = try #require(CaptionRasterizer.makeImage(
            cue: cue,
            activeWordIndex: nil,
            settings: CaptionSettings(enabled: true, style: .plain, fontScale: 2),
            canvasSize: canvas
        ))

        // Bigger type covers more pixels.
        #expect(
            CaptionRasterizer.opaquePixelCount(in: large) >
            CaptionRasterizer.opaquePixelCount(in: base)
        )
    }

    @Test("Frame renderer only emits captions when enabled and inside a cue")
    func rendererIntegration() {
        var project = ScreenForgeProject(
            source: SourceInfo(
                screenPath: "media/screen.mov",
                durationMs: 10_000,
                pixelWidth: 1920,
                pixelHeight: 1080
            )
        )
        project.captions = settings()
        let track = CaptionTrack(words: words(), settings: project.captions)

        let enabled = FrameRenderer(project: project, cursorTrack: nil, captionTrack: track)
        let state = enabled.state(atOutputMs: 1_000, canvasSize: canvas)
        let caption = try! #require(state.caption)
        #expect(caption.text == "Hello there friend.")
        #expect(caption.style == .pill)
        #expect(caption.rect.height > 0)

        // Outside every cue.
        #expect(enabled.state(atOutputMs: 9_000, canvasSize: canvas).caption == nil)

        // Disabled captions never render, even with a track attached.
        project.captions.enabled = false
        let disabled = FrameRenderer(project: project, cursorTrack: nil, captionTrack: track)
        #expect(disabled.state(atOutputMs: 1_000, canvasSize: canvas).caption == nil)
    }
}
