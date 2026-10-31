import AVFoundation
import CoreGraphics
import Foundation

public enum ImportError: LocalizedError, Sendable {
    case unreadableMedia(String)
    case noVideoTrack
    case copyFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unreadableMedia(let name):
            "\(name) could not be read as a video."
        case .noVideoTrack:
            "The selected file has no video track."
        case .copyFailed(let reason):
            "Could not import the video: \(reason)"
        }
    }
}

/// Creates a ScreenForge project from any existing video file.
///
/// The imported file becomes the project's screen track, so every editor feature
/// (zooms, trims, cursor-free compositing, captions) works on external footage —
/// including phone recordings and footage captured by another tool.
public enum ProjectImporter {
    public struct ImportedMedia: Sendable {
        public var durationMs: Int
        public var pixelWidth: Int
        public var pixelHeight: Int
        public var frameRate: Double
        public var hasAudio: Bool
    }

    public static func probe(url: URL) async throws -> ImportedMedia {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else {
            throw ImportError.noVideoTrack
        }
        guard let duration = try? await asset.load(.duration) else {
            throw ImportError.unreadableMedia(url.lastPathComponent)
        }

        let natural = (try? await track.load(.naturalSize)) ?? CGSize(width: 1920, height: 1080)
        let transform = (try? await track.load(.preferredTransform)) ?? .identity
        let transformed = natural.applying(transform)
        let width = Int(abs(transformed.width).rounded())
        let height = Int(abs(transformed.height).rounded())
        guard width > 0, height > 0 else { throw ImportError.unreadableMedia(url.lastPathComponent) }

        let fps = Double((try? await track.load(.nominalFrameRate)) ?? 30)
        let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        let hasAudio = !audioTracks.isEmpty

        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite, seconds > 0 else {
            throw ImportError.unreadableMedia(url.lastPathComponent)
        }

        return ImportedMedia(
            durationMs: Int((seconds * 1000).rounded()),
            pixelWidth: width,
            pixelHeight: height,
            frameRate: fps > 0 ? fps : 30,
            hasAudio: hasAudio
        )
    }

    /// Copies `mediaURL` into a new `.sforge` bundle inside `directory` and writes the
    /// project document. Returns the bundle URL.
    @discardableResult
    public static func createProject(
        from mediaURL: URL,
        in directory: URL,
        name: String? = nil
    ) async throws -> URL {
        let media = try await probe(url: mediaURL)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let baseName = sanitize(
            name ?? mediaURL.deletingPathExtension().lastPathComponent
        )
        let bundle = uniqueBundleURL(in: directory, name: baseName)

        let store = ProjectStore.shared
        try await store.createBundle(at: bundle)

        let fileName = "screen.\(mediaURL.pathExtension.isEmpty ? "mov" : mediaURL.pathExtension)"
        let relativePath: String
        do {
            relativePath = try await store.importMedia(
                from: mediaURL,
                into: bundle,
                preferredName: fileName
            )
        } catch {
            try? FileManager.default.removeItem(at: bundle)
            throw ImportError.copyFailed(error.localizedDescription)
        }

        let source = SourceInfo(
            screenPath: relativePath,
            webcamPath: nil,
            systemAudioPath: nil,
            microphonePath: nil,
            durationMs: media.durationMs,
            pixelWidth: media.pixelWidth,
            pixelHeight: media.pixelHeight,
            scale: 1,
            displayName: mediaURL.deletingPathExtension().lastPathComponent,
            cursorCaptureMode: .bakedIn
        )

        var project = ScreenForgeProject(source: source)
        project.cursor.visible = false
        project.export.fps = [24, 30, 60].contains(Int(media.frameRate.rounded()))
            ? Int(media.frameRate.rounded())
            : 30

        try await store.save(project, to: bundle)
        return bundle
    }

    // MARK: Naming

    static func sanitize(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        let cleaned = name.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "-" }
        let result = String(cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? "Imported Video" : String(result.prefix(60))
    }

    static func uniqueBundleURL(in directory: URL, name: String) -> URL {
        var candidate = directory
            .appendingPathComponent("\(name).\(ProjectBundleLayout.fileExtension)", isDirectory: true)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent(
                "\(name) \(index).\(ProjectBundleLayout.fileExtension)",
                isDirectory: true
            )
            index += 1
        }
        return candidate
    }
}
