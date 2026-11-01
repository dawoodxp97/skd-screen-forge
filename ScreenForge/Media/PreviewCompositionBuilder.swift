import AVFoundation
import CoreMedia
import Foundation

/// Builds an edited, playable composition for the preview.
///
/// Video and every audio source are cut on the same timeline map (trims + speed),
/// so scrubbing and playback match the exporter exactly.
public enum PreviewCompositionBuilder {
    /// The playable composition plus the mix that applies clip gains, fades, and
    /// ducking. `AVPlayerItem.audioMix` consumes the parameters.
    public struct Preview: @unchecked Sendable {
        public var composition: AVMutableComposition
        public var audioMix: AVMutableAudioMix?

        public init(composition: AVMutableComposition, audioMix: AVMutableAudioMix?) {
            self.composition = composition
            self.audioMix = audioMix
        }
    }

    public static func makeComposition(
        project: ScreenForgeProject,
        bundleURL: URL
    ) async throws -> AVMutableComposition {
        try await makePreview(project: project, bundleURL: bundleURL).composition
    }

    public static func makePreview(
        project: ScreenForgeProject,
        bundleURL: URL
    ) async throws -> Preview {
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

        let mixer = TimelineAudioMixer(project: normalized, bundleURL: bundleURL)
        var inputParameters = await mixer.addRecordedSources(to: composition)
        inputParameters += await mixer.addClips(to: composition)

        let audioMix: AVMutableAudioMix?
        if inputParameters.isEmpty {
            audioMix = nil
        } else {
            let mix = AVMutableAudioMix()
            mix.inputParameters = inputParameters
            audioMix = mix
        }

        return Preview(composition: composition, audioMix: audioMix)
    }
}
