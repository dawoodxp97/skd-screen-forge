import AVFoundation
import CoreVideo
import Foundation
import Testing
@testable import ScreenForge

@Suite("Project import")
struct ProjectImporterTests {
    private func writeMovie(to url: URL, seconds: Double, size: Int) throws {
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
        writer.startSession(atSourceTime: .zero)
        let pool = try #require(adaptor.pixelBufferPool)
        let frames = max(Int(seconds * 30), 1)
        for frame in 0..<frames {
            while !input.isReadyForMoreMediaData { usleep(500) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
            let pixelBuffer = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
                let bytes = base.assumingMemoryBound(to: UInt8.self)
                for index in stride(from: 0, to: CVPixelBufferGetDataSize(pixelBuffer), by: 4) {
                    bytes[index] = 90
                    bytes[index + 3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        #expect(writer.status == .completed)
    }

    @Test("Importing a movie creates a project pointing at a portable media copy")
    func importMovie() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenForgeImport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let movie = directory.appendingPathComponent("Keynote Export.mov")
        try writeMovie(to: movie, seconds: 1.0, size: 480)

        let bundle = try await ProjectImporter.createProject(from: movie, in: directory)
        defer { try? FileManager.default.removeItem(at: bundle) }

        #expect(bundle.pathExtension == "sforge")

        let store = ProjectStore.shared
        let project = try await store.load(from: bundle)
        #expect(abs(project.source.durationMs - 1_000) < 120)
        #expect(project.source.pixelWidth == 480)
        #expect(project.source.pixelHeight == 480)
        #expect(project.source.cursorCaptureMode == .bakedIn)
        #expect(!project.cursor.visible)

        let media = bundle.appendingPathComponent(project.source.screenPath)
        #expect(FileManager.default.fileExists(atPath: media.path))

        // The preview can be built from imported footage.
        let composition = try await PreviewCompositionBuilder.makeComposition(
            project: project,
            bundleURL: bundle
        )
        #expect(CMTimeGetSeconds(composition.duration) > 0.5)
    }

    @Test("A second import with the same name does not overwrite the first")
    func uniqueNames() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenForgeImport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let movie = directory.appendingPathComponent("demo.mov")
        try writeMovie(to: movie, seconds: 0.5, size: 160)

        let first = try await ProjectImporter.createProject(from: movie, in: directory)
        let second = try await ProjectImporter.createProject(from: movie, in: directory)
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }

        #expect(first.lastPathComponent != second.lastPathComponent)
        #expect(FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: second.path))
    }

    @Test("A non-video file is rejected")
    func rejectsNonVideo() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenForgeImport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let text = directory.appendingPathComponent("notes.mov")
        try "not a movie".write(to: text, atomically: true, encoding: .utf8)

        await #expect(throws: (any Error).self) {
            _ = try await ProjectImporter.createProject(from: text, in: directory)
        }
    }
}
