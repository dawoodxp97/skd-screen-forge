import AVFoundation
import Foundation

/// Places recorded sources and timeline audio clips into a composition on **output**
/// time, with per-source gain, clip fades, and music ducking.
///
/// Preview and export both call this, so what you hear while editing is exactly what
/// the encoder writes.
public struct TimelineAudioMixer: Sendable {
    public let project: ScreenForgeProject
    public let bundleURL: URL
    public let map: TimelineMap
    public let mix: AudioMixSettings

    /// Voiceover spans in seconds, used to duck music.
    public let voiceIntervals: [(start: Double, end: Double)]

    private static let duckAttack = 0.12
    private static let duckRelease = 0.18

    public init(project: ScreenForgeProject, bundleURL: URL) {
        let normalized = project.normalized()
        self.project = normalized
        self.bundleURL = bundleURL
        self.map = normalized.timeline.map(sourceDurationMs: normalized.source.durationMs)
        self.mix = normalized.audio
        self.voiceIntervals = normalized.timeline.audioClips
            .filter { $0.kind == .voiceover && !$0.muted && $0.durationMs > 0 }
            .map { (Double($0.startMs) / 1000, Double($0.endMs) / 1000) }
    }

    // MARK: - Recorded sources

    /// Adds the system/microphone tracks. Returns one set of mix parameters per
    /// inserted track.
    public func addRecordedSources(to composition: AVMutableComposition) async -> [AVMutableAudioMixInputParameters] {
        var parameters: [AVMutableAudioMixInputParameters] = []

        // A separately captured system track wins; otherwise the screen recording's
        // own audio track contains system sound.
        if let systemPath = project.source.systemAudioPath {
            if let params = await addMappedSource(
                bundleURL.appendingPathComponent(systemPath),
                gain: mix.systemVolume,
                to: composition
            ) {
                parameters.append(params)
            }
        } else if let params = await addMappedSource(
            bundleURL.appendingPathComponent(project.source.screenPath),
            gain: mix.systemVolume,
            to: composition
        ) {
            parameters.append(params)
        }

        if let micPath = project.source.microphonePath {
            var micURL = bundleURL.appendingPathComponent(micPath)
            if mix.voiceEnhancement != .off {
                let options = VoiceEnhancer.Options(
                    mode: mix.voiceEnhancement,
                    noiseReduction: mix.noiseReduction
                )
                if let enhanced = try? await VoiceEnhancer.cachedEnhanced(input: micURL, options: options) {
                    micURL = enhanced
                }
            }
            if let params = await addMappedSource(
                micURL,
                gain: mix.microphoneVolume,
                to: composition
            ) {
                parameters.append(params)
            }
        }
        if let externalPath = project.source.externalAudioPath,
           let params = await addMappedSource(
               bundleURL.appendingPathComponent(externalPath),
               gain: mix.externalVolume,
               to: composition
           ) {
            parameters.append(params)
        }

        return parameters
    }

    /// Inserts a full-length source through the trim/speed map. Returns nil when the
    /// file is missing or produced no usable audio.
    private func addMappedSource(
        _ url: URL,
        gain: Double,
        to composition: AVMutableComposition
    ) async -> AVMutableAudioMixInputParameters? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let asset = AVURLAsset(url: url)
        guard let sourceTrack = try? await asset.loadTracks(withMediaType: .audio).first,
              let outputTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
              ) else {
            return nil
        }

        var cursor = CMTime.zero
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
                try outputTrack.insertTimeRange(sourceRange, of: sourceTrack, at: cursor)
                if abs(segment.rate - 1) > 0.001, outputDuration > .zero {
                    outputTrack.scaleTimeRange(
                        CMTimeRange(start: cursor, duration: sourceRange.duration),
                        toDuration: outputDuration
                    )
                }
                cursor = CMTimeAdd(cursor, outputDuration)
                inserted = true
            } catch {
                NSLog("Audio insert failed (\(segment.sourceStartMs)–\(segment.sourceEndMs)): \(error.localizedDescription)")
            }
        }

        guard inserted else {
            composition.removeTrack(outputTrack)
            return nil
        }

        let parameters = AVMutableAudioMixInputParameters(track: outputTrack)
        parameters.setVolume(Float(min(max(gain, 0), 2)), at: .zero)
        return parameters
    }

    // MARK: - Clips

    /// Adds every music, sound-effect, voiceover, and external clip.
    public func addClips(to composition: AVMutableComposition) async -> [AVMutableAudioMixInputParameters] {
        var parameters: [AVMutableAudioMixInputParameters] = []
        for clip in project.timeline.audioClips
        where !clip.muted && clip.durationMs > 0 && !clip.path.isEmpty {
            if let params = await addClip(clip, to: composition) {
                parameters.append(params)
            }
        }
        return parameters
    }

    private func addClip(
        _ clip: AudioClip,
        to composition: AVMutableComposition
    ) async -> AVMutableAudioMixInputParameters? {
        let url = bundleURL.appendingPathComponent(clip.path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let asset = AVURLAsset(url: url)
        guard let sourceTrack = try? await asset.loadTracks(withMediaType: .audio).first,
              let outputTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
              ) else {
            return nil
        }

        let assetDuration = try? await asset.load(.duration)
        let assetSeconds = max(CMTimeGetSeconds(assetDuration ?? .zero), 0)
        guard assetSeconds > 0.02 else {
            composition.removeTrack(outputTrack)
            return nil
        }

        let clipStart = Double(clip.startMs) / 1000
        let clipLength = Double(clip.durationMs) / 1000
        var sourceCursor = min(Double(clip.sourceStartMs) / 1000, max(assetSeconds - 0.01, 0))
        var insertAt = clipStart
        var remaining = clipLength
        var inserted = false

        while remaining > 0.005 {
            let available = max(assetSeconds - sourceCursor, 0)
            if available <= 0.01 {
                guard clip.loops else { break }
                sourceCursor = 0
                continue
            }
            let take = min(remaining, available)
            do {
                try outputTrack.insertTimeRange(
                    CMTimeRange(
                        start: CMTime(seconds: sourceCursor, preferredTimescale: 600),
                        duration: CMTime(seconds: take, preferredTimescale: 600)
                    ),
                    of: sourceTrack,
                    at: CMTime(seconds: insertAt, preferredTimescale: 600)
                )
                inserted = true
                insertAt += take
                remaining -= take
                sourceCursor = take < available ? sourceCursor + take : (clip.loops ? 0 : assetSeconds)
            } catch {
                NSLog("Audio clip insert failed: \(error.localizedDescription)")
                break
            }
        }

        guard inserted else {
            composition.removeTrack(outputTrack)
            return nil
        }

        let parameters = AVMutableAudioMixInputParameters(track: outputTrack)
        applyEnvelope(for: clip, to: parameters)
        return parameters
    }

    // MARK: - Envelope

    private func applyEnvelope(
        for clip: AudioClip,
        to parameters: AVMutableAudioMixInputParameters
    ) {
        let clipStart = Double(clip.startMs) / 1000
        let clipLength = Double(clip.durationMs) / 1000
        let end = clipStart + clipLength
        let gain = min(max(clip.volume, 0), 2) * mix.gain(for: clip.kind)
        let fadeIn = Double(clip.fadeInMs) / 1000
        let fadeOut = Double(clip.fadeOutMs) / 1000
        let ducks = clip.kind == .music

        func envelope(at time: Double) -> Double {
            var value = gain
            if fadeIn > 0 {
                value *= min(max((time - clipStart) / fadeIn, 0), 1)
            }
            if fadeOut > 0 {
                value *= min(max((end - time) / fadeOut, 0), 1)
            }
            value *= duckMultiplier(at: time, enabled: ducks)
            return min(max(value, 0), 2)
        }

        var breakpoints: Set<Double> = [clipStart, end]
        if fadeIn > 0 {
            breakpoints.insert(fadeIn < clipLength ? clipStart + fadeIn : end)
        }
        if fadeOut > 0 {
            breakpoints.insert(fadeOut < clipLength ? end - fadeOut : clipStart)
        }
        if ducks && mix.duckMusicUnderVoice {
            for range in voiceIntervals
            where range.end + Self.duckRelease > clipStart && range.start - Self.duckAttack < end {
                breakpoints.insert(min(max(range.start - Self.duckAttack, clipStart), end))
                breakpoints.insert(min(max(range.start, clipStart), end))
                breakpoints.insert(min(max(range.end, clipStart), end))
                breakpoints.insert(min(max(range.end + Self.duckRelease, clipStart), end))
            }
        }

        let sorted = breakpoints.sorted()
        if sorted.count >= 2 {
            for index in 0..<(sorted.count - 1) {
                let start = sorted[index]
                let finish = sorted[index + 1]
                guard finish - start > 0.001 else { continue }
                parameters.setVolumeRamp(
                    fromStartVolume: Float(envelope(at: start)),
                    toEndVolume: Float(envelope(at: finish)),
                    timeRange: CMTimeRange(
                        start: CMTime(seconds: start, preferredTimescale: 600),
                        duration: CMTime(seconds: finish - start, preferredTimescale: 600)
                    )
                )
            }
        } else {
            parameters.setVolume(Float(envelope(at: clipStart)), at: .zero)
        }
    }

    private func duckMultiplier(at time: Double, enabled: Bool) -> Double {
        guard enabled, mix.duckMusicUnderVoice, !voiceIntervals.isEmpty else { return 1 }
        var multiplier = 1.0
        for range in voiceIntervals
        where time >= range.start - Self.duckRelease - Self.duckAttack &&
            time <= range.end + Self.duckRelease + Self.duckAttack {
            let ducked = 1 - mix.duckAmount
            if time < range.start {
                let progress = min(max((time - (range.start - Self.duckAttack)) / Self.duckAttack, 0), 1)
                multiplier = min(multiplier, 1 + (ducked - 1) * progress)
            } else if time <= range.end {
                multiplier = min(multiplier, ducked)
            } else {
                let progress = min(max((time - range.end) / Self.duckRelease, 0), 1)
                multiplier = min(multiplier, ducked + (1 - ducked) * progress)
            }
        }
        return multiplier
    }
}
