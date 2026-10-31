import AVFoundation
import CoreMedia
import Foundation

/// Builds an edited, playable composition for the preview.
///
/// Video and every audio source are cut on the same timeline map (trims + speed),
/// so scrubbing and playback match the exporter exactly.
public enum PreviewCompositionBuilder {
    public static func makeComposition(
        project: ScreenForgeProject,
        bundleURL: URL
    ) async throws -> AVMutableComposition {
        let normalized = project.normalized()
        let map = normalized.timeline.map(sourceDurationMs: normalized.source.durationMs)
        guard map.outputDurationMs > 100 else {
            throw ExportError.readerFailed("The edited video is empty.")
        }

        let composition = AVMutableComposition()
        let screenURL = bundleURL.appendingPathComponent(normalized.source.screenPath)
        guard FileManager.default.fileExists(atPath: screenURL.path) else {
            throw ExportError.missingScreenMedia(normalized.source.screenPath)
        }

        let screenAsset = AVURLAsset(url: screenURL)
        guard let videoSource = try await screenAsset.loadTracks(withMediaType: .video).first else {
            throw ExportError.noVideoTrack
        }
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw ExportError.readerFailed("Could not create a video track.")
        }

        var cursor = CMTime.zero
        for segment in map.segments where segment.rate > 0 && segment.sourceLengthMs > 0 {
            let sourceRange = CMTimeRange(
                start: CMTime(seconds: segment.sourceStartMs / 1000, preferredTimescale: 600),
                duration: CMTime(seconds: segment.sourceLengthMs / 1000, preferredTimescale: 600)
            )
            let outputDuration = CMTime(
                seconds: segment.outputLengthMs / 1000,
                preferredTimescale: 600
            )
            do {
                try videoTrack.insertTimeRange(sourceRange, of: videoSource, at: cursor)
                if abs(segment.rate - 1) > 0.001, outputDuration > .zero {
                    videoTrack.scaleTimeRange(
                        CMTimeRange(start: cursor, duration: sourceRange.duration),
                        toDuration: outputDuration
                    )
                }
                cursor = CMTimeAdd(cursor, outputDuration)
            } catch {
                NSLog("Preview video insert failed: \(error.localizedDescription)")
            }
        }

        guard CMTimeCompare(cursor, .zero) > 0 else {
            throw ExportError.noVideoTrack
        }

        var audioAssets: [AVURLAsset] = []
        if !(try await screenAsset.loadTracks(withMediaType: .audio)).isEmpty {
            audioAssets.append(screenAsset)
        }
        if let micPath = normalized.source.microphonePath {
            let url = bundleURL.appendingPathComponent(micPath)
            if FileManager.default.fileExists(atPath: url.path) {
                audioAssets.append(AVURLAsset(url: url))
            }
        }
        if let systemPath = normalized.source.systemAudioPath {
            let url = bundleURL.appendingPathComponent(systemPath)
            if FileManager.default.fileExists(atPath: url.path) {
                audioAssets.append(AVURLAsset(url: url))
            }
        }

        for asset in audioAssets {
            guard let audioSource = try? await asset.loadTracks(withMediaType: .audio).first,
                  let audioTrack = composition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                  ) else {
                continue
            }

            var audioCursor = CMTime.zero
            var inserted = false
            for segment in map.segments where segment.rate > 0 && segment.sourceLengthMs > 0 {
                let sourceRange = CMTimeRange(
                    start: CMTime(seconds: segment.sourceStartMs / 1000, preferredTimescale: 600),
                    duration: CMTime(seconds: segment.sourceLengthMs / 1000, preferredTimescale: 600)
                )
                let outputDuration = CMTime(
                    seconds: segment.outputLengthMs / 1000,
                    preferredTimescale: 600
                )
                do {
                    try audioTrack.insertTimeRange(sourceRange, of: audioSource, at: audioCursor)
                    if abs(segment.rate - 1) > 0.001, outputDuration > .zero {
                        audioTrack.scaleTimeRange(
                            CMTimeRange(start: audioCursor, duration: sourceRange.duration),
                            toDuration: outputDuration
                        )
                    }
                    audioCursor = CMTimeAdd(audioCursor, outputDuration)
                    inserted = true
                } catch {
                    NSLog("Preview audio insert failed: \(error.localizedDescription)")
                }
            }
            if !inserted {
                composition.removeTrack(audioTrack)
            }
        }

        return composition
    }
}
