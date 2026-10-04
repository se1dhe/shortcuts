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

        // Находим точное время окончания последней произнесенной реплики
        let lastSpeechEnd = sortedSpeech.last?.end ?? max(0.0, totalDuration - 3.0)

        // Затухание музыки начинается СТРОГО ПОСЛЕ окончания последней фразы
        // (даем 0.6с на прозвучание эха/интонации, затем плавный спад 2.0-2.5с)
        let outroFadeDuration: Double = 2.5
        let musicFadeStartTime: Double = max(min(lastSpeechEnd + 0.6, totalDuration - 0.5), max(0.0, totalDuration - outroFadeDuration))
        let climaxStartTime: Double = max(0.0, min(totalDuration - 45.0, musicFadeStartTime - 10.0))

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

        // Финальное крещендо музыки до начала финального затухания
        if musicFadeStartTime > climaxStartTime {
            let climaxStartCM = CMTime(seconds: climaxStartTime, preferredTimescale: 600)
            let climaxDurationCM = CMTime(seconds: musicFadeStartTime - climaxStartTime, preferredTimescale: 600)
            musicParams.setVolumeRamp(
                fromStartVolume: duckedVolume,
                toEndVolume: climaxVolume,
                timeRange: CMTimeRange(start: climaxStartCM, duration: climaxDurationCM)
            )
        }

        // Затухание дорожки речи: речь звучит на 100% громкости ДО КОНЦА,
        // и только в тишине после последней реплики плавно уходит в ноль
        if totalDuration > lastSpeechEnd {
            let speechFadeStartCM = CMTime(seconds: lastSpeechEnd, preferredTimescale: 600)
            let speechFadeDurationCM = CMTime(seconds: max(0.2, totalDuration - lastSpeechEnd), preferredTimescale: 600)
            speechParams.setVolumeRamp(
                fromStartVolume: 1.0,
                toEndVolume: 0.0,
                timeRange: CMTimeRange(start: speechFadeStartCM, duration: speechFadeDurationCM)
            )
        }

        // Финальное плавное затухание музыки строго ПОСЛЕ произнесения последней фразы
        if totalDuration > musicFadeStartTime {
            let musicFadeStartCM = CMTime(seconds: musicFadeStartTime, preferredTimescale: 600)
            let musicFadeDurationCM = CMTime(seconds: totalDuration - musicFadeStartTime, preferredTimescale: 600)
            musicParams.setVolumeRamp(
                fromStartVolume: climaxVolume,
                toEndVolume: 0.0,
                timeRange: CMTimeRange(start: musicFadeStartCM, duration: musicFadeDurationCM)
            )
        }

        audioMix.inputParameters = [speechParams, musicParams]
        return audioMix
    }
}
