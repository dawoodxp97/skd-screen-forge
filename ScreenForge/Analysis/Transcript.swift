import Foundation

// MARK: - Model

/// One recognized word with timings. Times are in source (media) milliseconds.
public struct TranscriptWord: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var text: String
    public var startMs: Int
    public var endMs: Int
    /// 0...1 recognizer confidence, when available.
    public var confidence: Double

    public init(
        id: String = UUID().uuidString,
        text: String,
        startMs: Int,
        endMs: Int,
        confidence: Double = 1
    ) {
        self.id = id
        self.text = text
        self.startMs = startMs
        self.endMs = endMs
        self.confidence = confidence
    }

    public var durationMs: Int { max(0, endMs - startMs) }
}

/// The transcript stored beside a project (`transcript.json`).
///
/// Words are the source of truth; captions and transcript cuts are both derived.
/// Re-running recognition replaces the words but keeps `TranscriptEdit` history in
/// the project so intent survives a re-transcription.
public struct TranscriptDocument: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    public var language: String
    public var engine: String
    public var createdAt: Date
    public var words: [TranscriptWord]

    public init(
        version: Int = TranscriptDocument.currentVersion,
        language: String = Locale.current.identifier,
        engine: String = "SFSpeechRecognizer",
        createdAt: Date = Date(),
        words: [TranscriptWord]
    ) {
        self.version = version
        self.language = language
        self.engine = engine
        self.createdAt = createdAt
        self.words = words
    }

    public var isEmpty: Bool { words.isEmpty }

    public var durationMs: Int {
        guard let first = words.first, let last = words.last else { return 0 }
        return max(0, last.endMs - first.startMs)
    }

    /// Full text, one space between tokens.
    public var plainText: String {
        words.map(\.text).joined(separator: " ")
    }
}

// MARK: - Editing

/// Turns transcript intents into timeline trims.
///
/// Every cut keeps handles on both sides so consonants are not clipped, and adjacent
/// or overlapping cuts are merged so the timeline never carries redundant regions.
public struct TranscriptEditor: Sendable {
    public struct Options: Sendable, Equatable {
        /// Audio kept on each side of a cut to avoid clipped phonemes.
        public var handleMs: Int = 80
        /// A gap at least this long becomes a removable pause.
        public var minimumPauseMs: Int = 700
        /// Audio kept around a compressed pause.
        public var pausePaddingMs: Int = 120
        /// Pauses shorter than this after trimming are not worth a cut.
        public var minimumCutMs: Int = 120
        /// Fillers that are removed whenever they stand alone.
        public var strongFillers: Set<String> = [
            "um", "umm", "uh", "uhm", "erm", "er", "ah", "eh", "hmm", "mm", "mhm"
        ]
        /// Words that are only fillers when they are surrounded by pauses.
        public var weakFillers: Set<String> = [
            "like", "so", "right", "well", "basically", "actually", "literally"
        ]
        /// Minimum silence around a weak filler for it to be treated as filler.
        public var weakFillerPauseMs: Int = 150

        public init() {}

        public static let `default` = Options()
    }

    public var options: Options

    public init(options: Options = .default) {
        self.options = options
    }

    // MARK: Whole-word cuts

    /// Trims for every filler word in `words`, with handles.
    public func fillerTrims(in words: [TranscriptWord]) -> [TrimRegion] {
        guard !words.isEmpty else { return [] }
        var regions: [TrimRegion] = []

        for (index, word) in words.enumerated() {
            let token = Self.normalize(word.text)
            guard !token.isEmpty else { continue }

            let previous = index > 0 ? words[index - 1] : nil
            let next = index + 1 < words.count ? words[index + 1] : nil
            let leadingGap = previous.map { word.startMs - $0.endMs } ?? Int.max
            let trailingGap = next.map { $0.startMs - word.endMs } ?? Int.max

            let isStrong = options.strongFillers.contains(token)
            // A weak filler ("like", "so") is only a filler when it sits between two
            // real pauses. At an utterance edge we cannot tell, so we leave it alone.
            let isWeak = options.weakFillers.contains(token) &&
                previous != nil && next != nil &&
                leadingGap >= options.weakFillerPauseMs &&
                trailingGap >= options.weakFillerPauseMs
            guard isStrong || isWeak else { continue }

            // Never consume a whole phrase: respect the pause boundaries when present.
            let start = word.startMs - min(options.handleMs, max(leadingGap, 0) / 2)
            let end = word.endMs + min(options.handleMs, max(trailingGap, 0) / 2)
            guard end - start >= 40 else { continue }
            regions.append(TrimRegion(startMs: max(start, 0), endMs: end))
        }

        return Self.merge(regions)
    }

    /// Trims for long silences between words.
    public func pauseTrims(in words: [TranscriptWord]) -> [TrimRegion] {
        guard words.count > 1 else { return [] }
        var regions: [TrimRegion] = []

        for (current, next) in zip(words, words.dropFirst()) {
            let gap = next.startMs - current.endMs
            guard gap >= options.minimumPauseMs else { continue }

            let start = current.endMs + options.pausePaddingMs
            let end = next.startMs - options.pausePaddingMs
            guard end - start >= options.minimumCutMs else { continue }
            regions.append(TrimRegion(startMs: start, endMs: end))
        }

        return Self.merge(regions)
    }

    /// Trims for an explicit word range (a sentence or a selection from the UI).
    public func trim(forWordRange range: Range<Int>, in words: [TranscriptWord]) -> TrimRegion? {
        guard !range.isEmpty,
              range.lowerBound >= 0,
              range.upperBound <= words.count else {
            return nil
        }
        let slice = words[range]
        guard let first = slice.first, let last = slice.last else { return nil }

        let start = first.startMs - options.handleMs
        let end = last.endMs + options.handleMs
        guard end > start else { return nil }
        return TrimRegion(startMs: max(start, 0), endMs: end)
    }

    /// Source ranges for a free-text selection mapped back onto the transcript.
    public func trim(forTextSelection selection: String, in words: [TranscriptWord]) -> TrimRegion? {
        let target = Self.normalize(selection)
        guard !target.isEmpty else { return nil }

        var matchedStart: Int?
        var matchedEnd: Int?
        for (index, word) in words.enumerated() {
            let token = Self.normalize(word.text)
            guard !token.isEmpty else { continue }
            if matchedStart == nil, target.contains(token) {
                matchedStart = index
            }
            if let start = matchedStart, index >= start, target.contains(token) {
                matchedEnd = index
            }
        }

        guard let start = matchedStart, let end = matchedEnd else { return nil }
        return trim(forWordRange: start..<(end + 1), in: words)
    }

    // MARK: Project edits

    /// Applies every transcript edit recorded in the project and returns the new
    /// timeline. Existing manual trims are preserved; transcript trims are rebuilt
    /// from intent, so re-transcription does not leave stale cuts behind.
    public func apply(to project: ScreenForgeProject, transcript: TranscriptDocument) -> Timeline {
        var timeline = project.timeline
        timeline.trims.removeAll { $0.id.hasPrefix(Self.generatedPrefix) }

        let words = transcript.words
        var generated: [TrimRegion] = []

        for edit in timeline.transcriptEdits {
            switch edit.kind {
            case .removeFiller, .removePause:
                // Rebuilt from the current words below; the marker only enables them.
                continue
            case .deleteSentence:
                generated.append(contentsOf: deleteSentenceRegions(edit: edit, words: words))
            case .deleteRange:
                if let region = deleteRangeRegion(edit: edit, words: words) {
                    generated.append(region)
                }
            }
        }

        if timeline.transcriptEdits.contains(where: { $0.kind == .removeFiller }) {
            generated.append(contentsOf: fillerTrims(in: words))
        }
        if timeline.transcriptEdits.contains(where: { $0.kind == .removePause }) {
            generated.append(contentsOf: pauseTrims(in: words))
        }

        let merged = Self.merge(generated).map { region -> TrimRegion in
            var tagged = region
            tagged.id = Self.generatedPrefix + region.id
            return tagged
        }

        timeline.trims = Self.mergePreservingIDs(timeline.trims + merged)
        return timeline
    }

    public static let generatedPrefix = "transcript:"

    // MARK: Private

    private func deleteRangeRegion(edit: TranscriptEdit, words: [TranscriptWord]) -> TrimRegion? {
        guard edit.endMs > edit.startMs else { return nil }
        let start = edit.startMs - options.handleMs
        let end = edit.endMs + options.handleMs
        guard end - start >= options.minimumCutMs else { return nil }
        return TrimRegion(startMs: max(start, 0), endMs: end)
    }

    private func deleteSentenceRegions(
        edit: TranscriptEdit,
        words: [TranscriptWord]
    ) -> [TrimRegion] {
        guard let text = edit.text, !text.isEmpty else { return [] }

        // Sentence edits store their text; match contiguous words inside the edit window.
        let window = words.filter { $0.endMs > edit.startMs && $0.startMs < edit.endMs }
        guard !window.isEmpty else { return [] }

        var regions: [TrimRegion] = []
        var run: [TranscriptWord] = []
        let target = Self.normalize(text)

        func flush() {
            guard !run.isEmpty else { return }
            let joined = run.map { Self.normalize($0.text) }.joined()
            if !target.isEmpty, !joined.isEmpty, target.contains(joined) || joined.contains(target) {
                if let first = run.first, let last = run.last {
                    regions.append(TrimRegion(
                        startMs: max(first.startMs - options.handleMs, 0),
                        endMs: last.endMs + options.handleMs
                    ))
                }
            }
            run = []
        }

        for word in window {
            let token = Self.normalize(word.text)
            if token.isEmpty || token.allSatisfy({ !$0.isLetter && !$0.isNumber }) {
                flush()
            } else {
                run.append(word)
            }
        }
        flush()
        return regions
    }

    /// Normalizes a token for comparison: lowercase, strip punctuation and spaces.
    static func normalize(_ text: String) -> String {
        var result = ""
        for character in text.lowercased() {
            if character.isLetter || character.isNumber {
                result.append(character)
            }
        }
        return result
    }

    /// Sorts and merges overlapping or touching ranges.
    static func merge(_ regions: [TrimRegion]) -> [TrimRegion] {
        let sorted = regions
            .map { ($0.startMs, $0.endMs) }
            .filter { $0.1 > $0.0 }
            .sorted { $0.0 < $1.0 }

        var merged: [(Int, Int)] = []
        for range in sorted {
            if let last = merged.last, range.0 <= last.1 {
                merged[merged.count - 1] = (last.0, max(last.1, range.1))
            } else {
                merged.append(range)
            }
        }

        return merged.map { TrimRegion(startMs: $0.0, endMs: $0.1) }
    }

    /// Same merge, but keeps each surviving region's identity so generated trims stay
    /// tagged and manual trims keep their selection after an edit is rebuilt.
    static func mergePreservingIDs(_ regions: [TrimRegion]) -> [TrimRegion] {
        let sorted = regions
            .filter { $0.endMs > $0.startMs }
            .sorted { $0.startMs < $1.startMs }

        var merged: [TrimRegion] = []
        for region in sorted {
            if var last = merged.last, region.startMs <= last.endMs {
                last.endMs = max(last.endMs, region.endMs)
                merged[merged.count - 1] = last
            } else {
                merged.append(region)
            }
        }
        return merged
    }
}

// MARK: - Captions

/// A caption line: the words to display together and when.
public struct CaptionCue: Sendable, Equatable, Identifiable {
    public var id: String
    public var text: String
    public var startMs: Int
    public var endMs: Int
    /// Per-word offsets inside the cue, for karaoke-style highlighting.
    public var wordTimings: [WordTiming]

    public struct WordTiming: Sendable, Equatable {
        public var text: String
        public var startMs: Int
        public var endMs: Int

        public init(text: String, startMs: Int, endMs: Int) {
            self.text = text
            self.startMs = startMs
            self.endMs = endMs
        }
    }

    public init(
        id: String = UUID().uuidString,
        text: String,
        startMs: Int,
        endMs: Int,
        wordTimings: [WordTiming]
    ) {
        self.id = id
        self.text = text
        self.startMs = startMs
        self.endMs = endMs
        self.wordTimings = wordTimings
    }

    public var durationMs: Int { max(0, endMs - startMs) }
}

/// Builds caption lines from timed words.
///
/// Lines break on sentence punctuation, long pauses, the configured word budget, and
/// a character budget, so a single long word cluster does not overflow the frame.
public enum CaptionLayoutBuilder {
    public struct Options: Sendable, Equatable {
        public var wordsPerLine: Int
        public var maximumCharacters: Int
        /// A gap this long always ends a line.
        public var lineBreakPauseMs: Int
        /// Leading time the cue appears before its first word.
        public var leadInMs: Int
        /// Trailing time the cue stays after its last word.
        public var holdMs: Int

        public init(
            wordsPerLine: Int = 5,
            maximumCharacters: Int = 42,
            lineBreakPauseMs: Int = 420,
            leadInMs: Int = 60,
            holdMs: Int = 220
        ) {
            self.wordsPerLine = wordsPerLine
            self.maximumCharacters = maximumCharacters
            self.lineBreakPauseMs = lineBreakPauseMs
            self.leadInMs = leadInMs
            self.holdMs = holdMs
        }

        public init(settings: CaptionSettings) {
            self.init(wordsPerLine: settings.wordsPerLine)
        }
    }

    public static func cues(
        from words: [TranscriptWord],
        options: Options = Options()
    ) -> [CaptionCue] {
        guard !words.isEmpty else { return [] }
        let wordsPerLine = max(options.wordsPerLine, 1)

        var cues: [CaptionCue] = []
        var line: [TranscriptWord] = []

        func flush() {
            guard let first = line.first, let last = line.last else { return }
            let text = line.map(\.text).joined(separator: " ")
            let start = max(first.startMs - options.leadInMs, 0)
            let end = last.endMs + options.holdMs
            cues.append(CaptionCue(
                text: text,
                startMs: start,
                endMs: max(end, start + 200),
                wordTimings: line.map {
                    CaptionCue.WordTiming(text: $0.text, startMs: $0.startMs, endMs: $0.endMs)
                }
            ))
            line = []
        }

        for word in words {
            if let previous = line.last {
                let gap = word.startMs - previous.endMs
                if gap >= options.lineBreakPauseMs {
                    flush()
                }
            }

            line.append(word)

            let text = line.map(\.text).joined(separator: " ")
            let endsSentence = word.text.last.map { ".!?".contains($0) } ?? false
            if line.count >= wordsPerLine ||
                text.count >= options.maximumCharacters ||
                endsSentence {
                flush()
            }
        }
        flush()

        return cues
    }
}
