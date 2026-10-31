import Foundation
import Testing
@testable import ScreenForgeCore

@Suite("Project store")
struct ProjectStoreTests {
    private func makeProject() -> ScreenForgeProject {
        ScreenForgeProject(
            source: SourceInfo(
                screenPath: "media/screen.mov",
                durationMs: 8_000,
                pixelWidth: 2560,
                pixelHeight: 1440
            ),
            timeline: Timeline(
                zooms: [ZoomRegion(startMs: 500, endMs: 2_500, scale: 2)],
                trims: [TrimRegion(startMs: 6_000, endMs: 7_000)]
            )
        )
    }

    private func temporaryBundle() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenForgeTests-\(UUID().uuidString).sforge", isDirectory: true)
    }

    @Test("Saving creates the bundle skeleton and round trips the project")
    func roundTrip() async throws {
        let bundle = temporaryBundle()
        defer { try? FileManager.default.removeItem(at: bundle) }

        let store = ProjectStore()
        let project = makeProject()
        try await store.save(project, to: bundle)

        #expect(FileManager.default.fileExists(atPath: bundle.appendingPathComponent("project.json").path))
        #expect(FileManager.default.fileExists(
            atPath: bundle.appendingPathComponent("media", isDirectory: true).path
        ))

        let loaded = try await store.load(from: bundle)
        #expect(loaded.id == project.id)
        #expect(loaded.timeline.zooms.count == 1)
        #expect(loaded.timeline.trims.count == 1)
        // Save stamps `updatedAt` with the write time; tolerate millisecond truncation.
        #expect(abs(loaded.updatedAt.timeIntervalSinceNow) < 5)
        #expect(loaded.createdAt.timeIntervalSince(project.createdAt) < 0.01)
    }

    @Test("Missing project.json is reported, not silently created")
    func missingBundle() async throws {
        let bundle = temporaryBundle()
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundle) }

        let store = ProjectStore()
        await #expect(throws: ProjectError.self) {
            _ = try await store.load(from: bundle)
        }
    }

    @Test("Cursor telemetry round trips through the bundle")
    func cursorRoundTrip() async throws {
        let bundle = temporaryBundle()
        defer { try? FileManager.default.removeItem(at: bundle) }

        let store = ProjectStore()
        try await store.save(makeProject(), to: bundle)
        let samples = [
            CursorSample(timeMs: 0, x: 0.1, y: 0.1),
            CursorSample(timeMs: 400, x: 0.4, y: 0.2, interaction: .click)
        ]
        try await store.writeCursor(samples, to: bundle)

        let loaded = try await store.loadCursor(from: bundle)
        #expect(loaded == samples)
    }

    @Test("Transcript round trips and is optional")
    func transcriptRoundTrip() async throws {
        let bundle = temporaryBundle()
        defer { try? FileManager.default.removeItem(at: bundle) }

        let store = ProjectStore()
        try await store.save(makeProject(), to: bundle)

        let missing = try await store.loadTranscript(from: bundle)
        #expect(missing == nil)

        let transcript = TranscriptDocument(
            words: [
                TranscriptWord(text: "hello", startMs: 0, endMs: 300),
                TranscriptWord(text: "world", startMs: 400, endMs: 700)
            ]
        )
        try await store.writeTranscript(transcript, to: bundle)

        let loaded = try await store.loadTranscript(from: bundle)
        #expect(loaded?.plainText == "hello world")
        #expect(loaded?.words.count == 2)
    }

    @Test("Missing media is detected before playback or export")
    func verifyMedia() async throws {
        let bundle = temporaryBundle()
        defer { try? FileManager.default.removeItem(at: bundle) }

        let store = ProjectStore()
        let project = makeProject()
        try await store.save(project, to: bundle)

        await #expect(throws: ProjectError.self) {
            try await store.verifyMedia(of: project, in: bundle)
        }

        let mediaURL = bundle.appendingPathComponent(project.source.screenPath)
        try FileManager.default.createDirectory(
            at: mediaURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        #expect(FileManager.default.createFile(atPath: mediaURL.path, contents: Data()))

        try await store.verifyMedia(of: project, in: bundle)
    }
}
