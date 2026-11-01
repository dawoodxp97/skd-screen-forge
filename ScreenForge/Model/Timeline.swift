import CoreGraphics
import Foundation

// MARK: - Zoom

public struct ZoomFocus: Codable, Sendable, Equatable {
    /// Normalized center of interest inside the source frame (0...1).
    public var x: Double
    public var y: Double

    public init(x: Double = 0.5, y: Double = 0.5) {
        self.x = x
        self.y = y
    }

    public func clamped() -> ZoomFocus {
        ZoomFocus(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
    }

    public static let center = ZoomFocus()
}

public enum ZoomKind: String, Codable, Sendable, CaseIterable {
    /// Scale the whole frame around the focus point.
    case classic
    /// Magnify a rounded lens while the surrounding frame stays put.
    case loupe

    public var label: String { self == .classic ? "Classic" : "Loupe" }
}

public enum ZoomEasing: String, Codable, Sendable, CaseIterable {
    case linear
    case easeInOut
    case smooth
    /// The snappy, slightly overshooting curve the original uses.
    case screenStudio

    public var label: String {
        switch self {
        case .linear: "Linear"
        case .easeInOut: "Ease in/out"
        case .smooth: "Smooth"
        case .screenStudio: "Studio"
        }
    }
}

public enum Rotation3DPreset: String, Codable, Sendable, CaseIterable {
    case iso
    case left
    case right

    public var label: String {
        switch self {
        case .iso: "Isometric"
        case .left: "Tilt left"
        case .right: "Tilt right"
        }
    }

    /// Degrees (x, y, z).
    public var angles: (x: Double, y: Double, z: Double) {
        switch self {
        case .iso: (-10, -16, 0)
        case .left: (0, -22, 0)
        case .right: (0, 22, 0)
        }
    }
}

public enum ZoomSource: String, Codable, Sendable {
    case auto
    case manual
}

public struct ZoomRegion: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var startMs: Int
    public var endMs: Int
    /// Magnification, 1.0...5.0.
    public var scale: Double
    public var focus: ZoomFocus
    public var kind: ZoomKind
    public var easing: ZoomEasing
    public var rotation: Rotation3DPreset?
    public var source: ZoomSource
    /// Set when the region came from a magic-wand pass; clearing the wand removes it.
    public var generated: Bool

    public init(
        id: String = UUID().uuidString,
        startMs: Int,
        endMs: Int,
        scale: Double = 1.8,
        focus: ZoomFocus = .center,
        kind: ZoomKind = .classic,
        easing: ZoomEasing = .screenStudio,
        rotation: Rotation3DPreset? = nil,
        source: ZoomSource = .manual,
        generated: Bool = false
    ) {
        self.id = id
        self.startMs = startMs
        self.endMs = endMs
        self.scale = scale
        self.focus = focus
        self.kind = kind
        self.easing = easing
        self.rotation = rotation
        self.source = source
        self.generated = generated
    }

    public var durationMs: Int { max(0, endMs - startMs) }
    public var midMs: Int { startMs + durationMs / 2 }

    public func clamped(toDuration durationMs: Int) -> ZoomRegion {
        var copy = self
        copy.startMs = min(max(startMs, 0), max(durationMs - 200, 0))
        copy.endMs = min(max(endMs, copy.startMs + 200), max(durationMs, 200))
        copy.scale = min(max(scale, 1.0), 5.0)
        copy.focus = focus.clamped()
        return copy
    }
}

// MARK: - Trims / speed

public struct TrimRegion: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var startMs: Int
    public var endMs: Int

    public init(id: String = UUID().uuidString, startMs: Int, endMs: Int) {
        self.id = id
        self.startMs = startMs
        self.endMs = endMs
    }

    public var durationMs: Int { max(0, endMs - startMs) }

    public func clamped(toDuration durationMs: Int) -> TrimRegion {
        var copy = self
        copy.startMs = min(max(startMs, 0), durationMs)
        copy.endMs = min(max(endMs, copy.startMs), durationMs)
        return copy
    }
}

public struct SpeedRegion: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var startMs: Int
    public var endMs: Int
    /// Playback rate; 2 means twice as fast.
    public var rate: Double

    public init(id: String = UUID().uuidString, startMs: Int, endMs: Int, rate: Double = 2.0) {
        self.id = id
        self.startMs = startMs
        self.endMs = endMs
        self.rate = rate
    }

    public var durationMs: Int { max(0, endMs - startMs) }

    public func clamped(toDuration durationMs: Int) -> SpeedRegion {
        var copy = self
        copy.startMs = min(max(startMs, 0), durationMs)
        copy.endMs = min(max(endMs, copy.startMs), durationMs)
        copy.rate = min(max(rate, 0.1), 16)
        return copy
    }
}

// MARK: - Layouts

public enum LayoutKind: String, Codable, Sendable, CaseIterable {
    case screenOnly
    case cameraFullscreen
    case split
    case cameraOverlay
    case cameraCutout

    public var label: String {
        switch self {
        case .screenOnly: "Screen only"
        case .cameraFullscreen: "Camera fullscreen"
        case .split: "Split screen"
        case .cameraOverlay: "Camera overlay"
        case .cameraCutout: "Camera cutout"
        }
    }
}

public struct LayoutRegion: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var startMs: Int
    public var endMs: Int
    public var kind: LayoutKind
    /// Overlay position when `kind == .cameraOverlay` (normalized center).
    public var cameraFocus: ZoomFocus
    /// Transition duration into this layout.
    public var transitionMs: Int

    public init(
        id: String = UUID().uuidString,
        startMs: Int,
        endMs: Int,
        kind: LayoutKind = .cameraOverlay,
        cameraFocus: ZoomFocus = ZoomFocus(x: 0.82, y: 0.8),
        transitionMs: Int = 500
    ) {
        self.id = id
        self.startMs = startMs
        self.endMs = endMs
        self.kind = kind
        self.cameraFocus = cameraFocus
        self.transitionMs = transitionMs
    }

    public var durationMs: Int { max(0, endMs - startMs) }

    public func clamped(toDuration durationMs: Int) -> LayoutRegion {
        var copy = self
        copy.startMs = min(max(startMs, 0), durationMs)
        copy.endMs = min(max(endMs, copy.startMs + 100), max(durationMs, 100))
        copy.transitionMs = min(max(transitionMs, 0), 2000)
        copy.cameraFocus = cameraFocus.clamped()
        return copy
    }
}

// MARK: - Annotations / masks

public enum AnnotationType: String, Codable, Sendable, CaseIterable {
    case text
    case image
    case figure
    case blur
    case highlight

    public var label: String {
        switch self {
        case .text: "Text"
        case .image: "Image"
        case .figure: "Shape"
        case .blur: "Blur"
        case .highlight: "Highlight"
        }
    }
}

public struct NormalizedRect: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double = 0.25, y: Double = 0.25, width: Double = 0.5, height: Double = 0.3) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    public func clamped() -> NormalizedRect {
        let w = min(max(width, 0.01), 1)
        let h = min(max(height, 0.01), 1)
        return NormalizedRect(
            x: min(max(x, 0), 1 - w),
            y: min(max(y, 0), 1 - h),
            width: w,
            height: h
        )
    }
}

public enum AnnotationTextAnimation: String, Codable, Sendable, CaseIterable {
    case none
    case fade
    case rise
    case pop
    case slideLeft
    case typewriter
    case pulse

    public var label: String {
        switch self {
        case .none: "None"
        case .fade: "Fade"
        case .rise: "Rise"
        case .pop: "Pop"
        case .slideLeft: "Slide"
        case .typewriter: "Typewriter"
        case .pulse: "Pulse"
        }
    }
}

public struct AnnotationStyle: Codable, Sendable, Equatable {
    public var colorHex: String
    public var backgroundHex: String
    public var fontSize: Double
    public var fontFamily: String
    public var isBold: Bool
    public var isItalic: Bool
    public var alignment: String
    public var animation: AnnotationTextAnimation
    public var opacity: Double

    public init(
        colorHex: String = "#FFFFFF",
        backgroundHex: String = "#00000000",
        fontSize: Double = 32,
        fontFamily: String = "SF Pro",
        isBold: Bool = true,
        isItalic: Bool = false,
        alignment: String = "center",
        animation: AnnotationTextAnimation = .none,
        opacity: Double = 1
    ) {
        self.colorHex = colorHex
        self.backgroundHex = backgroundHex
        self.fontSize = fontSize
        self.fontFamily = fontFamily
        self.isBold = isBold
        self.isItalic = isItalic
        self.alignment = alignment
        self.animation = animation
        self.opacity = opacity
    }

    public static let `default` = AnnotationStyle()
}

public enum MaskKind: String, Codable, Sendable, CaseIterable {
    case blur
    case mosaic
    case dim
}

public struct MaskSettings: Codable, Sendable, Equatable {
    public var kind: MaskKind
    public var intensity: Double
    public var blockSize: Int
    public var cornerRadius: Double
    /// Freehand points in annotation-local coordinates (0...1).
    public var freehandPoints: [CGPoint]?

    public init(
        kind: MaskKind = .blur,
        intensity: Double = 12,
        blockSize: Int = 12,
        cornerRadius: Double = 8,
        freehandPoints: [CGPoint]? = nil
    ) {
        self.kind = kind
        self.intensity = intensity
        self.blockSize = blockSize
        self.cornerRadius = cornerRadius
        self.freehandPoints = freehandPoints
    }
}

public struct AnnotationRegion: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var type: AnnotationType
    public var startMs: Int
    public var endMs: Int
    public var text: String?
    public var imagePath: String?
    public var rect: NormalizedRect
    public var style: AnnotationStyle
    public var zIndex: Int
    public var mask: MaskSettings?
    /// True for masks created by the automatic sensitive-data/face scanner.
    public var generated: Bool?

    public init(
        id: String = UUID().uuidString,
        type: AnnotationType = .text,
        startMs: Int,
        endMs: Int,
        text: String? = nil,
        imagePath: String? = nil,
        rect: NormalizedRect = NormalizedRect(),
        style: AnnotationStyle = .default,
        zIndex: Int = 1,
        mask: MaskSettings? = nil,
        generated: Bool? = nil
    ) {
        self.id = id
        self.type = type
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
        self.imagePath = imagePath
        self.rect = rect
        self.style = style
        self.zIndex = zIndex
        self.mask = mask
        self.generated = generated
    }

    public var durationMs: Int { max(0, endMs - startMs) }

    public func clamped(toDuration durationMs: Int) -> AnnotationRegion {
        var copy = self
        copy.startMs = min(max(startMs, 0), durationMs)
        copy.endMs = min(max(endMs, copy.startMs + 100), max(durationMs, 100))
        copy.rect = rect.clamped()
        return copy
    }
}

// MARK: - Transcript edits

public enum TranscriptEditKind: String, Codable, Sendable, CaseIterable {
    /// User selected words and deleted them.
    case deleteRange
    /// Filler-word cleanup (`um`, `uh`, ...).
    case removeFiller
    /// Long-silence compression.
    case removePause
    /// Sentence-level cut from the transcript UI.
    case deleteSentence

    public var label: String {
        switch self {
        case .deleteRange: "Deleted text"
        case .removeFiller: "Filler word"
        case .removePause: "Pause"
        case .deleteSentence: "Deleted sentence"
        }
    }
}

public struct TranscriptEdit: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var kind: TranscriptEditKind
    public var startMs: Int
    public var endMs: Int
    public var text: String?

    public init(
        id: String = UUID().uuidString,
        kind: TranscriptEditKind,
        startMs: Int,
        endMs: Int,
        text: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
    }
}

// MARK: - Timeline markers / audio tracks

public enum TimelineMarkerKind: String, Codable, Sendable, CaseIterable {
    case marker
    case flag
    case chapter

    public var label: String {
        switch self {
        case .marker: "Marker"
        case .flag: "Flag"
        case .chapter: "Chapter"
        }
    }

    public var symbol: String {
        switch self {
        case .marker: "bookmark.fill"
        case .flag: "flag.fill"
        case .chapter: "list.bullet.rectangle"
        }
    }
}

/// A lightweight point on the **output** timeline. Markers recorded live are
/// carried into the project and can later become chapters or export cue points.
public struct TimelineMarker: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var timeMs: Int
    public var label: String
    public var kind: TimelineMarkerKind
    public var colorHex: String

    public init(
        id: String = UUID().uuidString,
        timeMs: Int,
        label: String = "Marker",
        kind: TimelineMarkerKind = .marker,
        colorHex: String = "#FFD60A"
    ) {
        self.id = id
        self.timeMs = timeMs
        self.label = label
        self.kind = kind
        self.colorHex = colorHex
    }

    public func clamped(toDuration durationMs: Int) -> TimelineMarker {
        var copy = self
        copy.timeMs = min(max(timeMs, 0), max(durationMs, 0))
        if copy.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            copy.label = copy.kind.label
        }
        return copy
    }
}

public enum AudioClipKind: String, Codable, Sendable, CaseIterable {
    case voiceover
    case music
    case soundEffect
    case external

    public var label: String {
        switch self {
        case .voiceover: "Voiceover"
        case .music: "Music"
        case .soundEffect: "Sound effect"
        case .external: "Audio"
        }
    }

    public var symbol: String {
        switch self {
        case .voiceover: "waveform.circle.fill"
        case .music: "music.note"
        case .soundEffect: "sparkles"
        case .external: "speaker.wave.2.fill"
        }
    }
}

/// A free-standing audio clip placed on the **output** timeline. Voiceover,
/// background music, and sound effects all use this model. `startMs` is output
/// time so clips stay attached to the visible edit when cuts or speed changes
/// are applied underneath them.
public struct AudioClip: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var kind: AudioClipKind
    /// Bundle-relative path, e.g. `media/music-loop.m4a`.
    public var path: String
    public var label: String
    public var startMs: Int
    public var durationMs: Int
    public var sourceStartMs: Int
    /// Linear gain, 0...2 (1 = unity).
    public var volume: Double
    public var fadeInMs: Int
    public var fadeOutMs: Int
    /// Repeat the source until `durationMs` is filled.
    public var loops: Bool
    public var muted: Bool

    public init(
        id: String = UUID().uuidString,
        kind: AudioClipKind = .music,
        path: String,
        label: String? = nil,
        startMs: Int = 0,
        durationMs: Int,
        sourceStartMs: Int = 0,
        volume: Double = 1,
        fadeInMs: Int = 0,
        fadeOutMs: Int = 0,
        loops: Bool = false,
        muted: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.path = path
        self.label = label ?? kind.label
        self.startMs = startMs
        self.durationMs = durationMs
        self.sourceStartMs = sourceStartMs
        self.volume = volume
        self.fadeInMs = fadeInMs
        self.fadeOutMs = fadeOutMs
        self.loops = loops
        self.muted = muted
    }

    public var endMs: Int { startMs + durationMs }

    public func clamped(toDuration timelineDurationMs: Int) -> AudioClip {
        var copy = self
        copy.startMs = min(max(startMs, 0), max(timelineDurationMs, 0))
        let maximum = max(timelineDurationMs - copy.startMs, 0)
        copy.durationMs = min(max(durationMs, 0), maximum)
        copy.sourceStartMs = max(sourceStartMs, 0)
        copy.volume = min(max(volume, 0), 2)
        copy.fadeInMs = min(max(fadeInMs, 0), copy.durationMs)
        copy.fadeOutMs = min(max(fadeOutMs, 0), copy.durationMs - copy.fadeInMs)
        return copy
    }
}

// MARK: - Timeline

public struct Timeline: Codable, Sendable, Equatable {
    public var zooms: [ZoomRegion]
    public var trims: [TrimRegion]
    public var speeds: [SpeedRegion]
    public var annotations: [AnnotationRegion]
    public var layouts: [LayoutRegion]
    public var transcriptEdits: [TranscriptEdit]
    public var markers: [TimelineMarker]
    public var audioClips: [AudioClip]
    /// Master switch for magic-wand suggestions.
    public var autoZoomEnabled: Bool
    /// Flip every zoom between cursor-follow and fixed focus.
    public var autoFocusEnabled: Bool

    public init(
        zooms: [ZoomRegion] = [],
        trims: [TrimRegion] = [],
        speeds: [SpeedRegion] = [],
        annotations: [AnnotationRegion] = [],
        layouts: [LayoutRegion] = [],
        transcriptEdits: [TranscriptEdit] = [],
        markers: [TimelineMarker] = [],
        audioClips: [AudioClip] = [],
        autoZoomEnabled: Bool = true,
        autoFocusEnabled: Bool = false
    ) {
        self.zooms = zooms
        self.trims = trims
        self.speeds = speeds
        self.annotations = annotations
        self.layouts = layouts
        self.transcriptEdits = transcriptEdits
        self.markers = markers
        self.audioClips = audioClips
        self.autoZoomEnabled = autoZoomEnabled
        self.autoFocusEnabled = autoFocusEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case zooms, trims, speeds, annotations, layouts, transcriptEdits
        case markers, audioClips, autoZoomEnabled, autoFocusEnabled
    }

    /// Missing marker/audio keys decode to empty arrays so projects created by
    /// earlier ScreenForge builds keep opening without a migration prompt.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        zooms = try container.decodeIfPresent([ZoomRegion].self, forKey: .zooms) ?? []
        trims = try container.decodeIfPresent([TrimRegion].self, forKey: .trims) ?? []
        speeds = try container.decodeIfPresent([SpeedRegion].self, forKey: .speeds) ?? []
        annotations = try container.decodeIfPresent([AnnotationRegion].self, forKey: .annotations) ?? []
        layouts = try container.decodeIfPresent([LayoutRegion].self, forKey: .layouts) ?? []
        transcriptEdits = try container.decodeIfPresent([TranscriptEdit].self, forKey: .transcriptEdits) ?? []
        markers = try container.decodeIfPresent([TimelineMarker].self, forKey: .markers) ?? []
        audioClips = try container.decodeIfPresent([AudioClip].self, forKey: .audioClips) ?? []
        autoZoomEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoZoomEnabled) ?? true
        autoFocusEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoFocusEnabled) ?? false
    }

    public static let empty = Timeline()

    public func normalized(durationMs: Int) -> Timeline {
        var copy = self
        copy.zooms = zooms
            .map { $0.clamped(toDuration: durationMs) }
            .filter { $0.endMs > $0.startMs }
            .sorted { $0.startMs < $1.startMs }
        copy.trims = trims
            .map { $0.clamped(toDuration: durationMs) }
            .filter { $0.endMs > $0.startMs }
            .sorted { $0.startMs < $1.startMs }
        copy.speeds = speeds
            .map { $0.clamped(toDuration: durationMs) }
            .filter { $0.endMs > $0.startMs }
            .sorted { $0.startMs < $1.startMs }
        copy.annotations = annotations
            .map { $0.clamped(toDuration: durationMs) }
            .filter { $0.endMs > $0.startMs }
            .sorted { $0.zIndex < $1.zIndex }
        copy.layouts = layouts
            .map { $0.clamped(toDuration: durationMs) }
            .filter { $0.endMs > $0.startMs }
            .sorted { $0.startMs < $1.startMs }
        copy.transcriptEdits = transcriptEdits.sorted { $0.startMs < $1.startMs }
        // Markers and clips are output-time objects; `ScreenForgeProject.normalized`
        // clamps them once the output duration is known.
        copy.markers = markers.sorted { $0.timeMs < $1.timeMs }
        copy.audioClips = audioClips
            .filter { $0.durationMs > 0 && !$0.path.isEmpty }
            .sorted { $0.startMs < $1.startMs }
        return copy
    }

    /// Zooms active at a source timestamp, strongest first.
    public func activeZooms(at ms: Int) -> [ZoomRegion] {
        zooms
            .filter { ms >= $0.startMs && ms <= $0.endMs }
            .sorted { $0.scale > $1.scale }
    }

    public func layout(at ms: Int) -> LayoutRegion? {
        layouts.last { ms >= $0.startMs && ms < $0.endMs }
    }

    public func annotations(at ms: Int) -> [AnnotationRegion] {
        annotations.filter { ms >= $0.startMs && ms <= $0.endMs }
    }

    public func markers(at ms: Int, toleranceMs: Int = 40) -> [TimelineMarker] {
        markers.filter { abs($0.timeMs - ms) <= toleranceMs }
    }
}

// MARK: - Timeline mapping

/// Maps source time ↔ output time across trims (removed ranges) and speed regions.
///
/// The timeline presents *output* time. Rendering and export read *source* media,
/// so every seek/scrub/audio read goes through this map.
public struct TimelineMap: Sendable, Equatable {
    public struct Segment: Sendable, Equatable {
        public let sourceStartMs: Double
        public let sourceEndMs: Double
        public let outputStartMs: Double
        /// 0 means the range is removed; otherwise source ms per output ms.
        public let rate: Double

        public var sourceLengthMs: Double { max(0, sourceEndMs - sourceStartMs) }
        public var outputLengthMs: Double { rate > 0 ? sourceLengthMs / rate : 0 }
        public var isRemoved: Bool { rate <= 0 }
        public var outputEndMs: Double { outputStartMs + outputLengthMs }
    }

    public let segments: [Segment]
    public let outputDurationMs: Double
    public let sourceDurationMs: Double

    private init(segments: [Segment], outputDurationMs: Double, sourceDurationMs: Double) {
        self.segments = segments
        self.outputDurationMs = outputDurationMs
        self.sourceDurationMs = sourceDurationMs
    }

    /// Builds a piecewise-linear map. Trim ranges win over speed ranges; overlapping
    /// speed ranges resolve to the last one in document order.
    public static func build(
        trims: [TrimRegion],
        speeds: [SpeedRegion],
        sourceDurationMs: Int
    ) -> TimelineMap {
        let duration = Double(max(sourceDurationMs, 0))
        guard duration > 0 else {
            return TimelineMap(segments: [], outputDurationMs: 0, sourceDurationMs: 0)
        }

        let mergedTrims = merge(trims.map {
            (max(0, Double($0.startMs)), min(duration, Double($0.endMs)))
        }.filter { $0.1 > $0.0 })

        let normalizedSpeeds = speeds
            .map { (max(0, Double($0.startMs)), min(duration, Double($0.endMs)), min(max($0.rate, 0.1), 16)) }
            .filter { $0.1 > $0.0 }
            .sorted { $0.0 < $1.0 }

        var boundaries: Set<Double> = [0, duration]
        for trim in mergedTrims {
            boundaries.insert(trim.0)
            boundaries.insert(trim.1)
        }
        for speed in normalizedSpeeds {
            boundaries.insert(speed.0)
            boundaries.insert(speed.1)
        }

        let sorted = boundaries.sorted()
        var segments: [Segment] = []
        var outputCursor = 0.0

        for index in 0..<(sorted.count - 1) {
            let start = sorted[index]
            let end = sorted[index + 1]
            guard end > start else { continue }
            let mid = (start + end) / 2

            let isTrimmed = mergedTrims.contains { mid >= $0.0 && mid < $0.1 }
            let rate: Double
            if isTrimmed {
                rate = 0
            } else if let speed = normalizedSpeeds.last(where: { mid >= $0.0 && mid < $0.1 }) {
                rate = speed.2
            } else {
                rate = 1
            }

            if var last = segments.last,
               last.rate == rate,
               abs(last.sourceEndMs - start) < 0.0001 {
                last = Segment(
                    sourceStartMs: last.sourceStartMs,
                    sourceEndMs: end,
                    outputStartMs: last.outputStartMs,
                    rate: rate
                )
                segments[segments.count - 1] = last
            } else {
                segments.append(Segment(
                    sourceStartMs: start,
                    sourceEndMs: end,
                    outputStartMs: outputCursor,
                    rate: rate
                ))
            }

            if rate > 0 {
                outputCursor += (end - start) / rate
            }
        }

        return TimelineMap(
            segments: segments,
            outputDurationMs: outputCursor,
            sourceDurationMs: duration
        )
    }

    /// Source timestamp for a given output timestamp. Returns nil inside removed ranges.
    ///
    /// Segment boundaries are resolved to the *later* segment: the first output instant
    /// after a cut shows the frame that follows it, so preview and export never show a
    /// stale pre-cut frame on the boundary.
    public func sourceTime(forOutputMs outputMs: Double) -> Double? {
        guard !segments.isEmpty else { return nil }
        let clamped = min(max(outputMs, 0), outputDurationMs)
        for segment in segments.reversed() where !segment.isRemoved {
            guard clamped >= segment.outputStartMs - 0.0001 else { continue }
            let offset = min(max(clamped - segment.outputStartMs, 0), segment.outputLengthMs)
            return segment.sourceStartMs + offset * segment.rate
        }
        return sourceDurationMs
    }

    /// Output timestamp for a given source timestamp. Returns nil for trimmed media.
    public func outputTime(forSourceMs sourceMs: Double) -> Double? {
        guard !segments.isEmpty else { return nil }
        let clamped = min(max(sourceMs, 0), sourceDurationMs)
        for segment in segments.reversed() {
            guard clamped >= segment.sourceStartMs - 0.0001 else { continue }
            guard !segment.isRemoved else { return nil }
            let offset = min(max(clamped - segment.sourceStartMs, 0), segment.sourceLengthMs)
            return segment.outputStartMs + offset / segment.rate
        }
        return outputDurationMs
    }

    /// Segments intersecting an output range, with the intersection bounds.
    public func segments(forOutputRange range: Range<Double>) -> [Segment] {
        segments.compactMap { segment in
            guard !segment.isRemoved else { return nil }
            let start = max(range.lowerBound, segment.outputStartMs)
            let end = min(range.upperBound, segment.outputEndMs)
            guard end > start else { return nil }
            let sourceStart = segment.sourceStartMs + (start - segment.outputStartMs) * segment.rate
            let sourceEnd = segment.sourceStartMs + (end - segment.outputStartMs) * segment.rate
            return Segment(
                sourceStartMs: sourceStart,
                sourceEndMs: sourceEnd,
                outputStartMs: start,
                rate: segment.rate
            )
        }
    }

    private static func merge(_ ranges: [(Double, Double)]) -> [(Double, Double)] {
        let sorted = ranges.sorted { $0.0 < $1.0 }
        var result: [(Double, Double)] = []
        for range in sorted {
            if let last = result.last, range.0 <= last.1 {
                result[result.count - 1] = (last.0, max(last.1, range.1))
            } else {
                result.append(range)
            }
        }
        return result
    }
}

extension Timeline {
    /// Convenience factory used by the editor and exporter.
    public func map(sourceDurationMs: Int) -> TimelineMap {
        .build(trims: trims, speeds: speeds, sourceDurationMs: sourceDurationMs)
    }
}
