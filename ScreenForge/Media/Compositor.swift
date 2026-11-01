import CoreGraphics
import CoreVideo
import Foundation
import Metal
import MetalKit
import simd

public enum CompositorError: LocalizedError, Sendable {
    case metalUnavailable
    case commandQueueUnavailable
    case libraryUnavailable(String)
    case pipelineFailed(String)

    public var errorDescription: String? {
        switch self {
        case .metalUnavailable:
            "This Mac does not provide a Metal device."
        case .commandQueueUnavailable:
            "Could not create a Metal command queue."
        case .libraryUnavailable(let reason):
            "Could not load the Metal shader library: \(reason)"
        case .pipelineFailed(let reason):
            "Could not create a render pipeline: \(reason)"
        }
    }
}

/// Retains the `CVMetalTexture` wrapper for as long as its `MTLTexture` is in use.
public struct MetalFrameTexture: @unchecked Sendable {
    public let texture: MTLTexture
    private let cvTexture: CVMetalTexture?

    public init(texture: MTLTexture, cvTexture: CVMetalTexture? = nil) {
        self.texture = texture
        self.cvTexture = cvTexture
    }
}

// MARK: - Uniforms (must match Shaders.metal)

struct QuadUniforms {
    var color: SIMD4<Float>
    var cornerRadius: Float
    var opacity: Float
    var rect: SIMD4<Float>
    var maskShape: Int32
    var pad0: Int32
    var zoom: Float
    var focusX: Float
    var focusY: Float
    var mirror: Float
    var pad1: Float
    var pad2: Float
    var motionBlur: Float = 0
    var blurDirX: Float = 0
    var blurDirY: Float = 0
    var sharpen: Float = 0
    var grain: Float = 0
    var gradeIndex: Float = 0
    var gradeIntensity: Float = 1
    var superRes: Float = 0
    var hasLUT: Float = 0
    var pad3: Float = 0
    var pad4: Float = 0
    var pad5: Float = 0
}

struct ShadowUniforms {
    var color: SIMD4<Float>
    var rect: SIMD4<Float>
    var cornerRadius: Float
    var blur: Float
    var shapeSize: SIMD2<Float>
    var pad: SIMD2<Float>
}

struct GradientUniforms {
    var topColor: SIMD4<Float>
    var bottomColor: SIMD4<Float>
}

struct RingUniforms {
    var color: SIMD4<Float>
    var center: SIMD2<Float>
    var radius: Float
    var thickness: Float
    var aspect: Float
    var pad0: Float
    var pad1: Float
    var pad2: Float
}

struct BackdropUniforms {
    var texelSize: SIMD2<Float>
    var radius: Float
    var dim: Float
    var uvRect: SIMD4<Float>
}

// MARK: - Compositor

/// Draws a `RenderState` with Metal. Used by both the live preview and the exporter,
/// which guarantees WYSIWYG output.
public final class Compositor: @unchecked Sendable {
    public static let pixelFormat: MTLPixelFormat = .bgra8Unorm

    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue

    private let library: MTLLibrary
    private let cvTextureCache: CVMetalTextureCache
    private let pipelines: Pipelines
    private let lock = NSLock()

    private var imageTextures: [String: MTLTexture] = [:]
    private var cursorTextures: [CursorTheme: MTLTexture] = [:]
    private var annotationTextures: [String: MTLTexture] = [:]
    private var captionTextures: [String: MTLTexture] = [:]
    private var maskTextures: [String: MTLTexture] = [:]
    private var lutTextures: [String: MTLTexture] = [:]

    private struct Pipelines {
        let textured: MTLRenderPipelineState
        let cutout: MTLRenderPipelineState
        let cursor: MTLRenderPipelineState
        let solid: MTLRenderPipelineState
        let gradient: MTLRenderPipelineState
        let shadow: MTLRenderPipelineState
        let ring: MTLRenderPipelineState
        let backdrop: MTLRenderPipelineState
    }

    public init(device: MTLDevice? = MTLCreateSystemDefaultDevice(), library libraryOverride: MTLLibrary? = nil) throws {
        guard let device else { throw CompositorError.metalUnavailable }
        self.device = device

        guard let queue = device.makeCommandQueue() else {
            throw CompositorError.commandQueueUnavailable
        }
        self.commandQueue = queue

        let library: MTLLibrary
        if let provided = libraryOverride {
            library = provided
        } else {
            do {
                library = try device.makeDefaultLibrary(bundle: .main)
            } catch {
                throw CompositorError.libraryUnavailable(error.localizedDescription)
            }
        }
        self.library = library

        var cache: CVMetalTextureCache?
        let cacheStatus = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard cacheStatus == kCVReturnSuccess, let cache else {
            throw CompositorError.libraryUnavailable("Could not create a CoreVideo texture cache")
        }
        self.cvTextureCache = cache

        self.pipelines = Pipelines(
            textured: try Self.makePipeline(device: device, library: library, vertex: "quad_vertex", fragment: "textured_fragment"),
            cutout: try Self.makePipeline(device: device, library: library, vertex: "quad_vertex", fragment: "cutout_fragment"),
            cursor: try Self.makePipeline(device: device, library: library, vertex: "quad_vertex", fragment: "cursor_fragment"),
            solid: try Self.makePipeline(device: device, library: library, vertex: "quad_vertex", fragment: "solid_fragment"),
            gradient: try Self.makePipeline(device: device, library: library, vertex: "quad_vertex", fragment: "gradient_fragment"),
            shadow: try Self.makePipeline(device: device, library: library, vertex: "quad_vertex", fragment: "shadow_fragment"),
            ring: try Self.makePipeline(device: device, library: library, vertex: "quad_vertex", fragment: "ring_fragment"),
            backdrop: try Self.makePipeline(device: device, library: library, vertex: "quad_vertex", fragment: "backdrop_fragment")
        )
    }

    // MARK: - Textures

    public func makeOffscreenTexture(width: Int, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.pixelFormat,
            width: max(width, 1),
            height: max(height, 1),
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        return device.makeTexture(descriptor: descriptor)
    }

    /// Wraps a BGRA pixel buffer for sampling or render-target use.
    public func texture(from pixelBuffer: CVPixelBuffer) -> MetalFrameTexture? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else { return nil }

        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cvTextureCache,
            pixelBuffer,
            nil,
            Self.pixelFormat,
            width,
            height,
            0,
            &cvTexture
        )
        guard status == kCVReturnSuccess,
              let cvTexture,
              let texture = CVMetalTextureGetTexture(cvTexture) else {
            return nil
        }
        return MetalFrameTexture(texture: texture, cvTexture: cvTexture)
    }

    public func flushTextureCache() {
        CVMetalTextureCacheFlush(cvTextureCache, 0)
        lock.lock()
        imageTextures.removeAll()
        lock.unlock()
    }

    // MARK: - Frame encoding

    /// Encodes one composited frame into an existing render pass. The caller owns the
    /// command buffer (and is responsible for committing/presenting it).
    public func encode(
        state: RenderState,
        screen: MTLTexture?,
        camera: MTLTexture?,
        in pass: MTLRenderPassDescriptor,
        commandBuffer: MTLCommandBuffer
    ) {
        let canvas = state.canvasSize
        guard canvas.width > 1, canvas.height > 1,
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            return
        }

        drawBackground(state: state, screen: screen, canvas: canvas, encoder: encoder)

        if let screenRect = state.screenRect, screenRect.width > 1, screenRect.height > 1 {
            if state.deviceMockup.kind != .none {
                drawDeviceMockupBody(
                    state: state,
                    screenRect: screenRect,
                    canvas: canvas,
                    encoder: encoder
                )
            }
            let screenLUT = lutTexture(for: state.screenGrade, bundleURL: state.bundleURL)
            if state.shadow.opacity > 0.001 {
                drawShadow(
                    rect: screenRect,
                    cornerRadius: state.screenCornerRadius,
                    shadow: state.shadow,
                    canvas: canvas,
                    encoder: encoder
                )
            }
            if let screen {
                let usesLoupe = state.zoomKind == .loupe && state.zoomScale > 1.01
                drawTextured(
                    screen,
                    rect: screenRect,
                    canvas: canvas,
                    cornerRadius: state.screenCornerRadius,
                    maskShape: 0,
                    opacity: 1,
                    zoom: usesLoupe ? 1 : state.zoomScale,
                    focusX: usesLoupe ? 0.5 : state.zoomFocus.x,
                    focusY: usesLoupe ? 0.5 : state.zoomFocus.y,
                    mirrored: false,
                    pipeline: pipelines.textured,
                    encoder: encoder,
                    motionBlur: usesLoupe ? 0 : state.motionBlur,
                    motionDirection: state.motionBlurDirection,
                    grain: state.screenGrade.grain,
                    grade: state.screenGrade,
                    superResolution: state.superResolution && !usesLoupe,
                    lutTexture: screenLUT,
                    tiltX: usesLoupe ? 0 : state.tiltX,
                    tiltY: usesLoupe ? 0 : state.tiltY
                )
                if usesLoupe {
                    drawLoupe(
                        screen,
                        screenRect: screenRect,
                        zoom: state.zoomScale,
                        focus: state.zoomFocus,
                        grade: state.screenGrade,
                        superResolution: state.superResolution,
                        lutTexture: screenLUT,
                        canvas: canvas,
                        encoder: encoder
                    )
                }
            } else {
                drawSolid(
                    color: SIMD4<Float>(0.10, 0.11, 0.13, 1),
                    rect: screenRect,
                    canvas: canvas,
                    cornerRadius: state.screenCornerRadius,
                    maskShape: 0,
                    encoder: encoder
                )
            }
            if state.deviceMockup.kind != .none {
                drawDeviceMockupDetails(
                    state: state,
                    screenRect: screenRect,
                    canvas: canvas,
                    encoder: encoder
                )
            }
        }

        if let cameraRect = state.cameraRect, cameraRect.width > 1, cameraRect.height > 1 {
            if state.cameraOpacity > 0.001 {
                if state.shadow.opacity > 0.001 {
                    drawShadow(
                        rect: cameraRect,
                        cornerRadius: cameraCornerRadius(for: state.cameraMask, rect: cameraRect),
                        shadow: state.shadow,
                        canvas: canvas,
                        encoder: encoder
                    )
                }
                let mask = maskCode(for: state.cameraMask)
                if let camera {
                    let maskTexture = state.personMaskURL.flatMap { maskTexture(for: $0) }
                    let cameraLUT = lutTexture(for: state.cameraGrade, bundleURL: state.bundleURL)
                    drawTextured(
                        camera,
                        rect: cameraRect,
                        canvas: canvas,
                        cornerRadius: cameraCornerRadius(for: state.cameraMask, rect: cameraRect),
                        maskShape: mask,
                        opacity: state.cameraOpacity,
                        zoom: state.cameraZoom,
                        focusX: state.cameraFocus.x,
                        focusY: state.cameraFocus.y,
                        mirrored: state.cameraMirrored,
                        pipeline: maskTexture == nil ? pipelines.textured : pipelines.cutout,
                        encoder: encoder,
                        sharpen: state.cameraSharpen,
                        grade: state.cameraGrade,
                        lutTexture: cameraLUT,
                        personMask: maskTexture
                    )
                } else {
                    drawSolid(
                        color: SIMD4<Float>(0.16, 0.17, 0.2, 1),
                        rect: cameraRect,
                        canvas: canvas,
                        cornerRadius: cameraCornerRadius(for: state.cameraMask, rect: cameraRect),
                        maskShape: mask,
                        opacity: state.cameraOpacity,
                        encoder: encoder
                    )
                }
            }
        }

        drawAnnotations(
            state: state,
            screen: screen,
            canvas: canvas,
            encoder: encoder
        )
        drawCaption(state: state, canvas: canvas, encoder: encoder)
        drawCursor(state: state, canvas: canvas, encoder: encoder)

        encoder.endEncoding()
    }

    // MARK: - Background

    private func drawBackground(
        state: RenderState,
        screen: MTLTexture?,
        canvas: CGSize,
        encoder: MTLRenderCommandEncoder
    ) {
        let full = CGRect(origin: .zero, size: canvas)
        let colors = state.background.colors

        switch state.background.kind {
        case .gradient, .wallpaper:
            drawGradient(
                top: ColorHex.rgba(colors.first ?? "#141E30"),
                bottom: ColorHex.rgba(colors.count > 1 ? colors[1] : (colors.first ?? "#243B55")),
                rect: full,
                canvas: canvas,
                encoder: encoder
            )

        case .solid:
            drawSolid(
                color: ColorHex.rgba(colors.first ?? "#000000"),
                rect: full,
                canvas: canvas,
                cornerRadius: 0,
                maskShape: 3,
                encoder: encoder
            )

        case .image:
            if let url = state.backgroundImageURL, let texture = imageTexture(for: url) {
                drawTextured(
                    texture,
                    rect: full,
                    canvas: canvas,
                    cornerRadius: 0,
                    maskShape: 3,
                    opacity: 1,
                    zoom: 1,
                    focusX: 0.5,
                    focusY: 0.5,
                    mirrored: false,
                    pipeline: pipelines.textured,
                    encoder: encoder
                )
            } else {
                drawGradient(
                    top: ColorHex.rgba(colors.first ?? "#141E30"),
                    bottom: ColorHex.rgba(colors.count > 1 ? colors[1] : "#243B55"),
                    rect: full,
                    canvas: canvas,
                    encoder: encoder
                )
            }

        case .screenBlur:
            if let screen {
                var uniforms = BackdropUniforms(
                    texelSize: SIMD2<Float>(
                        1.0 / Float(max(screen.width, 1)),
                        1.0 / Float(max(screen.height, 1))
                    ),
                    radius: 18,
                    dim: 0.55,
                    uvRect: SIMD4<Float>(0, 0, 1, 1)
                )
                encodeQuad(
                    pipeline: pipelines.backdrop,
                    uniforms: &uniforms,
                    uniformLength: MemoryLayout<BackdropUniforms>.stride,
                    texture: screen,
                    rect: full,
                    canvas: canvas,
                    encoder: encoder
                )
            } else {
                drawGradient(
                    top: SIMD4<Float>(0.06, 0.07, 0.09, 1),
                    bottom: SIMD4<Float>(0.02, 0.02, 0.03, 1),
                    rect: full,
                    canvas: canvas,
                    encoder: encoder
                )
            }
        }
    }

    private func drawGradient(
        top: SIMD4<Float>,
        bottom: SIMD4<Float>,
        rect: CGRect,
        canvas: CGSize,
        encoder: MTLRenderCommandEncoder
    ) {
        var uniforms = GradientUniforms(topColor: top, bottomColor: bottom)
        encoder.setRenderPipelineState(pipelines.gradient)
        var transform = transform(for: rect, canvas: canvas)
        encoder.setVertexBytes(&transform, length: MemoryLayout<simd_float4x4>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<GradientUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }

    // MARK: - Quads

    private func drawTextured(
        _ texture: MTLTexture,
        rect: CGRect,
        canvas: CGSize,
        cornerRadius: CGFloat,
        maskShape: Int32,
        opacity: Double,
        zoom: Double,
        focusX: Double,
        focusY: Double,
        mirrored: Bool,
        pipeline: MTLRenderPipelineState,
        encoder: MTLRenderCommandEncoder,
        motionBlur: Double = 0,
        motionDirection: CGPoint = .zero,
        sharpen: Double = 0,
        grain: Double = 0,
        grade: ColorGrade = .none,
        superResolution: Bool = false,
        lutTexture: MTLTexture? = nil,
        tiltX: Double = 0,
        tiltY: Double = 0,
        personMask: MTLTexture? = nil
    ) {
        var uniforms = QuadUniforms(
            color: SIMD4<Float>(1, 1, 1, 1),
            cornerRadius: Float(max(cornerRadius, 0)),
            opacity: Float(min(max(opacity, 0), 1)),
            rect: SIMD4<Float>(
                Float(rect.minX),
                Float(rect.minY),
                Float(rect.width),
                Float(rect.height)
            ),
            maskShape: maskShape,
            pad0: 0,
            zoom: Float(max(zoom, 1)),
            focusX: Float(min(max(focusX, 0), 1)),
            focusY: Float(min(max(focusY, 0), 1)),
            mirror: mirrored ? 1 : 0,
            pad1: 0,
            pad2: 0
        )
        uniforms.motionBlur = Float(min(max(motionBlur, 0), 1))
        uniforms.blurDirX = Float(motionDirection.x)
        uniforms.blurDirY = Float(motionDirection.y)
        uniforms.sharpen = Float(min(max(sharpen, 0), 1))
        uniforms.grain = Float(min(max(grain, 0), 1))
        uniforms.gradeIndex = grade.preset.shaderIndex
        uniforms.gradeIntensity = Float(min(max(grade.intensity, 0), 1))
        uniforms.superRes = superResolution ? 1 : 0
        uniforms.hasLUT = lutTexture == nil ? 0 : 1

        encodeQuad(
            pipeline: pipeline,
            uniforms: &uniforms,
            uniformLength: MemoryLayout<QuadUniforms>.stride,
            texture: texture,
            rect: rect,
            canvas: canvas,
            encoder: encoder,
            tiltX: tiltX,
            tiltY: tiltY,
            secondaryTexture: personMask,
            lutTexture: lutTexture
        )
    }

    // MARK: - Loupe

    /// A glass magnifier placed over the focus point. The base frame stays at
    /// 1× while a rounded lens samples the same texture at the zoom scale.
    private func drawLoupe(
        _ texture: MTLTexture,
        screenRect: CGRect,
        zoom: Double,
        focus: CGPoint,
        grade: ColorGrade,
        superResolution: Bool,
        lutTexture: MTLTexture?,
        canvas: CGSize,
        encoder: MTLRenderCommandEncoder
    ) {
        let aspect = max(screenRect.width / max(screenRect.height, 1), 0.1)
        let lensWidth = min(screenRect.width * 0.48, screenRect.width - 12)
        let lensHeight = min(lensWidth / aspect, screenRect.height - 12)
        let width = min(lensWidth, lensHeight * aspect)
        let height = width / aspect
        guard width > 20, height > 20 else { return }

        let desiredX = screenRect.minX + focus.x * screenRect.width - width / 2
        let desiredY = screenRect.minY + focus.y * screenRect.height - height / 2
        let lens = CGRect(
            x: min(max(desiredX, screenRect.minX + 4), screenRect.maxX - width - 4),
            y: min(max(desiredY, screenRect.minY + 4), screenRect.maxY - height - 4),
            width: width,
            height: height
        )
        let radius = min(lens.width, lens.height) * 0.16

        drawShadow(
            rect: lens,
            cornerRadius: radius,
            shadow: ShadowSettings(angle: 90, distance: 0.008, blur: 0.035, opacity: 0.5),
            canvas: canvas,
            encoder: encoder
        )

        let border = lens.insetBy(dx: -3, dy: -3)
        drawSolid(
            color: SIMD4<Float>(1, 1, 1, 0.92),
            rect: border,
            canvas: canvas,
            cornerRadius: radius + 3,
            maskShape: 0,
            encoder: encoder
        )
        drawTextured(
            texture,
            rect: lens,
            canvas: canvas,
            cornerRadius: radius,
            maskShape: 0,
            opacity: 1,
            zoom: zoom,
            focusX: focus.x,
            focusY: focus.y,
            mirrored: false,
            pipeline: pipelines.textured,
            encoder: encoder,
            grade: grade,
            superResolution: superResolution,
            lutTexture: lutTexture
        )
    }

    // MARK: - Device mockups

    /// Draws the vector body of a device frame behind the screen pixels.
    private func drawDeviceMockupBody(
        state: RenderState,
        screenRect: CGRect,
        canvas: CGSize,
        encoder: MTLRenderCommandEncoder
    ) {
        let mockup = state.deviceMockup
        let inset = mockup.bezel * min(screenRect.width, screenRect.height)
        let body = screenRect.insetBy(dx: -inset, dy: -inset)
        let radius = mockup.kind == .iPhone || mockup.kind == .iPad
            ? inset * 2.6
            : max(inset * 1.2, 4)

        if state.shadow.opacity > 0.001 {
            drawShadow(
                rect: body,
                cornerRadius: radius,
                shadow: state.shadow,
                canvas: canvas,
                encoder: encoder
            )
        }

        drawSolid(
            color: ColorHex.rgba(mockup.colorHex),
            rect: body,
            canvas: canvas,
            cornerRadius: radius,
            maskShape: 0,
            encoder: encoder
        )

        // A subtle inner edge keeps the body from looking like a flat rectangle.
        drawSolid(
            color: SIMD4<Float>(0, 0, 0, 0.18),
            rect: body.insetBy(dx: inset * 0.35, dy: inset * 0.35),
            canvas: canvas,
            cornerRadius: max(radius - inset * 0.35, 2),
            maskShape: 0,
            encoder: encoder
        )
    }

    /// Notches, home indicators, and MacBook base bars drawn over the screen.
    private func drawDeviceMockupDetails(
        state: RenderState,
        screenRect: CGRect,
        canvas: CGSize,
        encoder: MTLRenderCommandEncoder
    ) {
        let mockup = state.deviceMockup
        let inset = mockup.bezel * min(screenRect.width, screenRect.height)

        switch mockup.kind {
        case .iPhone:
            let notchWidth = screenRect.width * 0.32
            let notchHeight = max(inset * 0.85, 6)
            let notch = CGRect(
                x: screenRect.midX - notchWidth / 2,
                y: screenRect.minY + notchHeight * 0.35,
                width: notchWidth,
                height: notchHeight
            )
            drawSolid(
                color: SIMD4<Float>(0, 0, 0, 0.92),
                rect: notch,
                canvas: canvas,
                cornerRadius: notchHeight / 2,
                maskShape: 0,
                encoder: encoder
            )
            let indicatorWidth = screenRect.width * 0.35
            let indicator = CGRect(
                x: screenRect.midX - indicatorWidth / 2,
                y: screenRect.maxY - inset * 0.9,
                width: indicatorWidth,
                height: max(inset * 0.22, 3)
            )
            drawSolid(
                color: SIMD4<Float>(1, 1, 1, 0.65),
                rect: indicator,
                canvas: canvas,
                cornerRadius: indicator.height / 2,
                maskShape: 0,
                encoder: encoder
            )

        case .iPad:
            let dot = max(inset * 0.35, 2)
            drawSolid(
                color: SIMD4<Float>(0, 0, 0, 0.75),
                rect: CGRect(
                    x: screenRect.midX - dot / 2,
                    y: screenRect.minY + inset * 0.45,
                    width: dot,
                    height: dot
                ),
                canvas: canvas,
                cornerRadius: dot / 2,
                maskShape: 0,
                encoder: encoder
            )

        case .macbook:
            let baseWidth = screenRect.width + inset * 2.6
            let baseHeight = max(inset * 0.9, 5)
            let base = CGRect(
                x: screenRect.midX - baseWidth / 2,
                y: screenRect.maxY + inset * 0.9,
                width: baseWidth,
                height: baseHeight
            )
            drawSolid(
                color: ColorHex.darkened(mockup.colorHex, by: 0.35),
                rect: base,
                canvas: canvas,
                cornerRadius: baseHeight / 2,
                maskShape: 0,
                encoder: encoder
            )

        case .display:
            let chin = CGRect(
                x: screenRect.minX,
                y: screenRect.maxY,
                width: screenRect.width,
                height: max(inset * 0.9, 4)
            )
            drawSolid(
                color: ColorHex.rgba(mockup.colorHex),
                rect: chin,
                canvas: canvas,
                cornerRadius: 2,
                maskShape: 0,
                encoder: encoder
            )

        case .none:
            break
        }
    }

    private func drawSolid(
        color: SIMD4<Float>,
        rect: CGRect,
        canvas: CGSize,
        cornerRadius: CGFloat,
        maskShape: Int32,
        opacity: Double = 1,
        encoder: MTLRenderCommandEncoder
    ) {        var uniforms = QuadUniforms(
            color: color,
            cornerRadius: Float(max(cornerRadius, 0)),
            opacity: Float(min(max(opacity, 0), 1)),
            rect: SIMD4<Float>(Float(rect.minX), Float(rect.minY), Float(rect.width), Float(rect.height)),
            maskShape: maskShape,
            pad0: 0,
            zoom: 1,
            focusX: 0.5,
            focusY: 0.5,
            mirror: 0,
            pad1: 0,
            pad2: 0
        )
        encodeQuad(
            pipeline: pipelines.solid,
            uniforms: &uniforms,
            uniformLength: MemoryLayout<QuadUniforms>.stride,
            texture: nil,
            rect: rect,
            canvas: canvas,
            encoder: encoder
        )
    }

    private func drawShadow(
        rect: CGRect,
        cornerRadius: CGFloat,
        shadow: ShadowSettings,
        canvas: CGSize,
        encoder: MTLRenderCommandEncoder
    ) {
        let minDimension = min(canvas.width, canvas.height)
        let blur = max(shadow.blur * minDimension, 0.5)
        let distance = shadow.distance * minDimension
        let radians = shadow.angle * .pi / 180
        let offset = CGPoint(x: sin(radians) * distance, y: -cos(radians) * distance)

        let center = CGPoint(x: rect.midX + offset.x, y: rect.midY + offset.y)
        let quad = CGRect(
            x: center.x - rect.width / 2 - blur * 2,
            y: center.y - rect.height / 2 - blur * 2,
            width: rect.width + blur * 4,
            height: rect.height + blur * 4
        )

        var uniforms = ShadowUniforms(
            color: SIMD4<Float>(0, 0, 0, Float(min(max(shadow.opacity, 0), 1))),
            rect: SIMD4<Float>(Float(quad.minX), Float(quad.minY), Float(quad.width), Float(quad.height)),
            cornerRadius: Float(max(cornerRadius, 0)),
            blur: Float(blur),
            shapeSize: SIMD2<Float>(Float(rect.width), Float(rect.height)),
            pad: SIMD2<Float>(0, 0)
        )

        encoder.setRenderPipelineState(pipelines.shadow)
        var transform = transform(for: quad, canvas: canvas)
        encoder.setVertexBytes(&transform, length: MemoryLayout<simd_float4x4>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ShadowUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }

    private func encodeQuad(
        pipeline: MTLRenderPipelineState,
        uniforms: UnsafeMutableRawPointer,
        uniformLength: Int,
        texture: MTLTexture?,
        rect: CGRect,
        canvas: CGSize,
        encoder: MTLRenderCommandEncoder,
        tiltX: Double = 0,
        tiltY: Double = 0,
        secondaryTexture: MTLTexture? = nil,
        lutTexture: MTLTexture? = nil
    ) {
        encoder.setRenderPipelineState(pipeline)
        var transform = transform(for: rect, canvas: canvas, tiltX: tiltX, tiltY: tiltY)
        encoder.setVertexBytes(&transform, length: MemoryLayout<simd_float4x4>.stride, index: 0)
        encoder.setFragmentBytes(uniforms, length: uniformLength, index: 0)
        if let texture {
            encoder.setFragmentTexture(texture, index: 0)
        }
        if let secondaryTexture {
            encoder.setFragmentTexture(secondaryTexture, index: 1)
        }
        if let lutTexture {
            encoder.setFragmentTexture(lutTexture, index: secondaryTexture == nil ? 1 : 2)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }

    private func transform(
        for rect: CGRect,
        canvas: CGSize,
        tiltX: Double = 0,
        tiltY: Double = 0
    ) -> simd_float4x4 {
        let safeWidth = max(canvas.width, 1)
        let safeHeight = max(canvas.height, 1)
        let scaleX = Float(rect.width / safeWidth * 2)
        let scaleY = Float(rect.height / safeHeight * 2)
        let translateX = Float(rect.minX / safeWidth * 2 - 1)
        let translateY = Float(1 - rect.minY / safeHeight * 2)
        let base = simd_float4x4(columns: (
            SIMD4<Float>(scaleX, 0, 0, 0),
            SIMD4<Float>(0, -scaleY, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(translateX, translateY, 0, 1)
        ))

        guard abs(tiltX) > 0.01 || abs(tiltY) > 0.01 else { return base }

        let center = SIMD3<Float>(translateX, translateY, 0)
        let radiansX = Float(tiltX * .pi / 180)
        let radiansY = Float(tiltY * .pi / 180)
        let rotateX = simd_float4x4(simd_quatf(angle: radiansX, axis: SIMD3<Float>(1, 0, 0)))
        let rotateY = simd_float4x4(simd_quatf(angle: radiansY, axis: SIMD3<Float>(0, 1, 0)))

        var perspective = matrix_identity_float4x4
        perspective.columns.2.w = -1.0 / 6.0

        var toOrigin = matrix_identity_float4x4
        toOrigin.columns.3 = SIMD4<Float>(-center.x, -center.y, 0, 1)
        var back = matrix_identity_float4x4
        back.columns.3 = SIMD4<Float>(center.x, center.y, 0, 1)

        return back * perspective * rotateY * rotateX * toOrigin * base
    }

    // MARK: - Annotations

    private func drawAnnotations(
        state: RenderState,
        screen: MTLTexture?,
        canvas: CGSize,
        encoder: MTLRenderCommandEncoder
    ) {
        for annotation in state.annotations.sorted(by: { $0.zIndex < $1.zIndex }) {
            let box = CGRect(
                x: annotation.rect.x * canvas.width,
                y: annotation.rect.y * canvas.height,
                width: annotation.rect.width * canvas.width,
                height: annotation.rect.height * canvas.height
            )
            guard box.width > 1, box.height > 1 else { continue }

            switch annotation.type {
            case .text:
                guard let texture = annotationTexture(
                    for: annotation,
                    bundleURL: state.bundleURL,
                    canvas: canvas
                ) else { continue }
                let fitted = aspectFit(
                    size: CGSize(width: texture.width, height: texture.height),
                    in: box
                )
                drawTextured(
                    texture,
                    rect: fitted,
                    canvas: canvas,
                    cornerRadius: 0,
                    maskShape: 3,
                    opacity: annotation.style.opacity,
                    zoom: 1,
                    focusX: 0.5,
                    focusY: 0.5,
                    mirrored: false,
                    pipeline: pipelines.textured,
                    encoder: encoder
                )

            case .image:
                guard let path = annotation.imagePath,
                      let url = state.bundleURL?.appendingPathComponent(path),
                      let texture = imageTexture(for: url) else { continue }
                drawTextured(
                    texture,
                    rect: box,
                    canvas: canvas,
                    cornerRadius: 0,
                    maskShape: 3,
                    opacity: annotation.style.opacity,
                    zoom: 1,
                    focusX: 0.5,
                    focusY: 0.5,
                    mirrored: false,
                    pipeline: pipelines.textured,
                    encoder: encoder
                )

            case .highlight:
                drawSolid(
                    color: ColorHex.rgba("#FFD60A", alpha: 0.28),
                    rect: box,
                    canvas: canvas,
                    cornerRadius: 8,
                    maskShape: 0,
                    encoder: encoder
                )

            case .blur:
                if let screen, let screenRect = state.screenRect, screenRect.width > 1 {
                    // True masked blur: sample the screen region under the mask and
                    // run the separable Gaussian approximation in the backdrop shader.
                    var uniforms = BackdropUniforms(
                        texelSize: SIMD2<Float>(
                            1.0 / Float(max(screen.width, 1)),
                            1.0 / Float(max(screen.height, 1))
                        ),
                        radius: Float(max(annotation.mask?.intensity ?? 16, 4)),
                        dim: 1.0,
                        uvRect: SIMD4<Float>(
                            Float((box.minX - screenRect.minX) / screenRect.width),
                            Float((box.minY - screenRect.minY) / screenRect.height),
                            Float(box.width / screenRect.width),
                            Float(box.height / screenRect.height)
                        )
                    )
                    encodeQuad(
                        pipeline: pipelines.backdrop,
                        uniforms: &uniforms,
                        uniformLength: MemoryLayout<BackdropUniforms>.stride,
                        texture: screen,
                        rect: box,
                        canvas: canvas,
                        encoder: encoder
                    )
                } else {
                    drawSolid(
                        color: SIMD4<Float>(0, 0, 0, 0.55),
                        rect: box,
                        canvas: canvas,
                        cornerRadius: 10,
                        maskShape: 0,
                        encoder: encoder
                    )
                }

            case .figure:
                drawSolid(
                    color: ColorHex.rgba(annotation.style.colorHex, alpha: 0.9),
                    rect: box,
                    canvas: canvas,
                    cornerRadius: 6,
                    maskShape: 0,
                    encoder: encoder
                )
            }
        }
    }

    private func annotationTexture(
        for annotation: AnnotationRegion,
        bundleURL: URL?,
        canvas: CGSize
    ) -> MTLTexture? {
        let key = [
            annotation.id,
            annotation.text ?? "",
            annotation.style.colorHex,
            annotation.style.backgroundHex,
            annotation.style.fontFamily,
            String(annotation.style.fontSize),
            annotation.style.alignment,
            annotation.style.isBold ? "b" : "r",
            annotation.style.isItalic ? "i" : "n",
            String(Int(canvas.width)),
            String(Int(canvas.height))
        ].joined(separator: "|")

        lock.lock()
        if let cached = annotationTextures[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        guard let texture = AnnotationTextureFactory.makeTexture(
            for: annotation,
            canvasSize: canvas,
            device: device
        ) else {
            return nil
        }

        lock.lock()
        if annotationTextures.count > 128 {
            annotationTextures.removeAll(keepingCapacity: true)
        }
        annotationTextures[key] = texture
        lock.unlock()
        return texture
    }

    private func aspectFit(size: CGSize, in box: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return box }
        let scale = min(box.width / size.width, box.height / size.height)
        let width = size.width * scale
        let height = size.height * scale
        return CGRect(
            x: box.midX - width / 2,
            y: box.midY - height / 2,
            width: width,
            height: height
        )
    }

    // MARK: - Captions

    private func drawCaption(
        state: RenderState,
        canvas: CGSize,
        encoder: MTLRenderCommandEncoder
    ) {
        guard let caption = state.caption,
              caption.rect.width > 1,
              caption.rect.height > 1,
              let texture = captionTexture(for: caption, canvas: canvas) else {
            return
        }

        drawTextured(
            texture,
            rect: caption.rect,
            canvas: canvas,
            cornerRadius: 0,
            maskShape: 3,
            opacity: 1,
            zoom: 1,
            focusX: 0.5,
            focusY: 0.5,
            mirrored: false,
            pipeline: pipelines.textured,
            encoder: encoder
        )
    }

    private func captionTexture(for caption: CaptionOverlay, canvas: CGSize) -> MTLTexture? {
        let key = [
            caption.cueID,
            String(caption.activeWordIndex ?? -1),
            caption.text,
            caption.style.rawValue,
            caption.uppercase ? "u" : "n",
            String(Int(caption.fontScale * 100)),
            String(Int(canvas.width)),
            String(Int(canvas.height))
        ].joined(separator: "|")

        lock.lock()
        if let cached = captionTextures[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let settings = CaptionSettings(
            enabled: true,
            style: caption.style,
            position: .bottom,
            wordsPerLine: 1,
            fontScale: caption.fontScale,
            uppercase: caption.uppercase
        )

        let cue = CaptionCue(
            id: caption.cueID,
            text: caption.text,
            startMs: 0,
            endMs: 0,
            wordTimings: caption.wordTimings
        )

        guard let texture = CaptionRasterizer.makeTexture(
            cue: cue,
            activeWordIndex: caption.activeWordIndex,
            settings: settings,
            canvasSize: canvas,
            pixelScale: 1,
            device: device
        ) else {
            return nil
        }

        lock.lock()
        if captionTextures.count > 96 {
            captionTextures.removeAll(keepingCapacity: true)
        }
        captionTextures[key] = texture
        lock.unlock()
        return texture
    }

    // MARK: - Cursor

    private func drawCursor(
        state: RenderState,
        canvas: CGSize,
        encoder: MTLRenderCommandEncoder
    ) {
        guard state.cursorVisible, state.cursorCanvasSize > 0 else { return }

        if state.clickEffect != .none,
           let click = state.clickCanvasPoint,
           let effect = state.cursor.effect {
            drawClickEffect(
                effect: effect,
                point: click,
                style: state.clickEffect,
                scale: state.clickEffectScale,
                canvas: canvas,
                encoder: encoder
            )
        }

        let size = state.cursorCanvasSize
        let rect = CGRect(
            x: state.cursorCanvasPoint.x - size / 2,
            y: state.cursorCanvasPoint.y - size / 2,
            width: size,
            height: size
        )

        guard let texture = cursorTexture(for: state.cursorTheme) else { return }
        drawTextured(
            texture,
            rect: rect,
            canvas: canvas,
            cornerRadius: 0,
            maskShape: 3,
            opacity: 1,
            zoom: 1,
            focusX: 0.5,
            focusY: 0.5,
            mirrored: false,
            pipeline: pipelines.cursor,
            encoder: encoder
        )
    }

    private func drawClickEffect(
        effect: CursorFrame.ClickEffectFrame,
        point: CGPoint,
        style: ClickEffect,
        scale: Double,
        canvas: CGSize,
        encoder: MTLRenderCommandEncoder
    ) {
        let progress = min(max(effect.progress, 0), 1)
        let eased = 1 - pow(1 - progress, 3)
        let minDimension = canvas.height
        guard minDimension > 1 else { return }

        let start = 0.018 * canvas.height
        let end = 0.085 * canvas.height
        let radius = (start + (end - start) * eased) * scale
        let thickness = max(2, 0.006 * minDimension * scale)
        let alpha: Float = style == .circle
            ? Float(1 - progress) * 0.7
            : Float(pow(1 - progress, 1.8)) * 0.85
        let color: SIMD4<Float> = effect.interaction == .rightClick
            ? ColorHex.rgba("#64D2FF", alpha: alpha)
            : SIMD4<Float>(1, 1, 1, alpha)

        let uniforms = RingUniforms(
            color: color,
            center: SIMD2<Float>(
                Float(point.x / max(canvas.width, 1)),
                Float(point.y / max(canvas.height, 1))
            ),
            radius: Float(radius / minDimension),
            thickness: Float(thickness / minDimension),
            aspect: Float(canvas.width / minDimension),
            pad0: 0,
            pad1: 0,
            pad2: 0
        )
        var uniformsCopy = uniforms
        let full = CGRect(origin: .zero, size: canvas)
        encodeQuad(
            pipeline: pipelines.ring,
            uniforms: &uniformsCopy,
            uniformLength: MemoryLayout<RingUniforms>.stride,
            texture: nil,
            rect: full,
            canvas: canvas,
            encoder: encoder
        )
    }

    // MARK: - Texture helpers

    private func cursorTexture(for theme: CursorTheme) -> MTLTexture? {
        lock.lock()
        if let cached = cursorTextures[theme] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        guard let texture = CursorTextureFactory.makeTexture(for: theme, device: device) else {
            return nil
        }
        lock.lock()
        cursorTextures[theme] = texture
        lock.unlock()
        return texture
    }

    private func imageTexture(for url: URL) -> MTLTexture? {
        let key = url.standardizedFileURL.path
        lock.lock()
        if let cached = imageTextures[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }

        let loader = MTKTextureLoader(device: device)
        let options: [MTKTextureLoader.Option: Any] = [
            .SRGB: false,
            .origin: MTKTextureLoader.Origin.topLeft,
            .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
            .textureStorageMode: NSNumber(value: MTLStorageMode.private.rawValue)
        ]
        guard let texture = try? loader.newTexture(cgImage: image, options: options) else {
            return nil
        }

        lock.lock()
        if imageTextures.count > 64 {
            imageTextures.removeAll(keepingCapacity: true)
        }
        imageTextures[key] = texture
        lock.unlock()
        return texture
    }

    private func maskCode(for mask: CameraMaskShape) -> Int32 {
        switch mask {
        case .circle:
            2
        default:
            3
        }
    }

    // MARK: - LUT / person-matte textures

    private func lutTexture(for grade: ColorGrade, bundleURL: URL?) -> MTLTexture? {
        guard let path = grade.lutPath, let bundleURL else { return nil }
        let url = bundleURL.appendingPathComponent(path)
        let key = url.standardizedFileURL.path

        lock.lock()
        if let cached = lutTextures[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        guard let lut = try? CubeLUT(contentsOf: url) else { return nil }
        guard let texture = makeLUTTexture(lut) else { return nil }

        lock.lock()
        if lutTextures.count > 16 {
            lutTextures.removeAll(keepingCapacity: true)
        }
        lutTextures[key] = texture
        lock.unlock()
        return texture
    }

    private func makeLUTTexture(_ lut: CubeLUT) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .rgba16Float
        descriptor.width = lut.size
        descriptor.height = lut.size
        descriptor.depth = lut.size
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .managed
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }

        var pixels = [UInt16](repeating: 0, count: lut.size * lut.size * lut.size * 4)
        for index in 0..<(lut.size * lut.size * lut.size) {
            let source = index * 3
            let destination = index * 4
            pixels[destination] = Float16(lut.entries[source]).bitPattern
            pixels[destination + 1] = Float16(lut.entries[source + 1]).bitPattern
            pixels[destination + 2] = Float16(lut.entries[source + 2]).bitPattern
            pixels[destination + 3] = Float16(1).bitPattern
        }

        pixels.withUnsafeBytes { bytes in
            texture.replace(
                region: MTLRegionMake3D(0, 0, 0, lut.size, lut.size, lut.size),
                mipmapLevel: 0,
                slice: 0,
                withBytes: bytes.baseAddress!,
                bytesPerRow: lut.size * 8,
                bytesPerImage: lut.size * lut.size * 8
            )
        }
        return texture
    }

    private func maskTexture(for url: URL) -> MTLTexture? {
        let key = url.standardizedFileURL.path

        lock.lock()
        if let cached = maskTextures[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }

        let loader = MTKTextureLoader(device: device)
        let options: [MTKTextureLoader.Option: Any] = [
            .SRGB: false,
            .origin: MTKTextureLoader.Origin.topLeft,
            .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
            .textureStorageMode: NSNumber(value: MTLStorageMode.private.rawValue)
        ]
        guard let texture = try? loader.newTexture(cgImage: image, options: options) else {
            return nil
        }

        lock.lock()
        if maskTextures.count > 128 {
            maskTextures.removeAll(keepingCapacity: true)
        }
        maskTextures[key] = texture
        lock.unlock()
        return texture
    }

    private func cameraCornerRadius(for mask: CameraMaskShape, rect: CGRect) -> CGFloat {
        switch mask {
        case .rounded(let radius):
            return min(rect.width, rect.height) * radius
        case .circle, .square, .none, .cutout:
            return 0
        }
    }

    private static func makePipeline(
        device: MTLDevice,
        library: MTLLibrary,
        vertex: String,
        fragment: String
    ) throws -> MTLRenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = fragment
        descriptor.vertexFunction = library.makeFunction(name: vertex)
        descriptor.fragmentFunction = library.makeFunction(name: fragment)
        guard let attachment = descriptor.colorAttachments[0] else {
            throw CompositorError.pipelineFailed("Missing color attachment")
        }
        attachment.pixelFormat = pixelFormat
        attachment.isBlendingEnabled = true
        attachment.sourceRGBBlendFactor = .sourceAlpha
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha

        do {
            return try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw CompositorError.pipelineFailed("\(fragment): \(error.localizedDescription)")
        }
    }
}
