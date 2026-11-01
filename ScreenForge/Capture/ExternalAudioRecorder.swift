import AVFoundation
import CoreMedia
import Foundation

// MARK: - Device catalog

public struct CaptureDeviceInfo: Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable {
        case microphone
        case externalAudio
        case camera
        case continuity
        case iPhone
        case iPad
        case display
    }

    public var id: String
    public var name: String
    public var kind: Kind
    public var manufacturer: String

    public init(id: String, name: String, kind: Kind, manufacturer: String = "") {
        self.id = id
        self.name = name
        self.kind = kind
        self.manufacturer = manufacturer
    }

    public var mockupKind: DeviceMockupKind {
        switch kind {
        case .iPhone: .iPhone
        case .iPad: .iPad
        default: .none
        }
    }
}

/// Lists capture hardware through AVFoundation. iPhones and iPads appear as
/// external/continuity video devices when connected and trusted, which is the same
/// path QuickTime uses for device recording.
public enum CaptureDeviceCatalog {
    public static func audioDevices() -> [CaptureDeviceInfo] {
        let types: [AVCaptureDevice.DeviceType] = [.microphone, .external]
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: types,
            mediaType: .audio,
            position: .unspecified
        )
        return session.devices.map { device in
            let kind: CaptureDeviceInfo.Kind = device.deviceType == .external
                ? .externalAudio
                : .microphone
            return CaptureDeviceInfo(
                id: device.uniqueID,
                name: device.localizedName,
                kind: kind,
                manufacturer: device.manufacturer
            )
        }
    }

    public static func videoDevices() -> [CaptureDeviceInfo] {
        let types: [AVCaptureDevice.DeviceType] = [
            .external,
            .continuityCamera,
            .deskViewCamera,
            .builtInWideAngleCamera
        ]
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: types,
            mediaType: .video,
            position: .unspecified
        )
        return session.devices.map { device in
            let name = device.localizedName
            let kind: CaptureDeviceInfo.Kind
            if name.localizedCaseInsensitiveContains("iphone") {
                kind = .iPhone
            } else if name.localizedCaseInsensitiveContains("ipad") {
                kind = .iPad
            } else if device.deviceType == .external {
                kind = .display
            } else if device.deviceType == .continuityCamera {
                kind = .continuity
            } else {
                kind = .camera
            }
            return CaptureDeviceInfo(
                id: device.uniqueID,
                name: name,
                kind: kind,
                manufacturer: device.manufacturer
            )
        }
    }

    public static func device(withID id: String, mediaType: AVMediaType) -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType] = mediaType == .audio
            ? [.microphone, .external]
            : [.external, .continuityCamera, .deskViewCamera, .builtInWideAngleCamera]
        return AVCaptureDevice.DiscoverySession(
            deviceTypes: types,
            mediaType: mediaType,
            position: .unspecified
        ).devices.first { $0.uniqueID == id }
    }
}

// MARK: - External audio recorder

/// Records a separately selected audio input (interface, mixer, USB microphone) to
/// an `.m4a`. The screen recording keeps its own system audio; this track is mixed
/// as the "external device" bus.
public final class ExternalAudioRecorder: NSObject, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let queue = DispatchQueue(label: "studio.screenforge.external-audio")
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var didStart = false
    private var isRunning = false
    private let url: URL
    private let deviceID: String?

    public init(url: URL, deviceID: String?) {
        self.url = url
        self.deviceID = deviceID
        super.init()
    }

    public func start() throws {
        guard !isRunning else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }

        session.beginConfiguration()
        let device = deviceID.flatMap { CaptureDeviceCatalog.device(withID: $0, mediaType: .audio) }
            ?? AVCaptureDevice.default(for: .audio)
        guard let device,
              let deviceInput = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(deviceInput) else {
            session.commitConfiguration()
            throw RecorderError.noDevice
        }
        session.addInput(deviceInput)

        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw RecorderError.configurationFailed
        }
        session.addOutput(output)
        session.commitConfiguration()

        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 160_000
        ])
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw RecorderError.configurationFailed }
        writer.add(input)
        self.writer = writer
        self.input = input
        didStart = false
        isRunning = true

        queue.async { [weak self] in
            self?.session.startRunning()
        }
    }

    @discardableResult
    public func stop() -> URL? {
        guard isRunning else { return nil }
        isRunning = false
        queue.sync {
            session.stopRunning()
            output.setSampleBufferDelegate(nil, queue: nil)
            input?.markAsFinished()
        }
        let semaphore = DispatchSemaphore(value: 0)
        writer?.finishWriting { semaphore.signal() }
        _ = semaphore.wait(timeout: .now() + 5)
        writer = nil
        input = nil
        didStart = false
        return url
    }

    public enum RecorderError: LocalizedError {
        case noDevice
        case configurationFailed

        public var errorDescription: String? {
            switch self {
            case .noDevice: "No external audio device is available."
            case .configurationFailed: "Could not configure the external audio recorder."
            }
        }
    }
}

extension ExternalAudioRecorder: AVCaptureAudioDataOutputSampleBufferDelegate {
    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard isRunning,
              let input,
              let writer,
              CMSampleBufferDataIsReady(sampleBuffer) else { return }

        if !didStart {
            guard writer.startWriting() else { return }
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            didStart = true
        }
        if input.isReadyForMoreMediaData {
            input.append(sampleBuffer)
        }
    }
}

// MARK: - Device (iPhone/iPad) recorder

/// Records the screen of a connected iPhone/iPad (or any external video device)
/// through AVFoundation, then hands the movie to a project.
public final class DeviceCaptureRecorder: NSObject, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let fileOutput = AVCaptureMovieFileOutput()
    private let queue = DispatchQueue(label: "studio.screenforge.device-capture")
    private var isRunning = false
    private var finishedContinuation: CheckedContinuation<URL, Error>?
    private let url: URL
    private let deviceID: String?
    public private(set) var displayName: String = "Device"

    public init(url: URL, deviceID: String?) {
        self.url = url
        self.deviceID = deviceID
        super.init()
    }

    public func start() throws {
        guard !isRunning else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }

        session.beginConfiguration()
        session.sessionPreset = .high
        let device = deviceID.flatMap { CaptureDeviceCatalog.device(withID: $0, mediaType: .video) }
        guard let device,
              let deviceInput = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(deviceInput) else {
            session.commitConfiguration()
            throw ExternalAudioRecorder.RecorderError.noDevice
        }
        session.addInput(deviceInput)
        displayName = device.localizedName

        if session.canAddOutput(fileOutput) {
            session.addOutput(fileOutput)
        } else {
            session.commitConfiguration()
            throw ExternalAudioRecorder.RecorderError.configurationFailed
        }
        session.commitConfiguration()

        isRunning = true
        queue.async { [weak self] in
            self?.session.startRunning()
        }
        fileOutput.startRecording(to: url, recordingDelegate: self)
    }

    public func stop() async throws -> URL {
        guard isRunning else { return url }
        return try await withCheckedThrowingContinuation { continuation in
            finishedContinuation = continuation
            fileOutput.stopRecording()
        }
    }

    public func cancel() {
        fileOutput.stopRecording()
        queue.async { [weak self] in
            self?.session.stopRunning()
        }
        isRunning = false
    }
}

extension DeviceCaptureRecorder: AVCaptureFileOutputRecordingDelegate {
    public func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        queue.async { [weak self] in
            self?.session.stopRunning()
        }
        isRunning = false
        let continuation = finishedContinuation
        finishedContinuation = nil

        if let error, !FileManager.default.fileExists(atPath: outputFileURL.path) {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume(returning: outputFileURL)
        }
    }
}
