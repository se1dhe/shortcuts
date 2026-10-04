import AVFoundation
import CoreMedia

/// Реализация кинематографического сведения звука Shortcast Cinema:
/// - Непрерывный кинематографический саундтрек
/// - Автоматический Sidechain Ducking под реплики персонажей
/// - Сглаживание склеек (Crossfade)
/// - Эмоциональное крещендо в последние 45 секунд
final class LongformAudioMasteringService: LongformAudioMasteringProtocol, Sendable {

    func buildAudioMixParameters(
        composition: AVComposition,
        musicTrack: AVCompositionTrack,
        speechTrack: AVCompositionTrack,
        speechIntervals: [TimeSegment],
        totalDuration: Double,
        baseMusicVolume: Float = 0.28,
        duckingEnabled: Bool = true
    ) -> AVAudioMix {
        let audioMix = AVMutableAudioMix()

        // 1. Параметры дорожки речи
        let speechParams = AVMutableAudioMixInputParameters(track: speechTrack)
        speechParams.setVolume(1.0, at: .zero)

        // 2. Параметры фонового саундтрека с дакингом
        let musicParams = AVMutableAudioMixInputParameters(track: musicTrack)
        let sortedSpeech = speechIntervals.sorted { $0.start < $1.start }

        let normalVolume: Float = max(0.05, min(0.60, baseMusicVolume))
        let duckedVolume: Float = duckingEnabled ? (normalVolume * 0.40) : normalVolume
        let climaxVolume: Float = min(0.90, normalVolume * 2.2)

        let outroFadeDuration = 2.5
        let fadeOutStartTime = max(0.0, totalDuration - outroFadeDuration)
        let climaxStartTime = max(0.0, min(totalDuration - 45.0, fadeOutStartTime - 10.0))

        // Начальная громкость музыки
        musicParams.setVolume(normalVolume, at: .zero)

        if duckingEnabled {
            var currentTime = 0.0

            for interval in sortedSpeech {
                guard interval.end <= climaxStartTime else { break }

                if interval.start > currentTime {
                    // В паузе между фразами плавно поднимаем громкость музыки
                    let pauseStart = CMTime(seconds: currentTime, preferredTimescale: 600)
                    let pauseDuration = CMTime(seconds: min(0.3, interval.start - currentTime), preferredTimescale: 600)
                    musicParams.setVolumeRamp(fromStartVolume: duckedVolume, toEndVolume: normalVolume, timeRange: CMTimeRange(start: pauseStart, duration: pauseDuration))
                }

                // Перед началом речи приглушаем музыку (ducking)
                let speechStart = CMTime(seconds: max(0.0, interval.start - 0.15), preferredTimescale: 600)
                let duckDuration = CMTime(seconds: 0.25, preferredTimescale: 600)
                musicParams.setVolumeRamp(fromStartVolume: normalVolume, toEndVolume: duckedVolume, timeRange: CMTimeRange(start: speechStart, duration: duckDuration))

                currentTime = interval.end
            }
        }

        // Финальное крещендо (до начала финального затухания)
        if fadeOutStartTime > climaxStartTime {
            let climaxStartCM = CMTime(seconds: climaxStartTime, preferredTimescale: 600)
            let climaxDurationCM = CMTime(seconds: fadeOutStartTime - climaxStartTime, preferredTimescale: 600)
            musicParams.setVolumeRamp(
                fromStartVolume: duckedVolume,
                toEndVolume: climaxVolume,
                timeRange: CMTimeRange(start: climaxStartCM, duration: climaxDurationCM)
            )
        }

        // Плавное затухание в конце ролика (последние 2.5 секунды) до абсолютной тишины
        if totalDuration > outroFadeDuration {
            let fadeOutStartCM = CMTime(seconds: fadeOutStartTime, preferredTimescale: 600)
            let fadeOutDurationCM = CMTime(seconds: totalDuration - fadeOutStartTime, preferredTimescale: 600)

            // Дорожка речи плавно гасится до нуля
            speechParams.setVolumeRamp(
                fromStartVolume: 1.0,
                toEndVolume: 0.0,
                timeRange: CMTimeRange(start: fadeOutStartCM, duration: fadeOutDurationCM)
            )

            // Фоновая музыка плавно гасится до нуля
            musicParams.setVolumeRamp(
                fromStartVolume: climaxVolume,
                toEndVolume: 0.0,
                timeRange: CMTimeRange(start: fadeOutStartCM, duration: fadeOutDurationCM)
            )
        }

        audioMix.inputParameters = [speechParams, musicParams]
        return audioMix
    }
}
