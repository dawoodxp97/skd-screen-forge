import CoreGraphics
import Foundation

/// Resolves which caption cue is on screen at a source timestamp.
///
/// Built once per project (like `CursorTrack`) so scrubbing does not re-layout text
/// on every frame.
public struct CaptionTrack: Sendable {
    public let cues: [CaptionCue]
    public let settings: CaptionSettings

    public init(words: [TranscriptWord], settings: CaptionSettings) {
        let settings = settings.normalized()
        self.settings = settings
        self.cues = CaptionLayoutBuilder.cues(
            from: words,
            options: CaptionLayoutBuilder.Options(settings: settings)
        )
    }

    public init(cues: [CaptionCue], settings: CaptionSettings) {
        self.cues = cues
        self.settings = settings.normalized()
    }

    public var isEmpty: Bool { cues.isEmpty }

    /// Cue shown at `sourceMs`, plus the index of the word being spoken.
    ///
    /// Returns nil between cues, so gaps in speech produce gaps in captions rather
    /// than a stale line lingering on screen.
    public func activeCue(at sourceMs: Int) -> (cue: CaptionCue, activeWord: Int?)? {
        guard let cue = cues.first(where: { sourceMs >= $0.startMs && sourceMs < $0.endMs }) else {
            return nil
        }
        let activeWord = cue.wordTimings.lastIndex { $0.startMs <= sourceMs }
        return (cue, activeWord)
    }
}

// MARK: - Geometry

public enum CaptionGeometry {
    /// Width of the caption box as a fraction of the canvas width.
    public static let widthFraction = 0.86
    /// Height of the caption box as a fraction of the canvas height.
    public static let heightFraction = 0.18

    /// Caption box in canvas coordinates (origin top-left).
    public static func overlayRect(canvas: CGSize, position: CaptionPosition) -> CGRect {
        let width = canvas.width * widthFraction
        let height = canvas.height * heightFraction
        let x = (canvas.width - width) / 2
        let y: Double
        switch position {
        case .bottom:
            y = (canvas.height * 0.84 - height / 2).rounded()
        case .middle:
            y = ((canvas.height - height) / 2).rounded()
        case .top:
            y = (canvas.height * 0.06).rounded()
        }
        return CGRect(x: x.rounded(), y: y, width: width.rounded(), height: height)
    }
}
