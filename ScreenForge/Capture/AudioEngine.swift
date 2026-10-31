import AVFoundation
import Foundation

public enum MicrophoneError: LocalizedError, Sendable {
    case permissionDenied
    case noInputDevice
    case engineFailed(String)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "Microphone access is required. Enable ScreenForge in System Settings → Privacy & Security → Microphone."
        case .noInputDevice:
            "No microphone input device is available."
        case .engineFailed(let reason):
            "Microphone engine failed: \(reason)"
        }
    }
}

/// Records the microphone to a lossless `.caf` (32-bit float PCM) while publishing a live
/// level. The recording is converted to AAC when the project is finalized.
///
/// The output file is opened lazily from the **first actual tap buffer** rather than from
/// the input node's format before the engine starts. Voice processing can change the
/// sample rate/channel count after `setVoiceProcessingEnabled`, and writing a 48 kHz
/// buffer into a file opened as 44.1 kHz fails with `paramErr` (-50) on every buffer —
/// which previously produced an empty microphone track.
public final class MicrophoneRecorder: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var fileURL: URL?
    private var level: Float = 0
    private var running = false
    private var loggedWriteFailure = false

    public init() {}

    public static func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    public var currentLevel: Float {
        lock.lock()
        defer { lock.unlock() }
        return level
    }

    /// URL of the file being written (`.caf`).
    public var outputURL: URL? {
        lock.lock()
        defer { lock.unlock() }
        return fileURL
    }

    public func start(url: URL, enableVoiceProcessing: Bool = true) throws {
        lock.lock()
        guard !running else {
            lock.unlock()
            return
        }
        lock.unlock()

        let input = engine.inputNode
        if enableVoiceProcessing {
            do {
                try input.setVoiceProcessingEnabled(true)
            } catch {
                NSLog("Voice processing unavailable: \(error.localizedDescription)")
            }
        }

        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw MicrophoneError.noInputDevice
        }

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }

        lock.lock()
        fileURL = url
        file = nil
        loggedWriteFailure = false
        lock.unlock()

        input.installTap(onBus: 0, bufferSize: 4_096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.write(buffer)
            self.publishLevel(buffer)
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            lock.lock()
            file = nil
            fileURL = nil
            lock.unlock()
            throw MicrophoneError.engineFailed(error.localizedDescription)
        }

        lock.lock()
        running = true
        lock.unlock()
    }

    public func stop() {
        lock.lock()
        guard running else {
            lock.unlock()
            return
        }
        running = false
        lock.unlock()

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        lock.lock()
        file = nil
        level = 0
        lock.unlock()
    }

    // MARK: Capture

    private func write(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        var destination = file
        let url = fileURL
        lock.unlock()

        if destination == nil, let url {
            do {
                // `buffer.format.settings` describes exactly what we are about to write.
                destination = try AVAudioFile(
                    forWriting: url,
                    settings: buffer.format.settings,
                    commonFormat: buffer.format.commonFormat,
                    interleaved: buffer.format.isInterleaved
                )
                lock.lock()
                file = destination
                lock.unlock()
            } catch {
                lock.lock()
                let alreadyLogged = loggedWriteFailure
                loggedWriteFailure = true
                lock.unlock()
                if !alreadyLogged {
                    NSLog("Microphone file creation failed: \(error.localizedDescription)")
                }
                return
            }
        }

        guard let destination else { return }
        do {
            try destination.write(from: buffer)
        } catch {
            lock.lock()
            let alreadyLogged = loggedWriteFailure
            loggedWriteFailure = true
            lock.unlock()
            if !alreadyLogged {
                NSLog("Microphone write failed: \(error.localizedDescription)")
            }
        }
    }

    private func publishLevel(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else {
            return
        }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        var sum: Float = 0
        for index in 0..<frames {
            let sample = channel[index]
            sum += sample * sample
        }
        let rms = sqrt(sum / Float(frames))
        lock.lock()
        level = min(rms * 6, 1)
        lock.unlock()
    }
}
