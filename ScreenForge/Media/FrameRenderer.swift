import CoreGraphics
import Foundation

// MARK: - Easing

public enum EasingMath {
    /// `t` is clamped to 0...1; returns the eased 0...1 progress.
    public static func apply(_ easing: ZoomEasing, _ t: Double) -> Double {
        let t = min(max(t, 0), 1)
        switch easing {
        case .linear:
            return t
        case .easeInOut:
            return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
        case .smooth:
            return t * t * (3 - 2 * t)
        case .screenStudio:
            // Ease-out-back: a short, confident overshoot then settle.
            let c1 = 1.2
            let c3 = c1 + 1
            let p = t - 1
            return 1 + c3 * p * p * p + c1 * p * p
        }
    }
}

// MARK: - Camera mask

public enum CameraMaskShape: Sendable, Equatable {
    case none
    case rounded(radius: CGFloat)
    case circle
    case square
    /// Person-segmentation cutout (alpha mask supplied by the compositor).
    case cutout
}

// MARK: - Render state

/// A caption line positioned on the canvas, ready for rasterization.
public struct CaptionOverlay: Sendable, Equatable {
    public var cueID: String
    public var text: String
    public var activeWordIndex: Int?
    public var wordTimings: [CaptionCue.WordTiming]
    public var rect: CGRect
    public var style: CaptionStyle
    public var uppercase: Bool
    public var fontScale: Double

    public init(
        cueID: String,
        text: String,
        activeWordIndex: Int?,
        wordTimings: [CaptionCue.WordTiming],
        rect: CGRect,
        style: CaptionStyle,
        uppercase: Bool,
        fontScale: Double
    ) {
        self.cueID = cueID
        self.text = text
        self.activeWordIndex = activeWordIndex
        self.wordTimings = wordTimings
        self.rect = rect
        self.style = style
        self.uppercase = uppercase
        self.fontScale = fontScale
    }
}

/// Everything the compositor needs for one frame. Preview and export share this.
public struct RenderState: Sendable {
    public var outputTimeMs: Double
    public var sourceTimeMs: Double
    public var canvasSize: CGSize

    /// Frame of the screen recording in canvas coordinates (nil when camera-only).
    public var screenRect: CGRect?
    public var screenCornerRadius: CGFloat
    public var zoomScale: Double
    public var zoomFocus: CGPoint
    public var zoomKind: ZoomKind = .classic
    public var rotation: Rotation3DPreset?

    public var background: BackgroundStyle
    public var backgroundImageURL: URL?
    public var shadow: ShadowSettings
    public var bundleURL: URL?

    public var screenGrade: ColorGrade = .none
    public var superResolution: Bool = false
    public var motionBlur: Double = 0
    public var motionBlurDirection: CGPoint = .zero
    public var tiltX: Double = 0
    public var tiltY: Double = 0
    public var deviceMockup: DeviceMockup = .none

    public var cameraRect: CGRect?
    public var cameraMask: CameraMaskShape
    public var cameraMirrored: Bool
    public var cameraOpacity: Double
    public var cameraZoom: Double = 1
    public var cameraFocus: CGPoint = .init(x: 0.5, y: 0.5)
    public var cameraGrade: ColorGrade = .none
    public var cameraSharpen: Double = 0
    public var personMaskURL: URL?

    public var layout: LayoutKind
    public var previousLayout: LayoutKind?
    public var layoutBlend: Double

    public var cursor: CursorFrame
    public var cursorTheme: CursorTheme
    public var clickEffect: ClickEffect
    public var clickEffectScale: Double
    public var cursorCanvasPoint: CGPoint
    public var cursorCanvasSize: CGFloat
    public var cursorVisible: Bool
    public var clickCanvasPoint: CGPoint?

    public var annotations: [AnnotationRegion]
    public var caption: CaptionOverlay?
}

// MARK: - Renderer

/// Pure function: project + time → render state.
public struct FrameRenderer: Sendable {
    public let project: ScreenForgeProject
    public let timelineMap: TimelineMap
    public let cursorTrack: CursorTrack?
    public let captionTrack: CaptionTrack?
    public let bundleURL: URL?

    public init(
        project: ScreenForgeProject,
        bundleURL: URL? = nil,
        cursorSamples: [CursorSample] = [],
        captionTrack: CaptionTrack? = nil
    ) {
        let normalized = project.normalized()
        self.project = normalized
        self.bundleURL = bundleURL
        self.captionTrack = captionTrack
        self.timelineMap = normalized.timeline.map(sourceDurationMs: normalized.source.durationMs)
        if normalized.cursor.visible {
            self.cursorTrack = CursorTrack(
                samples: cursorSamples,
                settings: normalized.cursor,
                durationMs: normalized.source.durationMs
            )
        } else {
            self.cursorTrack = nil
        }
    }

    /// Uses a prebuilt cursor track. Editors cache the track so slider changes do not
    /// re-filter minutes of telemetry on every frame.
    public init(
        project: ScreenForgeProject,
        bundleURL: URL? = nil,
        cursorTrack: CursorTrack?,
        captionTrack: CaptionTrack? = nil
    ) {
        let normalized = project.normalized()
        self.project = normalized
        self.bundleURL = bundleURL
        self.captionTrack = captionTrack
        self.timelineMap = normalized.timeline.map(sourceDurationMs: normalized.source.durationMs)
        self.cursorTrack = normalized.cursor.visible ? cursorTrack : nil
    }

    public var outputDurationMs: Int {
        Int(timelineMap.outputDurationMs.rounded())
    }

    public func state(atOutputMs outputMs: Double, canvasSize: CGSize? = nil) -> RenderState {
        let canvas = canvasSize ?? defaultCanvasSize()
        let clampedOutput = min(max(outputMs, 0), timelineMap.outputDurationMs)
        let sourceMs = timelineMap.sourceTime(forOutputMs: clampedOutput) ?? 0

        let layout = resolvedLayout(at: Int(sourceMs))
        // Zoom is resolved first: the overlay PiP shrinks relative to it.
        let zoom = resolvedZoom(at: Int(sourceMs))
        let previousZoom = resolvedZoom(at: max(Int(sourceMs) - 34, 0))
        var frames = layoutFrames(for: layout.kind, canvas: canvas, zoomScale: zoom.scale)

        // Device mockups wrap the screen layer in a vector body and inset the pixels.
        if project.canvas.deviceMockup.kind != .none, var screen = frames.screen {
            let inset = project.canvas.deviceMockup.bezel * min(screen.width, screen.height)
            screen = screen.insetBy(dx: inset, dy: inset)
            frames.screen = screen
        }

        let cameraEnabled = project.camera.enabled || layout.kind != .screenOnly

        let screenRect = frames.screen
        let screenCorner: CGFloat = screenRect.map { rect in
            min(rect.width, rect.height) * CGFloat(project.canvas.cornerRadius)
        } ?? 0

        // Cursor mapping through the zoom viewport.
        var cursorFrame = cursorTrack?.frame(at: Int(sourceMs)) ?? .hidden
        var cursorPoint = CGPoint.zero
        var cursorSize: CGFloat = 0
        var clickPoint: CGPoint?
        var cursorVisible = false

        if let screenRect, cursorFrame.isVisible, project.cursor.visible {
            let viewport = 1.0 / max(zoom.scale, 1.0)
            let originX = clamp(zoom.focus.x - viewport / 2, 0, 1 - viewport)
            let originY = clamp(zoom.focus.y - viewport / 2, 0, 1 - viewport)
            let relative = CGPoint(
                x: (cursorFrame.position.x - originX) / viewport,
                y: (cursorFrame.position.y - originY) / viewport
            )
            cursorPoint = CGPoint(
                x: screenRect.minX + relative.x * screenRect.width,
                y: screenRect.minY + relative.y * screenRect.height
            )
            cursorVisible = relative.x >= -0.02 && relative.x <= 1.02 &&
                            relative.y >= -0.02 && relative.y <= 1.02

            let base = 30.0 * (canvas.height / 1_080.0)
            cursorSize = base * project.cursor.scale * (0.85 + 0.15 * zoom.scale)
            cursorSize *= (1.0 - 0.08 * cursorFrame.pressAmount)

            if let effect = cursorFrame.effect {
                let effectRelative = CGPoint(
                    x: (effect.position.x - originX) / viewport,
                    y: (effect.position.y - originY) / viewport
                )
                clickPoint = CGPoint(
                    x: screenRect.minX + effectRelative.x * screenRect.width,
                    y: screenRect.minY + effectRelative.y * screenRect.height
                )
            }

            if project.cursor.clipToBounds {
                cursorPoint.x = clamp(cursorPoint.x, screenRect.minX, screenRect.maxX)
                cursorPoint.y = clamp(cursorPoint.y, screenRect.minY, screenRect.maxY)
            }
        } else {
            cursorFrame = .hidden
        }

        let backgroundURL: URL? = {
            guard project.canvas.background.kind == .image,
                  let path = project.canvas.background.imagePath else { return nil }
            return bundleURL?.appendingPathComponent(path)
        }()

        let face = project.camera.faceTracking ? analysisFace(at: Int(sourceMs)) : nil
        let cameraZoom = face == nil ? 1 : 1.28
        let cameraFocus = face.map { CGPoint(x: $0.x, y: $0.y) } ?? CGPoint(x: 0.5, y: 0.5)
        let cameraOpacity: Double = {
            guard cameraEnabled, layout.kind != .screenOnly else { return 0 }
            guard project.camera.hideDuringSilence else { return 1 }
            return project.analysis.cameraOpacity(atSourceMs: Int(sourceMs))
        }()

        // Motion blur follows the zoom's own movement: focus travel plus scale change.
        let focusDX = zoom.focus.x - previousZoom.focus.x
        let focusDY = zoom.focus.y - previousZoom.focus.y
        let scaleDelta = abs(zoom.scale - previousZoom.scale)
        let movement = min(hypot(focusDX, focusDY) * 6 + scaleDelta * 1.5, 1)
        var blurDirection = CGPoint(x: focusDX, y: focusDY)
        if hypot(blurDirection.x, blurDirection.y) < 0.0001, scaleDelta > 0.0001 {
            // Radial component for pure zoom: blur outward from the focus.
            blurDirection = CGPoint(x: zoom.focus.x - 0.5, y: zoom.focus.y - 0.5)
        }
        let directionLength = hypot(blurDirection.x, blurDirection.y)
        if directionLength > 0.0001 {
            blurDirection = CGPoint(
                x: blurDirection.x / directionLength,
                y: blurDirection.y / directionLength
            )
        }
        let motionBlur = project.canvas.motionBlur * movement * (zoom.scale > 1.001 ? 1 : 0.35)

        let personMaskURL: URL? = {
            guard project.camera.cutout,
                  let frame = project.analysis.personMask(atSourceMs: Int(sourceMs)) else { return nil }
            return bundleURL?.appendingPathComponent(frame.path)
        }()

        let tilt = zoom.rotation?.angles
        let tiltStrength = max(zoom.scale - 1, 0) / 4
        let tiltX = (tilt?.x ?? 0) * tiltStrength
        let tiltY = (tilt?.y ?? 0) * tiltStrength

        return RenderState(
            outputTimeMs: clampedOutput,
            sourceTimeMs: sourceMs,
            canvasSize: canvas,
            screenRect: screenRect,
            screenCornerRadius: screenCorner,
            zoomScale: zoom.scale,
            zoomFocus: zoom.focus,
            zoomKind: zoom.kind,
            rotation: zoom.rotation,
            background: project.canvas.background,
            backgroundImageURL: backgroundURL,
            shadow: project.canvas.shadow,
            bundleURL: bundleURL,
            screenGrade: project.canvas.grade,
            superResolution: project.canvas.superResolution,
            motionBlur: motionBlur,
            motionBlurDirection: blurDirection,
            tiltX: tiltX,
            tiltY: tiltY,
            deviceMockup: project.canvas.deviceMockup,
            cameraRect: cameraEnabled ? frames.camera : nil,
            cameraMask: maskShape(),
            cameraMirrored: project.camera.mirrored,
            cameraOpacity: cameraOpacity,
            cameraZoom: cameraZoom,
            cameraFocus: cameraFocus,
            cameraGrade: project.camera.grade,
            cameraSharpen: project.camera.sharpen,
            personMaskURL: personMaskURL,
            layout: layout.kind,
            previousLayout: layout.previous,
            layoutBlend: layout.blend,
            cursor: cursorFrame,
            cursorTheme: project.cursor.theme,
            clickEffect: project.cursor.clickEffect,
            clickEffectScale: project.cursor.clickEffectScale,
            cursorCanvasPoint: cursorPoint,
            cursorCanvasSize: cursorSize,
            cursorVisible: cursorVisible,
            clickCanvasPoint: clickPoint,
            annotations: project.timeline.annotations(at: Int(sourceMs)),
            caption: resolvedCaption(at: Int(sourceMs), canvas: canvas)
        )
    }

    private func analysisFace(at sourceMs: Int) -> FaceSample? {
        guard let sample = project.analysis.faceSamples.last(where: { $0.timeMs <= sourceMs }) else {
            return project.analysis.faceSamples.first
        }
        // Ignore stale detections (e.g. the person left the frame).
        guard sourceMs - sample.timeMs < 1_500, sample.confidence > 0.25 else { return nil }
        return sample
    }

    /// Active caption line for a source timestamp. Disabled captions or gaps between
    /// cues simply produce nil, so nothing is drawn.
    private func resolvedCaption(at sourceMs: Int, canvas: CGSize) -> CaptionOverlay? {
        guard project.captions.enabled, let captionTrack else { return nil }
        guard let active = captionTrack.activeCue(at: sourceMs) else { return nil }

        let settings = captionTrack.settings
        return CaptionOverlay(
            cueID: active.cue.id,
            text: active.cue.text,
            activeWordIndex: active.activeWord,
            wordTimings: active.cue.wordTimings,
            rect: CaptionGeometry.overlayRect(canvas: canvas, position: settings.position),
            style: settings.style,
            uppercase: settings.uppercase,
            fontScale: settings.fontScale
        )
    }

    // MARK: Canvas

    public func canvasSize(forLongEdge longEdge: Int) -> CGSize {
        let ratio = project.canvas.aspect.ratio
        if ratio >= 1 {
            return CGSize(width: CGFloat(longEdge), height: CGFloat(Double(longEdge) / ratio))
        }
        return CGSize(width: CGFloat(Double(longEdge) * ratio), height: CGFloat(longEdge))
    }

    private func defaultCanvasSize() -> CGSize {
        let longEdge: Int
        switch project.export.resolution {
        case .p720: longEdge = 1280
        case .p1080: longEdge = 1920
        case .p4k: longEdge = 3840
        case .custom: longEdge = project.export.customLongEdge ?? 1920
        }
        return canvasSize(forLongEdge: longEdge)
    }

    // MARK: Zoom

    private struct ResolvedZoom {
        var scale: Double
        var focus: CGPoint
        var kind: ZoomKind
        var rotation: Rotation3DPreset?
    }

    private func resolvedZoom(at sourceMs: Int) -> ResolvedZoom {
        let active = project.timeline.zooms
            .filter { sourceMs >= $0.startMs && sourceMs <= $0.endMs }
        guard let strongest = active.max(by: { $0.scale < $1.scale }) else {
            return ResolvedZoom(
                scale: 1,
                focus: .init(x: 0.5, y: 0.5),
                kind: .classic,
                rotation: nil
            )
        }

        let duration = Double(max(strongest.endMs - strongest.startMs, 1))
        let local = Double(sourceMs - strongest.startMs)
        let intro = min(420.0, duration * 0.35)
        let outro = min(420.0, duration * 0.35)
        let envelope: Double
        if local < intro {
            envelope = EasingMath.apply(strongest.easing, local / intro)
        } else if local > duration - outro {
            envelope = EasingMath.apply(strongest.easing, max(0, (duration - local) / outro))
        } else {
            envelope = 1
        }

        let scale = 1 + (strongest.scale - 1) * max(0, envelope)
        return ResolvedZoom(
            scale: scale,
            focus: CGPoint(x: strongest.focus.x, y: strongest.focus.y),
            kind: strongest.kind,
            rotation: strongest.rotation
        )
    }

    // MARK: Layout

    private struct ResolvedLayout {
        var kind: LayoutKind
        var previous: LayoutKind?
        var blend: Double
    }

    private func resolvedLayout(at sourceMs: Int) -> ResolvedLayout {
        let layouts = project.timeline.layouts
        guard !layouts.isEmpty else {
            return ResolvedLayout(
                kind: project.camera.enabled ? .cameraOverlay : .screenOnly,
                previous: nil,
                blend: 1
            )
        }

        guard let index = layouts.lastIndex(where: { sourceMs >= $0.startMs && sourceMs < $0.endMs }) else {
            let first = layouts[0]
            return ResolvedLayout(
                kind: .screenOnly,
                previous: first.kind,
                blend: sourceMs < first.startMs ? 0 : 1
            )
        }

        let region = layouts[index]
        let previousKind: LayoutKind? = index > 0 ? layouts[index - 1].kind : nil
        let elapsed = sourceMs - region.startMs
        let blend = region.transitionMs > 0
            ? EasingMath.apply(.smooth, Double(elapsed) / Double(region.transitionMs))
            : 1
        return ResolvedLayout(kind: region.kind, previous: previousKind, blend: blend)
    }

    private struct LayoutFrames {
        var screen: CGRect?
        var camera: CGRect?
    }

    private func layoutFrames(for kind: LayoutKind, canvas: CGSize, zoomScale: Double) -> LayoutFrames {
        let minDimension = min(canvas.width, canvas.height)
        let padding = project.canvas.padding * minDimension
        let content = CGRect(origin: .zero, size: canvas).insetBy(dx: padding, dy: padding)
        let sourceAspect = project.source.sourceAspect

        switch kind {
        case .screenOnly:
            return LayoutFrames(screen: fit(aspect: sourceAspect, in: content), camera: nil)

        case .cameraFullscreen, .cameraCutout:
            return LayoutFrames(screen: nil, camera: CGRect(origin: .zero, size: canvas))

        case .split:
            let gap = minDimension * 0.02
            let isWide = canvas.width >= canvas.height
            if isWide {
                let leftWidth = (content.width - gap) * 0.58
                let rightWidth = content.width - gap - leftWidth
                let left = CGRect(x: content.minX, y: content.minY, width: leftWidth, height: content.height)
                let right = CGRect(
                    x: content.minX + leftWidth + gap,
                    y: content.minY,
                    width: rightWidth,
                    height: content.height
                )
                return LayoutFrames(
                    screen: fit(aspect: sourceAspect, in: left),
                    camera: fit(aspect: 16.0 / 9.0, in: right)
                )
            }
            let topHeight = (content.height - gap) * 0.55
            let bottomHeight = content.height - gap - topHeight
            let top = CGRect(x: content.minX, y: content.minY, width: content.width, height: topHeight)
            let bottom = CGRect(
                x: content.minX,
                y: content.minY + topHeight + gap,
                width: content.width,
                height: bottomHeight
            )
            return LayoutFrames(
                screen: fit(aspect: sourceAspect, in: top),
                camera: fit(aspect: 16.0 / 9.0, in: bottom)
            )

        case .cameraOverlay:
            let screen = fit(aspect: sourceAspect, in: content)
            let region = project.timeline.layouts.last { $0.kind == .cameraOverlay }
            let focus = region?.cameraFocus ?? ZoomFocus(x: 0.82, y: 0.8)
            var size = minDimension * project.camera.sizeFraction
            if project.camera.reactiveZoom {
                size /= pow(max(zoomScale, 1), 0.35)
            }
            size = max(size, minDimension * 0.08)

            var camera = CGRect(
                x: focus.x * canvas.width - size / 2,
                y: focus.y * canvas.height - size / 2,
                width: size,
                height: size
            )
            camera.origin.x = clamp(camera.origin.x, padding, canvas.width - padding - size)
            camera.origin.y = clamp(camera.origin.y, padding, canvas.height - padding - size)
            return LayoutFrames(screen: screen, camera: camera)
        }
    }

    private func maskShape() -> CameraMaskShape {
        if project.camera.cutout { return .cutout }
        switch project.camera.mask {
        case .rectangle: return .none
        case .rounded: return .rounded(radius: 0.16)
        case .circle: return .circle
        case .square: return .square
        }
    }

    // MARK: Geometry

    private func fit(aspect: Double, in rect: CGRect) -> CGRect {
        guard aspect > 0, rect.width > 0, rect.height > 0 else { return rect }
        let rectAspect = rect.width / rect.height
        if rectAspect > aspect {
            let width = rect.height * aspect
            return CGRect(x: rect.midX - width / 2, y: rect.minY, width: width, height: rect.height)
        } else {
            let height = rect.width / aspect
            return CGRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height)
        }
    }
}

private func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
    min(max(value, lower), upper)
}

private func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
    min(max(value, lower), upper)
}
