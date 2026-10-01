import AVFoundation
import Foundation

/// Trims a video to a [start, end] time range (seconds) without re-encoding
/// the picture where possible. Returns a new temporary `.mp4`.
enum VideoTrimmer {

    enum TrimError: LocalizedError {
        case exportUnavailable
        case exportFailed(String)

        var errorDescription: String? {
            switch self {
            case .exportUnavailable: return "Couldn't create the trim export session."
            case .exportFailed(let m): return "Trim failed: \(m)"
            }
        }
    }

    /// Trims `videoURL` to [startSeconds, endSeconds]. `endSeconds <= 0` (or past
    /// the asset) means "until the end". Keeps audio in sync with the video.
    static func trim(
        videoURL: URL,
        startSeconds: Double,
        endSeconds: Double,
        outputURL: URL? = nil
    ) async throws -> URL {
        let asset = AVURLAsset(url: videoURL)
        let duration = try await asset.load(.duration)
        let totalSeconds = CMTimeGetSeconds(duration)

        let start = max(0, min(startSeconds, totalSeconds))
        var safeEnd = endSeconds > 0 ? min(endSeconds, totalSeconds) : totalSeconds
        if let videoTrack = try? await asset.loadTracks(withMediaType: .video).first,
           let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first {
            let vDur = (try? await videoTrack.load(.timeRange).duration.seconds) ?? totalSeconds
            let aDur = (try? await audioTrack.load(.timeRange).duration.seconds) ?? totalSeconds
            let minTrackDuration = min(vDur, aDur)
            safeEnd = min(safeEnd, minTrackDuration)
        }
        // Nothing meaningful to trim — hand back the original.
        guard safeEnd - start > 0.1 else { return videoURL }

        let timescale: CMTimeScale = 600
        let range = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: timescale),
            duration: CMTime(seconds: safeEnd - start, preferredTimescale: timescale))

        let output = outputURL ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("shortcast-trim-\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: output)

        guard let session = AVAssetExportSession(
            asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw TrimError.exportUnavailable
        }
        session.timeRange = range

        if #available(macOS 15.0, *) {
            do {
                try await session.export(to: output, as: .mp4)
            } catch {
                throw TrimError.exportFailed(error.localizedDescription)
            }
        } else {
            session.outputURL = output
            session.outputFileType = .mp4
            await session.export()
            guard session.status == .completed else {
                throw TrimError.exportFailed(session.error?.localizedDescription ?? "unknown")
            }
        }
        return output
    }

    /// Stitches multiple segments from a video together with 15ms micro-fades
    /// to avoid audio clicks/pops at the cut points.
    static func stitch(
        videoURL: URL,
        segments: [CMTimeRange],
        outputURL: URL? = nil
    ) async throws -> URL {
        let asset = AVURLAsset(url: videoURL)
        let composition = AVMutableComposition()
        
        var insertTime: CMTime = .zero
        for range in segments {
            // Create a fresh AVURLAsset instance for EACH segment to prevent AVFoundation's
            // decoder from bleeding B-frame PTS across jump cuts, which causes A/V desync.
            let segmentAsset = AVURLAsset(url: videoURL)
            try await composition.insertTimeRange(range, of: segmentAsset, at: insertTime)
            insertTime = CMTimeAdd(insertTime, range.duration)
        }
        
        let compVideoTracks = try await composition.loadTracks(withMediaType: .video)
        let compAudioTracks = try await composition.loadTracks(withMediaType: .audio)
        
        if let videoTrack = try await asset.loadTracks(withMediaType: .video).first {
            let transform = try await videoTrack.load(.preferredTransform)
            for track in compVideoTracks {
                track.preferredTransform = transform
            }
        }
        
        let audioMix = AVMutableAudioMix()
        var mixParams = [AVMutableAudioMixInputParameters]()
        
        if let compAudioTrack = compAudioTracks.first {
            let param = AVMutableAudioMixInputParameters(track: compAudioTrack)
            let totalDuration = insertTime
            let fadeDuration = CMTime(value: 20, timescale: 1000) // 20ms fade
            
            if totalDuration > CMTimeMultiply(fadeDuration, multiplier: 2) {
                // Smooth fade-in at the very start of the stitched clip
                let fadeInRange = CMTimeRange(start: .zero, duration: fadeDuration)
                param.setVolumeRamp(fromStartVolume: 0.0, toEndVolume: 1.0, timeRange: fadeInRange)
                
                // Continuous sustained volume throughout the dialogue
                let bodyDuration = CMTimeSubtract(totalDuration, CMTimeMultiply(fadeDuration, multiplier: 2))
                let bodyRange = CMTimeRange(start: fadeDuration, duration: bodyDuration)
                param.setVolumeRamp(fromStartVolume: 1.0, toEndVolume: 1.0, timeRange: bodyRange)
                
                // Smooth fade-out at the very end of the stitched clip
                let fadeOutStart = CMTimeSubtract(totalDuration, fadeDuration)
                let fadeOutRange = CMTimeRange(start: fadeOutStart, duration: fadeDuration)
                param.setVolumeRamp(fromStartVolume: 1.0, toEndVolume: 0.0, timeRange: fadeOutRange)
            } else {
                param.setVolume(1.0, at: .zero)
            }
            mixParams.append(param)
            audioMix.inputParameters = mixParams
        }
        
        let output = outputURL ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("shortcast-stitched-\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: output)
        
        guard let session = AVAssetExportSession(
            asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw TrimError.exportUnavailable
        }
        session.audioMix = audioMix

        if let firstVideo = compVideoTracks.first, let firstAudio = compAudioTracks.first {
            let vDuration = try await firstVideo.load(.timeRange).duration
            let aDuration = try await firstAudio.load(.timeRange).duration
            let clampedDuration = CMTimeMinimum(vDuration, aDuration)
            session.timeRange = CMTimeRange(start: .zero, duration: clampedDuration)
        }
        
        let videoComposition: AVMutableVideoComposition = try await withCheckedThrowingContinuation { continuation in
            AVMutableVideoComposition.videoComposition(withPropertiesOf: composition) { comp, error in
                if let comp {
                    continuation.resume(returning: comp)
                } else {
                    continuation.resume(throwing: error ?? TrimError.exportUnavailable)
                }
            }
        }
        if let videoTrack = try await asset.loadTracks(withMediaType: .video).first {
            videoComposition.frameDuration = try await videoTrack.load(.minFrameDuration)
            let naturalSize = try await videoTrack.load(.naturalSize)
            let transform = try await videoTrack.load(.preferredTransform)
            let oriented = naturalSize.applying(transform)
            videoComposition.renderSize = CGSize(width: abs(oriented.width), height: abs(oriented.height))
        }
        session.videoComposition = videoComposition
        
        do {
            try await session.export(to: output, as: .mp4)
        } catch {
            throw TrimError.exportFailed(error.localizedDescription)
        }
        return output
    }
}
