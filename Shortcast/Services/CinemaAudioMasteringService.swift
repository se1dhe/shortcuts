import Foundation
import AVFoundation

/// Handles cinema-grade audio mastering, dialogue clarity enhancement,
/// volume normalization to the shared loudness target, and sidechain ducking of background music.
public enum CinemaAudioMasteringService {

    // MARK: - Standards & Constants (Cinema Standard)

    /// Shared integrated loudness target for mastering and render validation.
    public static let targetLUFS: Double = -16.0

    /// Maximum true peak level (-2.0 dBTP) for cinema-grade mastering with safe headroom.
    public static let targetTruePeak: Double = -2.0

    /// Loudness range target (7.0 LRA) optimized for dialog clarity and dynamic range.
    public static let targetLRA: Double = 7.0

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

}
