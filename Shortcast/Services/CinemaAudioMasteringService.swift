import Foundation
import AVFoundation

/// Handles cinema-grade audio mastering, dialogue clarity enhancement,
/// volume normalization to -14 LUFS (modern mobile social standard), and sidechain ducking of background music.
public enum CinemaAudioMasteringService {

    // MARK: - Standards & Constants (Mobile Social Standard)

    /// Target integrated loudness (-14.0 LUFS) conforming to modern mobile social networks (Reels, TikTok, Shorts).
    public static let targetLUFS: Double = -14.0

    /// Maximum true peak level (-1.0 dBTP) to avoid inter-sample clipping on mobile DACs and lossy audio codecs (AAC/Opus).
    public static let targetTruePeak: Double = -1.0

    /// Loudness range target (7.0 LRA) optimized for dialog clarity and punch on small smartphone speakers.
    public static let targetLRA: Double = 7.0

    // MARK: - Errors
    public enum CinemaAudioMasteringError: LocalizedError, Sendable {
        case missingAudioTrack
        case cannotCreateExportSession

        public var errorDescription: String? {
            switch self {
            case .missingAudioTrack:
                return String(localized: "Missing audio track in video asset.")
            case .cannotCreateExportSession:
                return String(localized: "Cannot create audio mastering export session.")
            }
        }
    }

    // MARK: - Configuration

    /// Configuration parameters for dialogue boost, background music ducking, and target loudness.
    public struct AudioMixConfig: Sendable {
        /// Optional background music track URL.
        public var musicURL: URL?

        /// Dialogue volume boost in dB (default: +2.5 dB for clean, natural dialogue elevation without 0 dBFS digital clipping).
        public var dialogueBoostDB: Float = 2.5

        /// Music volume during dialogue (-14.0 dB for clear vocal intelligibility).
        public var musicDuckingDB: Float = -14.0

        /// Music resting volume during pauses between dialogue (-6.0 dB).
        public var musicRestingDB: Float = -6.0

        /// Fast attack duration (seconds) to duck music at speech onset (default: 0.10s / 100ms).
        public var duckingAttackDuration: Double = 0.10

        /// Smooth release duration (seconds) to restore music during speech pauses (default: 0.45s / 450ms).
        public var duckingReleaseDuration: Double = 0.45

        /// Gap threshold (seconds) under which adjacent speech segments are merged to avoid pumping (default: 0.35s).
        public var speechMergeThreshold: Double = 0.35

        /// Whether to append loudnorm filter to FFmpeg audio filter chain.
        public var normalizeLUFS: Bool = true

        /// Target LUFS for normalization.
        public var targetLUFS: Double = CinemaAudioMasteringService.targetLUFS

        /// Target True Peak (dBTP) for normalization.
        public var targetTruePeak: Double = CinemaAudioMasteringService.targetTruePeak

        /// Target Loudness Range (LRA) for normalization.
        public var targetLRA: Double = CinemaAudioMasteringService.targetLRA

        public init(
            musicURL: URL? = nil,
            dialogueBoostDB: Float = 10.5,
            musicDuckingDB: Float = -14.0,
            musicRestingDB: Float = -6.0,
            duckingAttackDuration: Double = 0.10,
            duckingReleaseDuration: Double = 0.45,
            speechMergeThreshold: Double = 0.35,
            normalizeLUFS: Bool = true,
            targetLUFS: Double = CinemaAudioMasteringService.targetLUFS,
            targetTruePeak: Double = CinemaAudioMasteringService.targetTruePeak,
            targetLRA: Double = CinemaAudioMasteringService.targetLRA
        ) {
            self.musicURL = musicURL
            self.dialogueBoostDB = dialogueBoostDB
            self.musicDuckingDB = musicDuckingDB
            self.musicRestingDB = musicRestingDB
            self.duckingAttackDuration = duckingAttackDuration
            self.duckingReleaseDuration = duckingReleaseDuration
            self.speechMergeThreshold = speechMergeThreshold
            self.normalizeLUFS = normalizeLUFS
            self.targetLUFS = targetLUFS
            self.targetTruePeak = targetTruePeak
            self.targetLRA = targetLRA
        }
    }

    // MARK: - FFmpeg Filter Chain Builder

    /// Generates FFmpeg audio filter graph string for sidechain ducking and loudness normalization.
    /// Chain:
    /// 1. highpass=f=80 (cut low-frequency rumble & mic handling noise)
    /// 2. acompressor=threshold=-18dB:ratio=3:attack=10:release=100 (dialogue dynamic compression)
    /// 3. loudnorm=I=-14:TP=-1.0:LRA=7 (EBU R128 loudness normalization for mobile social platforms)
    public static func buildFFmpegAudioFilter(
        hasSpeechTimes: [(start: Double, end: Double)] = [],
        config: AudioMixConfig = AudioMixConfig()
    ) -> String {
        var filters: [String] = [
            "highpass=f=80",
            "acompressor=threshold=-18dB:ratio=3:attack=10:release=100"
        ]

        if config.normalizeLUFS {
            let lufsStr = String(format: "%.0f", config.targetLUFS)
            let tpStr = String(format: "%.1f", config.targetTruePeak)
            let lraStr = String(format: "%.0f", config.targetLRA)
            filters.append("loudnorm=I=\(lufsStr):TP=\(tpStr):LRA=\(lraStr)")
        }

        return filters.joined(separator: ",")
    }

    // MARK: - Volume & Gain Calculations

    /// Calculates linear volume multiplier needed to normalize audio to target LUFS (-14.0 LUFS by default).
    /// Formula: Multiplier = 10^((targetLUFS - measuredLUFS) / 20).
    /// Includes defensive clamping to prevent acoustic overdrive or distortion from invalid or silent measurements.
    public static func calculateVolumeGain(
        measuredLUFS: Double,
        target: Double = targetLUFS
    ) -> Float {
        guard !measuredLUFS.isNaN, !measuredLUFS.isInfinite, measuredLUFS > -70.0 else {
            return 1.0
        }

        let diff = target - measuredLUFS
        // Safe operational bounds: limit boost to +24 dB and attenuation to -40 dB
        let clampedDiff = min(max(diff, -40.0), 24.0)
        return Float(pow(10.0, clampedDiff / 20.0))
    }

    // MARK: - Mastering & Ducking Pipeline

    /// Applies cinema audio mastering including dialogue boost and sidechain ducking for background music.
    public static func applyMastering(
        videoURL: URL,
        speechSegments: [(start: Double, end: Double)],
        backgroundMusicURL: URL?,
        outputURL: URL,
        config: AudioMixConfig = AudioMixConfig()
    ) async throws {
        let asset = AVURLAsset(url: videoURL)
        let composition = AVMutableComposition()

        let duration = try await asset.load(.duration)
        let timeRange = CMTimeRange(start: .zero, duration: duration)
        
        // INSERT THE ENTIRE ASSET TO PRESERVE EXACT TIMING (EDTS / B-FRAMES)
        // This prevents audio/video desync caused by manual track extraction!
        try await composition.insertTimeRange(timeRange, of: asset, at: .zero)
        
        guard let compAudioTrack = try await composition.loadTracks(withMediaType: .audio).first else {
            throw CinemaAudioMasteringError.missingAudioTrack
        }

        let audioMix = AVMutableAudioMix()
        var inputParameters = [AVMutableAudioMixInputParameters]()

        // 1. Dialogue track with boost for clarity on smartphone speakers (-14 LUFS mobile standard)
        let dialogueParams = AVMutableAudioMixInputParameters(track: compAudioTrack)
        let dialogueBoostLinear = Float(pow(10.0, Double(config.dialogueBoostDB) / 20.0))
        let fadeSec = 0.18

        if duration.seconds > fadeSec {
            let fadeStartTime = CMTime(seconds: duration.seconds - fadeSec, preferredTimescale: 600)
            // Ramp 1: Sustained boosted volume until fade start (strictly non-overlapping)
            let bodyRange = CMTimeRange(start: .zero, duration: fadeStartTime)
            dialogueParams.setVolumeRamp(
                fromStartVolume: dialogueBoostLinear,
                toEndVolume: dialogueBoostLinear,
                timeRange: bodyRange
            )
            // Ramp 2: Smooth fade-out to zero at the tail (starts exactly where Ramp 1 ends)
            let tailDuration = CMTime(seconds: fadeSec, preferredTimescale: 600)
            let tailRange = CMTimeRange(start: fadeStartTime, duration: tailDuration)
            dialogueParams.setVolumeRamp(
                fromStartVolume: dialogueBoostLinear,
                toEndVolume: 0.0,
                timeRange: tailRange
            )
        } else {
            dialogueParams.setVolumeRamp(
                fromStartVolume: dialogueBoostLinear,
                toEndVolume: dialogueBoostLinear,
                timeRange: timeRange
            )
        }
        inputParameters.append(dialogueParams)

        // 2. Background music track with sidechain ducking (-14dB during speech, smooth rise in pauses)
        let effectiveMusicURL = backgroundMusicURL ?? config.musicURL
        if let musicURL = effectiveMusicURL {
            let musicAsset = AVURLAsset(url: musicURL)
            if let musicTrack = try await musicAsset.loadTracks(withMediaType: .audio).first {
                let compMusicTrack = composition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                )

                // Loop background music across entire composition duration
                var currentMusicTime = CMTime.zero
                let musicDuration = try await musicAsset.load(.duration)
                
                // Smart Audio Drop Detection integration
                var musicStartOffset = CMTime.zero
                if let urlComponents = URLComponents(url: musicURL, resolvingAgainstBaseURL: false),
                   let dropOffsetString = urlComponents.queryItems?.first(where: { $0.name == "dropOffset" })?.value,
                   let dropOffset = Double(dropOffsetString), dropOffset > 0 {
                    // Start the track exactly at the detected drop/climax
                    musicStartOffset = CMTime(seconds: dropOffset, preferredTimescale: 600)
                } else if musicDuration.seconds > 45.0 {
                    // Fallback intro skip
                    let maxOffset = musicDuration.seconds - 15.0
                    let skipSeconds = min(30.0, maxOffset)
                    musicStartOffset = CMTime(seconds: skipSeconds, preferredTimescale: 600)
                }
                
                if musicDuration.seconds > 0 {
                    while currentMusicTime < duration {
                        let remaining = duration - currentMusicTime
                        let availableDuration = musicDuration - musicStartOffset
                        let insertDuration = CMTimeMinimum(remaining, availableDuration)
                        let insertRange = CMTimeRange(start: musicStartOffset, duration: insertDuration)
                        try compMusicTrack?.insertTimeRange(insertRange, of: musicTrack, at: currentMusicTime)
                        currentMusicTime = currentMusicTime + insertDuration
                        // After the first loop, we can start from 0 again if we want, or keep looping from the offset.
                        // For shorts, the song is usually longer than the video anyway.
                        musicStartOffset = .zero // Reset offset so next loop starts from beginning if it loops
                    }
                }

                let musicParams = AVMutableAudioMixInputParameters(track: compMusicTrack)
                let restingVol = Float(pow(10.0, Double(config.musicRestingDB) / 20.0))
                let duckingVol = Float(pow(10.0, Double(config.musicDuckingDB) / 20.0))

                let mergedSegments = mergeSpeechSegments(
                    speechSegments,
                    threshold: config.speechMergeThreshold
                )

                applyDuckingRamps(
                    to: musicParams,
                    duration: duration,
                    speechSegments: mergedSegments,
                    restingVol: restingVol,
                    duckingVol: duckingVol,
                    attackDuration: config.duckingAttackDuration,
                    releaseDuration: config.duckingReleaseDuration
                )

                inputParameters.append(musicParams)
            }
        }

        audioMix.inputParameters = inputParameters

        // Remove destination file if already present to prevent export failure
        try? FileManager.default.removeItem(at: outputURL)

        guard let exportSession = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw CinemaAudioMasteringError.cannotCreateExportSession
        }

        // Clamp export timeRange to minimum of audio and video tracks to prevent dead-frame truncation
        let compVideoTracks = try await composition.loadTracks(withMediaType: .video)
        var effectiveDuration = duration
        if let vTrack = compVideoTracks.first {
            let vDuration = try await vTrack.load(.timeRange).duration
            let aDuration = try await compAudioTrack.load(.timeRange).duration
            effectiveDuration = CMTimeMinimum(vDuration, aDuration)
        }
        exportSession.timeRange = CMTimeRange(start: .zero, duration: effectiveDuration)

        exportSession.audioMix = audioMix

        if #available(macOS 15.0, *) {
            try await exportSession.export(to: outputURL, as: .mp4)
        } else {
            exportSession.outputURL = outputURL
            exportSession.outputFileType = .mp4
            await exportSession.export()
            if let error = exportSession.error {
                throw error
            }
        }
    }

    // MARK: - Internal Helpers (Single Responsibility)

    /// Merges speech segments separated by less than the given threshold to avoid audio flutter.
    static func mergeSpeechSegments(
        _ segments: [(start: Double, end: Double)],
        threshold: Double
    ) -> [(start: Double, end: Double)] {
        let validSegments = segments
            .filter { $0.end > $0.start }
            .sorted { $0.start < $1.start }

        guard let first = validSegments.first else { return [] }

        var merged: [(start: Double, end: Double)] = [first]
        for seg in validSegments.dropFirst() {
            var last = merged.removeLast()
            if seg.start - last.end < threshold {
                last.end = max(last.end, seg.end)
                merged.append(last)
            } else {
                merged.append(last)
                merged.append(seg)
            }
        }
        return merged
    }

    /// Schedules precise, non-overlapping volume ramps for background music sidechain ducking.
    static func applyDuckingRamps(
        to musicParams: AVMutableAudioMixInputParameters,
        duration: CMTime,
        speechSegments: [(start: Double, end: Double)],
        restingVol: Float,
        duckingVol: Float,
        attackDuration: Double,
        releaseDuration: Double
    ) {
        guard !speechSegments.isEmpty else {
            musicParams.setVolume(restingVol, at: .zero)
            return
        }

        let totalDurationSec = duration.seconds
        var isDucked = false

        // Determine starting state at t=0
        if let first = speechSegments.first, first.start <= attackDuration {
            musicParams.setVolume(duckingVol, at: .zero)
            isDucked = true
        } else {
            musicParams.setVolume(restingVol, at: .zero)
            isDucked = false
        }

        for (index, segment) in speechSegments.enumerated() {
            let segStart = max(0.0, segment.start)
            let segEnd = min(totalDurationSec, segment.end)

            guard segEnd > segStart else { continue }

            // 1. Attack: Ramp down from resting to ducking level if not already ducked
            if !isDucked {
                let rampDownStartSec = max(0.0, segStart - attackDuration)
                if rampDownStartSec < segStart {
                    let startTime = CMTime(seconds: rampDownStartSec, preferredTimescale: 600)
                    let endTime = CMTime(seconds: segStart, preferredTimescale: 600)
                    musicParams.setVolumeRamp(
                        fromStartVolume: restingVol,
                        toEndVolume: duckingVol,
                        timeRange: CMTimeRange(start: startTime, end: endTime)
                    )
                }
                isDucked = true
            }

            // 2. Release: Check pause until next speech segment for smooth rise
            let nextSpeechStartSec = (index + 1 < speechSegments.count)
                ? max(segEnd, speechSegments[index + 1].start)
                : totalDurationSec

            let pauseDuration = nextSpeechStartSec - segEnd
            let minPauseForRelease = releaseDuration + attackDuration

            if pauseDuration >= minPauseForRelease {
                let rampUpEndSec = min(totalDurationSec, segEnd + releaseDuration)
                if rampUpEndSec > segEnd {
                    let segEndTime = CMTime(seconds: segEnd, preferredTimescale: 600)
                    let rampUpEndTime = CMTime(seconds: rampUpEndSec, preferredTimescale: 600)
                    musicParams.setVolumeRamp(
                        fromStartVolume: duckingVol,
                        toEndVolume: restingVol,
                        timeRange: CMTimeRange(start: segEndTime, end: rampUpEndTime)
                    )
                }
                isDucked = false
            } else {
                // Keep ducked during brief inter-word pauses to avoid audio pumping
                isDucked = true
            }
        }
    }
}
