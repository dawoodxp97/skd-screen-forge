import Foundation
import Testing
@testable import ScreenForgeCore

@Suite("Timeline mapping")
struct TimelineMapTests {
    @Test("Identity mapping without trims or speeds")
    func identity() {
        let map = TimelineMap.build(trims: [], speeds: [], sourceDurationMs: 10_000)
        #expect(map.outputDurationMs == 10_000)
        #expect(map.sourceTime(forOutputMs: 4_000) == 4_000)
        #expect(map.outputTime(forSourceMs: 7_500) == 7_500)
    }

    @Test("Trims collapse output time and map back to source")
    func trim() {
        let trims = [TrimRegion(startMs: 2_000, endMs: 4_000)]
        let map = TimelineMap.build(trims: trims, speeds: [], sourceDurationMs: 10_000)

        #expect(map.outputDurationMs == 8_000)
        #expect(map.sourceTime(forOutputMs: 0) == 0)
        #expect(map.sourceTime(forOutputMs: 2_000) == 4_000)
        #expect(map.sourceTime(forOutputMs: 5_000) == 7_000)
        #expect(map.outputTime(forSourceMs: 3_000) == nil)
        #expect(map.outputTime(forSourceMs: 5_000) == 3_000)
    }

    @Test("Speed regions compress and expand output time")
    func speed() {
        let speeds = [SpeedRegion(startMs: 2_000, endMs: 6_000, rate: 2)]
        let map = TimelineMap.build(trims: [], speeds: speeds, sourceDurationMs: 10_000)

        // 2s normal + 4s at 2x + 4s normal = 8s
        #expect(map.outputDurationMs == 8_000)
        #expect(map.outputTime(forSourceMs: 4_000) == 3_000)
        #expect(map.sourceTime(forOutputMs: 3_000) == 4_000)
        #expect(map.sourceTime(forOutputMs: 6_000) == 8_000)
    }

    @Test("Trim and speed regions compose")
    func trimAndSpeed() {
        let trims = [TrimRegion(startMs: 1_000, endMs: 2_000)]
        let speeds = [SpeedRegion(startMs: 3_000, endMs: 5_000, rate: 2)]
        let map = TimelineMap.build(trims: trims, speeds: speeds, sourceDurationMs: 9_000)

        // 1s + (3s normal) + (2s @2x = 1s) + (4s normal) = 9 - 1 - 1 = 7s
        #expect(abs(map.outputDurationMs - 7_000) < 0.001)
        #expect(map.sourceTime(forOutputMs: 0) == 0)
        #expect(map.outputTime(forSourceMs: 1_500) == nil)
        #expect(map.sourceTime(forOutputMs: 1_000) == 2_000)
    }

    @Test("Segments intersecting an output range are clamped correctly")
    func rangeSegments() {
        let trims = [TrimRegion(startMs: 1_000, endMs: 2_000)]
        let map = TimelineMap.build(trims: trims, speeds: [], sourceDurationMs: 4_000)
        let segments = map.segments(forOutputRange: 500..<2_500)
        #expect(!segments.isEmpty)
        let covered = segments.reduce(0.0) { $0 + ($1.outputEndMs - $1.outputStartMs) }
        #expect(abs(covered - 2_000) < 0.001)
        #expect(map.sourceTime(forOutputMs: 2_500) == 3_500)
    }

    @Test("Segment boundaries resolve to the post-cut frame")
    func cutBoundary() {
        let trims = [TrimRegion(startMs: 2_000, endMs: 4_000)]
        let map = TimelineMap.build(trims: trims, speeds: [], sourceDurationMs: 10_000)

        // The cut instant shows the frame that follows the cut, not the one before it.
        #expect(map.sourceTime(forOutputMs: 1_999.9) == 1_999.9)
        #expect(map.sourceTime(forOutputMs: 2_000) == 4_000)
        #expect(map.sourceTime(forOutputMs: 2_000.1) == 4_000.1)
        #expect(map.sourceTime(forOutputMs: 8_000) == 10_000)
    }
}

@Suite("Zoom suggestions")
struct ZoomSuggestionTests {
    private func click(_ time: Int, _ x: Double, _ y: Double) -> CursorSample {
        CursorSample(timeMs: time, x: x, y: y, interaction: .click)
    }

    @Test("Nearby clicks merge into one zoom")
    func nearbyClicksMerge() {
        let engine = ZoomSuggestionEngine()
        let samples = [
            click(10_000, 0.42, 0.55),
            click(10_400, 0.44, 0.56),
            click(10_900, 0.43, 0.54)
        ]
        let regions = engine.suggest(samples: samples, durationMs: 30_000)
        #expect(regions.count == 1)
        #expect(regions[0].startMs <= 10_000)
        #expect(regions[0].endMs >= 10_900)
        #expect(regions[0].durationMs >= 1_400)
        #expect((1.3...2.5).contains(regions[0].scale))
    }

    @Test("Distant clicks produce separate, non-overlapping zooms")
    func distantClicks() {
        let engine = ZoomSuggestionEngine()
        let samples = [
            click(5_000, 0.15, 0.2),
            click(20_000, 0.85, 0.75)
        ]
        let regions = engine.suggest(samples: samples, durationMs: 30_000)
        #expect(regions.count == 2)
        #expect(regions[0].endMs <= regions[1].startMs)
    }

    @Test("Dwell is detected when the cursor stays still")
    func dwell() {
        var samples: [CursorSample] = []
        for t in stride(from: 3_000, through: 4_200, by: 60) {
            samples.append(CursorSample(timeMs: t, x: 0.5, y: 0.5))
        }
        let engine = ZoomSuggestionEngine()
        let regions = engine.suggest(samples: samples, durationMs: 20_000)
        #expect(regions.count == 1)
        #expect(regions[0].startMs <= 3_000)
        #expect(regions[0].endMs >= 4_200)
    }

    @Test("Existing zoom regions are avoided")
    func avoidsExisting() {
        let existing = [
            ZoomRegion(startMs: 0, endMs: 15_000, scale: 2)
        ]
        let samples = [click(5_000, 0.2, 0.2), click(18_000, 0.8, 0.8)]
        let engine = ZoomSuggestionEngine()
        let regions = engine.suggest(samples: samples, durationMs: 30_000, existingRegions: existing)
        #expect(regions.count == 1)
        #expect(regions[0].startMs >= 15_000)
    }

    @Test("No samples means no suggestions")
    func empty() {
        let engine = ZoomSuggestionEngine()
        #expect(engine.suggest(samples: [], durationMs: 10_000).isEmpty)
    }
}

@Suite("Cursor telemetry")
struct CursorTelemetryTests {
    @Test("JSONL round trips")
    func jsonlRoundTrip() throws {
        let samples = [
            CursorSample(timeMs: 0, x: 0.1, y: 0.2),
            CursorSample(timeMs: 120, x: 0.15, y: 0.25, interaction: .click),
            CursorSample(timeMs: 240, x: 0.2, y: 0.3, interaction: .scroll)
        ]
        let data = try CursorJSONL.encode(samples)
        let decoded = try CursorJSONL.decode(data)
        #expect(decoded == samples)
    }

    @Test("Track follows samples and reports click effects")
    func trackEvaluation() {
        let settings = CursorSettings(visible: true, smoothing: 0, hideWhenIdleMs: 0)
        let samples = [
            CursorSample(timeMs: 0, x: 0.2, y: 0.2),
            CursorSample(timeMs: 500, x: 0.8, y: 0.8, interaction: .click),
            CursorSample(timeMs: 1_000, x: 0.8, y: 0.8)
        ]
        let track = CursorTrack(samples: samples, settings: settings, durationMs: 2_000)
        let frame = track.frame(at: 500)
        #expect(abs(frame.position.x - 0.8) < 0.1)
        #expect(frame.effect != nil)
        #expect(frame.pressAmount > 0)
    }

    @Test("Idle-hide hides a motionless cursor")
    func idleHide() {
        let settings = CursorSettings(visible: true, smoothing: 0, hideWhenIdleMs: 500)
        let samples = [CursorSample(timeMs: 0, x: 0.5, y: 0.5)]
        let track = CursorTrack(samples: samples, settings: settings, durationMs: 3_000)
        #expect(track.frame(at: 0).isVisible)
        #expect(!track.frame(at: 2_500).isVisible)
    }

    @Test("Invisible setting wins over telemetry")
    func invisible() {
        let settings = CursorSettings(visible: false)
        let track = CursorTrack(
            samples: [CursorSample(timeMs: 0, x: 0.5, y: 0.5)],
            settings: settings,
            durationMs: 1_000
        )
        #expect(!track.frame(at: 500).isVisible)
    }
}

@Suite("Project codec")
struct ProjectCodecTests {
    private func sampleProject() -> ScreenForgeProject {
        ScreenForgeProject(
            source: SourceInfo(
                screenPath: "media/screen.mov",
                durationMs: 12_000,
                pixelWidth: 3024,
                pixelHeight: 1964
            ),
            timeline: Timeline(
                zooms: [ZoomRegion(startMs: 1_000, endMs: 4_000, scale: 2.0)],
                trims: [TrimRegion(startMs: 8_000, endMs: 9_000)]
            )
        )
    }

    @Test("Round trips with normalized values")
    func roundTrip() throws {
        let project = sampleProject()
        let data = try ProjectCodec.encode(project)
        let decoded = try ProjectCodec.decode(data)
        #expect(decoded.id == project.id)
        #expect(decoded.timeline.zooms.count == 1)
        #expect(decoded.timeline.trims.count == 1)
        #expect(decoded.source.durationMs == 12_000)
    }

    @Test("Rejects a future schema")
    func futureSchema() throws {
        let project = sampleProject()
        var data = try ProjectCodec.encode(project)
        let text = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\"schemaVersion\" : 1", with: "\"schemaVersion\" : 99")
        data = Data(text.utf8)
        #expect(throws: ProjectError.self) {
            _ = try ProjectCodec.decode(data)
        }
    }
}
