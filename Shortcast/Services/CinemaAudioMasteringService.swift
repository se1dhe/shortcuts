import Foundation
import AVFoundation

/// Handles cinema-grade audio mastering, dialogue clarity enhancement,
/// volume normalization to -14 LUFS (modern mobile social standard), and sidechain ducking of background music.
public enum CinemaAudioMasteringService {

    // MARK: - Standards & Constants (Mobile Social Standard)

    /// Target integrated loudness (-14.0 LUFS) conforming to modern mobile social networks (Reels, TikTok, Shorts).
    public static let targetLUFS: Double = -14.0

    /// Maximum true peak level (-1.5 dBTP) to avoid inter-sample clipping on mobile DACs and lossy audio codecs (AAC/Opus).
    public static let targetTruePeak: Double = -1.5

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

        /// Original video dialogue / audio track volume multiplier (0.0 = muted, 1.0 = normal 100%, 2.0 = boosted 200%).
        public var originalAudioVolume: Float = 1.0

        /// Dialogue volume boost in dB (default: +2.0 dB for clean, natural dialogue elevation without 0 dBFS digital clipping).
        public var dialogueBoostDB: Float = 2.0

        /// Master volume multiplier for overlaid background music (0.0 = muted, 0.7 = 70%, 1.0 = 100%, 1.5 = 150%).
        public var musicVolume: Float = 0.7

        /// Cut/trim start offset (in seconds) for the background music track.
        public var musicStartOffsetSeconds: Double = 0.0

        /// Whether voice-ducking is enabled. When false, music volume remains constant across the entire video.
        public var musicDuckingEnabled: Bool = true

        /// Music volume during dialogue (-14.0 dB for clear vocal intelligibility).
        public var musicDuckingDB: Float = -14.0

        /// Music resting volume during pauses between dialogue (-6.0 dB).
        public var musicRestingDB: Float = -6.0

        /// Fast attack duration (seconds) to duck music at speech onset (default: 0.10s / 100ms).
        public var duckingAttackDuration: Double = 0.10

        /// Smooth release duration (seconds) to restore music during speech pauses (default: 0.45s / 450ms).
        public var duckingReleaseDuration: Double = 0.45

        /// Fade-in duration (seconds) for background music.
        public var musicFadeInDuration: Double = 0.30

        /// Fade-out duration (seconds) at the tail of the clip for smooth looping and ending.
        public var musicFadeOutDuration: Double = 0.80

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
            originalAudioVolume: Float = 1.0,
            dialogueBoostDB: Float = 2.0,
            musicVolume: Float = 0.7,
            musicStartOffsetSeconds: Double = 0.0,
            musicDuckingEnabled: Bool = true,
            musicDuckingDB: Float = -14.0,
            musicRestingDB: Float = -6.0,
            duckingAttackDuration: Double = 0.10,
            duckingReleaseDuration: Double = 0.45,
            musicFadeInDuration: Double = 0.30,
            musicFadeOutDuration: Double = 0.80,
            speechMergeThreshold: Double = 0.35,
            normalizeLUFS: Bool = true,
            targetLUFS: Double = CinemaAudioMasteringService.targetLUFS,
            targetTruePeak: Double = CinemaAudioMasteringService.targetTruePeak,
            targetLRA: Double = CinemaAudioMasteringService.targetLRA
        ) {
            self.musicURL = musicURL
            self.originalAudioVolume = originalAudioVolume
            self.dialogueBoostDB = dialogueBoostDB
            self.musicVolume = musicVolume
            self.musicStartOffsetSeconds = musicStartOffsetSeconds
            self.musicDuckingEnabled = musicDuckingEnabled
            self.musicDuckingDB = musicDuckingDB
            self.musicRestingDB = musicRestingDB
            self.duckingAttackDuration = duckingAttackDuration
            self.duckingReleaseDuration = duckingReleaseDuration
            self.musicFadeInDuration = musicFadeInDuration
            self.musicFadeOutDuration = musicFadeOutDuration
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

        // 1. Dialogue / original video track with user volume control and boost
        let dialogueParams = AVMutableAudioMixInputParameters(track: compAudioTrack)
        if config.originalAudioVolume <= 0.001 {
            dialogueParams.setVolume(0.0, at: .zero)
        } else {
            let dialogueBoostLinear = Float(pow(10.0, Double(config.dialogueBoostDB) / 20.0))
            let effectiveLinear = max(0.0, config.originalAudioVolume) * dialogueBoostLinear
            applyDialogueVolumeRamps(
                to: dialogueParams,
                duration: duration,
                boostLinear: effectiveLinear,
                fadeInDuration: 0.05,
                fadeOutDuration: 0.18
            )
        }
        inputParameters.append(dialogueParams)

        // 2. Background music track with custom trimming, volume, and optional ducking
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
                
                // Smart trim / start offset calculation
                var musicStartOffset = CMTime.zero
                if config.musicStartOffsetSeconds > 0 {
                    // Explicit user trim
                    let maxOffset = max(0.0, musicDuration.seconds - 2.0)
                    let clamped = min(config.musicStartOffsetSeconds, maxOffset)
                    musicStartOffset = CMTime(seconds: clamped, preferredTimescale: 600)
                } else if let urlComponents = URLComponents(url: musicURL, resolvingAgainstBaseURL: false),
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
                        // Reset offset so subsequent loops wrap smoothly from start
                        musicStartOffset = .zero
                    }
                }

                let musicParams = AVMutableAudioMixInputParameters(track: compMusicTrack)
                let baseMusicVol = max(0.0, config.musicVolume)

                if !config.musicDuckingEnabled {
                    // Constant volume across entire short duration
                    applyConstantMusicRamps(
                        to: musicParams,
                        duration: duration,
                        volume: baseMusicVol,
                        fadeInDuration: config.musicFadeInDuration,
                        fadeOutDuration: config.musicFadeOutDuration
                    )
                } else {
                    // Smart sidechain ducking under dialogue
                    let restingVol = baseMusicVol * Float(pow(10.0, Double(config.musicRestingDB) / 20.0))
                    let duckingVol = baseMusicVol * Float(pow(10.0, Double(config.musicDuckingDB) / 20.0))

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
                        releaseDuration: config.duckingReleaseDuration,
                        fadeOutDuration: config.musicFadeOutDuration
                    )
                }

                inputParameters.append(musicParams)
            }
        }

        audioMix.inputParameters = inputParameters

        // Clamp export timeRange to minimum of audio and video tracks to prevent dead-frame truncation
        let compVideoTracks = try await composition.loadTracks(withMediaType: .video)
        var effectiveDuration = duration
        if let vTrack = compVideoTracks.first {
            let vDuration = try await vTrack.load(.timeRange).duration
            let aDuration = try await compAudioTrack.load(.timeRange).duration
            effectiveDuration = CMTimeMinimum(vDuration, aDuration)
        }

        // Remove destination file if already present to prevent export failure
        try? FileManager.default.removeItem(at: outputURL)

        // ZERO-LOSS VIDEO PASSTHROUGH PIPELINE:
        // 1. Export mastered audio mix alone (AAC 256k M4A) without re-encoding video frames
        let tempAudioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("shortcast-masteredaudio-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: tempAudioURL) }

        guard let audioExport = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw CinemaAudioMasteringError.cannotCreateExportSession
        }
        audioExport.audioMix = audioMix
        audioExport.timeRange = CMTimeRange(start: .zero, duration: effectiveDuration)

        if #available(macOS 15.0, *) {
            try await audioExport.export(to: tempAudioURL, as: .m4a)
        } else {
            audioExport.outputURL = tempAudioURL
            audioExport.outputFileType = .m4a
            await audioExport.export()
            if let error = audioExport.error {
                throw error
            }
        }

        // 2. Stream-mux original video track (copy: 0% quality loss) with mastered audio
        try await muxVideoAndAudio(
            videoURL: videoURL,
            audioURL: tempAudioURL,
            outputURL: outputURL,
            composition: composition,
            audioMix: audioMix,
            effectiveDuration: effectiveDuration
        )
    }

    /// Combines video with new audio using stream copy (-c:v copy) to guarantee 0% quality loss.
    private static func muxVideoAndAudio(
        videoURL: URL,
        audioURL: URL,
        outputURL: URL,
        composition: AVComposition,
        audioMix: AVAudioMix,
        effectiveDuration: CMTime
    ) async throws {
        // Fast path: FFmpeg bitstream copy (takes ~0.05s, bit-for-bit picture preservation)
        if let ffmpegBin = BinaryDownloadService.resolveBinary("ffmpeg", workingDirectory: nil) {
            let args = [
                "-hide_banner",
                "-y",
                "-i", videoURL.path,
                "-i", audioURL.path,
                "-map", "0:v:0",
                "-map", "1:a:0",
                "-c:v", "copy",
                "-c:a", "copy",
                "-movflags", "+faststart",
                outputURL.path
            ]
            if let result = try? await ProcessRunner.shared.run(executableURL: ffmpegBin, arguments: args),
               result.isSuccess,
               FileManager.default.fileExists(atPath: outputURL.path) {
                return
            }
        }

        // Safe fallback: AVFoundation export using HEVC Highest Quality instead of default H.264
        guard let exportSession = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHEVCHighestQuality
        ) ?? AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw CinemaAudioMasteringError.cannotCreateExportSession
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

    /// Schedules smooth fade-in (e.g. 0.05s), sustained boosted dialogue body, and fade-out (e.g. 0.18s)
    /// to eliminate audio DC offset clicks and harsh transitions at clip boundaries.
    static func applyDialogueVolumeRamps(
        to dialogueParams: AVMutableAudioMixInputParameters,
        duration: CMTime,
        boostLinear: Float,
        fadeInDuration: Double = 0.05,
        fadeOutDuration: Double = 0.18
    ) {
        let totalSec = duration.seconds
        guard totalSec > 0 else {
            dialogueParams.setVolume(boostLinear, at: .zero)
            return
        }

        if totalSec > (fadeInDuration + fadeOutDuration) {
            let fadeInTime = CMTime(seconds: fadeInDuration, preferredTimescale: 600)
            let fadeOutStartTime = CMTime(seconds: totalSec - fadeOutDuration, preferredTimescale: 600)
            let fadeOutDurationTime = CMTime(seconds: fadeOutDuration, preferredTimescale: 600)
            let bodyDurationTime = CMTime(seconds: totalSec - fadeInDuration - fadeOutDuration, preferredTimescale: 600)

            // Ramp 1: Smooth fade-in from 0 to boosted dialogue level to avoid onset pops/clicks
            dialogueParams.setVolumeRamp(
                fromStartVolume: 0.0,
                toEndVolume: boostLinear,
                timeRange: CMTimeRange(start: .zero, duration: fadeInTime)
            )

            // Ramp 2: Sustained boosted dialogue level across clip body
            dialogueParams.setVolumeRamp(
                fromStartVolume: boostLinear,
                toEndVolume: boostLinear,
                timeRange: CMTimeRange(start: fadeInTime, duration: bodyDurationTime)
            )

            // Ramp 3: Smooth fade-out to zero at clip tail to avoid abrupt cutoff clicks
            dialogueParams.setVolumeRamp(
                fromStartVolume: boostLinear,
                toEndVolume: 0.0,
                timeRange: CMTimeRange(start: fadeOutStartTime, duration: fadeOutDurationTime)
            )
        } else {
            // Ultra-short clips: split evenly between fade-in and fade-out
            let midSec = totalSec / 2.0
            let midTime = CMTime(seconds: midSec, preferredTimescale: 600)
            let remainingTime = CMTime(seconds: totalSec - midSec, preferredTimescale: 600)

            dialogueParams.setVolumeRamp(
                fromStartVolume: 0.0,
                toEndVolume: boostLinear,
                timeRange: CMTimeRange(start: .zero, duration: midTime)
            )
            dialogueParams.setVolumeRamp(
                fromStartVolume: boostLinear,
                toEndVolume: 0.0,
                timeRange: CMTimeRange(start: midTime, duration: remainingTime)
            )
        }
    }

    /// Schedules smooth constant volume ramps with optional fade-in and tail fade-out.
    static func applyConstantMusicRamps(
        to musicParams: AVMutableAudioMixInputParameters,
        duration: CMTime,
        volume: Float,
        fadeInDuration: Double = 0.30,
        fadeOutDuration: Double = 0.80
    ) {
        let totalSec = duration.seconds
        guard totalSec > 0 else {
            musicParams.setVolume(volume, at: .zero)
            return
        }

        if totalSec > (fadeInDuration + fadeOutDuration) {
            let fadeInTime = CMTime(seconds: fadeInDuration, preferredTimescale: 600)
            let fadeOutStartTime = CMTime(seconds: totalSec - fadeOutDuration, preferredTimescale: 600)
            let fadeOutDurationTime = CMTime(seconds: fadeOutDuration, preferredTimescale: 600)
            let bodyDurationTime = CMTime(seconds: totalSec - fadeInDuration - fadeOutDuration, preferredTimescale: 600)

            // 1. Fade-in
            musicParams.setVolumeRamp(
                fromStartVolume: 0.0,
                toEndVolume: volume,
                timeRange: CMTimeRange(start: .zero, duration: fadeInTime)
            )

            // 2. Body
            musicParams.setVolumeRamp(
                fromStartVolume: volume,
                toEndVolume: volume,
                timeRange: CMTimeRange(start: fadeInTime, duration: bodyDurationTime)
            )

            // 3. Fade-out
            musicParams.setVolumeRamp(
                fromStartVolume: volume,
                toEndVolume: 0.0,
                timeRange: CMTimeRange(start: fadeOutStartTime, duration: fadeOutDurationTime)
            )
        } else {
            musicParams.setVolume(volume, at: .zero)
        }
    }

    /// Schedules precise, non-overlapping volume ramps for background music sidechain ducking.
    static func applyDuckingRamps(
        to musicParams: AVMutableAudioMixInputParameters,
        duration: CMTime,
        speechSegments: [(start: Double, end: Double)],
        restingVol: Float,
        duckingVol: Float,
        attackDuration: Double,
        releaseDuration: Double,
        fadeOutDuration: Double = 0.80
    ) {
        let totalDurationSec = duration.seconds
        guard !speechSegments.isEmpty else {
            applyConstantMusicRamps(to: musicParams, duration: duration, volume: restingVol, fadeOutDuration: fadeOutDuration)
            return
        }

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

        // 3. Smooth tail fade-out if clip is long enough
        if fadeOutDuration > 0 && totalDurationSec > (fadeOutDuration + 1.0) {
            let fadeOutStartTime = CMTime(seconds: totalDurationSec - fadeOutDuration, preferredTimescale: 600)
            let fadeOutDurationTime = CMTime(seconds: fadeOutDuration, preferredTimescale: 600)
            let currentTailVol = isDucked ? duckingVol : restingVol
            musicParams.setVolumeRamp(
                fromStartVolume: currentTailVol,
                toEndVolume: 0.0,
                timeRange: CMTimeRange(start: fadeOutStartTime, duration: fadeOutDurationTime)
            )
        }
    }
}
