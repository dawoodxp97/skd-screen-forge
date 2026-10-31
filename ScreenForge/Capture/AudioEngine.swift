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

/// Records the microphone to compressed AAC (`.m4a`) while publishing a live level.
///
/// Voice processing (AEC/AGC) is enabled when available; the heavier noise-reduction
/// chain lives in the export-time `VoiceEnhancer` so previews stay cheap.
public final class MicrophoneRecorder: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var level: Float = 0
    private var running = false

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

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: Int(min(format.channelCount, 2)),
            AVEncoderBitRateKey: 128_000
        ]

        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(
                forWriting: url,
                settings: settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        } catch {
            throw MicrophoneError.engineFailed(error.localizedDescription)
        }

        lock.lock()
        file = audioFile
        lock.unlock()

        input.installTap(onBus: 0, bufferSize: 4_096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.lock.lock()
            let destination = self.file
            self.lock.unlock()
            guard let destination else { return }

            do {
                try destination.write(from: buffer)
            } catch {
                NSLog("Microphone write failed: \(error.localizedDescription)")
            }

            if let channel = buffer.floatChannelData?[0] {
                let frames = Int(buffer.frameLength)
                guard frames > 0 else { return }
                var sum: Float = 0
                for index in 0..<frames {
                    let sample = channel[index]
                    sum += sample * sample
                }
                let rms = sqrt(sum / Float(frames))
                self.lock.lock()
                self.level = min(rms * 6, 1)
                self.lock.unlock()
            }
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            lock.lock()
            file = nil
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
        lock.unlock()

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        lock.lock()
        file = nil
        running = false
        level = 0
        lock.unlock()
    }
}
