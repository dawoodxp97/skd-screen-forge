import Foundation
import Testing
@testable import ScreenForgeCore

@Suite("Transcript editing")
struct TranscriptEditingTests {
    private func word(_ text: String, _ start: Int, _ end: Int) -> TranscriptWord {
        TranscriptWord(text: text, startMs: start, endMs: end)
    }

    private func sentence(_ tokens: [String], start: Int, spacing: Int = 180) -> [TranscriptWord] {
        var result: [TranscriptWord] = []
        var cursor = start
        for token in tokens {
            result.append(word(token, cursor, cursor + spacing / 2))
            cursor += spacing
        }
        return result
    }

    @Test("Standalone fillers become trims with handles")
    func fillerTrims() {
        let words = [
            word("So", 0, 200),
            word("um", 900, 1_100),
            word("today", 1_400, 1_800),
            word("we", 1_900, 2_050),
            word("ship", 2_100, 2_500)
        ]
        let editor = TranscriptEditor()
        let trims = editor.fillerTrims(in: words)

        #expect(trims.count == 1)
        let trim = try! #require(trims.first)
        #expect(trim.startMs <= 900)
        #expect(trim.endMs >= 1_100)
        // Handles never reach into the neighbouring words.
        #expect(trim.endMs < 1_400)
    }

    @Test("Weak fillers only go when they sit between pauses")
    func weakFiller() {
        let editor = TranscriptEditor()

        let filler = [
            word("I", 0, 150),
            word("like", 600, 800),
            word("this", 1_300, 1_600)
        ]
        #expect(editor.fillerTrims(in: filler).count == 1)

        // "like" used as a verb — no pauses around it.
        let verb = [
            word("I", 0, 200),
            word("like", 220, 500),
            word("this", 520, 800)
        ]
        #expect(editor.fillerTrims(in: verb).isEmpty)
    }

    @Test("Punctuation does not hide a filler")
    func punctuationNormalization() {
        let words = [
            word("Well,", 0, 200),
            word("uh…", 700, 900),
            word("okay.", 1_300, 1_700)
        ]
        let trims = TranscriptEditor().fillerTrims(in: words)
        #expect(trims.count == 1)
        #expect(trims[0].startMs < 900)
        #expect(trims[0].endMs > 900)
    }

    @Test("Long silences are compressed, short ones are kept")
    func pauseTrims() {
        let longGap = [
            word("first", 0, 400),
            word("second", 2_400, 2_800)
        ]
        let trims = TranscriptEditor().pauseTrims(in: longGap)
        let trim = try! #require(trims.first)
        #expect(trim.startMs == 520)
        #expect(trim.endMs == 2_280)

        let shortGap = [
            word("first", 0, 400),
            word("second", 900, 1_300)
        ]
        #expect(TranscriptEditor().pauseTrims(in: shortGap).isEmpty)
    }

    @Test("Overlapping cuts merge instead of stacking")
    func mergeRegions() {
        let merged = TranscriptEditor.merge([
            TrimRegion(startMs: 1_000, endMs: 2_000),
            TrimRegion(startMs: 1_800, endMs: 2_600),
            TrimRegion(startMs: 2_600, endMs: 3_000),
            TrimRegion(startMs: 5_000, endMs: 5_500)
        ])
        #expect(merged.count == 2)
        #expect(merged[0].startMs == 1_000)
        #expect(merged[0].endMs == 3_000)
        #expect(merged[1].startMs == 5_000)
    }

    @Test("A word range becomes one handled trim")
    func wordRange() {
        let words = sentence(["Hello", "there", "friend", "goodbye"], start: 1_000)
        let trim = try! #require(TranscriptEditor().trim(forWordRange: 1..<3, in: words))
        // Words are 90 ms long with 180 ms spacing: 1180…1270 and 1360…1450.
        #expect(trim.startMs == 1_180 - 80)
        #expect(trim.endMs == 1_450 + 80)
    }

    @Test("Deleting a sentence trims only that sentence")
    func deleteSentence() {
        let words = [
            word("Intro", 0, 300),
            word("this", 400, 600),
            word("is", 620, 700),
            word("cut.", 720, 900),
            word("Keep", 1_200, 1_500)
        ]
        var project = ScreenForgeProject(
            source: SourceInfo(
                screenPath: "media/screen.mov",
                durationMs: 4_000,
                pixelWidth: 1920,
                pixelHeight: 1080
            )
        )
        project.timeline.transcriptEdits = [
            TranscriptEdit(kind: .deleteSentence, startMs: 400, endMs: 900, text: "this is cut")
        ]

        let timeline = TranscriptEditor().apply(to: project, transcript: TranscriptDocument(words: words))
        #expect(timeline.trims.count == 1)
        #expect(timeline.trims[0].startMs == 320)
        #expect(timeline.trims[0].endMs == 980)
    }

    @Test("Re-applying transcript edits replaces generated trims")
    func idempotentApply() {
        var project = ScreenForgeProject(
            source: SourceInfo(
                screenPath: "media/screen.mov",
                durationMs: 4_000,
                pixelWidth: 1920,
                pixelHeight: 1080
            )
        )
        project.timeline.trims = [TrimRegion(startMs: 3_000, endMs: 3_500)]
        project.timeline.transcriptEdits = [TranscriptEdit(kind: .removeFiller, startMs: 0, endMs: 4_000)]

        let words = [
            word("um", 500, 700),
            word("hello", 900, 1_200)
        ]
        let transcript = TranscriptDocument(words: words)
        let editor = TranscriptEditor()

        let first = editor.apply(to: project, transcript: transcript)
        let second = editor.apply(to: project, transcript: transcript)

        #expect(first.trims.count == 2)
        #expect(second.trims.count == 2)
        #expect(second.trims.contains { $0.startMs == 3_000 })
        #expect(second.trims.contains { $0.id.hasPrefix(TranscriptEditor.generatedPrefix) })
    }
}

@Suite("Caption layout")
struct CaptionLayoutTests {
    private func words(_ tokens: [String], start: Int = 0, spacing: Int = 250) -> [TranscriptWord] {
        var result: [TranscriptWord] = []
        var cursor = start
        for token in tokens {
            result.append(TranscriptWord(text: token, startMs: cursor, endMs: cursor + 180))
            cursor += spacing
        }
        return result
    }

    @Test("Lines respect the word budget")
    func wordBudget() {
        let tokens = (0..<12).map { "word\($0)" }
        let cues = CaptionLayoutBuilder.cues(
            from: words(tokens),
            options: .init(wordsPerLine: 4, maximumCharacters: 200)
        )
        #expect(cues.count == 3)
        #expect(cues.allSatisfy { $0.wordTimings.count <= 4 })
        #expect(cues[0].text.hasPrefix("word0"))
        #expect(cues[0].startMs == 0)
    }

    @Test("A long pause starts a new line")
    func pauseBreak() {
        var input = words(["one", "two"], start: 0, spacing: 200)
        input.append(TranscriptWord(text: "three", startMs: 3_000, endMs: 3_200))

        let cues = CaptionLayoutBuilder.cues(from: input, options: .init(wordsPerLine: 8))
        #expect(cues.count == 2)
        #expect(cues[1].text == "three")
        #expect(cues[0].endMs <= cues[1].startMs)
    }

    @Test("Sentence punctuation ends a cue")
    func sentenceBreak() {
        let cues = CaptionLayoutBuilder.cues(
            from: words(["Hello.", "Next", "one"]),
            options: .init(wordsPerLine: 8, maximumCharacters: 200)
        )
        #expect(cues.count == 2)
        #expect(cues[0].text == "Hello.")
    }

    @Test("Character budget splits long words")
    func characterBudget() {
        let cues = CaptionLayoutBuilder.cues(
            from: words(["supercalifragilistic", "expialidocious", "and", "more"]),
            options: .init(wordsPerLine: 8, maximumCharacters: 12)
        )
        #expect(cues.count > 1)
        #expect(cues.allSatisfy { $0.text.count <= 30 })
    }

    @Test("Cue timings cover every word")
    func timings() {
        let input = words(["alpha", "beta", "gamma"])
        let cue = try! #require(CaptionLayoutBuilder.cues(from: input).first)
        #expect(cue.startMs <= input[0].startMs)
        #expect(cue.endMs >= input[2].endMs)
        #expect(cue.wordTimings.count == 3)
        #expect(cue.wordTimings[1].startMs == input[1].startMs)
    }

    @Test("Empty transcript yields no cues")
    func empty() {
        #expect(CaptionLayoutBuilder.cues(from: []).isEmpty)
    }
}
