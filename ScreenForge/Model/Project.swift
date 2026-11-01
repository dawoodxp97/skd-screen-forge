import CoreGraphics
import Foundation

// MARK: - Project document

/// Root document stored at `<Project>.sforge/project.json`.
///
/// The schema is intentionally additive: decoders ignore unknown keys, and every
/// breaking change bumps `schemaVersion` and ships a migration in `ProjectCodec`.
public struct ScreenForgeProject: Codable, Sendable, Equatable, Identifiable {
    public static let currentSchemaVersion = 2

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
    public var audio: AudioMixSettings
    public var analysis: ProjectAnalysis
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
        audio: AudioMixSettings = .default,
        analysis: ProjectAnalysis = .empty,
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
        self.audio = audio
        self.analysis = analysis
        self.export = export
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, createdAt, updatedAt, source, canvas, camera
        case timeline, cursor, captions, audio, analysis, export
    }

    /// Additive decoding: audio and analysis were introduced in schema v2 and
    /// default cleanly when an older project is opened.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        id = try container.decode(UUID.self, forKey: .id)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        source = try container.decode(SourceInfo.self, forKey: .source)
        canvas = try container.decode(CanvasSettings.self, forKey: .canvas)
        camera = try container.decode(CameraSettings.self, forKey: .camera)
        timeline = try container.decode(Timeline.self, forKey: .timeline)
        cursor = try container.decode(CursorSettings.self, forKey: .cursor)
        captions = try container.decode(CaptionSettings.self, forKey: .captions)
        audio = try container.decodeIfPresent(AudioMixSettings.self, forKey: .audio) ?? .default
        analysis = try container.decodeIfPresent(ProjectAnalysis.self, forKey: .analysis) ?? .empty
        export = try container.decode(ExportSettings.self, forKey: .export)
    }

    /// Clamps every editable value into its supported range. Safe to call on
    /// load and before every render.
    public func normalized() -> ScreenForgeProject {
        var copy = self
        copy.canvas = canvas.normalized()
        copy.camera = camera.normalized()
        copy.timeline = timeline.normalized(durationMs: source.durationMs)
        // Markers and clips live on the output timeline, which can be shorter than
        // the source after trims (or longer after slow motion).
        let outputMs = Int(
            copy.timeline
                .map(sourceDurationMs: source.durationMs)
                .outputDurationMs
                .rounded()
        )
        copy.timeline.markers = copy.timeline.markers.map {
            $0.clamped(toDuration: outputMs)
        }
        copy.timeline.audioClips = copy.timeline.audioClips.map {
            $0.clamped(toDuration: outputMs)
        }
        copy.cursor = cursor.normalized()
        copy.captions = captions.normalized()
        copy.audio = audio.normalized()
        copy.analysis = analysis.normalized(durationMs: source.durationMs)
        copy.export = export.normalized()
        return copy
    }
}

// MARK: - Color grading / motion / mockups

public enum ColorGradePreset: String, Codable, Sendable, CaseIterable {
    case none
    /// Warm highlights, lifted shadows, golden skin.
    case golden
    /// Neutral black-and-white with a gentle S-curve.
    case mono
    /// Earthy greens and warm skin.
    case terra
    /// Teal shadows, orange highlights.
    case cinematic
    /// Cool blue shadows, clean highlights.
    case cool
    /// Soft warm film look.
    case warm
    /// High-contrast desaturated noir.
    case noir

    public var label: String {
        switch self {
        case .none: "None"
        case .golden: "Golden"
        case .mono: "Mono"
        case .terra: "Terra"
        case .cinematic: "Teal & Orange"
        case .cool: "Cool"
        case .warm: "Warm"
        case .noir: "Noir"
        }
    }

    /// 1...7 maps to the shader branch.
    public var shaderIndex: Float {
        switch self {
        case .none: 0
        case .golden: 1
        case .mono: 2
        case .terra: 3
        case .cinematic: 4
        case .cool: 5
        case .warm: 6
        case .noir: 7
        }
    }
}

/// Non-destructive grade applied to the screen (or camera) layer. A user `.cube`
/// LUT replaces the analytic preset when `lutPath` is set.
public struct ColorGrade: Codable, Sendable, Equatable {
    public var preset: ColorGradePreset
    /// 0...1 blend between the original and the graded image.
    public var intensity: Double
    /// 0...1 film grain.
    public var grain: Double
    /// 0...1 unsharp amount.
    public var sharpen: Double
    /// Bundle-relative path to a 3D `.cube` LUT.
    public var lutPath: String?

    public init(
        preset: ColorGradePreset = .none,
        intensity: Double = 1,
        grain: Double = 0,
        sharpen: Double = 0,
        lutPath: String? = nil
    ) {
        self.preset = preset
        self.intensity = intensity
        self.grain = grain
        self.sharpen = sharpen
        self.lutPath = lutPath
    }

    public static let none = ColorGrade()

    public var isActive: Bool {
        preset != .none || lutPath != nil || grain > 0.001 || sharpen > 0.001
    }

    public func normalized() -> ColorGrade {
        var copy = self
        copy.intensity = min(max(intensity, 0), 1)
        copy.grain = min(max(grain, 0), 1)
        copy.sharpen = min(max(sharpen, 0), 1)
        return copy
    }
}

public enum DeviceMockupKind: String, Codable, Sendable, CaseIterable {
    case none
    case macbook
    case display
    case iPhone
    case iPad

    public var label: String {
        switch self {
        case .none: "None"
        case .macbook: "MacBook"
        case .display: "Display"
        case .iPhone: "iPhone"
        case .iPad: "iPad"
        }
    }
}

/// Vector device frames drawn by the compositor. Screen Studio ships 156 raster
/// frames; this rebuilds the same silhouettes procedurally so the app stays
/// asset-free and colour-accurate at any resolution.
public struct DeviceMockup: Codable, Sendable, Equatable {
    public var kind: DeviceMockupKind
    /// Body colour as `#RRGGBB`.
    public var colorHex: String
    /// Fraction of the frame used for the bezel.
    public var bezel: Double
    /// Human-readable model name for saved presets (e.g. "iPhone 17 Pro").
    public var model: String?

    public init(
        kind: DeviceMockupKind = .none,
        colorHex: String = "#B9BEC6",
        bezel: Double = 0.045,
        model: String? = nil
    ) {
        self.kind = kind
        self.colorHex = colorHex
        self.bezel = bezel
        self.model = model
    }

    public static let none = DeviceMockup()

    public func normalized() -> DeviceMockup {
        var copy = self
        copy.bezel = min(max(bezel, 0.01), 0.14)
        return copy
    }
}

/// Model-specific frame presets matching the families observed in Screen Studio's
/// device asset folder. Frames are still drawn as vectors; this controls silhouette,
/// bezel, and body colour.
public struct DeviceMockupPreset: Identifiable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var mockup: DeviceMockup

    public init(id: String, name: String, mockup: DeviceMockup) {
        self.id = id
        self.name = name
        self.mockup = mockup
    }

    public static let all: [DeviceMockupPreset] = [
        DeviceMockupPreset(id: "iphone-17-pro", name: "iPhone 17 Pro",
                           mockup: DeviceMockup(kind: .iPhone, colorHex: "#C8896A", model: "iPhone 17 Pro")),
        DeviceMockupPreset(id: "iphone-16-pro", name: "iPhone 16 Pro",
                           mockup: DeviceMockup(kind: .iPhone, colorHex: "#D8D4CE", model: "iPhone 16 Pro")),
        DeviceMockupPreset(id: "iphone-15-pro", name: "iPhone 15 Pro",
                           mockup: DeviceMockup(kind: .iPhone, colorHex: "#5A6472", model: "iPhone 15 Pro")),
        DeviceMockupPreset(id: "iphone-14", name: "iPhone 14",
                           mockup: DeviceMockup(kind: .iPhone, colorHex: "#2E3A59", model: "iPhone 14")),
        DeviceMockupPreset(id: "ipad-pro-13", name: "iPad Pro 13",
                           mockup: DeviceMockup(kind: .iPad, colorHex: "#B9BEC6", model: "iPad Pro 13")),
        DeviceMockupPreset(id: "ipad-air", name: "iPad Air",
                           mockup: DeviceMockup(kind: .iPad, colorHex: "#8E8E93", model: "iPad Air")),
        DeviceMockupPreset(id: "macbook-air-m2", name: "MacBook Air M2",
                           mockup: DeviceMockup(kind: .macbook, colorHex: "#C7CBD1", model: "MacBook Air M2")),
        DeviceMockupPreset(id: "macbook-pro", name: "MacBook Pro",
                           mockup: DeviceMockup(kind: .macbook, colorHex: "#2F3136", model: "MacBook Pro")),
        DeviceMockupPreset(id: "imac-24", name: "iMac 24-inch",
                           mockup: DeviceMockup(kind: .display, colorHex: "#7DA7D9", bezel: 0.055, model: "iMac 24-inch")),
        DeviceMockupPreset(id: "studio-display", name: "Studio Display",
                           mockup: DeviceMockup(kind: .display, colorHex: "#B9BEC6", bezel: 0.03, model: "Studio Display"))
    ]
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
    /// Audio captured from a separately selected input device (interface, mixer).
    public var externalAudioPath: String?
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
        externalAudioPath: String? = nil,
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
        self.externalAudioPath = externalAudioPath
        self.durationMs = durationMs
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.scale = scale
        self.displayName = displayName
        self.cursorCaptureMode = cursorCaptureMode
    }

    private enum CodingKeys: String, CodingKey {
        case screenPath, webcamPath, systemAudioPath, microphonePath
        case externalAudioPath, durationMs, pixelWidth, pixelHeight, scale
        case displayName, cursorCaptureMode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        screenPath = try container.decode(String.self, forKey: .screenPath)
        webcamPath = try container.decodeIfPresent(String.self, forKey: .webcamPath)
        systemAudioPath = try container.decodeIfPresent(String.self, forKey: .systemAudioPath)
        microphonePath = try container.decodeIfPresent(String.self, forKey: .microphonePath)
        externalAudioPath = try container.decodeIfPresent(String.self, forKey: .externalAudioPath)
        durationMs = try container.decode(Int.self, forKey: .durationMs)
        pixelWidth = try container.decode(Int.self, forKey: .pixelWidth)
        pixelHeight = try container.decode(Int.self, forKey: .pixelHeight)
        scale = try container.decodeIfPresent(Double.self, forKey: .scale) ?? 2
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? "Recording"
        cursorCaptureMode = try container.decodeIfPresent(CursorCaptureMode.self, forKey: .cursorCaptureMode)
            ?? .syntheticOverlay
    }

    public var sourceAspect: Double {
        guard pixelHeight > 0 else { return 16.0 / 9.0 }
        return Double(pixelWidth) / Double(pixelHeight)
    }
}

// MARK: - Audio mix / analysis

public enum VoiceEnhancementMode: String, Codable, Sendable, CaseIterable {
    case off
    case standard
    case podcast
    case denoise

    public var label: String {
        switch self {
        case .off: "Off"
        case .standard: "Standard"
        case .podcast: "Podcast"
        case .denoise: "Strong denoise"
        }
    }
}

/// Global gain stage for the recorded sources plus imported music and
/// voiceover clips. Audio clips also carry their own gain, so this is the mixer
/// layer rather than a destructive edit.
public struct AudioMixSettings: Codable, Sendable, Equatable {
    public var microphoneVolume: Double
    public var systemVolume: Double
    public var externalVolume: Double
    public var musicVolume: Double
    public var voiceoverVolume: Double
    public var soundEffectVolume: Double
    /// Lower music while a voiceover clip is active.
    public var duckMusicUnderVoice: Bool
    /// 0...1: how far music falls while voice is present.
    public var duckAmount: Double
    /// Offline cleanup applied to the microphone track before mixing.
    public var voiceEnhancement: VoiceEnhancementMode
    /// 0...1 noise-gate depth for the enhancement chain.
    public var noiseReduction: Double
    /// 0...1 click sound effect volume (cursor clicks).
    public var clickSoundVolume: Double

    public init(
        microphoneVolume: Double = 1,
        systemVolume: Double = 1,
        externalVolume: Double = 1,
        musicVolume: Double = 0.8,
        voiceoverVolume: Double = 1,
        soundEffectVolume: Double = 1,
        duckMusicUnderVoice: Bool = true,
        duckAmount: Double = 0.45,
        voiceEnhancement: VoiceEnhancementMode = .standard,
        noiseReduction: Double = 0.35,
        clickSoundVolume: Double = 0.5
    ) {
        self.microphoneVolume = microphoneVolume
        self.systemVolume = systemVolume
        self.externalVolume = externalVolume
        self.musicVolume = musicVolume
        self.voiceoverVolume = voiceoverVolume
        self.soundEffectVolume = soundEffectVolume
        self.duckMusicUnderVoice = duckMusicUnderVoice
        self.duckAmount = duckAmount
        self.voiceEnhancement = voiceEnhancement
        self.noiseReduction = noiseReduction
        self.clickSoundVolume = clickSoundVolume
    }

    private enum CodingKeys: String, CodingKey {
        case microphoneVolume, systemVolume, externalVolume, musicVolume
        case voiceoverVolume, soundEffectVolume, duckMusicUnderVoice, duckAmount
        case voiceEnhancement, noiseReduction, clickSoundVolume
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        microphoneVolume = try container.decodeIfPresent(Double.self, forKey: .microphoneVolume) ?? 1
        systemVolume = try container.decodeIfPresent(Double.self, forKey: .systemVolume) ?? 1
        externalVolume = try container.decodeIfPresent(Double.self, forKey: .externalVolume) ?? 1
        musicVolume = try container.decodeIfPresent(Double.self, forKey: .musicVolume) ?? 0.8
        voiceoverVolume = try container.decodeIfPresent(Double.self, forKey: .voiceoverVolume) ?? 1
        soundEffectVolume = try container.decodeIfPresent(Double.self, forKey: .soundEffectVolume) ?? 1
        duckMusicUnderVoice = try container.decodeIfPresent(Bool.self, forKey: .duckMusicUnderVoice) ?? true
        duckAmount = try container.decodeIfPresent(Double.self, forKey: .duckAmount) ?? 0.45
        voiceEnhancement = try container.decodeIfPresent(VoiceEnhancementMode.self, forKey: .voiceEnhancement) ?? .standard
        noiseReduction = try container.decodeIfPresent(Double.self, forKey: .noiseReduction) ?? 0.35
        clickSoundVolume = try container.decodeIfPresent(Double.self, forKey: .clickSoundVolume) ?? 0.5
    }

    public static let `default` = AudioMixSettings()

    public func normalized() -> AudioMixSettings {
        var copy = self
        copy.microphoneVolume = min(max(microphoneVolume, 0), 2)
        copy.systemVolume = min(max(systemVolume, 0), 2)
        copy.externalVolume = min(max(externalVolume, 0), 2)
        copy.musicVolume = min(max(musicVolume, 0), 2)
        copy.voiceoverVolume = min(max(voiceoverVolume, 0), 2)
        copy.soundEffectVolume = min(max(soundEffectVolume, 0), 2)
        copy.duckAmount = min(max(duckAmount, 0), 1)
        copy.noiseReduction = min(max(noiseReduction, 0), 1)
        copy.clickSoundVolume = min(max(clickSoundVolume, 0), 1)
        return copy
    }

    public func gain(for kind: AudioClipKind) -> Double {
        switch kind {
        case .voiceover: voiceoverVolume
        case .music: musicVolume
        case .soundEffect: soundEffectVolume
        case .external: externalVolume
        }
    }
}

public struct SilenceRange: Codable, Sendable, Equatable {
    public var startMs: Int
    public var endMs: Int

    public init(startMs: Int, endMs: Int) {
        self.startMs = startMs
        self.endMs = endMs
    }

    public var durationMs: Int { max(0, endMs - startMs) }

    public func clamped(toDuration durationMs: Int) -> SilenceRange {
        var copy = self
        copy.startMs = min(max(startMs, 0), max(durationMs, 0))
        copy.endMs = min(max(endMs, copy.startMs), max(durationMs, 0))
        return copy
    }
}

/// Derived, non-destructive analysis stored with the project so preview and
/// export behave identically without running ML twice.
/// One precomputed person-segmentation mask sampled from the webcam track.
///
/// Masks are stored as single-channel PNGs inside the project bundle so preview and
/// export never run the segmentation model during playback.
public struct PersonMaskFrame: Codable, Sendable, Equatable {
    public var timeMs: Int
    /// Bundle-relative path, e.g. `media/masks/mask-0001.png`.
    public var path: String

    public init(timeMs: Int, path: String) {
        self.timeMs = timeMs
        self.path = path
    }
}

public struct ProjectAnalysis: Codable, Sendable, Equatable {
    public var silenceRanges: [SilenceRange]
    /// Normalized face centers sampled from the webcam track (time + x/y).
    public var faceSamples: [FaceSample]
    /// Person matte masks ordered by time.
    public var personMasks: [PersonMaskFrame]

    public init(
        silenceRanges: [SilenceRange] = [],
        faceSamples: [FaceSample] = [],
        personMasks: [PersonMaskFrame] = []
    ) {
        self.silenceRanges = silenceRanges
        self.faceSamples = faceSamples
        self.personMasks = personMasks
    }

    private enum CodingKeys: String, CodingKey {
        case silenceRanges, faceSamples, personMasks
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        silenceRanges = try container.decodeIfPresent([SilenceRange].self, forKey: .silenceRanges) ?? []
        faceSamples = try container.decodeIfPresent([FaceSample].self, forKey: .faceSamples) ?? []
        personMasks = try container.decodeIfPresent([PersonMaskFrame].self, forKey: .personMasks) ?? []
    }

    public static let empty = ProjectAnalysis()

    public func normalized(durationMs: Int) -> ProjectAnalysis {
        var copy = self
        copy.silenceRanges = SilenceRange.merged(
            silenceRanges
                .map { $0.clamped(toDuration: durationMs) }
                .filter { $0.durationMs > 0 }
        )
        copy.faceSamples = faceSamples
            .map { $0.clamped(toDuration: durationMs) }
            .sorted { $0.timeMs < $1.timeMs }
        copy.personMasks = personMasks
            .map { frame in
                var copy = frame
                copy.timeMs = min(max(frame.timeMs, 0), max(durationMs, 0))
                return copy
            }
            .filter { !$0.path.isEmpty }
            .sorted { $0.timeMs < $1.timeMs }
        return copy
    }

    /// Nearest person mask at or just before `sourceMs`, tolerating a short gap.
    public func personMask(atSourceMs sourceMs: Int, toleranceMs: Int = 1_500) -> PersonMaskFrame? {
        guard let frame = personMasks.last(where: { $0.timeMs <= sourceMs }) else {
            return personMasks.first
        }
        guard sourceMs - frame.timeMs <= toleranceMs else { return nil }
        return frame
    }

    /// 0...1 camera visibility, with a short fade at both ends of each silence:
    /// fully visible at the edge, fully hidden `fadeMs` inside.
    public func cameraOpacity(atSourceMs sourceMs: Int, fadeMs: Int = 180) -> Double {
        guard !silenceRanges.isEmpty else { return 1 }
        var opacity = 1.0
        for range in silenceRanges {
            guard sourceMs >= range.startMs, sourceMs <= range.endMs else { continue }
            let distanceFromEdge = min(sourceMs - range.startMs, range.endMs - sourceMs)
            let fade = max(fadeMs, 1)
            opacity = min(opacity, min(max(1 - Double(distanceFromEdge) / Double(fade), 0), 1))
        }
        return min(max(opacity, 0), 1)
    }
}

public struct FaceSample: Codable, Sendable, Equatable {    public var timeMs: Int
    /// Normalized center in the camera image, origin top-left.
    public var x: Double
    public var y: Double
    public var confidence: Double

    public init(timeMs: Int, x: Double, y: Double, confidence: Double = 1) {
        self.timeMs = timeMs
        self.x = x
        self.y = y
        self.confidence = confidence
    }

    public func clamped(toDuration durationMs: Int) -> FaceSample {
        var copy = self
        copy.timeMs = min(max(timeMs, 0), max(durationMs, 0))
        copy.x = min(max(x, 0), 1)
        copy.y = min(max(y, 0), 1)
        copy.confidence = min(max(confidence, 0), 1)
        return copy
    }
}

public extension SilenceRange {
    static func merged(_ ranges: [SilenceRange]) -> [SilenceRange] {
        let sorted = ranges.sorted { $0.startMs < $1.startMs }
        var result: [SilenceRange] = []
        for range in sorted {
            if let last = result.last, range.startMs <= last.endMs + 120 {
                result[result.count - 1].endMs = max(last.endMs, range.endMs)
            } else {
                result.append(range)
            }
        }
        return result
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
    /// Screen-layer color grading.
    public var grade: ColorGrade
    /// Edge-directed upscale when the frame is magnified or upscaled.
    public var superResolution: Bool
    /// 0...1 temporal motion blur for screen movement.
    public var motionBlur: Double
    /// Vector device frame around the screen layer.
    public var deviceMockup: DeviceMockup

    public init(
        aspect: AspectRatio = .wide,
        background: BackgroundStyle = .defaultStyle,
        padding: Double = 0.06,
        inset: Double = 0,
        cornerRadius: Double = 0.02,
        shadow: ShadowSettings = ShadowSettings(),
        grade: ColorGrade = .none,
        superResolution: Bool = false,
        motionBlur: Double = 0.6,
        deviceMockup: DeviceMockup = .none
    ) {
        self.aspect = aspect
        self.background = background
        self.padding = padding
        self.inset = inset
        self.cornerRadius = cornerRadius
        self.shadow = shadow
        self.grade = grade
        self.superResolution = superResolution
        self.motionBlur = motionBlur
        self.deviceMockup = deviceMockup
    }

    private enum CodingKeys: String, CodingKey {
        case aspect, background, padding, inset, cornerRadius, shadow
        case grade, superResolution, motionBlur, deviceMockup
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        aspect = try container.decode(AspectRatio.self, forKey: .aspect)
        background = try container.decode(BackgroundStyle.self, forKey: .background)
        padding = try container.decode(Double.self, forKey: .padding)
        inset = try container.decodeIfPresent(Double.self, forKey: .inset) ?? 0
        cornerRadius = try container.decode(Double.self, forKey: .cornerRadius)
        shadow = try container.decode(ShadowSettings.self, forKey: .shadow)
        grade = try container.decodeIfPresent(ColorGrade.self, forKey: .grade) ?? .none
        superResolution = try container.decodeIfPresent(Bool.self, forKey: .superResolution) ?? false
        motionBlur = try container.decodeIfPresent(Double.self, forKey: .motionBlur) ?? 0.6
        deviceMockup = try container.decodeIfPresent(DeviceMockup.self, forKey: .deviceMockup) ?? .none
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
        copy.grade = grade.normalized()
        copy.motionBlur = min(max(motionBlur, 0), 1)
        copy.deviceMockup = deviceMockup.normalized()
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
    /// Person-segmentation cutout: only the speaker is drawn over the background.
    public var cutout: Bool
    public var grade: ColorGrade
    /// 0...1 unsharp mask applied to the camera image.
    public var sharpen: Double

    public init(
        enabled: Bool = false,
        mirrored: Bool = true,
        sizeFraction: Double = 0.22,
        mask: WebcamMaskShape = .rounded,
        reactiveZoom: Bool = true,
        faceTracking: Bool = true,
        hideDuringSilence: Bool = false,
        shadowOpacity: Double = 0.25,
        cutout: Bool = false,
        grade: ColorGrade = .none,
        sharpen: Double = 0
    ) {
        self.enabled = enabled
        self.mirrored = mirrored
        self.sizeFraction = sizeFraction
        self.mask = mask
        self.reactiveZoom = reactiveZoom
        self.faceTracking = faceTracking
        self.hideDuringSilence = hideDuringSilence
        self.shadowOpacity = shadowOpacity
        self.cutout = cutout
        self.grade = grade
        self.sharpen = sharpen
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, mirrored, sizeFraction, mask, reactiveZoom, faceTracking
        case hideDuringSilence, shadowOpacity, cutout, grade, sharpen
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        mirrored = try container.decodeIfPresent(Bool.self, forKey: .mirrored) ?? true
        sizeFraction = try container.decode(Double.self, forKey: .sizeFraction)
        mask = try container.decode(WebcamMaskShape.self, forKey: .mask)
        reactiveZoom = try container.decodeIfPresent(Bool.self, forKey: .reactiveZoom) ?? true
        faceTracking = try container.decodeIfPresent(Bool.self, forKey: .faceTracking) ?? true
        hideDuringSilence = try container.decodeIfPresent(Bool.self, forKey: .hideDuringSilence) ?? false
        shadowOpacity = try container.decodeIfPresent(Double.self, forKey: .shadowOpacity) ?? 0.25
        cutout = try container.decodeIfPresent(Bool.self, forKey: .cutout) ?? false
        grade = try container.decodeIfPresent(ColorGrade.self, forKey: .grade) ?? .none
        sharpen = try container.decodeIfPresent(Double.self, forKey: .sharpen) ?? 0
    }

    public static let `default` = CameraSettings()

    public func normalized() -> CameraSettings {
        var copy = self
        copy.sizeFraction = min(max(sizeFraction, 0.08), 0.5)
        copy.shadowOpacity = min(max(shadowOpacity, 0), 1)
        copy.grade = grade.normalized()
        copy.sharpen = min(max(sharpen, 0), 1)
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
    /// Click sound pack identifier (e.g. `apple-magic-mouse`); nil means silent.
    public var clickSound: String?

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
        clipToBounds: Bool = false,
        clickSound: String? = nil
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
        self.clickSound = clickSound
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
    case proRes422LT
    case proRes422
    case proRes422HQ
    case proRes4444

    public var label: String {
        switch self {
        case .h264: "H.264"
        case .hevc: "HEVC"
        case .proRes422LT: "ProRes 422 LT"
        case .proRes422: "ProRes 422"
        case .proRes422HQ: "ProRes 422 HQ"
        case .proRes4444: "ProRes 4444"
        }
    }

    public var shortLabel: String {
        switch self {
        case .h264: "H.264"
        case .hevc: "HEVC"
        case .proRes422LT: "422 LT"
        case .proRes422: "422"
        case .proRes422HQ: "422 HQ"
        case .proRes4444: "4444"
        }
    }

    public var isProRes: Bool {
        switch self {
        case .proRes422LT, .proRes422, .proRes422HQ, .proRes4444: true
        case .h264, .hevc: false
        }
    }

    public var fileExtension: String { isProRes ? "mov" : "mp4" }
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
        copy.fps = [10, 24, 30, 50, 60].contains(fps) ? fps : 60
        copy.quality = min(max(quality, 0.1), 1)
        copy.audioBitrateKbps = min(max(audioBitrateKbps, 64), 320)
        if let long = customLongEdge {
            copy.customLongEdge = min(max(long, 480), 7680)
        }
        return copy
    }

    public var fileExtension: String {
        codec.isProRes ? "mov" : "mp4"
    }
}

// MARK: - Export presets

/// Delivery recipes matching Screen Studio's built-in output menu. Presets are
/// intentionally data, so a project file only stores the concrete settings; the
/// menu can evolve without breaking older documents.
public struct ExportPreset: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var detail: String
    public var settings: ExportSettings

    public init(id: String, name: String, detail: String, settings: ExportSettings) {
        self.id = id
        self.name = name
        self.detail = detail
        self.settings = settings
    }

    public static let builtIn: [ExportPreset] = [
        ExportPreset(
            id: "mp4-4k-studio-60",
            name: "MP4 4K Studio 60",
            detail: "HEVC · high quality · 60 fps",
            settings: ExportSettings(resolution: .p4k, fps: 60, codec: .hevc, quality: 0.95)
        ),
        ExportPreset(
            id: "mp4-4k-social-60",
            name: "MP4 4K Social 60",
            detail: "H.264 · broad compatibility · 60 fps",
            settings: ExportSettings(resolution: .p4k, fps: 60, codec: .h264, quality: 0.8)
        ),
        ExportPreset(
            id: "mp4-720p-web-low-10",
            name: "MP4 720p Web Low 10",
            detail: "H.264 · small file · 10 fps",
            settings: ExportSettings(resolution: .p720, fps: 10, codec: .h264, quality: 0.45)
        ),
        ExportPreset(
            id: "mp4-720p-web-high-60",
            name: "MP4 720p Web High 60",
            detail: "H.264 · smooth motion · 60 fps",
            settings: ExportSettings(resolution: .p720, fps: 60, codec: .h264, quality: 0.9)
        ),
        ExportPreset(
            id: "mp4-1080p-social-60",
            name: "MP4 1080p Social 60",
            detail: "H.264 · everyday delivery · 60 fps",
            settings: ExportSettings(resolution: .p1080, fps: 60, codec: .h264, quality: 0.85)
        ),
        ExportPreset(
            id: "mp4-1080p-studio-30",
            name: "MP4 1080p Studio 30",
            detail: "HEVC · compact master · 30 fps",
            settings: ExportSettings(resolution: .p1080, fps: 30, codec: .hevc, quality: 0.92)
        ),
        ExportPreset(
            id: "prores-4k-422hq-60",
            name: "ProRes 4K 422 HQ 60",
            detail: "Apple ProRes 422 HQ · .mov · 60 fps",
            settings: ExportSettings(resolution: .p4k, fps: 60, codec: .proRes422HQ, quality: 1)
        ),
        ExportPreset(
            id: "prores-1080p-4444-30",
            name: "ProRes 1080p 4444 30",
            detail: "Apple ProRes 4444 · .mov · 30 fps",
            settings: ExportSettings(resolution: .p1080, fps: 30, codec: .proRes4444, quality: 1)
        )
    ]

    public func matches(_ settings: ExportSettings) -> Bool {
        let left = settings.normalized()
        let right = self.settings.normalized()
        return left.resolution == right.resolution &&
            left.fps == right.fps &&
            left.codec == right.codec
    }
}

// MARK: - Empty/static factories
