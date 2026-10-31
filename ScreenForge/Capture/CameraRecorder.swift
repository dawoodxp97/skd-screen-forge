import AVFoundation
import Foundation

public enum CameraError: LocalizedError, Sendable {
    case permissionDenied
    case noCamera
    case setupFailed(String)
    case recordingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "Camera access is required. Enable ScreenForge in System Settings → Privacy & Security → Camera."
        case .noCamera:
            "No camera is available."
        case .setupFailed(let reason):
            "Could not start the camera: \(reason)"
        case .recordingFailed(let reason):
            "The camera recording failed: \(reason)"
        }
    }
}

/// Records the webcam to a standalone `.mov` beside the screen recording.
///
/// The camera is captured at its native resolution and written as a separate asset,
/// so the editor can move, mask, or remove it at any time without touching the screen
/// capture. Audio is intentionally not recorded here; the microphone track is captured
/// by `MicrophoneRecorder`.
public final class CameraRecorder: NSObject, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let sessionQueue = DispatchQueue(label: "studio.screenforge.camera.session")
    private let stateLock = NSLock()

    private var isRunning = false
    private var finishedContinuation: CheckedContinuation<Void, Never>?
    private var recordingError: Error?

    public override init() {
        super.init()
    }

    // MARK: Permissions / devices

    public static var authorizationStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .video)
    }

    public static var isAuthorized: Bool {
        authorizationStatus == .authorized
    }

    public static func requestPermission() async -> Bool {
        switch authorizationStatus {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }

    public static func availableCameras() -> [AVCaptureDevice] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        )
        return discovery.devices
    }

    // MARK: Lifecycle

    public func start(deviceID: String? = nil, url: URL) throws {
        guard Self.isAuthorized else { throw CameraError.permissionDenied }

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }

        let device: AVCaptureDevice?
        if let deviceID {
            device = AVCaptureDevice(uniqueID: deviceID)
        } else {
            device = Self.availableCameras().first
        }
        guard let device else { throw CameraError.noCamera }

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw CameraError.setupFailed(error.localizedDescription)
        }

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = .high
        for existing in session.inputs {
            session.removeInput(existing)
        }
        guard session.canAddInput(input) else {
            throw CameraError.setupFailed("The camera input was rejected.")
        }
        session.addInput(input)

        if !session.outputs.contains(where: { $0 === movieOutput }) {
            guard session.canAddOutput(movieOutput) else {
                throw CameraError.setupFailed("The camera recorder output was rejected.")
            }
            session.addOutput(movieOutput)
        }

        movieOutput.movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)

        stateLock.lock()
        recordingError = nil
        finishedContinuation = nil
        stateLock.unlock()

        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.startRunning()
            self.movieOutput.startRecording(to: url, recordingDelegate: self)
        }

        stateLock.lock()
        isRunning = true
        stateLock.unlock()
    }

    /// Stops the camera and returns once the file has been finalized.
    public func stop() async {
        let running = withState { () -> Bool in
            guard isRunning else { return false }
            isRunning = false
            return true
        }
        guard running else { return }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let needsStop = withState { () -> Bool in
                guard movieOutput.isRecording else { return false }
                finishedContinuation = continuation
                return true
            }
            if needsStop {
                sessionQueue.async { [weak self] in
                    self?.movieOutput.stopRecording()
                }
            } else {
                continuation.resume(returning: ())
            }
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sessionQueue.async { [weak self] in
                self?.session.stopRunning()
                continuation.resume(returning: ())
            }
        }
    }

    private func withState<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    public var lastError: Error? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return recordingError
    }

    // MARK: Delegate

    fileprivate func handleFinished(error: Error?) {
        stateLock.lock()
        recordingError = error
        let continuation = finishedContinuation
        finishedContinuation = nil
        stateLock.unlock()
        continuation?.resume(returning: ())
    }
}

extension CameraRecorder: AVCaptureFileOutputRecordingDelegate {
    public func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        handleFinished(error: error)
    }
}
