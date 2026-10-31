import CoreGraphics
import Foundation
import Testing
@testable import ScreenForge

@Suite("Cursor recorder")
struct CursorRecorderTests {
    @Test("Recording produces samples and a log without Accessibility permission")
    func recordsWithoutPermission() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenForgeCursor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let log = directory.appendingPathComponent("cursor.jsonl")
        let recorder = CursorRecorder()

        try recorder.start(
            configuration: CursorRecorder.Configuration(
                displayID: CGMainDisplayID(),
                sampleIntervalMs: 8,
                hideSystemCursor: false
            ),
            outputURL: log
        )

        // Give the poll timer a few ticks; the cursor does not need to move.
        try await Task.sleep(for: .milliseconds(300))
        let samples = recorder.stop()

        #expect(!samples.isEmpty, "polling produced no cursor samples")
        #expect(samples.allSatisfy { $0.x >= 0 && $0.x <= 1 && $0.y >= 0 && $0.y <= 1 })

        let data = try Data(contentsOf: log)
        #expect(!data.isEmpty)

        let decoded = try CursorJSONL.decode(data)
        #expect(decoded.count >= 1)
    }

    @Test("The first click after idle does not overflow the click sentinel")
    func firstClick() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenForgeCursor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let recorder = CursorRecorder()
        try recorder.start(
            configuration: CursorRecorder.Configuration(
                displayID: CGMainDisplayID(),
                sampleIntervalMs: 8,
                hideSystemCursor: false
            ),
            outputURL: directory.appendingPathComponent("cursor.jsonl")
        )

        // Previously `nowMs - Int.min` trapped here (crash report: CursorRecorder:223).
        recorder.poll(location: CGPoint(x: 420, y: 320), left: true, right: false, other: false)
        recorder.poll(location: CGPoint(x: 424, y: 322), left: false, right: false, other: false)

        let samples = recorder.stop()
        #expect(samples.contains { $0.interaction == .click })
        #expect(samples.count >= 2)
    }

    @Test("Samples are normalized inside the configured window bounds")
    func windowBounds() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenForgeCursor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let recorder = CursorRecorder()
        try recorder.start(
            configuration: CursorRecorder.Configuration(
                displayID: CGMainDisplayID(),
                sampleIntervalMs: 4,
                hideSystemCursor: false,
                normalizedBounds: CGRect(x: 0, y: 0, width: 4_000, height: 3_000)
            ),
            outputURL: directory.appendingPathComponent("cursor.jsonl")
        )
        try await Task.sleep(for: .milliseconds(250))
        let samples = recorder.stop()

        #expect(samples.allSatisfy { $0.x >= 0 && $0.x <= 1 && $0.y >= 0 && $0.y <= 1 })
    }
}
