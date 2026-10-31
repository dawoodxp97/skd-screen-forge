import CoreGraphics
import Foundation
import Metal
import Testing
@testable import ScreenForge

/// Runtime smoke test for the Metal path.
///
/// The shader library ships inside the app bundle, so this only runs when the test
/// bundle is hosted by `ScreenForge.app` (Xcode's test action). Under plain SwiftPM
/// there is no compiled `default.metallib`, and the test is skipped.
@Suite("Metal compositor")
struct MetalCompositorTests {
    private var isHosted: Bool {
        Bundle.main.bundleIdentifier == "studio.screenforge.app"
    }

    @Test("Pipelines load and a solid background renders the expected pixel")
    func solidBackground() throws {
        guard isHosted, let device = MTLCreateSystemDefaultDevice() else { return }
        let compositor = try Compositor(device: device)

        let size = 64
        let offscreen = try #require(compositor.makeOffscreenTexture(width: size, height: size))
        let readback = try #require(device.makeBuffer(length: size * size * 4, options: .storageModeShared))

        let state = RenderState(
            outputTimeMs: 0,
            sourceTimeMs: 0,
            canvasSize: CGSize(width: size, height: size),
            screenRect: nil,
            screenCornerRadius: 0,
            zoomScale: 1,
            zoomFocus: CGPoint(x: 0.5, y: 0.5),
            rotation: nil,
            background: BackgroundStyle(kind: .solid, colors: ["#FF0000"]),
            backgroundImageURL: nil,
            shadow: .none,
            bundleURL: nil,
            cameraRect: nil,
            cameraMask: .none,
            cameraMirrored: false,
            cameraOpacity: 0,
            layout: .screenOnly,
            previousLayout: nil,
            layoutBlend: 1,
            cursor: .hidden,
            cursorTheme: .filledArrow,
            clickEffect: .none,
            clickEffectScale: 1,
            cursorCanvasPoint: .zero,
            cursorCanvasSize: 0,
            cursorVisible: false,
            clickCanvasPoint: nil,
            annotations: [],
            caption: nil
        )

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = offscreen
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        let commandBuffer = try #require(compositor.commandQueue.makeCommandBuffer())
        compositor.encode(state: state, screen: nil, camera: nil, in: pass, commandBuffer: commandBuffer)

        let blit = try #require(commandBuffer.makeBlitCommandEncoder())
        blit.copy(
            from: offscreen,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: size, height: size, depth: 1),
            to: readback,
            destinationOffset: 0,
            destinationBytesPerRow: size * 4,
            destinationBytesPerImage: size * size * 4
        )
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        #expect(commandBuffer.status == .completed)

        let bytes = readback.contents().bindMemory(to: UInt8.self, capacity: size * size * 4)
        let center = ((size / 2) * size + size / 2) * 4
        // BGRA: opaque red.
        #expect(bytes[center + 2] > 240)
        #expect(bytes[center + 1] < 16)
        #expect(bytes[center] < 16)
        #expect(bytes[center + 3] > 240)
    }

    @Test("Cursor, annotation, and caption textures rasterize")
    func textures() throws {
        guard isHosted, let device = MTLCreateSystemDefaultDevice() else { return }
        let compositor = try Compositor(device: device)

        let cursor = try #require(CursorTextureFactory.makeTexture(for: .filledArrow, device: device))
        #expect(cursor.width == CursorTextureFactory.textureSize)

        let annotation = AnnotationRegion(
            type: .text,
            startMs: 0,
            endMs: 1_000,
            text: "Hello",
            rect: NormalizedRect(x: 0.2, y: 0.7, width: 0.6, height: 0.2)
        )
        let textTexture = try #require(AnnotationTextureFactory.makeTexture(
            for: annotation,
            canvasSize: CGSize(width: 1920, height: 1080),
            device: device
        ))
        #expect(textTexture.width > 10)

        let cue = CaptionCue(
            text: "Hello there",
            startMs: 0,
            endMs: 1_000,
            wordTimings: [
                .init(text: "Hello", startMs: 0, endMs: 400),
                .init(text: "there", startMs: 400, endMs: 800)
            ]
        )
        let caption = try #require(CaptionRasterizer.makeTexture(
            cue: cue,
            activeWordIndex: 1,
            settings: CaptionSettings(enabled: true, style: .karaoke),
            canvasSize: CGSize(width: 1920, height: 1080),
            pixelScale: 1,
            device: device
        ))
        #expect(caption.width > 100)
    }
}
