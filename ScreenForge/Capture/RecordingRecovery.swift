import AVFoundation
import Foundation

/// Rebuilds projects from recording sessions left behind by a crash or force-quit.
///
/// A session directory is self-describing — segments, a manifest, cursor telemetry, and
/// the microphone/camera files — so a project can be assembled without live capture
/// state. Segments are discovered from the directory as well as the manifest, because a
/// crash can happen between writing a segment and recording it in the manifest.
public enum RecordingRecovery {
    public struct OrphanedSession: Sendable, Equatable {
        public var directory: URL
        public var manifest: RecordingManifest
    }

    public static func sessionsDirectory(in outputDirectory: URL) -> URL {
        outputDirectory.appendingPathComponent("Sessions", isDirectory: true)
    }

    /// Sessions that can be recovered: at least one readable segment on disk.
    public static func recoverableSessions(in outputDirectory: URL) async -> [OrphanedSession] {
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

            let segments = await readableSegments(in: candidate, manifest: manifest)
            guard !segments.isEmpty else { continue }

            var updated = manifest
            updated.segments = segments
            sessions.append(OrphanedSession(directory: candidate, manifest: updated))
        }

        return sessions.sorted { $0.manifest.displayName < $1.manifest.displayName }
    }

    /// Builds a `.sforge` project from an orphaned session and removes the session when
    /// successful.
    @discardableResult
    public static func recover(
        session: OrphanedSession,
        outputDirectory: URL
    ) async throws -> URL {
        let cursorURL = session.directory.appendingPathComponent(ProjectBundleLayout.cursorFileName)
        let samples = (try? CursorJSONL.load(from: cursorURL)) ?? []
        let markerURL = session.directory.appendingPathComponent("markers.json")
        let markers = (try? Data(contentsOf: markerURL))
            .flatMap { try? JSONDecoder().decode([TimelineMarker].self, from: $0) } ?? []

        let name = "\(session.manifest.displayName) (Recovered)"
        let result = try await RecordingFinalizer.makeProject(
            sessionDirectory: session.directory,
            manifest: session.manifest,
            cursorSamples: samples,
            pauses: session.manifest.pauses,
            markers: markers,
            outputDirectory: outputDirectory,
            projectName: name
        )
        return result.projectBundleURL
    }

    /// Recovers everything that can be recovered. Returns the new project URLs.
    public static func recoverAll(in outputDirectory: URL) async -> [URL] {
        var recovered: [URL] = []
        for session in await recoverableSessions(in: outputDirectory) {
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

    // MARK: Segments

    /// Manifest segments that still exist, plus any `screen*.seg-NNNN.mov` files the
    /// manifest does not know about (written after the last manifest update).
    private static func readableSegments(
        in sessionDirectory: URL,
        manifest: RecordingManifest
    ) async -> [RecordingSegment] {
        var segments: [RecordingSegment] = []
        var known = Set<String>()

        for segment in manifest.segments {
            let url = sessionDirectory.appendingPathComponent(segment.fileName)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            known.insert(segment.fileName)
            segments.append(segment)
        }

        let discovered = (try? FileManager.default.contentsOfDirectory(
            at: sessionDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        for url in discovered.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = url.lastPathComponent
            guard name.contains(".seg-"), name.hasSuffix(".mov"), !known.contains(name) else { continue }

            // Unfinalized files have no duration and are skipped rather than failing the
            // whole recovery.
            let asset = AVURLAsset(url: url)
            guard let duration = try? await asset.load(.duration),
                  CMTimeGetSeconds(duration) > 0.05 else {
                continue
            }
            segments.append(RecordingSegment(
                fileName: name,
                startMs: 0,
                durationMs: Int((CMTimeGetSeconds(duration) * 1000).rounded())
            ))
        }

        return segments
    }

    private static func loadManifest(in sessionDirectory: URL) -> RecordingManifest? {
        let url = sessionDirectory.appendingPathComponent("screen.manifest.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(RecordingManifest.self, from: data)
    }
}
