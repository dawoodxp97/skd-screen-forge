import Foundation
import Speech

public enum TranscriptionError: LocalizedError, Sendable {
    case permissionDenied
    case recognizerUnavailable(String)
    case missingAudio(String)
    case noSpeech
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "Speech recognition access is required. Enable ScreenForge in System Settings → Privacy & Security → Speech Recognition."
        case .recognizerUnavailable(let language):
            "No speech recognizer is available for \(language)."
        case .missingAudio(let path):
            "The recording is missing its audio track: \(path)."
        case .noSpeech:
            "No speech was recognized in this recording."
        case .failed(let reason):
            "Transcription failed: \(reason)"
        }
    }
}

/// On-device word-level transcription.
///
/// Uses `SFSpeechRecognizer` in on-device mode when the locale supports it, and falls
/// back to the server recognizer otherwise (never for the microphone track of a
/// recording unless the user opts in — the bundled engine name records which ran).
public actor TranscriptionEngine {
    public init() {}

    public static var authorizationStatus: SFSpeechRecognizerAuthorizationStatus {
        SFSpeechRecognizer.authorizationStatus()
    }

    public static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    /// Transcribes a local audio file into timed words.
    ///
    /// - Parameters:
    ///   - url: A local audio file (the enhanced microphone track, or system audio).
    ///   - language: BCP-47 identifier. Defaults to the current locale.
    ///   - preferOnDevice: Keeps audio on the Mac when the recognizer supports it.
    public func transcribe(
        audioURL url: URL,
        language: String? = nil,
        preferOnDevice: Bool = true
    ) async throws -> TranscriptDocument {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw TranscriptionError.missingAudio(url.lastPathComponent)
        }

        let status = SFSpeechRecognizer.authorizationStatus()
        if status == .notDetermined {
            guard await Self.requestAuthorization() else {
                throw TranscriptionError.permissionDenied
            }
        } else if status != .authorized {
            throw TranscriptionError.permissionDenied
        }

        let localeIdentifier = language ?? Locale.current.identifier
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)),
              recognizer.isAvailable else {
            throw TranscriptionError.recognizerUnavailable(localeIdentifier)
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.taskHint = .dictation
        request.addsPunctuation = true
        let onDevice = preferOnDevice && recognizer.supportsOnDeviceRecognition
        request.requiresOnDeviceRecognition = onDevice

        let outcome = try await recognize(request: request, recognizer: recognizer)

        let words = outcome.segments
            .sorted { $0.timestamp < $1.timestamp }
            .compactMap { segment -> TranscriptWord? in
                let text = segment.substring.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                let start = Int((segment.timestamp * 1000).rounded())
                let end = max(start + 1, Int(((segment.timestamp + segment.duration) * 1000).rounded()))
                return TranscriptWord(
                    text: text,
                    startMs: start,
                    endMs: end,
                    confidence: Double(segment.confidence)
                )
            }

        guard !words.isEmpty else { throw TranscriptionError.noSpeech }

        return TranscriptDocument(
            language: localeIdentifier,
            engine: onDevice ? "SFSpeechRecognizer.onDevice" : "SFSpeechRecognizer.server",
            words: words
        )
    }

    // MARK: - Recognition

    private struct Outcome: Sendable {
        var segments: [Segment]
        var text: String
    }

    /// Sendable snapshot of `SFTranscriptionSegment` (which is not `Sendable`).
    private struct Segment: Sendable {
        var substring: String
        var timestamp: TimeInterval
        var duration: TimeInterval
        var confidence: Float
    }

    private final class ContinuationBox: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !finished else { return false }
            finished = true
            return true
        }
    }

    private func recognize(
        request: SFSpeechRecognitionRequest,
        recognizer: SFSpeechRecognizer
    ) async throws -> Outcome {
        let box = ContinuationBox()

        return try await withCheckedThrowingContinuation { continuation in
            recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    guard box.claim() else { return }
                    continuation.resume(throwing: TranscriptionError.failed(error.localizedDescription))
                    return
                }
                guard let result, result.isFinal else { return }
                guard box.claim() else { return }

                let best = result.bestTranscription
                let segments = best.segments.map {
                    Segment(
                        substring: $0.substring,
                        timestamp: $0.timestamp,
                        duration: $0.duration,
                        confidence: $0.confidence
                    )
                }
                continuation.resume(returning: Outcome(segments: segments, text: best.formattedString))
            }
        }
    }
}
