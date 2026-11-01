import Foundation

/// A saved look: canvas, camera, cursor, captions, audio mix, and export defaults.
///
/// Presets are stored as JSON in `Application Support/ScreenForge/Presets` so they can
/// be shared as files and survive project deletion.
public struct ProjectPreset: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var canvas: CanvasSettings
    public var camera: CameraSettings
    public var cursor: CursorSettings
    public var captions: CaptionSettings
    public var audio: AudioMixSettings
    public var export: ExportSettings

    public init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = Date(),
        canvas: CanvasSettings,
        camera: CameraSettings,
        cursor: CursorSettings,
        captions: CaptionSettings,
        audio: AudioMixSettings,
        export: ExportSettings
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.canvas = canvas
        self.camera = camera
        self.cursor = cursor
        self.captions = captions
        self.audio = audio
        self.export = export
    }

    public init(name: String, project: ScreenForgeProject) {
        self.init(
            name: name,
            canvas: project.canvas,
            camera: project.camera,
            cursor: project.cursor,
            captions: project.captions,
            audio: project.audio,
            export: project.export
        )
    }

    /// Applies the preset's look while keeping the project's media and timeline.
    public func apply(to project: inout ScreenForgeProject) {
        project.canvas = canvas
        project.camera = camera
        project.cursor = cursor
        project.captions = captions
        project.audio = audio
        project.export = export
    }
}

public actor ProjectPresetStore {
    public static let shared = ProjectPresetStore()

    private let fileManager: FileManager
    private let directoryURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileManager: FileManager = .default, directory: URL? = nil) {
        self.fileManager = fileManager
        if let directory {
            self.directoryURL = directory
        } else {
            let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.temporaryDirectory
            self.directoryURL = base
                .appendingPathComponent("ScreenForge", isDirectory: true)
                .appendingPathComponent("Presets", isDirectory: true)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = ISO8601Coding.encoderStrategy
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = ISO8601Coding.decoderStrategy
        self.decoder = decoder
    }

    public nonisolated var directory: URL { directoryURL }

    public func list() -> [ProjectPreset] {
        let urls = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(ProjectPreset.self, from: data)
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    @discardableResult
    public func save(_ preset: ProjectPreset) throws -> URL {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let safeName = preset.name
            .replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let url = directory.appendingPathComponent("\(safeName.isEmpty ? preset.id.uuidString : safeName).json")
        let data = try encoder.encode(preset)
        try data.write(to: url, options: .atomic)
        return url
    }

    public func delete(id: UUID) {
        let urls = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        for url in urls where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let preset = try? decoder.decode(ProjectPreset.self, from: data),
                  preset.id == id else { continue }
            try? fileManager.removeItem(at: url)
        }
    }

    public func rename(id: UUID, to newName: String) throws {
        guard var preset = list().first(where: { $0.id == id }) else { return }
        delete(id: id)
        preset.name = newName
        try save(preset)
    }
}
