import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

// MARK: - Public types

public enum ExportFormat: String, Sendable, CaseIterable {
    case mp4
    case gif

    public var fileExtension: String { rawValue }
    public var label: String { self == .mp4 ? "MP4" : "GIF" }
}

public struct ExportProgress: Sendable, Equatable {
    public enum Phase: String, Sendable {
        case preparing
        case rendering
        case audio
        case muxing
        case finishing

        public var label: String {
            switch self {
            case .preparing: "Preparing"
            case .rendering: "Rendering"
            case .audio: "Mixing audio"
            case .muxing: "Finalizing"
            case .finishing: "Done"
            }
        }
    }

    public var phase: Phase
    public var fraction: Double
    public var message: String

    public init(phase: Phase, fraction: Double, message: String = "") {
        self.phase = phase
        self.fraction = min(max(fraction, 0), 1)
        self.message = message
    }
}

public struct ExportJob: Sendable {
    public var project: ScreenForgeProject
    public var bundleURL: URL
    public var outputURL: URL
    public var format: ExportFormat
    public var gifFPS: Int
    public var gifMaxWidth: Int

    public init(
        project: ScreenForgeProject,
        bundleURL: URL,
        outputURL: URL,
        format: ExportFormat = .mp4,
        gifFPS: Int = 12,
        gifMaxWidth: Int = 720
    ) {
        self.project = project
        self.bundleURL = bundleURL
        self.outputURL = outputURL
        self.format = format
        self.gifFPS = gifFPS
        self.gifMaxWidth = gifMaxWidth
    }
}

public enum ExportError: LocalizedError, Sendable {
    case missingScreenMedia(String)
    case noVideoTrack
    case readerFailed(String)
    case writerFailed(String)
    case metalUnavailable
    case cancelled
    case audioFailed(String)
    case muxFailed(String)
    case gifFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingScreenMedia(let path):
            "Missing recording: \(path)."
        case .noVideoTrack:
            "The recording has no video track."
        case .readerFailed(let reason):
            "Could not read the recording: \(reason)"
        case .writerFailed(let reason):
            "Could not write the export: \(reason)"
        case .metalUnavailable:
            "Metal is unavailable, so export cannot continue."
        case .cancelled:
            "Export cancelled."
        case .audioFailed(let reason):
            "Audio mixing failed: \(reason)"
        case .muxFailed(let reason):
            "Could not finalize the movie: \(reason)"
        case .gifFailed(let reason):
            "GIF export failed: \(reason)"
        }
    }
}

// MARK: - Exporter

/// Decodes source media, drives the shared Metal compositor, and encodes a final file.
///
/// Video is always rendered frame-by-frame through `FrameRenderer` + `Compositor`, so
/// preview and export produce the same pixels. Audio is rebuilt on the same timeline
/// (trims + speeds) and muxed in a second, passthrough pass.
public final class Exporter: @unchecked Sendable {
    private let compositor: Compositor

    public init(compositor: Compositor) {
        self.compositor = compositor
    }

    public func export(
        job: ExportJob,
        progress: @escaping @Sendable (ExportProgress) -> Void
    ) async throws -> URL {
        switch job.format {
        case .mp4:
            return try await exportMovie(job: job, progress: progress)
        case .gif:
            let movie = try await exportMovie(job: job, progress: progress)
            defer { try? FileManager.default.removeItem(at: movie) }
            progress(ExportProgress(phase: .finishing, fraction: 0.95, message: "Encoding GIF"))
            return try await GifExporter.convert(
                movieURL: movie,
                outputURL: job.outputURL,
                fps: job.gifFPS,
                maxWidth: job.gifMaxWidth
            )
        }
    }

    // MARK: Movie export

    private func exportMovie(
        job: ExportJob,
        progress: @escaping @Sendable (ExportProgress) -> Void
    ) async throws -> URL {
        progress(ExportProgress(phase: .preparing, fraction: 0, message: "Loading project"))

        let project = job.project.normalized()
        let sourceURL = job.bundleURL.appendingPathComponent(project.source.screenPath)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw ExportError.missingScreenMedia(project.source.screenPath)
        }

        let screenAsset = AVURLAsset(url: sourceURL)
        guard let screenTrack = try await screenAsset.loadTracks(withMediaType: .video).first else {
            throw ExportError.noVideoTrack
        }

        let map = project.timeline.map(sourceDurationMs: project.source.durationMs)
        let outputDurationMs = map.outputDurationMs
        guard outputDurationMs > 100 else {
            throw ExportError.readerFailed("The edited video is empty.")
        }

        let settings = project.export.normalized()
        let fps = max(settings.fps, 1)
        let canvas = Self.canvasSize(project: project, settings: settings)

        let screenReader = try SequentialFrameReader(asset: screenAsset, track: screenTrack)

        var cameraReader: SequentialFrameReader?
        if project.camera.enabled,
           let webcamPath = project.source.webcamPath {
            let cameraURL = job.bundleURL.appendingPathComponent(webcamPath)
            if FileManager.default.fileExists(atPath: cameraURL.path) {
                let cameraAsset = AVURLAsset(url: cameraURL)
                if let track = try? await cameraAsset.loadTracks(withMediaType: .video).first {
                    cameraReader = try? SequentialFrameReader(asset: cameraAsset, track: track)
                }
            }
        }

        let renderer = FrameRenderer(
            project: project,
            bundleURL: job.bundleURL,
            cursorSamples: try await ProjectStore.shared.loadCursor(from: job.bundleURL)
        )

        let tempDirectory = FileManager.default.temporaryDirectory
        let tempVideo = tempDirectory
            .appendingPathComponent("ScreenForge-\(UUID().uuidString)-video.mov")
        let tempAudio = tempDirectory
            .appendingPathComponent("ScreenForge-\(UUID().uuidString)-audio.m4a")
        let destination = job.outputURL

        defer {
            try? FileManager.default.removeItem(at: tempVideo)
            try? FileManager.default.removeItem(at: tempAudio)
        }

        // 1. Render video-only.
        let writer = try AVAssetWriter(outputURL: tempVideo, fileType: .mov)
        let videoSettings = Self.videoSettings(
            width: Int(canvas.width),
            height: Int(canvas.height),
            fps: fps,
            settings: settings
        )
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false

        let bufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(canvas.width),
            kCVPixelBufferHeightKey as String: Int(canvas.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: bufferAttributes
        )

        guard writer.canAdd(videoInput) else {
            throw ExportError.writerFailed("The video encoder rejected the output settings.")
        }
        writer.add(videoInput)
        guard writer.startWriting() else {
            throw ExportError.writerFailed(writer.error?.localizedDescription ?? "Could not start the encoder.")
        }
        writer.startSession(atSourceTime: .zero)

        guard let offscreen = compositor.makeOffscreenTexture(
            width: Int(canvas.width),
            height: Int(canvas.height)
        ) else {
            throw ExportError.metalUnavailable
        }

        let totalFrames = max(Int((outputDurationMs / 1000.0 * Double(fps)).rounded()), 1)
        var appended = 0

        for frameIndex in 0..<totalFrames {
            try Task.checkCancellation()
            if writer.status == .failed {
                throw ExportError.writerFailed(writer.error?.localizedDescription ?? "The encoder stopped.")
            }
            while !videoInput.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 2_000_000)
                if writer.status == .failed {
                    throw ExportError.writerFailed(writer.error?.localizedDescription ?? "The encoder stopped.")
                }
            }

            let outputSeconds = Double(frameIndex) / Double(fps)
            let outputMs = outputSeconds * 1000
            let sourceSeconds = (map.sourceTime(forOutputMs: outputMs) ?? 0) / 1000
            let state = renderer.state(atOutputMs: outputMs, canvasSize: canvas)

            let screenSample = screenReader.sample(at: sourceSeconds)
            let screenFrame = screenSample.flatMap { sample -> MetalFrameTexture? in
                guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { return nil }
                return compositor.texture(from: pixelBuffer)
            }
            let cameraFrame: MetalFrameTexture? = cameraReader?.sample(at: sourceSeconds).flatMap { sample in
                guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { return nil }
                return compositor.texture(from: pixelBuffer)
            }

            guard let pool = adaptor.pixelBufferPool else {
                throw ExportError.writerFailed("The encoder did not provide a pixel buffer pool.")
            }
            var pixelBuffer: CVPixelBuffer?
            let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
            guard status == kCVReturnSuccess, let pixelBuffer else {
                throw ExportError.writerFailed("Could not allocate an output frame.")
            }

            guard let target = compositor.texture(from: pixelBuffer) else {
                throw ExportError.metalUnavailable
            }

            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = offscreen
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

            guard let commandBuffer = compositor.commandQueue.makeCommandBuffer() else {
                throw ExportError.metalUnavailable
            }

            compositor.encode(
                state: state,
                screen: screenFrame?.texture,
                camera: cameraFrame?.texture,
                in: pass,
                commandBuffer: commandBuffer
            )

            if let blit = commandBuffer.makeBlitCommandEncoder() {
                blit.copy(
                    from: offscreen,
                    sourceSlice: 0,
                    sourceLevel: 0,
                    sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                    sourceSize: MTLSize(width: offscreen.width, height: offscreen.height, depth: 1),
                    to: target.texture,
                    destinationSlice: 0,
                    destinationLevel: 0,
                    destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
                )
                blit.endEncoding()
            }

            commandBuffer.commit()
            await commandBuffer.completed()

            let pts = CMTime(value: CMTimeValue(frameIndex), timescale: CMTimeScale(fps))
            if !adaptor.append(pixelBuffer, withPresentationTime: pts) {
                throw ExportError.writerFailed(writer.error?.localizedDescription ?? "Could not append a frame.")
            }
            appended += 1
            if frameIndex % 3 == 0 || frameIndex == totalFrames - 1 {
                let fraction = 0.05 + 0.78 * (Double(frameIndex + 1) / Double(totalFrames))
                progress(ExportProgress(
                    phase: .rendering,
                    fraction: fraction,
                    message: "Frame \(frameIndex + 1) of \(totalFrames)"
                ))
            }
        }

        videoInput.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed, appended > 0 else {
            throw ExportError.writerFailed(writer.error?.localizedDescription ?? "The encoder produced no frames.")
        }
        screenReader.finish()
        cameraReader?.finish()

        // 2. Rebuild audio on the edited timeline.
        progress(ExportProgress(phase: .audio, fraction: 0.85, message: "Mixing audio"))
        let hasAudio = try await buildAudio(
            project: project,
            bundleURL: job.bundleURL,
            map: map,
            outputDurationMs: outputDurationMs,
            destination: tempAudio
        )

        // 3. Mux (or move when silent).
        progress(ExportProgress(phase: .muxing, fraction: 0.92, message: "Finalizing movie"))
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }

        if hasAudio {
            try await Self.mux(
                videoURL: tempVideo,
                audioURL: tempAudio,
                destination: destination,
                outputFileType: destination.pathExtension.lowercased() == "mov" ? .mov : .mp4
            )
        } else {
            try FileManager.default.moveItem(at: tempVideo, to: destination)
        }

        progress(ExportProgress(phase: .finishing, fraction: 1, message: "Export complete"))
        return destination
    }

    // MARK: Audio

    /// Builds an audio-only movie for the edited timeline. Returns false when the
    /// project has no audio at all.
    private func buildAudio(
        project: ScreenForgeProject,
        bundleURL: URL,
        map: TimelineMap,
        outputDurationMs: Double,
        destination: URL
    ) async throws -> Bool {
        var sources: [AVURLAsset] = []
        let screenURL = bundleURL.appendingPathComponent(project.source.screenPath)
        let screenAsset = AVURLAsset(url: screenURL)
        if !(try await screenAsset.loadTracks(withMediaType: .audio)).isEmpty {
            sources.append(screenAsset)
        }
        if let micPath = project.source.microphonePath {
            let micURL = bundleURL.appendingPathComponent(micPath)
            if FileManager.default.fileExists(atPath: micURL.path) {
                sources.append(AVURLAsset(url: micURL))
            }
        }
        if let systemPath = project.source.systemAudioPath {
            let url = bundleURL.appendingPathComponent(systemPath)
            if FileManager.default.fileExists(atPath: url.path) {
                sources.append(AVURLAsset(url: url))
            }
        }
        guard !sources.isEmpty else { return false }

        let composition = AVMutableComposition()
        var insertedTracks = 0

        for asset in sources {
            guard let sourceTrack = try await asset.loadTracks(withMediaType: .audio).first,
                  let compositionTrack = composition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                  ) else {
                continue
            }

            var cursor = CMTime.zero
            var inserted = false
            for segment in map.segments where segment.rate > 0 && segment.sourceLengthMs > 0 {
                let sourceRange = CMTimeRange(
                    start: CMTime(seconds: segment.sourceStartMs / 1000, preferredTimescale: 600),
                    duration: CMTime(seconds: segment.sourceLengthMs / 1000, preferredTimescale: 600)
                )
                do {
                    try compositionTrack.insertTimeRange(sourceRange, of: sourceTrack, at: cursor)
                    let insertedDuration = CMTime(seconds: segment.sourceLengthMs / 1000, preferredTimescale: 600)
                    let outputDuration = CMTime(seconds: segment.outputLengthMs / 1000, preferredTimescale: 600)
                    if abs(segment.rate - 1) > 0.001, outputDuration > .zero {
                        compositionTrack.scaleTimeRange(
                            CMTimeRange(start: cursor, duration: insertedDuration),
                            toDuration: outputDuration
                        )
                    }
                    cursor = CMTimeAdd(cursor, outputDuration)
                    inserted = true
                } catch {
                    NSLog("Audio insert failed (\(segment.sourceStartMs)–\(segment.sourceEndMs)): \(error.localizedDescription)")
                }
            }

            if inserted {
                insertedTracks += 1
            } else {
                composition.removeTrack(compositionTrack)
            }
        }

        guard insertedTracks > 0 else { return false }

        // Match the visual duration exactly, even if the audio source ran short.
        let target = CMTime(seconds: outputDurationMs / 1000, preferredTimescale: 600)
        if CMTimeCompare(composition.duration, target) < 0 {
            if let last = composition.tracks(withMediaType: .audio).last {
                let missing = CMTimeSubtract(target, composition.duration)
                last.insertEmptyTimeRange(CMTimeRange(start: composition.duration, duration: missing))
            }
        }

        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw ExportError.audioFailed("Could not create the audio export session.")
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        session.outputURL = destination
        session.outputFileType = .m4a
        session.shouldOptimizeForNetworkUse = false

        nonisolated(unsafe) let exportSession = session
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            exportSession.exportAsynchronously {
                switch exportSession.status {
                case .completed:
                    continuation.resume()
                case .cancelled:
                    continuation.resume(throwing: ExportError.cancelled)
                default:
                    continuation.resume(
                        throwing: ExportError.audioFailed(
                            exportSession.error?.localizedDescription ?? "Unknown audio error"
                        )
                    )
                }
            }
        }
        return true
    }

    private static func mux(
        videoURL: URL,
        audioURL: URL,
        destination: URL,
        outputFileType: AVFileType
    ) async throws {
        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: videoURL)
        let audioAsset = AVURLAsset(url: audioURL)

        guard let videoSource = try await videoAsset.loadTracks(withMediaType: .video).first,
              let videoTrack = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
              ) else {
            throw ExportError.muxFailed("The rendered video is missing.")
        }
        let videoDuration = try await videoAsset.load(.duration)
        try videoTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: videoDuration),
            of: videoSource,
            at: .zero
        )

        if let audioSource = try await audioAsset.loadTracks(withMediaType: .audio).first,
           let audioTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            let audioDuration = try await audioAsset.load(.duration)
            try audioTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: min(audioDuration, videoDuration)),
                of: audioSource,
                at: .zero
            )
        }

        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw ExportError.muxFailed("Could not create the mux export session.")
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        session.outputURL = destination
        session.outputFileType = outputFileType
        session.shouldOptimizeForNetworkUse = true

        nonisolated(unsafe) let exportSession = session
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            exportSession.exportAsynchronously {
                switch exportSession.status {
                case .completed:
                    continuation.resume()
                case .cancelled:
                    continuation.resume(throwing: ExportError.cancelled)
                default:
                    continuation.resume(
                        throwing: ExportError.muxFailed(
                            exportSession.error?.localizedDescription ?? "Unknown mux error"
                        )
                    )
                }
            }
        }
    }

    // MARK: Settings

    public static func canvasSize(project: ScreenForgeProject, settings: ExportSettings) -> CGSize {
        let longEdge: Int
        switch settings.resolution {
        case .p720: longEdge = 1280
        case .p1080: longEdge = 1920
        case .p4k: longEdge = 3840
        case .custom: longEdge = settings.customLongEdge ?? 1920
        }
        let ratio = project.canvas.aspect.ratio
        if ratio >= 1 {
            return CGSize(
                width: CGFloat(longEdge),
                height: CGFloat((Double(longEdge) / ratio).rounded() / 2 * 2)
            )
        }
        return CGSize(
            width: CGFloat((Double(longEdge) * ratio).rounded() / 2 * 2),
            height: CGFloat(longEdge)
        )
    }

    private static func videoSettings(
        width: Int,
        height: Int,
        fps: Int,
        settings: ExportSettings
    ) -> [String: Any] {
        let codec: AVVideoCodecType = settings.codec == .hevc ? .hevc : .h264
        let bitsPerPixel = settings.codec == .hevc ? 0.11 : 0.16
        let rawBitrate = Double(width) * Double(height) * Double(fps) * bitsPerPixel * settings.quality
        let bitrate = Int(min(max(rawBitrate, 4_000_000), 160_000_000))

        return [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
                AVVideoAllowFrameReorderingKey: true,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoProfileLevelKey: settings.codec == .hevc
                    ? kVTProfileLevel_HEVC_Main_AutoLevel
                    : kVTProfileLevel_H264_High_AutoLevel
            ]
        ]
    }
}

// MARK: - Sequential decoding

/// Reads video frames forward in presentation order. Export requests source times
/// monotonically, so a single reader advances lazily instead of seeking per frame.
private final class SequentialFrameReader {
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private var current: CMSampleBuffer?
    private var lookahead: CMSampleBuffer?

    init(asset: AVAsset, track: AVAssetTrack) throws {
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw ExportError.readerFailed(error.localizedDescription)
        }
        output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw ExportError.readerFailed("Could not attach the video output.")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw ExportError.readerFailed(reader.error?.localizedDescription ?? "Could not start reading.")
        }
    }

    /// Returns the newest frame at or before `seconds`, advancing the reader as needed.
    func sample(at seconds: Double) -> CMSampleBuffer? {
        while true {
            let candidate: CMSampleBuffer?
            if let pending = lookahead {
                candidate = pending
                lookahead = nil
            } else {
                candidate = output.copyNextSampleBuffer()
            }

            guard let candidate else { return current }
            let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(candidate))
            if pts <= seconds + 0.0005 {
                current = candidate
            } else {
                lookahead = candidate
                return current ?? candidate
            }
        }
    }

    func finish() {
        reader.cancelReading()
        current = nil
        lookahead = nil
    }
}

// MARK: - GIF

public enum GifExporter {
    public static func convert(
        movieURL: URL,
        outputURL: URL,
        fps: Int,
        maxWidth: Int
    ) async throws -> URL {
        let asset = AVURLAsset(url: movieURL)
        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)
        guard durationSeconds.isFinite, durationSeconds > 0 else {
            throw ExportError.gifFailed("The rendered movie is empty.")
        }

        let frameRate = max(min(fps, 30), 5)
        let frameCount = max(Int((durationSeconds * Double(frameRate)).rounded()), 1)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.002, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.002, preferredTimescale: 600)

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            UTType.gif.identifier as CFString,
            frameCount,
            nil
        ) else {
            throw ExportError.gifFailed("Could not create the GIF destination.")
        }

        let loopProperties: [CFString: Any] = [
            kCGImagePropertyGIFLoopCount: 0
        ]
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: loopProperties
        ] as CFDictionary)

        let frameProperties: [CFString: Any] = [
            kCGImagePropertyGIFDelayTime: 1.0 / Double(frameRate),
            kCGImagePropertyGIFUnclampedDelayTime: 1.0 / Double(frameRate)
        ]

        for index in 0..<frameCount {
            try Task.checkCancellation()
            let seconds = min(Double(index) / Double(frameRate), max(durationSeconds - 0.001, 0))
            let requested = CMTime(seconds: seconds, preferredTimescale: 600)
            guard let image = try? await generator.image(at: requested).image else { continue }

            let width = CGFloat(image.width)
            let targetWidth = CGFloat(min(maxWidth, image.width))
            let scale = targetWidth / max(width, 1)
            let targetSize = CGSize(
                width: max((CGFloat(image.width) * scale).rounded(), 1),
                height: max((CGFloat(image.height) * scale).rounded(), 1)
            )

            let resized = resize(image: image, to: targetSize) ?? image
            CGImageDestinationAddImage(destination, resized, [
                kCGImagePropertyGIFDictionary: frameProperties
            ] as CFDictionary)
        }

        guard CGImageDestinationFinalize(destination) else {
            throw ExportError.gifFailed("Could not write the GIF.")
        }
        return outputURL
    }

    private static func resize(image: CGImage, to size: CGSize) -> CGImage? {
        guard size.width > 0, size.height > 0 else { return nil }
        guard let context = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: size))
        return context.makeImage()
    }
}
