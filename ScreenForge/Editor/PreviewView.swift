import AVFoundation
import Combine
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
        context.coordinator.attach(view: view, document: document, playback: playback)
        return view
    }

    public func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.update(document: document, playback: playback)
        view.isPaused = !playback.isPlaying
        view.needsDisplay = true
        // Repaint synchronously while paused so every inspector tweak is visible even if
        // the display-link-driven path is idle.
        if !playback.isPlaying {
            view.draw()
        }
    }

    public static func dismantleNSView(_ view: MTKView, coordinator: Coordinator) {
        view.delegate = nil
        view.isPaused = true
    }

    // MARK: - Coordinator

    public final class Coordinator: NSObject, MTKViewDelegate, @unchecked Sendable {
        /// Test hook: number of frames drawn by any live preview.
        nonisolated(unsafe) public static var drawCount = 0

        private(set) var document: ProjectDocument
        private(set) var playback: PlaybackEngine
        private let compositor: Compositor?
        private var lastFrame: MetalFrameTexture?
        private var lastBuffer: CVPixelBuffer?
        private var lastCameraFrame: MetalFrameTexture?
        private var lastCameraBuffer: CVPixelBuffer?
        private weak var mtkView: MTKView?

        private var cancellables: Set<AnyCancellable> = []
        private var redrawScheduled = false

        init(document: ProjectDocument, playback: PlaybackEngine) {
            self.document = document
            self.playback = playback
            self.compositor = document.compositor
        }

        func attach(view: MTKView, document: ProjectDocument, playback: PlaybackEngine) {
            mtkView = view
            self.document = document
            self.playback = playback
            observe()
        }

        func update(document: ProjectDocument, playback: PlaybackEngine) {
            if self.document !== document {
                self.document = document
                observe()
            }
            self.playback = playback
        }

        /// SwiftUI does not call `updateNSView` for every mutation of an observed
        /// reference type, so the preview listens to the document and player directly.
        private func observe() {
            cancellables.removeAll()

            document.objectWillChange
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.scheduleRedraw() }
                .store(in: &cancellables)

            playback.objectWillChange
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.scheduleRedraw() }
                .store(in: &cancellables)
        }

        private func scheduleRedraw() {
            guard !redrawScheduled else { return }
            redrawScheduled = true
            // `objectWillChange` fires before the value lands; draw on the next turn.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.redrawScheduled = false
                guard let view = self.mtkView else { return }
                view.needsDisplay = true
                if view.isPaused {
                    view.draw()
                }
            }
        }

        public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            view.needsDisplay = true
        }

        public func draw(in view: MTKView) {
            MainActor.assumeIsolated {
                Coordinator.drawCount += 1
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

                if let buffer = playback.currentCameraPixelBuffer() {
                    lastCameraBuffer = buffer
                    if let frame = compositor.texture(from: buffer) {
                        lastCameraFrame = frame
                    }
                }

                let state = document.renderer.state(
                    atOutputMs: playback.outputTimeMs,
                    canvasSize: view.drawableSize
                )

                compositor.encode(
                    state: state,
                    screen: lastFrame?.texture,
                    camera: lastCameraFrame?.texture,
                    in: pass,
                    commandBuffer: commandBuffer
                )
                commandBuffer.present(drawable)
                commandBuffer.commit()
            }
        }
    }
}
