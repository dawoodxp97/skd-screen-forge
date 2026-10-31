import AVFoundation
import CoreVideo
import Foundation
import Testing
@testable import ScreenForge

@Suite("Recording recovery")
struct RecordingRecoveryTests {
    private func writeSegment(to url: URL, seconds: Double) throws {
        let size = 160
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: size,
                AVVideoHeightKey: size
            ]
        )
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: size,
                kCVPixelBufferHeightKey as String: size
            ]
        )
        #expect(writer.canAdd(input))
        writer.add(input)
        #expect(writer.startWriting())
        // Crash-safe segments are anchored to the host clock.
        let anchor = 5_000.0
        writer.startSession(atSourceTime: CMTime(seconds: anchor, preferredTimescale: 600))
        let pool = try #require(adaptor.pixelBufferPool)
        for frame in 0..<Int(seconds * 30) {
            while !input.isReadyForMoreMediaData { usleep(500) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
            let pixelBuffer = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
                let bytes = base.assumingMemoryBound(to: UInt8.self)
                for index in stride(from: 0, to: CVPixelBufferGetDataSize(pixelBuffer), by: 4) {
                    bytes[index] = 40
                    bytes[index + 3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            adaptor.append(
                pixelBuffer,
                withPresentationTime: CMTime(seconds: anchor + Double(frame) / 30, preferredTimescale: 600)
            )
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        #expect(writer.status == .completed)
    }

    @Test("An orphaned session becomes a playable project")
    func recoverSession() async throws {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenForgeRecovery-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: output) }

        let sessions = RecordingRecovery.sessionsDirectory(in: output)
        let session = sessions.appendingPathComponent("2026-10-31 at 10.00.00 Demo", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)

        let segmentName = "screen.seg-0001.mov"
        try writeSegment(to: session.appendingPathComponent(segmentName), seconds: 1.0)
        try CursorJSONL.encode([
            CursorSample(timeMs: 0, x: 0.2, y: 0.2),
            CursorSample(timeMs: 500, x: 0.6, y: 0.6, interaction: .click)
        ]).write(to: session.appendingPathComponent(ProjectBundleLayout.cursorFileName))

        let manifest = RecordingManifest(
            sessionID: UUID(),
            displayName: "Demo",
            pixelWidth: 160,
            pixelHeight: 160,
            scale: 1,
            fps: 30,
            hasSystemAudio: false,
            hasMicrophone: false,
            segments: [RecordingSegment(fileName: segmentName, startMs: 5_000_000, durationMs: 1_000)],
            state: .recording
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: session.appendingPathComponent("screen.manifest.json"),
            options: .atomic
        )

        let orphans = await RecordingRecovery.recoverableSessions(in: output)
        #expect(orphans.count == 1)
        #expect(orphans[0].manifest.displayName == "Demo")

        let recovered = await RecordingRecovery.recoverAll(in: output)
        #expect(recovered.count == 1)

        let bundle = try #require(recovered.first)
        #expect(bundle.lastPathComponent.contains("Recovered"))

        let project = try await ProjectStore.shared.load(from: bundle)
        #expect(abs(project.source.durationMs - 1_000) < 120, "duration=\(project.source.durationMs)")
        #expect(project.source.pixelWidth == 160)

        let cursors = try await ProjectStore.shared.loadCursor(from: bundle)
        #expect(cursors.count == 2)

        // The session is consumed, so a second pass finds nothing.
        #expect(await RecordingRecovery.recoverableSessions(in: output).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: session.path))
    }

    @Test("Segments missing from the manifest are still recovered")
    func recoversUnlistedSegment() async throws {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenForgeRecovery-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: output) }

        let session = RecordingRecovery.sessionsDirectory(in: output)
            .appendingPathComponent("Crash", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)

        // The manifest was written before the segment finished; the file exists on disk.
        let segmentName = "screen.seg-0001.mov"
        try writeSegment(to: session.appendingPathComponent(segmentName), seconds: 0.8)

        let manifest = RecordingManifest(
            sessionID: UUID(),
            displayName: "Crash",
            pixelWidth: 160,
            pixelHeight: 160,
            scale: 1,
            fps: 30,
            hasSystemAudio: false,
            hasMicrophone: false,
            segments: [],
            state: .recording
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: session.appendingPathComponent("screen.manifest.json"),
            options: .atomic
        )

        let orphans = await RecordingRecovery.recoverableSessions(in: output)
        #expect(orphans.count == 1)
        #expect(orphans[0].manifest.segments.map(\.fileName) == [segmentName])

        let recovered = await RecordingRecovery.recoverAll(in: output)
        #expect(recovered.count == 1)

        let bundle = try #require(recovered.first)
        let project = try await ProjectStore.shared.load(from: bundle)
        #expect(abs(project.source.durationMs - 800) < 120)
    }

    @Test("Sessions without segments are not offered for recovery")
    func skipsEmptySessions() async throws {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenForgeRecovery-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: output) }

        let session = RecordingRecovery.sessionsDirectory(in: output)
            .appendingPathComponent("Empty", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)

        let manifest = RecordingManifest(
            sessionID: UUID(),
            displayName: "Empty",
            pixelWidth: 160,
            pixelHeight: 160,
            scale: 1,
            fps: 30,
            hasSystemAudio: false,
            hasMicrophone: false,
            segments: []
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: session.appendingPathComponent("screen.manifest.json"),
            options: .atomic
        )

        #expect(await RecordingRecovery.recoverableSessions(in: output).isEmpty)
    }
}
