import Foundation

// MARK: - Errors

public enum ProjectError: LocalizedError, Sendable {
    case missingProjectFile(URL)
    case unsupportedSchema(Int)
    case invalidBundle(URL)
    case mediaMissing(String)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingProjectFile(let url):
            "No project.json found in \(url.lastPathComponent)."
        case .unsupportedSchema(let version):
            "This project was created by a newer version (schema \(version)). Please update ScreenForge."
        case .invalidBundle(let url):
            "\(url.lastPathComponent) is not a valid ScreenForge project."
        case .mediaMissing(let path):
            "Missing media file: \(path). Use Relink Media to locate it."
        case .writeFailed(let reason):
            "Could not write the project: \(reason)"
        }
    }
}

// MARK: - Bundle layout

public enum ProjectBundleLayout {
    public static let projectFileName = "project.json"
    public static let mediaDirectory = "media"
    public static let cursorFileName = "cursor.jsonl"
    public static let transcriptFileName = "transcript.json"
    public static let thumbnailsDirectory = "thumbnails"
    public static let fileExtension = "sforge"
}

// MARK: - Schema header + date coding

/// ISO-8601 with fractional seconds, falling back to second precision on read.
///
/// Plain `.iso8601` drops sub-second precision, which makes `updatedAt` comparisons
/// (autosave, conflict detection) unreliable, so the codec uses these helpers.
public enum ISO8601Coding {
    public static func string(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    public static func date(from string: String) -> Date? {
        let precise = ISO8601DateFormatter()
        precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = precise.date(from: string) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }

    static var encoderStrategy: JSONEncoder.DateEncodingStrategy {
        .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(string(from: date))
        }
    }

    static var decoderStrategy: JSONDecoder.DateDecodingStrategy {
        .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = date(from: text) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected an ISO-8601 date, got \(text)"
                )
            }
            return date
        }
    }
}

public enum ProjectCodec {
    private struct SchemaHeader: Decodable {
        let schemaVersion: Int
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = ISO8601Coding.decoderStrategy
        decoder.keyDecodingStrategy = .useDefaultKeys
        return decoder
    }

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = ISO8601Coding.encoderStrategy
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static func decode(_ data: Data) throws -> ScreenForgeProject {
        let decoder = decoder()
        let header = try decoder.decode(SchemaHeader.self, from: data)
        guard header.schemaVersion <= ScreenForgeProject.currentSchemaVersion else {
            throw ProjectError.unsupportedSchema(header.schemaVersion)
        }

        let project = try decoder.decode(ScreenForgeProject.self, from: data)
        return migrateIfNeeded(project).normalized()
    }

    public static func encode(_ project: ScreenForgeProject) throws -> Data {
        try encoder().encode(project)
    }

    /// Schema migrations run oldest → newest. v1 is the initial schema; future
    /// versions add cases here instead of changing the decoder above.
    private static func migrateIfNeeded(_ project: ScreenForgeProject) -> ScreenForgeProject {
        var updated = project
        updated.schemaVersion = ScreenForgeProject.currentSchemaVersion
        return updated
    }
}

// MARK: - Store

/// Reads and writes `.sforge` packages. All disk work happens off the main actor.
public actor ProjectStore {
    public static let shared = ProjectStore()

    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    // MARK: Bundle lifecycle

    /// Creates the package skeleton. Safe to call on an existing bundle.
    public func createBundle(at bundleURL: URL) throws {
        do {
            try fileManager.createDirectory(at: bundleURL, withIntermediateDirectories: true)
            try fileManager.createDirectory(
                at: bundleURL.appendingPathComponent(ProjectBundleLayout.mediaDirectory, isDirectory: true),
                withIntermediateDirectories: true
            )
            try fileManager.createDirectory(
                at: bundleURL.appendingPathComponent(ProjectBundleLayout.thumbnailsDirectory, isDirectory: true),
                withIntermediateDirectories: true
            )
        } catch {
            throw ProjectError.writeFailed(error.localizedDescription)
        }
    }

    // MARK: Project JSON

    public func load(from bundleURL: URL) throws -> ScreenForgeProject {
        guard fileManager.fileExists(atPath: bundleURL.path) else {
            throw ProjectError.invalidBundle(bundleURL)
        }
        let projectURL = bundleURL.appendingPathComponent(ProjectBundleLayout.projectFileName)
        guard fileManager.fileExists(atPath: projectURL.path) else {
            throw ProjectError.missingProjectFile(bundleURL)
        }
        let data = try Data(contentsOf: projectURL)
        return try ProjectCodec.decode(data)
    }

    public func save(_ project: ScreenForgeProject, to bundleURL: URL) throws {
        try createBundle(at: bundleURL)
        var clean = project.normalized()
        clean.updatedAt = Date()
        let data = try ProjectCodec.encode(clean)
        let projectURL = bundleURL.appendingPathComponent(ProjectBundleLayout.projectFileName)

        do {
            try data.write(to: projectURL, options: .atomic)
        } catch {
            throw ProjectError.writeFailed(error.localizedDescription)
        }
    }

    // MARK: Media

    /// Copies media into the bundle and returns its bundle-relative path.
    @discardableResult
    public func importMedia(
        from sourceURL: URL,
        into bundleURL: URL,
        preferredName: String? = nil
    ) throws -> String {
        try createBundle(at: bundleURL)
        let name = preferredName ?? sourceURL.lastPathComponent
        let destination = bundleURL
            .appendingPathComponent(ProjectBundleLayout.mediaDirectory, isDirectory: true)
            .appendingPathComponent(name)

        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        do {
            try fileManager.copyItem(at: sourceURL, to: destination)
        } catch {
            throw ProjectError.writeFailed(error.localizedDescription)
        }
        return "\(ProjectBundleLayout.mediaDirectory)/\(name)"
    }

    public func mediaURL(for relativePath: String, in bundleURL: URL) -> URL {
        bundleURL.appendingPathComponent(relativePath)
    }

    public func verifyMedia(of project: ScreenForgeProject, in bundleURL: URL) throws {
        let required = [
            project.source.screenPath,
            project.source.webcamPath,
            project.source.systemAudioPath,
            project.source.microphonePath
        ].compactMap { $0 }
        for path in required where !fileManager.fileExists(
            atPath: mediaURL(for: path, in: bundleURL).path
        ) {
            throw ProjectError.mediaMissing(path)
        }
    }

    // MARK: Cursor

    public func writeCursor(_ samples: [CursorSample], to bundleURL: URL) throws {
        let url = bundleURL.appendingPathComponent(ProjectBundleLayout.cursorFileName)
        try CursorJSONL.encode(samples).write(to: url, options: .atomic)
    }

    public func loadCursor(from bundleURL: URL) throws -> [CursorSample] {
        let url = bundleURL.appendingPathComponent(ProjectBundleLayout.cursorFileName)
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        return try CursorJSONL.load(from: url)
    }

    // MARK: Transcript

    public func writeTranscript(_ transcript: TranscriptDocument, to bundleURL: URL) throws {
        try createBundle(at: bundleURL)
        let url = bundleURL.appendingPathComponent(ProjectBundleLayout.transcriptFileName)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = ISO8601Coding.encoderStrategy
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try encoder.encode(transcript).write(to: url, options: .atomic)
        } catch {
            throw ProjectError.writeFailed(error.localizedDescription)
        }
    }

    public func loadTranscript(from bundleURL: URL) throws -> TranscriptDocument? {
        let url = bundleURL.appendingPathComponent(ProjectBundleLayout.transcriptFileName)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = ISO8601Coding.decoderStrategy
        return try decoder.decode(TranscriptDocument.self, from: Data(contentsOf: url))
    }
}
