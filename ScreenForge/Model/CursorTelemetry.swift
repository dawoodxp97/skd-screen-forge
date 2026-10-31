import CoreGraphics
import Foundation

// MARK: - Sample

/// One cursor observation. Coordinates are normalized against the captured display,
/// origin top-left, so they survive any output resolution.
public struct CursorSample: Codable, Sendable, Equatable {
    public enum Interaction: String, Codable, Sendable {
        case move
        case click
        case doubleClick
        case rightClick
        case middleClick
        case scroll
        case drag
    }

    public var timeMs: Int
    public var x: Double
    public var y: Double
    public var interaction: Interaction
    public var cursorType: String?
    /// False when the system cursor was hidden (e.g. fullscreen video).
    public var visible: Bool

    public init(
        timeMs: Int,
        x: Double,
        y: Double,
        interaction: Interaction = .move,
        cursorType: String? = nil,
        visible: Bool = true
    ) {
        self.timeMs = timeMs
        self.x = x
        self.y = y
        self.interaction = interaction
        self.cursorType = cursorType
        self.visible = visible
    }
}

public struct CursorRecording: Codable, Sendable, Equatable {
    public var version: Int
    public var samples: [CursorSample]

    public init(version: Int = 1, samples: [CursorSample]) {
        self.version = version
        self.samples = samples
    }
}

// MARK: - JSONL storage

public enum CursorJSONL {
    public static func encode(_ samples: [CursorSample]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = Data()
        for sample in samples {
            data.append(try encoder.encode(sample))
            data.append(0x0A)
        }
        return data
    }

    public static func decode(_ data: Data) throws -> [CursorSample] {
        let decoder = JSONDecoder()
        var samples: [CursorSample] = []
        samples.reserveCapacity(data.count / 64)
        for line in data.split(separator: 0x0A) where !line.isEmpty {
            samples.append(try decoder.decode(CursorSample.self, from: Data(line)))
        }
        return samples
    }

    public static func load(from url: URL) throws -> [CursorSample] {
        try decode(Data(contentsOf: url))
    }

    public static func append(_ samples: [CursorSample], to url: URL) throws {
        let data = try encode(samples)
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: url, options: .atomic)
        }
    }
}

// MARK: - Filtering

/// One Euro filter — the standard low-latency smoother for pointer telemetry.
private final class OneEuroAxis {
    private var lastValue: Double?
    private var lastDerivative: Double?
    private var lastTime: Double?
    private var valueFilter: Double?

    func reset() {
        lastValue = nil
        lastDerivative = nil
        lastTime = nil
        valueFilter = nil
    }

    func filter(_ value: Double, time: Double, minCutoff: Double, beta: Double, derivativeCutoff: Double) -> Double {
        let dt = lastTime.map { max(time - $0, 1.0 / 240.0) } ?? 1.0 / 120.0
        lastTime = time

        let derivative = lastValue.map { (value - $0) / dt } ?? 0
        lastValue = value

        let smoothedDerivative = lowPass(
            derivative,
            previous: &lastDerivative,
            alpha: alpha(cutoff: derivativeCutoff, dt: dt)
        )
        let cutoff = minCutoff + beta * abs(smoothedDerivative)
        return lowPass(value, previous: &valueFilter, alpha: alpha(cutoff: cutoff, dt: dt))
    }

    private func lowPass(_ value: Double, previous: inout Double?, alpha: Double) -> Double {
        let result = previous.map { $0 + alpha * (value - $0) } ?? value
        previous = result
        return result
    }

    private func alpha(cutoff: Double, dt: Double) -> Double {
        let tau = 1.0 / (2.0 * .pi * max(cutoff, 0.001))
        return 1.0 / (1.0 + tau / dt)
    }
}

// MARK: - Evaluated frame

public struct CursorFrame: Sendable, Equatable {
    /// Normalized position (0...1).
    public var position: CGPoint
    public var isVisible: Bool
    /// 0...1 press animation; 1 = fully pressed.
    public var pressAmount: Double
    /// Active click ripple, if any.
    public var effect: ClickEffectFrame?

    public struct ClickEffectFrame: Sendable, Equatable {
        public var position: CGPoint
        public var progress: Double
        public var interaction: CursorSample.Interaction
    }

    public static let hidden = CursorFrame(
        position: .zero,
        isVisible: false,
        pressAmount: 0,
        effect: nil
    )
}

/// A resampled, smoothed, random-access view over cursor telemetry.
///
/// Building the track once (at 120 Hz) makes scrubbing and frame-accurate export cheap:
/// evaluation is interpolation over a preallocated array, not re-filtering the raw log.
public struct CursorTrack: Sendable {
    public let settings: CursorSettings
    public let durationMs: Int
    public let sampleRate: Int

    private let positions: [CGPoint]
    private let visibility: [Bool]
    private let clickSamples: [CursorSample]

    public init(samples rawSamples: [CursorSample], settings: CursorSettings, durationMs: Int) {
        let settings = settings.normalized()
        self.settings = settings
        self.durationMs = max(durationMs, 0)
        self.sampleRate = 120

        let samples = rawSamples.sorted { $0.timeMs < $1.timeMs }
        self.clickSamples = samples.filter { $0.interaction != .move && $0.interaction != .scroll }

        let frameCount = max(Int(Double(self.durationMs) / 1000.0 * Double(sampleRate)) + 1, 1)
        var xs = [Double](repeating: 0, count: frameCount)
        var ys = [Double](repeating: 0, count: frameCount)
        var visibility = [Bool](repeating: true, count: frameCount)

        let oneEuro = OneEuroAxis()
        let oneEuroY = OneEuroAxis()
        // 0 → responsive (120 Hz cutoff), 1 → very smooth (~1.2 Hz cutoff).
        let minCutoff = exp(log(120.0) + (log(1.2) - log(120.0)) * settings.smoothing)
        let beta = 0.02 * (1.0 - settings.smoothing)

        var rawIndex = 0
        var activityIndex = 0
        var lastActivityMs = 0
        var lastKnown = CGPoint(x: 0.5, y: 0.5)

        for frame in 0..<frameCount {
            let timeMs = Double(frame) / Double(sampleRate) * 1000.0

            while rawIndex + 1 < samples.count, Double(samples[rawIndex + 1].timeMs) <= timeMs {
                rawIndex += 1
            }

            // Every recorded sample is an event (moves are throttled, not periodic),
            // so the newest sample timestamp is the last activity timestamp.
            while activityIndex < samples.count, Double(samples[activityIndex].timeMs) <= timeMs {
                lastActivityMs = samples[activityIndex].timeMs
                activityIndex += 1
            }

            let current = samples.isEmpty ? nil : samples[rawIndex]
            let next = rawIndex + 1 < samples.count ? samples[rawIndex + 1] : nil

            var position = lastKnown
            if let current {
                if let next,
                   Double(next.timeMs) > Double(current.timeMs),
                   timeMs >= Double(current.timeMs),
                   Double(next.timeMs) - Double(current.timeMs) <= 500 {
                    let t = (timeMs - Double(current.timeMs)) / Double(next.timeMs - current.timeMs)
                    position = CGPoint(
                        x: current.x + (next.x - current.x) * t,
                        y: current.y + (next.y - current.y) * t
                    )
                } else if timeMs >= Double(current.timeMs) {
                    position = CGPoint(x: current.x, y: current.y)
                }
            }

            lastKnown = position

            let filteredX = oneEuro.filter(
                position.x,
                time: timeMs / 1000.0,
                minCutoff: minCutoff,
                beta: beta,
                derivativeCutoff: 1.0
            )
            let filteredY = oneEuroY.filter(
                position.y,
                time: timeMs / 1000.0,
                minCutoff: minCutoff,
                beta: beta,
                derivativeCutoff: 1.0
            )

            xs[frame] = filteredX
            ys[frame] = filteredY

            if settings.hideWhenIdleMs > 0 {
                visibility[frame] = Int(timeMs) - lastActivityMs <= settings.hideWhenIdleMs
            }
        }

        // Optional loop: ease the cursor back to its starting position at the tail.
        if settings.loopToStart, frameCount > 2, let first = xs.first, let firstY = ys.first {
            let tailFrames = min(frameCount, sampleRate / 2)
            for offset in 0..<tailFrames {
                let index = frameCount - tailFrames + offset
                let t = Double(offset) / Double(max(tailFrames - 1, 1))
                let eased = t * t * (3 - 2 * t)
                xs[index] = xs[index] + (first - xs[index]) * eased
                ys[index] = ys[index] + (firstY - ys[index]) * eased
            }
        }

        self.positions = zip(xs, ys).map { CGPoint(x: $0, y: $1) }
        self.visibility = visibility
    }

    public var isEmpty: Bool { positions.isEmpty }

    public func frame(at timeMs: Int) -> CursorFrame {
        guard !positions.isEmpty else { return .hidden }
        guard settings.visible else { return .hidden }

        let clamped = min(max(timeMs, 0), max(durationMs, 0))
        let exact = Double(clamped) / 1000.0 * Double(sampleRate)
        let lower = min(Int(exact), positions.count - 1)
        let upper = min(lower + 1, positions.count - 1)
        let fraction = exact - Double(lower)
        let position = CGPoint(
            x: positions[lower].x + (positions[upper].x - positions[lower].x) * fraction,
            y: positions[lower].y + (positions[upper].y - positions[lower].y) * fraction
        )

        var press: Double = 0
        var effect: CursorFrame.ClickEffectFrame?
        if let click = clickSamples.last(where: { $0.timeMs <= clamped && clamped - $0.timeMs < 450 }) {
            let elapsed = Double(clamped - click.timeMs)
            if elapsed < 180 {
                // Press reads as fully engaged on the click frame, then releases smoothly.
                let t = elapsed / 180
                press = 1 - (t * t * (3 - 2 * t))
            }
            effect = CursorFrame.ClickEffectFrame(
                position: CGPoint(x: click.x, y: click.y),
                progress: min(elapsed / 450.0, 1),
                interaction: click.interaction
            )
        }

        return CursorFrame(
            position: position,
            isVisible: visibility[lower],
            pressAmount: press,
            effect: effect
        )
    }
}
