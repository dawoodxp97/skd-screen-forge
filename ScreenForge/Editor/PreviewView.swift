import AVFoundation
import MetalKit
import SwiftUI

/// Metal-backed editor preview. Renders the same `FrameRenderer` output as the exporter.
public struct PreviewView: NSViewRepresentable {
    public let document: ProjectDocument
    @ObservedObject public var playback: PlaybackEngine

    public init(document: ProjectDocument, playback: PlaybackEngine) {
        self.document = document
        self.playback = playback
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(document: document, playback: playback)
    }

    public func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: document.compositor?.device)
        view.delegate = context.coordinator
        view.colorPixelFormat = Compositor.pixelFormat
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 60
        view.autoResizeDrawable = true
        view.enableSetNeedsDisplay = true
        view.isPaused = true
        view.clearColor = MTLClearColor(red: 0.04, green: 0.04, blue: 0.05, alpha: 1)
        view.wantsLayer = true
        context.coordinator.attach(view: view)
        return view
    }

    public func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.document = document
        context.coordinator.playback = playback
        view.isPaused = !playback.isPlaying
        view.setNeedsDisplay(view.bounds)
    }

    public static func dismantleNSView(_ view: MTKView, coordinator: Coordinator) {
        view.delegate = nil
        view.isPaused = true
    }

    // MARK: - Coordinator

    public final class Coordinator: NSObject, MTKViewDelegate {
        var document: ProjectDocument
        var playback: PlaybackEngine
        private let compositor: Compositor?
        private var lastFrame: MetalFrameTexture?
        private var lastBuffer: CVPixelBuffer?
        private weak var mtkView: MTKView?

        init(document: ProjectDocument, playback: PlaybackEngine) {
            self.document = document
            self.playback = playback
            self.compositor = document.compositor
        }

        func attach(view: MTKView) {
            mtkView = view
        }

        public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            view.setNeedsDisplay(view.bounds)
        }

        public func draw(in view: MTKView) {
            MainActor.assumeIsolated {
                guard view.drawableSize.width > 2,
                      view.drawableSize.height > 2,
                      let compositor,
                      let pass = view.currentRenderPassDescriptor,
                      let drawable = view.currentDrawable,
                      let commandBuffer = compositor.commandQueue.makeCommandBuffer() else {
                    return
                }

                if let buffer = playback.currentPixelBuffer() {
                    lastBuffer = buffer
                    if let frame = compositor.texture(from: buffer) {
                        lastFrame = frame
                    }
                }

                let state = document.renderer.state(
                    atOutputMs: playback.outputTimeMs,
                    canvasSize: view.drawableSize
                )

                compositor.encode(
                    state: state,
                    screen: lastFrame?.texture,
                    camera: nil,
                    in: pass,
                    commandBuffer: commandBuffer
                )
                commandBuffer.present(drawable)
                commandBuffer.commit()
            }
        }
    }
}
