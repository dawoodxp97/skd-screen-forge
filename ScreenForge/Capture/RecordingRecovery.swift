import Foundation

/// Rebuilds projects from recording sessions left behind by a crash or force-quit.
///
/// A session directory is self-describing — finalized segments, a manifest, cursor
/// telemetry, and the microphone/camera files — so a project can be assembled without
/// any live capture state.
public enum RecordingRecovery {
    public struct OrphanedSession: Sendable, Equatable {
        public var directory: URL
        public var manifest: RecordingManifest
    }

    public static func sessionsDirectory(in outputDirectory: URL) -> URL {
        outputDirectory.appendingPathComponent("Sessions", isDirectory: true)
    }

    /// Sessions that can be recovered: a decodable manifest with at least one segment
    /// whose file still exists on disk.
    public static func recoverableSessions(in outputDirectory: URL) -> [OrphanedSession] {
        let directory = sessionsDirectory(in: outputDirectory)
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var sessions: [OrphanedSession] = []
        for candidate in contents {
            let values = try? candidate.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else { continue }
            guard let manifest = loadManifest(in: candidate) else { continue }
            guard manifest.state != .failed else { continue }
            let existing = manifest.segments.filter {
                FileManager.default.fileExists(atPath: candidate.appendingPathComponent($0.fileName).path)
            }
            guard !existing.isEmpty else { continue }

            var updated = manifest
            updated.segments = existing
            sessions.append(OrphanedSession(directory: candidate, manifest: updated))
        }

        return sessions.sorted { $0.manifest.displayName < $1.manifest.displayName }
    }

    /// Builds a `.sforge` project from an orphaned session and removes the session when
    /// successful. Already-recovered sessions simply disappear from `recoverableSessions`.
    @discardableResult
    public static func recover(
        session: OrphanedSession,
        outputDirectory: URL
    ) async throws -> URL {
        let cursorURL = session.directory.appendingPathComponent(ProjectBundleLayout.cursorFileName)
        let samples = (try? CursorJSONL.load(from: cursorURL)) ?? []

        let name = "\(session.manifest.displayName) (Recovered)"
        let result = try await RecordingFinalizer.makeProject(
            sessionDirectory: session.directory,
            manifest: session.manifest,
            cursorSamples: samples,
            pauses: session.manifest.pauses,
            outputDirectory: outputDirectory,
            projectName: name
        )
        return result.projectBundleURL
    }

    /// Recovers everything that can be recovered. Returns the new project URLs.
    public static func recoverAll(in outputDirectory: URL) async -> [URL] {
        var recovered: [URL] = []
        for session in recoverableSessions(in: outputDirectory) {
            do {
                let url = try await recover(session: session, outputDirectory: outputDirectory)
                recovered.append(url)
            } catch {
                NSLog(
                    "Could not recover \(session.directory.lastPathComponent): \(error.localizedDescription)"
                )
            }
        }
        return recovered
    }

    // MARK: Private

    private static func loadManifest(in sessionDirectory: URL) -> RecordingManifest? {
        let url = sessionDirectory.appendingPathComponent("screen.manifest.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(RecordingManifest.self, from: data)
    }
}
