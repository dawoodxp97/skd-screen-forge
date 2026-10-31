import CoreGraphics
import Foundation

// MARK: - Project document

/// Root document stored at `<Project>.sforge/project.json`.
///
/// The schema is intentionally additive: decoders ignore unknown keys, and every
/// breaking change bumps `schemaVersion` and ships a migration in `ProjectCodec`.
public struct ScreenForgeProject: Codable, Sendable, Equatable, Identifiable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var id: UUID
    public var createdAt: Date
    public var updatedAt: Date
    public var source: SourceInfo
    public var canvas: CanvasSettings
    public var camera: CameraSettings
    public var timeline: Timeline
    public var cursor: CursorSettings
    public var captions: CaptionSettings
    public var export: ExportSettings

    public init(
        schemaVersion: Int = ScreenForgeProject.currentSchemaVersion,
        id: UUID = UUID(),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        source: SourceInfo,
        canvas: CanvasSettings = .default,
        camera: CameraSettings = .default,
        timeline: Timeline = .empty,
        cursor: CursorSettings = .default,
        captions: CaptionSettings = .default,
        export: ExportSettings = .default
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.source = source
        self.canvas = canvas
        self.camera = camera
        self.timeline = timeline
        self.cursor = cursor
        self.captions = captions
        self.export = export
    }

    /// Clamps every editable value into its supported range. Safe to call on
    /// load and before every render.
    public func normalized() -> ScreenForgeProject {
        var copy = self
        copy.canvas = canvas.normalized()
        copy.camera = camera.normalized()
        copy.timeline = timeline.normalized(durationMs: source.durationMs)
        copy.cursor = cursor.normalized()
        copy.captions = captions.normalized()
        copy.export = export.normalized()
        return copy
    }
}

// MARK: - Source

public enum CursorCaptureMode: String, Codable, Sendable, CaseIterable {
    /// Cursor is excluded from capture and re-rendered from telemetry.
    case syntheticOverlay
    /// Capture burned the cursor in (imported video or fallback capture).
    case bakedIn
}

public struct SourceInfo: Codable, Sendable, Equatable {
    /// Paths are relative to the project bundle so projects stay portable.
    public var screenPath: String
    public var webcamPath: String?
    public var systemAudioPath: String?
    public var microphonePath: String?
    public var durationMs: Int
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// Backing scale factor at capture time (2.0 on Retina).
    public var scale: Double
    public var displayName: String
    public var cursorCaptureMode: CursorCaptureMode

    public init(
        screenPath: String,
        webcamPath: String? = nil,
        systemAudioPath: String? = nil,
        microphonePath: String? = nil,
        durationMs: Int,
        pixelWidth: Int,
        pixelHeight: Int,
        scale: Double = 2,
        displayName: String = "Recording",
        cursorCaptureMode: CursorCaptureMode = .syntheticOverlay
    ) {
        self.screenPath = screenPath
        self.webcamPath = webcamPath
        self.systemAudioPath = systemAudioPath
        self.microphonePath = microphonePath
        self.durationMs = durationMs
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.scale = scale
        self.displayName = displayName
        self.cursorCaptureMode = cursorCaptureMode
    }

    public var sourceAspect: Double {
        guard pixelHeight > 0 else { return 16.0 / 9.0 }
        return Double(pixelWidth) / Double(pixelHeight)
    }
}

// MARK: - Canvas / style

public enum AspectRatio: String, Codable, Sendable, CaseIterable {
    case wide
    case square
    case vertical

    public var ratio: Double {
        switch self {
        case .wide: 16.0 / 9.0
        case .square: 1.0
        case .vertical: 9.0 / 16.0
        }
    }

    public var label: String {
        switch self {
        case .wide: "16:9"
        case .square: "1:1"
        case .vertical: "9:16"
        }
    }
}

public struct BackgroundStyle: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case wallpaper
        case gradient
        case solid
        case image
        /// Blurred and dimmed copy of the recording itself.
        case screenBlur
    }

    public var kind: Kind
    /// Wallpaper or preset identifier (e.g. `macos.sonoma.dark`).
    public var identifier: String
    /// Gradient stops / solid fill, as `#RRGGBB`.
    public var colors: [String]
    /// Relative path for `.image` backgrounds.
    public var imagePath: String?
    public var blurRadius: Double

    public init(
        kind: Kind,
        identifier: String = "",
        colors: [String] = ["#1A1A2E", "#16213E"],
        imagePath: String? = nil,
        blurRadius: Double = 0
    ) {
        self.kind = kind
        self.identifier = identifier
        self.colors = colors
        self.imagePath = imagePath
        self.blurRadius = blurRadius
    }

    public static let aurora = BackgroundStyle(
        kind: .gradient,
        identifier: "aurora",
        colors: ["#00C6FF", "#0072FF", "#6A11CB"]
    )

    public static let defaultStyle = BackgroundStyle(
        kind: .gradient,
        identifier: "midnight",
        colors: ["#141E30", "#243B55"]
    )
}

public struct ShadowSettings: Codable, Sendable, Equatable {
    /// Degrees, clockwise from "up".
    public var angle: Double
    /// Offset distance as a fraction of the canvas min-dimension.
    public var distance: Double
    /// Blur radius as a fraction of the canvas min-dimension.
    public var blur: Double
    public var opacity: Double

    public init(angle: Double = 90, distance: Double = 0.03, blur: Double = 0.06, opacity: Double = 0.35) {
        self.angle = angle
        self.distance = distance
        self.blur = blur
        self.opacity = opacity
    }

    public static let none = ShadowSettings(angle: 90, distance: 0, blur: 0, opacity: 0)
}

public struct CanvasSettings: Codable, Sendable, Equatable {
    public var aspect: AspectRatio
    public var background: BackgroundStyle
    /// Outer padding as a fraction of the canvas min-dimension.
    public var padding: Double
    /// Inset of the recording inside its padded frame (fraction).
    public var inset: Double
    /// Corner radius as a fraction of the recording's min-dimension.
    public var cornerRadius: Double
    public var shadow: ShadowSettings

    public init(
        aspect: AspectRatio = .wide,
        background: BackgroundStyle = .defaultStyle,
        padding: Double = 0.06,
        inset: Double = 0,
        cornerRadius: Double = 0.02,
        shadow: ShadowSettings = ShadowSettings()
    ) {
        self.aspect = aspect
        self.background = background
        self.padding = padding
        self.inset = inset
        self.cornerRadius = cornerRadius
        self.shadow = shadow
    }

    public static let `default` = CanvasSettings()

    public func normalized() -> CanvasSettings {
        var copy = self
        copy.padding = min(max(padding, 0), 0.45)
        copy.inset = min(max(inset, 0), 0.25)
        copy.cornerRadius = min(max(cornerRadius, 0), 0.2)
        copy.shadow.distance = min(max(copy.shadow.distance, 0), 0.2)
        copy.shadow.blur = min(max(copy.shadow.blur, 0), 0.25)
        copy.shadow.opacity = min(max(copy.shadow.opacity, 0), 1)
        return copy
    }
}

// MARK: - Camera

public enum WebcamMaskShape: String, Codable, Sendable, CaseIterable {
    case rectangle
    case rounded
    case circle
    case square

    public var label: String { rawValue.capitalized }
}

public struct CameraSettings: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var mirrored: Bool
    /// Overlay width as a fraction of the canvas min-dimension.
    public var sizeFraction: Double
    public var mask: WebcamMaskShape
    /// Shrink the overlay as the screen zooms in, keeping the cursor visible.
    public var reactiveZoom: Bool
    public var faceTracking: Bool
    public var hideDuringSilence: Bool
    public var shadowOpacity: Double

    public init(
        enabled: Bool = false,
        mirrored: Bool = true,
        sizeFraction: Double = 0.22,
        mask: WebcamMaskShape = .rounded,
        reactiveZoom: Bool = true,
        faceTracking: Bool = true,
        hideDuringSilence: Bool = false,
        shadowOpacity: Double = 0.25
    ) {
        self.enabled = enabled
        self.mirrored = mirrored
        self.sizeFraction = sizeFraction
        self.mask = mask
        self.reactiveZoom = reactiveZoom
        self.faceTracking = faceTracking
        self.hideDuringSilence = hideDuringSilence
        self.shadowOpacity = shadowOpacity
    }

    public static let `default` = CameraSettings()

    public func normalized() -> CameraSettings {
        var copy = self
        copy.sizeFraction = min(max(sizeFraction, 0.08), 0.5)
        copy.shadowOpacity = min(max(shadowOpacity, 0), 1)
        return copy
    }
}

// MARK: - Cursor

public enum CursorTheme: String, Codable, Sendable, CaseIterable {
    case systemArrow
    case filledArrow
    case outlinedArrow
    case dot
    case crosshair
    case hand

    public var label: String {
        switch self {
        case .systemArrow: "System arrow"
        case .filledArrow: "Filled arrow"
        case .outlinedArrow: "Outlined arrow"
        case .dot: "Dot"
        case .crosshair: "Crosshair"
        case .hand: "Hand"
        }
    }
}

public enum ClickEffect: String, Codable, Sendable, CaseIterable {
    case none
    case ripple
    case circle
    case pulse

    public var label: String { rawValue.capitalized }
}

public struct CursorSettings: Codable, Sendable, Equatable {
    public var visible: Bool
    /// Multiplier over the system cursor size (1.0 = native).
    public var scale: Double
    /// 0 = raw telemetry, 1 = maximally smoothed.
    public var smoothing: Double
    public var motionBlur: Double
    public var theme: CursorTheme
    public var clickEffect: ClickEffect
    public var clickEffectScale: Double
    /// Hide the cursor after this much idle time; 0 disables.
    public var hideWhenIdleMs: Int
    /// Glide back to the starting point at the end of the video (seamless loops).
    public var loopToStart: Bool
    /// Clip the cursor to the recording frame instead of allowing overflow.
    public var clipToBounds: Bool

    public init(
        visible: Bool = true,
        scale: Double = 1.6,
        smoothing: Double = 0.65,
        motionBlur: Double = 0.3,
        theme: CursorTheme = .filledArrow,
        clickEffect: ClickEffect = .ripple,
        clickEffectScale: Double = 1.0,
        hideWhenIdleMs: Int = 2500,
        loopToStart: Bool = false,
        clipToBounds: Bool = false
    ) {
        self.visible = visible
        self.scale = scale
        self.smoothing = smoothing
        self.motionBlur = motionBlur
        self.theme = theme
        self.clickEffect = clickEffect
        self.clickEffectScale = clickEffectScale
        self.hideWhenIdleMs = hideWhenIdleMs
        self.loopToStart = loopToStart
        self.clipToBounds = clipToBounds
    }

    public static let `default` = CursorSettings()

    public func normalized() -> CursorSettings {
        var copy = self
        copy.scale = min(max(scale, 0.25), 5)
        copy.smoothing = min(max(smoothing, 0), 0.98)
        copy.motionBlur = min(max(motionBlur, 0), 1)
        copy.clickEffectScale = min(max(clickEffectScale, 0.25), 3)
        copy.hideWhenIdleMs = min(max(hideWhenIdleMs, 0), 30_000)
        return copy
    }
}

// MARK: - Captions

public enum CaptionStyle: String, Codable, Sendable, CaseIterable {
    case plain
    case pill
    case bold
    case outline
    case karaoke
    case minimal

    public var label: String { rawValue.capitalized }
}

public enum CaptionPosition: String, Codable, Sendable, CaseIterable {
    case bottom
    case middle
    case top

    public var label: String { rawValue.capitalized }
}

public struct CaptionSettings: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var style: CaptionStyle
    public var position: CaptionPosition
    public var wordsPerLine: Int
    public var fontScale: Double
    public var uppercase: Bool
    /// BCP-47 identifier, e.g. `en-US`.
    public var language: String

    public init(
        enabled: Bool = false,
        style: CaptionStyle = .pill,
        position: CaptionPosition = .bottom,
        wordsPerLine: Int = 5,
        fontScale: Double = 1.0,
        uppercase: Bool = false,
        language: String = Locale.current.identifier
    ) {
        self.enabled = enabled
        self.style = style
        self.position = position
        self.wordsPerLine = wordsPerLine
        self.fontScale = fontScale
        self.uppercase = uppercase
        self.language = language
    }

    public static let `default` = CaptionSettings()

    public func normalized() -> CaptionSettings {
        var copy = self
        copy.wordsPerLine = min(max(wordsPerLine, 1), 12)
        copy.fontScale = min(max(fontScale, 0.5), 2.5)
        return copy
    }
}

// MARK: - Export

public enum ExportResolution: String, Codable, Sendable, CaseIterable {
    case p720
    case p1080
    case p4k
    case custom

    public var shortEdge: Int? {
        switch self {
        case .p720: 720
        case .p1080: 1080
        case .p4k: 2160
        case .custom: nil
        }
    }

    public var label: String {
        switch self {
        case .p720: "720p"
        case .p1080: "1080p"
        case .p4k: "4K"
        case .custom: "Custom"
        }
    }
}

public enum VideoCodec: String, Codable, Sendable, CaseIterable {
    case h264
    case hevc

    public var label: String { self == .h264 ? "H.264" : "HEVC" }
}

public struct ExportSettings: Codable, Sendable, Equatable {
    public var resolution: ExportResolution
    public var customLongEdge: Int?
    public var fps: Int
    public var codec: VideoCodec
    /// 0...1, mapped to AVAssetWriter bitrate heuristics.
    public var quality: Double
    public var includeAudio: Bool
    public var audioBitrateKbps: Int

    public init(
        resolution: ExportResolution = .p1080,
        customLongEdge: Int? = nil,
        fps: Int = 60,
        codec: VideoCodec = .hevc,
        quality: Double = 0.8,
        includeAudio: Bool = true,
        audioBitrateKbps: Int = 192
    ) {
        self.resolution = resolution
        self.customLongEdge = customLongEdge
        self.fps = fps
        self.codec = codec
        self.quality = quality
        self.includeAudio = includeAudio
        self.audioBitrateKbps = audioBitrateKbps
    }

    public static let `default` = ExportSettings()

    public func normalized() -> ExportSettings {
        var copy = self
        copy.fps = [24, 30, 60].contains(fps) ? fps : 60
        copy.quality = min(max(quality, 0.1), 1)
        copy.audioBitrateKbps = min(max(audioBitrateKbps, 64), 320)
        if let long = customLongEdge {
            copy.customLongEdge = min(max(long, 480), 7680)
        }
        return copy
    }
}

// MARK: - Empty/static factories
