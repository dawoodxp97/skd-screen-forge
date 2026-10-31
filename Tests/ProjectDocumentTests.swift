import Foundation
import Testing
@testable import ScreenForgeCore

@MainActor
@Suite("Project document")
struct ProjectDocumentTests {
    private func makeDocument(
        durationMs: Int = 10_000,
        transcript: TranscriptDocument? = nil
    ) -> ProjectDocument {
        let bundle = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenForgeDoc-\(UUID().uuidString).sforge", isDirectory: true)
        let project = ScreenForgeProject(
            source: SourceInfo(
                screenPath: "media/screen.mov",
                durationMs: durationMs,
                pixelWidth: 1920,
                pixelHeight: 1080
            )
        )
        return ProjectDocument(
            bundleURL: bundle,
            project: project,
            cursorSamples: [],
            compositor: nil,
            transcript: transcript
        )
    }

    private func cleanUp(_ document: ProjectDocument) {
        try? FileManager.default.removeItem(at: document.bundleURL)
    }

    @Test("Adding a zoom is undoable and redoable")
    func zoomUndo() {
        let document = makeDocument()
        defer { cleanUp(document) }

        let zoom = document.addZoomAtPlayhead(outputMs: 2_000)
        #expect(zoom != nil)
        #expect(document.project.timeline.zooms.count == 1)
        #expect(document.canUndo)
        #expect(document.selectedZoom?.scale == 1.8)

        document.undo()
        #expect(document.project.timeline.zooms.isEmpty)
        #expect(document.canRedo)

        document.redo()
        #expect(document.project.timeline.zooms.count == 1)
    }

    @Test("Trim helpers cut the head and tail")
    func trims() {
        let document = makeDocument()
        defer { cleanUp(document) }

        document.trimStart(atOutputMs: 1_000)
        #expect(document.project.timeline.trims.count == 1)
        #expect(document.map.outputDurationMs == 9_000)

        document.trimEnd(atOutputMs: 8_000)
        #expect(document.project.timeline.trims.count == 2)
        #expect(document.map.outputDurationMs == 8_000)
    }

    @Test("Annotations are added at the playhead and deleted with selection")
    func annotations() {
        let document = makeDocument()
        defer { cleanUp(document) }

        let text = document.addTextAnnotation(atOutputMs: 1_000, text: "Look here")
        #expect(text != nil)
        #expect(document.selectedAnnotationID == text?.id)
        #expect(document.project.timeline.annotations.first?.text == "Look here")

        document.deleteSelectedAnnotation()
        #expect(document.project.timeline.annotations.isEmpty)
        #expect(document.selectedAnnotationID == nil)
    }

    @Test("Filler removal rebuilds transcript trims and can be turned off")
    func fillerToggle() {
        let words = [
            TranscriptWord(text: "um", startMs: 500, endMs: 700),
            TranscriptWord(text: "hello", startMs: 900, endMs: 1_300),
            TranscriptWord(text: "world", startMs: 1_400, endMs: 1_800)
        ]
        let document = makeDocument(transcript: TranscriptDocument(words: words))
        defer { cleanUp(document) }

        document.setRemoveFillers(true)
        #expect(document.project.timeline.trims.count == 1)
        #expect(document.map.outputDurationMs < 10_000)

        document.setRemoveFillers(false)
        #expect(document.project.timeline.trims.isEmpty)
        #expect(document.map.outputDurationMs == 10_000)
    }

    @Test("Captions appear only when enabled and inside a cue")
    func captionRendering() {
        let words = [
            TranscriptWord(text: "Hello", startMs: 1_000, endMs: 1_400),
            TranscriptWord(text: "there", startMs: 1_450, endMs: 1_800)
        ]
        let document = makeDocument(transcript: TranscriptDocument(words: words))
        defer { cleanUp(document) }

        document.project.captions.enabled = false
        #expect(document.renderer.state(atOutputMs: 1_200, canvasSize: CGSize(width: 1920, height: 1080)).caption == nil)

        document.apply { $0.captions.enabled = true }
        let state = document.renderer.state(atOutputMs: 1_200, canvasSize: CGSize(width: 1920, height: 1080))
        #expect(state.caption?.text == "Hello there")

        // Caption cues come back in source time for the UI.
        #expect(document.captionCues.count == 1)
    }

    @Test("Saving writes the project bundle")
    func saveNow() async {
        let document = makeDocument()
        defer { cleanUp(document) }

        document.addTextAnnotation(atOutputMs: 1_000, text: "Saved")
        await document.saveNow()

        #expect(document.isDirty == false)
        #expect(FileManager.default.fileExists(
            atPath: document.bundleURL.appendingPathComponent("project.json").path
        ))
    }

    @Test("Export without Metal reports a clear error")
    func exportWithoutMetal() async {
        let document = makeDocument()
        defer { cleanUp(document) }

        await #expect(throws: ExportError.self) {
            _ = try await document.export(to: document.bundleURL, format: .mp4) { _ in }
        }
    }
}
