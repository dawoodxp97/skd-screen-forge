import AppKit
import AVFoundation
import Foundation
import SwiftUI
import Testing
@testable import ScreenForge

/// Renders the SwiftUI screens offscreen.
///
/// This catches crashes and layout failures in the view tree without needing Screen
/// Recording permission (nothing is captured from the display). Only meaningful when
/// hosted by the app, where Metal and the shader library are available.
@MainActor
@Suite("App UI")
struct AppUISmokeTests {
    private var isHosted: Bool {
        Bundle.main.bundleIdentifier == "studio.screenforge.app"
    }

    @Test("Recorder screen renders visible content")
    func recorderRenders() throws {
        guard isHosted else { return }

        let app = AppState()
        let colors = try renderOffscreen(
            RecorderView()
                .environmentObject(app)
                .frame(width: 1_280, height: 820)
        )
        #expect(colors > 8, "Recorder view rendered only \(colors) distinct colors")
    }

    @Test("Editor screen renders with a document")
    func editorRenders() throws {
        guard isHosted else { return }

        let app = AppState()
        let bundle = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenForgeUI-\(UUID().uuidString).sforge", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: bundle) }

        let project = ScreenForgeProject(
            source: SourceInfo(
                screenPath: "media/screen.mov",
                durationMs: 12_000,
                pixelWidth: 1920,
                pixelHeight: 1080
            ),
            timeline: Timeline(zooms: [ZoomRegion(startMs: 1_000, endMs: 3_000, scale: 2)])
        )
        let document = ProjectDocument(
            bundleURL: bundle,
            project: project,
            cursorSamples: [],
            compositor: app.compositor,
            transcript: TranscriptDocument(words: [
                TranscriptWord(text: "Hello", startMs: 1_000, endMs: 1_400),
                TranscriptWord(text: "world", startMs: 1_450, endMs: 1_800)
            ])
        )

        let colors = try renderOffscreen(
            EditorView(document: document)
                .environmentObject(app)
                .frame(width: 1_320, height: 860)
        )
        #expect(colors > 8, "Editor view rendered only \(colors) distinct colors")
    }

    @Test("Importing a video opens the editor and exports from it")
    func importThenExport() async throws {
        guard isHosted else { return }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenForgeFlow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let movie = directory.appendingPathComponent("flow.mov")
        try writeMovie(to: movie, seconds: 0.8, size: 240)

        let app = AppState()
        await app.importVideo(from: movie)
        #expect(app.mode == .editor)
        let document = try #require(app.document)
        #expect(abs(document.outputDurationMs - 800) < 150)

        let output = directory.appendingPathComponent("flow-out.mp4")
        _ = try await document.export(to: output, format: .mp4) { _ in }
        #expect(FileManager.default.fileExists(atPath: output.path))

        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration)
        #expect(CMTimeGetSeconds(duration) > 0.5)
    }

    /// Minimal H.264 writer used by the flow test.
    private func writeMovie(to url: URL, seconds: Double, size: Int) throws {
        let fps = 30
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
        for frame in 0..<Int(seconds * Double(fps)) {
            while !input.isReadyForMoreMediaData { usleep(500) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
            let pixelBuffer = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
                let bytes = base.assumingMemoryBound(to: UInt8.self)
                for index in stride(from: 0, to: CVPixelBufferGetDataSize(pixelBuffer), by: 4) {
                    bytes[index] = UInt8((frame * 6) % 255)
                    bytes[index + 3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            adaptor.append(
                pixelBuffer,
                withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps))
            )
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        #expect(writer.status == .completed)
    }

    // MARK: - Rendering

    /// SwiftUI builds its content once the hosting view is attached to a window, so
    /// the tests use an offscreen window and spin the run loop before snapshotting.
    private func renderOffscreen<V: View>(_ view: V) throws -> Int {
        let size = NSSize(width: 1_320, height: 860)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black

        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderBack(nil)

        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        hosting.layoutSubtreeIfNeeded()

        defer { window.close() }

        let colors = try renderedColorCount(hosting)
        return colors
    }

    private func renderedColorCount(_ view: NSView) throws -> Int {
        let bounds = view.bounds
        let width = Int(bounds.width)
        let height = Int(bounds.height)
        try #require(width > 10 && height > 10)

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return 0
        }

        view.wantsLayer = true
        view.layoutSubtreeIfNeeded()

        if let layer = view.layer {
            // Layer-backed SwiftUI content does not draw through `draw(_:)`.
            layer.render(in: context)
        } else {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            view.draw(bounds)
            NSGraphicsContext.restoreGraphicsState()
        }

        var seen: Set<UInt32> = []
        for index in stride(from: 0, to: pixels.count, by: 4 * 17) {
            let packed = UInt32(pixels[index]) << 16
                | UInt32(pixels[index + 1]) << 8
                | UInt32(pixels[index + 2])
            seen.insert(packed)
            if seen.count > 64 { break }
        }
        return seen.count
    }
}
