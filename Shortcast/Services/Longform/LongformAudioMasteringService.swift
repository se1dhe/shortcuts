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
        sceneCutPoints: [Double] = [],
        totalDuration: Double,
        baseMusicVolume: Float = 0.28,
        duckingEnabled: Bool = true,
        dialogueFocusEnabled: Bool = true,
        originalMusicDucking: Float = 0.82
    ) -> AVAudioMix {
        let audioMix = AVMutableAudioMix()

        // 1. Параметры дорожки речи
        let speechParams = AVMutableAudioMixInputParameters(track: speechTrack)
        speechParams.audioTimePitchAlgorithm = .spectral

        let sortedSpeech = speechIntervals.sorted { $0.start < $1.start }
        let lastSpeechEnd = sortedSpeech.last?.end ?? max(0.0, totalDuration - 3.0)

        // Подавление оригинальной музыки фильма в паузах между фразами (Dialogue Focus)
        let duckedSpeechVolume: Float = max(0.05, 1.0 - originalMusicDucking)

        // В первые 2.5 секунды (Cold Open) речь фильма заглушена
        speechParams.setVolume(0.0, at: .zero)
        var lastSpeechRampEnd: Double = 0.0

        if dialogueFocusEnabled && !sortedSpeech.isEmpty {
            // Объединяем близкие реплики (пауза < 0.8с) во избежание частых перепадов громкости
            var mergedSpeech: [TimeSegment] = []
            for s in sortedSpeech {
                if let last = mergedSpeech.last {
                    if s.start <= last.end + 0.8 {
                        mergedSpeech[mergedSpeech.count - 1] = TimeSegment(start: last.start, end: max(last.end, s.end))
                    } else {
                        mergedSpeech.append(s)
                    }
                } else {
                    mergedSpeech.append(s)
                }
            }

            let firstSpeechStart = mergedSpeech.first?.start ?? 2.5
            let initialTargetVolume: Float = (firstSpeechStart <= 2.8) ? 1.0 : duckedSpeechVolume
            safeSetVolumeRamp(
                params: speechParams,
                from: 0.0,
                to: initialTargetVolume,
                start: 2.2,
                duration: 0.3,
                lastRampEnd: &lastSpeechRampEnd
            )

            for (idx, interval) in mergedSpeech.enumerated() {
                // Подъем до 100% громкости перед репликой
                let rampUpStart = max(lastSpeechRampEnd + 0.01, interval.start - 0.18)
                let rampUpDur = min(0.15, max(0.04, interval.start - rampUpStart))
                if rampUpStart < interval.start {
                    safeSetVolumeRamp(
                        params: speechParams,
                        from: duckedSpeechVolume,
                        to: 1.0,
                        start: rampUpStart,
                        duration: rampUpDur,
                        lastRampEnd: &lastSpeechRampEnd
                    )
                }

                // Спад до duckedSpeechVolume после реплики, если до следующей фразы есть пауза > 0.8с
                let nextStart = (idx + 1 < mergedSpeech.count) ? mergedSpeech[idx + 1].start : lastSpeechEnd
                let pause = nextStart - interval.end
                if pause > 0.8 && interval.end < lastSpeechEnd {
                    let rampDownStart = max(lastSpeechRampEnd + 0.01, interval.end + 0.15)
                    let rampDownDur: Double = 0.20
                    if (rampDownStart + rampDownDur) < (nextStart - 0.20) {
                        safeSetVolumeRamp(
                            params: speechParams,
                            from: 1.0,
                            to: duckedSpeechVolume,
                            start: rampDownStart,
                            duration: rampDownDur,
                            lastRampEnd: &lastSpeechRampEnd
                        )
                    }
                }
            }
        } else {
            // Классический режим: подъем до 100% громкости к 2.5с
            safeSetVolumeRamp(
                params: speechParams,
                from: 0.0,
                to: 1.0,
                start: 2.2,
                duration: 0.3,
                lastRampEnd: &lastSpeechRampEnd
            )
        }

        // Микро-кроссфейды на склейках сцен (только если точка склейки свободна и не пересекается)
        let validCutPoints = sceneCutPoints.sorted().filter { $0 > (lastSpeechRampEnd + 0.1) && $0 < min(totalDuration - 0.5, lastSpeechEnd) }
        for cut in validCutPoints {
            let fadeDuration: Double = 0.04
            let cutFadeOutStart = cut - fadeDuration
            guard cutFadeOutStart >= lastSpeechRampEnd + 0.01 else { continue }
            let cutFadeInEnd = cut + fadeDuration
            guard cutFadeInEnd < lastSpeechEnd else { continue }

            safeSetVolumeRamp(
                params: speechParams,
                from: 1.0,
                to: 0.0,
                start: cutFadeOutStart,
                duration: fadeDuration,
                lastRampEnd: &lastSpeechRampEnd
            )
            safeSetVolumeRamp(
                params: speechParams,
                from: 0.0,
                to: 1.0,
                start: cut,
                duration: fadeDuration,
                lastRampEnd: &lastSpeechRampEnd
            )
        }

        // Затухание дорожки речи: после последней фразы плавно уходит в ноль
        let finalSpeechFadeStart = max(lastSpeechEnd, lastSpeechRampEnd + 0.01)
        if totalDuration > finalSpeechFadeStart {
            safeSetVolumeRamp(
                params: speechParams,
                from: 1.0,
                to: 0.0,
                start: finalSpeechFadeStart,
                duration: max(0.2, min(1.0, totalDuration - finalSpeechFadeStart)),
                lastRampEnd: &lastSpeechRampEnd
            )
        }

        // 2. Параметры фонового саундтрека с дакингом
        let musicParams = AVMutableAudioMixInputParameters(track: musicTrack)

        let normalVolume: Float = max(0.05, min(0.60, baseMusicVolume))
        let duckedVolume: Float = duckingEnabled ? (normalVolume * 0.40) : normalVolume
        let climaxVolume: Float = min(0.90, normalVolume * 2.2)

        // Затухание музыки начинается СТРОГО ПОСЛЕ окончания последней фразы
        // (даем 0.6с на прозвучание эха/интонации, затем плавный спад 2.0-2.5с)
        let outroFadeDuration: Double = 2.5
        let musicFadeStartTime: Double = max(min(lastSpeechEnd + 0.6, totalDuration - 0.5), max(0.0, totalDuration - outroFadeDuration))
        let climaxStartTime: Double = max(0.0, min(totalDuration - 45.0, musicFadeStartTime - 10.0))

        // Cold Open Fade-In музыки: старт с 0.0 и плавный подъем до normalVolume за 2.0с
        musicParams.setVolume(0.0, at: .zero)
        let musicIntroFadeDuration: Double = 2.0
        musicParams.setVolumeRamp(
            fromStartVolume: 0.0,
            toEndVolume: normalVolume,
            timeRange: CMTimeRange(
                start: .zero,
                duration: CMTime(seconds: musicIntroFadeDuration, preferredTimescale: 600)
            )
        )
        var lastMusicRampEnd: Double = musicIntroFadeDuration

        if duckingEnabled && !sortedSpeech.isEmpty {
            // Объединяем близкие реплики (пауза < 0.8с) во избежание pumping-эффекта («хлюпанья»)
            var mergedSpeech: [TimeSegment] = []
            for s in sortedSpeech {
                if let last = mergedSpeech.last {
                    if s.start <= last.end + 0.8 {
                        mergedSpeech[mergedSpeech.count - 1] = TimeSegment(start: last.start, end: max(last.end, s.end))
                    } else {
                        mergedSpeech.append(s)
                    }
                } else {
                    mergedSpeech.append(s)
                }
            }

            var lastMusicRampEnd: Double = 0.0

            for (idx, interval) in mergedSpeech.enumerated() {
                guard interval.start < climaxStartTime else { break }

                // Приглушение перед началом речи
                let duckStart = max(lastMusicRampEnd, interval.start - 0.25)
                let duckDuration = max(0.05, interval.start - duckStart)
                if duckDuration >= 0.05 && duckStart >= lastMusicRampEnd {
                    musicParams.setVolumeRamp(
                        fromStartVolume: normalVolume,
                        toEndVolume: duckedVolume,
                        timeRange: CMTimeRange(
                            start: CMTime(seconds: duckStart, preferredTimescale: 600),
                            duration: CMTime(seconds: duckDuration, preferredTimescale: 600)
                        )
                    )
                    lastMusicRampEnd = duckStart + duckDuration
                }

                // Плавное возвращение музыки в паузе после фразы
                let nextStart = (idx + 1 < mergedSpeech.count) ? mergedSpeech[idx + 1].start : climaxStartTime
                let availablePause = nextStart - interval.end

                if availablePause >= 1.0 && interval.end < climaxStartTime {
                    let restoreStart = max(lastMusicRampEnd, interval.end + 0.15)
                    let restoreDuration: Double = 0.35
                    if (restoreStart + restoreDuration) < (nextStart - 0.20) {
                        musicParams.setVolumeRamp(
                            fromStartVolume: duckedVolume,
                            toEndVolume: normalVolume,
                            timeRange: CMTimeRange(
                                start: CMTime(seconds: restoreStart, preferredTimescale: 600),
                                duration: CMTime(seconds: restoreDuration, preferredTimescale: 600)
                            )
                        )
                        lastMusicRampEnd = restoreStart + restoreDuration
                    }
                }
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

    /// Безопасно применяет volume ramp к дорожке, гарантируя полное отсутствие пересечений временных диапазонов в AVFoundation
    private func safeSetVolumeRamp(
        params: AVMutableAudioMixInputParameters,
        from startVolume: Float,
        to endVolume: Float,
        start: Double,
        duration: Double,
        lastRampEnd: inout Double
    ) {
        guard duration >= 0.02 else { return }
        let safeStart = max(lastRampEnd + 0.005, start)
        let timeRange = CMTimeRange(
            start: CMTime(seconds: safeStart, preferredTimescale: 600),
            duration: CMTime(seconds: duration, preferredTimescale: 600)
        )
        params.setVolumeRamp(fromStartVolume: startVolume, toEndVolume: endVolume, timeRange: timeRange)
        lastRampEnd = safeStart + duration
    }
}
