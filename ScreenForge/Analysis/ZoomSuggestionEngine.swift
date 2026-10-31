import CoreGraphics
import Foundation

/// Turns raw cursor telemetry into zoom suggestions.
///
/// Heuristics:
/// 1. Clicks are the strongest signal — zoom where the user acted.
/// 2. Dwells (cursor nearly stationary for a while) indicate reading/attention.
/// 3. Long movement bursts fall back to activity clusters when there are no clicks.
/// 4. Nearby candidates merge so a burst of clicks yields one calm zoom, not five.
/// 5. Regions never overlap existing/previous suggestions; the result is deterministic.
public struct ZoomSuggestionEngine: Sendable {
    public struct Options: Sendable, Equatable {
        public var minimumDurationMs: Int = 1_400
        public var maximumDurationMs: Int = 6_500
        public var preRollMs: Int = 350
        public var postRollMs: Int = 900
        public var mergeGapMs: Int = 1_200
        /// Normalized distance under which two candidates merge.
        public var mergeDistance: Double = 0.24
        public var minimumScale: Double = 1.35
        public var maximumScale: Double = 2.4
        /// Extra room around the cluster before solving the scale.
        public var focusPadding: Double = 0.08
        public var detectDwells: Bool = true
        public var dwellMinimumMs: Int = 500
        /// Max normalized movement for a window to count as a dwell.
        public var dwellTolerance: Double = 0.02
        public var detectScrolls: Bool = true
        /// When there are no clicks/dwells, cluster movement into activity windows.
        public var fallbackToActivityClusters: Bool = true
        public var activityGapMs: Int = 2_000
        public var maximumRegions: Int = 200

        public init() {}

        public static let `default` = Options()
    }

    public var options: Options

    public init(options: Options = .default) {
        self.options = options
    }

    // MARK: - Public API

    public func suggest(
        samples: [CursorSample],
        durationMs: Int,
        existingRegions: [ZoomRegion] = []
    ) -> [ZoomRegion] {
        guard durationMs > 0, samples.count >= 2 else { return [] }

        let sorted = samples.sorted { $0.timeMs < $1.timeMs }
        var candidates = clickCandidates(in: sorted)
        if options.detectDwells {
            candidates.append(contentsOf: dwellCandidates(in: sorted))
        }
        if options.detectScrolls {
            candidates.append(contentsOf: scrollCandidates(in: sorted))
        }
        if candidates.isEmpty, options.fallbackToActivityClusters {
            candidates = activityClusterCandidates(in: sorted)
        }
        guard !candidates.isEmpty else { return [] }

        let merged = merge(candidates)
        var accepted: [ZoomRegion] = existingRegions.sorted { $0.startMs < $1.startMs }
        var generated: [ZoomRegion] = []

        for candidate in merged {
            guard generated.count < options.maximumRegions else { break }

            // A click or dwell already covered by an accepted zoom needs no new region.
            let candidateMid = (candidate.startMs + candidate.endMs) / 2
            if accepted.contains(where: { candidateMid >= $0.startMs && candidateMid <= $0.endMs }) {
                continue
            }

            guard let region = makeRegion(from: candidate, durationMs: durationMs) else { continue }
            if let resolved = resolveOverlap(region, accepted: accepted, durationMs: durationMs) {
                accepted.append(resolved)
                accepted.sort { $0.startMs < $1.startMs }
                generated.append(resolved)
            }
        }

        return generated.sorted { $0.startMs < $1.startMs }
    }

    // MARK: - Candidates

    private struct Candidate {
        var startMs: Int
        var endMs: Int
        var center: CGPoint
        var weight: Double
        var spread: Double
    }

    private func clickCandidates(in samples: [CursorSample]) -> [Candidate] {
        samples
            .filter { $0.interaction == .click || $0.interaction == .doubleClick ||
                      $0.interaction == .rightClick || $0.interaction == .middleClick }
            .map { sample in
                Candidate(
                    startMs: sample.timeMs,
                    endMs: sample.timeMs,
                    center: CGPoint(x: sample.x, y: sample.y),
                    weight: sample.interaction == .doubleClick ? 4 : 3,
                    spread: 0
                )
            }
    }

    private func scrollCandidates(in samples: [CursorSample]) -> [Candidate] {
        samples
            .filter { $0.interaction == .scroll }
            .map { sample in
                Candidate(
                    startMs: sample.timeMs,
                    endMs: sample.timeMs,
                    center: CGPoint(x: sample.x, y: sample.y),
                    weight: 2,
                    spread: 0
                )
            }
    }

    private func dwellCandidates(in samples: [CursorSample]) -> [Candidate] {
        var result: [Candidate] = []
        var windowStart = 0

        for index in 0..<samples.count {
            let start = samples[windowStart]
            let current = samples[index]
            let elapsed = current.timeMs - start.timeMs
            let distance = hypot(current.x - start.x, current.y - start.y)

            if distance > options.dwellTolerance {
                windowStart = index
                continue
            }
            if elapsed >= options.dwellMinimumMs {
                let slice = samples[windowStart...index]
                let center = CGPoint(
                    x: slice.reduce(0.0) { $0 + $1.x } / Double(slice.count),
                    y: slice.reduce(0.0) { $0 + $1.y } / Double(slice.count)
                )
                let spread = slice.reduce(0.0) { partial, sample in
                    max(partial, hypot(sample.x - center.x, sample.y - center.y))
                }
                result.append(Candidate(
                    startMs: start.timeMs,
                    endMs: current.timeMs,
                    center: center,
                    weight: 1.2 + Double(elapsed) / 1_000.0,
                    spread: spread
                ))
                windowStart = index
            }
        }

        // Merge overlapping dwell windows (a dwell split by tiny movement).
        return merge(result)
    }

    private func activityClusterCandidates(in samples: [CursorSample]) -> [Candidate] {
        guard let first = samples.first else { return [] }
        var clusters: [Candidate] = []
        var clusterStart = first.timeMs
        var lastTime = first.timeMs
        var points: [CursorSample] = [first]

        func flush() {
            guard points.count >= 3, lastTime - clusterStart >= 250 else { return }
            let center = CGPoint(
                x: points.reduce(0.0) { $0 + $1.x } / Double(points.count),
                y: points.reduce(0.0) { $0 + $1.y } / Double(points.count)
            )
            let spread = points.reduce(0.0) { partial, sample in
                max(partial, hypot(sample.x - center.x, sample.y - center.y))
            }
            clusters.append(Candidate(
                startMs: clusterStart,
                endMs: lastTime,
                center: center,
                weight: Double(lastTime - clusterStart) / 1_000.0,
                spread: spread
            ))
        }

        for sample in samples.dropFirst() {
            if sample.timeMs - lastTime > options.activityGapMs {
                flush()
                points = [sample]
                clusterStart = sample.timeMs
            } else {
                points.append(sample)
            }
            lastTime = sample.timeMs
        }
        flush()
        return clusters
    }

    // MARK: - Merging

    private func merge(_ candidates: [Candidate]) -> [Candidate] {
        guard !candidates.isEmpty else { return [] }
        let sorted = candidates.sorted {
            $0.startMs == $1.startMs ? $0.weight > $1.weight : $0.startMs < $1.startMs
        }
        var result: [Candidate] = []

        for candidate in sorted {
            if var last = result.last {
                let gap = candidate.startMs - last.endMs
                let distance = hypot(candidate.center.x - last.center.x, candidate.center.y - last.center.y)
                if gap <= options.mergeGapMs && distance <= options.mergeDistance {
                    let totalWeight = last.weight + candidate.weight
                    last.center = CGPoint(
                        x: (last.center.x * last.weight + candidate.center.x * candidate.weight) / totalWeight,
                        y: (last.center.y * last.weight + candidate.center.y * candidate.weight) / totalWeight
                    )
                    last.endMs = max(last.endMs, candidate.endMs)
                    last.weight = totalWeight
                    last.spread = max(last.spread, distance + candidate.spread)
                    result[result.count - 1] = last
                    continue
                }
            }
            result.append(candidate)
        }
        return result
    }

    // MARK: - Region construction

    private func makeRegion(from candidate: Candidate, durationMs: Int) -> ZoomRegion? {
        var start = candidate.startMs - options.preRollMs
        var end = candidate.endMs + options.postRollMs

        // Extend sparse candidates (a single click) to the minimum duration.
        let minimum = options.minimumDurationMs
        if end - start < minimum {
            let deficit = minimum - (end - start)
            start -= deficit / 2
            end += deficit - deficit / 2
        }
        if end - start > options.maximumDurationMs {
            let center = (candidate.startMs + candidate.endMs) / 2
            start = center - options.maximumDurationMs / 2
            end = center + options.maximumDurationMs / 2
        }

        start = max(0, start)
        end = min(durationMs, end)
        guard end - start >= 600 else { return nil }

        let focus = CGPoint(
            x: min(max(candidate.center.x, 0.02), 0.98),
            y: min(max(candidate.center.y, 0.02), 0.98)
        )
        let spread = max(candidate.spread + options.focusPadding, 0.08)
        let solved = 0.5 / spread
        let scale = (min(max(solved, options.minimumScale), options.maximumScale) * 20).rounded() / 20

        return ZoomRegion(
            startMs: start,
            endMs: end,
            scale: scale,
            focus: ZoomFocus(x: focus.x, y: focus.y),
            kind: .classic,
            easing: .screenStudio,
            source: .auto,
            generated: true
        )
    }

    private func resolveOverlap(
        _ region: ZoomRegion,
        accepted: [ZoomRegion],
        durationMs: Int
    ) -> ZoomRegion? {
        var candidate = region
        let padding = 150

        for existing in accepted where candidate.startMs < existing.endMs + padding &&
                                        candidate.endMs > existing.startMs - padding {
            // Try to slide right of the existing region first.
            let shiftedStart = existing.endMs + padding
            let shiftedEnd = shiftedStart + candidate.durationMs
            if shiftedEnd <= durationMs - 300 {
                candidate.startMs = shiftedStart
                candidate.endMs = shiftedEnd
                continue
            }
            // Otherwise truncate on the left if enough remains.
            let newEnd = existing.startMs - padding
            if newEnd - candidate.startMs >= 800 {
                candidate.endMs = newEnd
                continue
            }
            return nil
        }
        return candidate
    }
}
