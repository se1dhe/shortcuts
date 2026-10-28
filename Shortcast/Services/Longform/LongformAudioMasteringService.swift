import AVFoundation
import CoreMedia
import Foundation
import OSLog

/// Реализация кинематографического сведения звука Shortcast Cinema:
/// - Непрерывный кинематографический саундтрек
/// - Автоматический Sidechain Ducking под реплики персонажей
/// - Сглаживание склеек (Crossfade)
/// - Эмоциональное крещендо в последние 45 секунд
final class LongformAudioMasteringService: LongformAudioMasteringProtocol, Sendable {

    /// Минимальный уровень речи в паузах между фразами (5%).
    static let minimumDuckedSpeechVolume: Float = 0.05

    func buildAudioMixParameters(
        composition: AVComposition,
        musicTrack: AVCompositionTrack,
        speechTrack: AVCompositionTrack,
        speechIntervals: [TimeSegment],
        sceneCutPoints: [Double] = [],
        cutTransitions: [LongformCutTransition] = [],
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
        // Полное подавление (1.0) означало бы цифровую тишину в паузах и -29.5 LUFS на всём
        // ролике, поэтому у приглушения есть нижний предел.
        let duckedSpeechVolume: Float = Self.duckedSpeechVolume(originalMusicDucking: originalMusicDucking)

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
                totalDuration: totalDuration,
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
                        totalDuration: totalDuration,
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
                            totalDuration: totalDuration,
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
                totalDuration: totalDuration,
                lastRampEnd: &lastSpeechRampEnd
            )
        }

        // Мягкие кинематографические переходы и затухания речи на склейках сцен
        if !cutTransitions.isEmpty {
            let sortedTransitions = cutTransitions.sorted { $0.sceneEndTime < $1.sceneEndTime }
            for cut in sortedTransitions {
                guard cut.sceneEndTime > (lastSpeechRampEnd + 0.05) && cut.nextSceneStartTime < (totalDuration - 0.2) else { continue }

                let fadeOutDur: Double = 0.20
                let fadeOutStart = max(lastSpeechRampEnd + 0.01, cut.sceneEndTime - fadeOutDur)
                let actualFadeOutDur = cut.sceneEndTime - fadeOutStart
                if actualFadeOutDur >= 0.04 {
                    safeSetVolumeRamp(
                        params: speechParams,
                        from: 1.0,
                        to: 0.0,
                        start: fadeOutStart,
                        duration: actualFadeOutDur,
                        totalDuration: totalDuration,
                        lastRampEnd: &lastSpeechRampEnd
                    )
                }

                // В паузе между сценами (черный экран) речь полностью заглушена
                speechParams.setVolume(0.0, at: CMTime(seconds: cut.sceneEndTime, preferredTimescale: 600))
                lastSpeechRampEnd = max(lastSpeechRampEnd, cut.sceneEndTime)

                // Плавное нарастание речи в начале новой сцены
                let fadeInDur: Double = 0.20
                let fadeInStart = max(lastSpeechRampEnd + 0.01, cut.nextSceneStartTime)
                if fadeInStart + fadeInDur < min(totalDuration - 0.2, lastSpeechEnd) {
                    safeSetVolumeRamp(
                        params: speechParams,
                        from: 0.0,
                        to: 1.0,
                        start: fadeInStart,
                        duration: fadeInDur,
                        totalDuration: totalDuration,
                        lastRampEnd: &lastSpeechRampEnd
                    )
                }
            }
        } else {
            // Резервный режим для одиночных точек склеек
            let validCutPoints = sceneCutPoints.sorted().filter { $0 > (lastSpeechRampEnd + 0.1) && $0 < min(totalDuration - 0.5, lastSpeechEnd) }
            for cut in validCutPoints {
                let fadeDuration: Double = 0.05
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
                    totalDuration: totalDuration,
                    lastRampEnd: &lastSpeechRampEnd
                )
                safeSetVolumeRamp(
                    params: speechParams,
                    from: 0.0,
                    to: 1.0,
                    start: cut,
                    duration: fadeDuration,
                    totalDuration: totalDuration,
                    lastRampEnd: &lastSpeechRampEnd
                )
            }
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
                totalDuration: totalDuration,
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

            for (idx, interval) in mergedSpeech.enumerated() {
                // Reserve the climax and outro for their own non-overlapping
                // automation. AVFoundation may stop an export when two volume
                // ramps on one track intersect, even by a single frame.
                let dynamicDuckingEnd = max(0.0, climaxStartTime - 0.01)
                guard interval.start < dynamicDuckingEnd else { break }

                // Приглушение перед началом речи
                let duckStart = max(lastMusicRampEnd + 0.005, interval.start - 0.25)
                let duckEnd = min(interval.start, dynamicDuckingEnd)
                let duckDuration = duckEnd - duckStart
                if duckDuration >= 0.05 {
                    safeSetVolumeRamp(
                        params: musicParams,
                        from: normalVolume,
                        to: duckedVolume,
                        start: duckStart,
                        duration: duckDuration,
                        totalDuration: totalDuration,
                        lastRampEnd: &lastMusicRampEnd
                    )
                }

                // Плавное возвращение музыки в паузе после фразы
                let nextStart = (idx + 1 < mergedSpeech.count) ? mergedSpeech[idx + 1].start : dynamicDuckingEnd
                let availablePause = nextStart - interval.end

                if availablePause >= 1.0 && interval.end < dynamicDuckingEnd {
                    let restoreStart = max(lastMusicRampEnd + 0.005, interval.end + 0.15)
                    let restoreDuration: Double = 0.35
                    if (restoreStart + restoreDuration) < min(nextStart - 0.20, dynamicDuckingEnd) {
                        safeSetVolumeRamp(
                            params: musicParams,
                            from: duckedVolume,
                            to: normalVolume,
                            start: restoreStart,
                            duration: restoreDuration,
                            totalDuration: totalDuration,
                            lastRampEnd: &lastMusicRampEnd
                        )
                    }
                }
            }
        }

        // Финальное крещендо музыки до начала финального затухания
        let safeClimaxStart = max(climaxStartTime, lastMusicRampEnd + 0.005)
        if musicFadeStartTime > safeClimaxStart {
            safeSetVolumeRamp(
                params: musicParams,
                from: duckedVolume,
                to: climaxVolume,
                start: safeClimaxStart,
                duration: musicFadeStartTime - safeClimaxStart,
                totalDuration: totalDuration,
                lastRampEnd: &lastMusicRampEnd
            )
        }

        // Финальное плавное затухание музыки строго ПОСЛЕ произнесения последней фразы
        let safeFadeStart = max(musicFadeStartTime, lastMusicRampEnd + 0.005)
        if totalDuration > safeFadeStart {
            safeSetVolumeRamp(
                params: musicParams,
                from: climaxVolume,
                to: 0.0,
                start: safeFadeStart,
                duration: totalDuration - safeFadeStart,
                totalDuration: totalDuration,
                lastRampEnd: &lastMusicRampEnd
            )
        }

        audioMix.inputParameters = [speechParams, musicParams]
        return audioMix
    }

    /// Нижний предел громкости речи в паузах (Dialogue Focus).
    /// Любое значение UI-ползунка `originalMusicDucking` оставляет диалогу минимум 5%
    /// уровня: при 0.0 речь в паузах вымирала полностью, и итоговый рендер приходил к тишине.
    static func duckedSpeechVolume(originalMusicDucking: Float) -> Float {
        max(minimumDuckedSpeechVolume, 1.0 - max(0.0, originalMusicDucking))
    }

    /// Чистый (без AVFoundation) расчёт диапазона volume ramp.
    /// AVFoundation прерывает экспорт, если рампы на одной дорожке пересекаются хотя бы на
    /// кадр, и тем более если рамп выходит за конец таймлайна — поэтому здесь ограничиваются
    /// ОБЕ границы: старт (строго после предыдущего рампа) и длительность (не дальше конца таймлайна).
    static func volumeRampTimeRange(
        start: Double,
        duration: Double,
        lastRampEnd: Double,
        totalDuration: Double
    ) -> CMTimeRange? {
        let safeStart = max(lastRampEnd + 0.005, start)
        guard safeStart < totalDuration else { return nil }
        let safeDuration = min(duration, totalDuration - safeStart)
        guard safeDuration >= 0.02 else { return nil }
        return CMTimeRange(
            start: CMTime(seconds: safeStart, preferredTimescale: 600),
            duration: CMTime(seconds: safeDuration, preferredTimescale: 600)
        )
    }

    /// Безопасно применяет volume ramp к дорожке: гарантированно непересекающиеся диапазоны,
    /// которые никогда не выходят за пределы таймлайна.
    private func safeSetVolumeRamp(
        params: AVMutableAudioMixInputParameters,
        from startVolume: Float,
        to endVolume: Float,
        start: Double,
        duration: Double,
        totalDuration: Double,
        lastRampEnd: inout Double
    ) {
        guard let timeRange = Self.volumeRampTimeRange(
            start: start,
            duration: duration,
            lastRampEnd: lastRampEnd,
            totalDuration: totalDuration
        ) else { return }

        params.setVolumeRamp(fromStartVolume: startVolume, toEndVolume: endVolume, timeRange: timeRange)
        lastRampEnd = timeRange.start.seconds + timeRange.duration.seconds
    }
}

// MARK: - Пост-экспортная нормализация громкости (EBU R128, -14 LUFS)

/// Протокол пост-экспортной нормализации громкости готового рендера (SOLID: DIP & ISP).
protocol LongformLoudnessNormalizing: Sendable {
    /// Приводит аудиодорожку к целевым -14 LUFS / -1.5 dBTP двухпроходным `ffmpeg loudnorm`.
    /// Возвращает путь, который конвейер использует дальше: нормализованный файл либо
    /// исходный ненормализованный рендер — отказы этого этапа всегда не фатальны.
    func normalize(videoURL: URL, outputURL: URL, workingDirectory: URL?) async throws -> URL
}

/// Измерения из отчёта `loudnorm=print_format=json` (измерительный проход).
struct LongformLoudnessMeasurement: Sendable, Equatable {
    /// `input_i` — измеренная интегрированная громкость в LUFS.
    let inputIntegrated: Double
    /// `input_tp` — измеренный истинный пик в dBTP.
    let inputTruePeak: Double
    /// `input_lra` — измеренный динамический диапазон громкости (Loudness Range).
    let inputLoudnessRange: Double
    /// `input_thresh` — gating threshold измерителя.
    let inputThreshold: Double
    /// `target_offset` — поправка, которую ffmpeg советует применить во втором проходе.
    let targetOffset: Double
    /// `maximum_ratio` — доля линейного усиления, пережившая потолок true peak (0…1).
    let maximumRatio: Double?

    /// PLR: насколько пики выше интегрированной громкости.
    var peakToLoudnessRatio: Double { inputTruePeak - inputIntegrated }
    /// Сколько децибел нужно добавить, чтобы достичь целевого LUFS.
    var requiredGainDB: Double { CinemaAudioMasteringService.targetLUFS - inputIntegrated }
    /// Сколько децибел остаётся до целевого true peak.
    var truePeakHeadroomDB: Double { CinemaAudioMasteringService.targetTruePeak - inputTruePeak }
}

/// Двухпроходная нормализация громкости поверх ffmpeg (мягкая зависимость: этап просто
/// пропускается, если бинарник или свободное место недоступны).
///
/// Порядок попыток: линейный `loudnorm` с измеренными значениями → динамический
/// `loudnorm` в один проход → статическое усиление → оставить как есть.
final class LongformLoudnessService: LongformLoudnessNormalizing, Sendable {

    private static let logger = Logger(subsystem: "app.shortcast", category: "LongformLoudness")

    /// Запас свободного места на томе результата: временный файл лежит рядом с рендером,
    /// поэтому нужно минимум 2.2× от его текущего размера.
    static let requiredFreeSpaceFactor: Double = 2.2

    /// Сколько децибел мы готовы отдать лимитеру линейного прохода: lookahead-лимитер
    /// loudnorm справляется с этим прозрачно, больше — уже «давит» материал.
    static let maxLimiterAbsorptionDB: Double = 6.0

    /// Если ffmpeg сообщает, что линейное усиление почти целиком упирается в потолок
    /// true peak, надёжнее отдать материал динамическому loudnorm.
    static let minAcceptableMaximumRatio: Double = 0.35

    /// Верхняя граница статического усиления: фильтр `volume` принимает до 10× (20 дБ).
    static let maxStaticGainDB: Double = 20.0

    /// Вариант второго прохода, упорядоченные от предпочтительного к запасным.
    enum Attempt: Sendable, Equatable {
        case linear(LongformLoudnessMeasurement)
        case dynamic
        case staticGainDB(Double)

        var label: String {
            switch self {
            case .linear: return "linear-loudnorm"
            case .dynamic: return "dynamic-loudnorm"
            case .staticGainDB: return "static-gain"
            }
        }
    }

    private let processRunner: any ProcessRunning
    private let ffmpegResolver: @Sendable (URL?) -> URL?
    private let freeSpaceProvider: @Sendable (URL) -> Int64?

    init(
        processRunner: any ProcessRunning = ProcessRunner.shared,
        ffmpegResolver: @Sendable @escaping (URL?) -> URL? = { BinaryUtilities.resolveFFmpegBinary(workingDirectory: $0) },
        freeSpaceProvider: @Sendable @escaping (URL) -> Int64? = { LongformLoudnessService.availableCapacity(for: $0) }
    ) {
        self.processRunner = processRunner
        self.ffmpegResolver = ffmpegResolver
        self.freeSpaceProvider = freeSpaceProvider
    }

    func normalize(videoURL: URL, outputURL: URL, workingDirectory: URL?) async throws -> URL {
        let sourceSize = Self.fileSize(of: videoURL)
        guard sourceSize > 0 else {
            Self.logger.warning("Loudness pass skipped: nothing to normalize at \(videoURL.lastPathComponent, privacy: .public)")
            return outputURL
        }

        guard let ffmpegURL = ffmpegResolver(workingDirectory) else {
            Self.logger.warning("Loudness pass skipped: ffmpeg is unavailable, keeping the pre-normalized render")
            return outputURL
        }

        guard Self.hasEnoughFreeSpace(at: outputURL, sourceSize: sourceSize, provider: freeSpaceProvider) else {
            Self.logger.warning("Loudness pass skipped: the output volume has no room for a 2.2x temporary render")
            return outputURL
        }

        // Временный файл — рядом с результатом (тот же том), поэтому публикация остаётся
        // атомарным rename, а не копированием гигабайтов между volume'ами.
        let tmpURL = Self.makeTemporaryURL(for: outputURL)
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let measurement = await measure(inputURL: videoURL, ffmpegURL: ffmpegURL)
        let attempts = Self.attempts(for: measurement)

        for attempt in attempts {
            do {
                let result = try await processRunner.run(
                    executableURL: ffmpegURL,
                    arguments: Self.normalizationArguments(inputURL: videoURL, outputURL: tmpURL, attempt: attempt),
                    environment: nil
                )
                guard result.isSuccess,
                      Self.isPlausibleNormalizedFile(at: tmpURL, sourceSize: sourceSize) else {
                    Self.logger.warning("Loudness \(attempt.label, privacy: .public) pass produced no usable file")
                    continue
                }
                try Self.publish(tmpURL, replacing: outputURL)
                Self.logOutcome(measurement: measurement, attempt: attempt, ffmpegLog: result.standardError + "\n" + result.standardOutput)
                return outputURL
            } catch {
                Self.logger.warning("Loudness \(attempt.label, privacy: .public) pass failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        Self.logger.warning(
            "Loudness normalization unavailable after \(attempts.count, privacy: .public) attempt(s), keeping the pre-normalized render"
        )
        return outputURL
    }

    // MARK: - Проходы

    /// Проход 1: только измерение. `-vn` не трогает видеопоток, `-f null -` ничего не пишет на диск.
    private func measure(inputURL: URL, ffmpegURL: URL) async -> LongformLoudnessMeasurement? {
        do {
            let result = try await processRunner.run(
                executableURL: ffmpegURL,
                arguments: Self.measurementArguments(inputURL: inputURL),
                environment: nil
            )
            guard result.isSuccess else { return nil }
            return Self.parseMeasurement(from: result.standardError + "\n" + result.standardOutput)
        } catch {
            Self.logger.warning("Loudness measurement pass failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Команда ffmpeg

    /// Целевой префикс loudnorm из общих констант стандарта (без магических чисел).
    static func targetFilterPrefix() -> String {
        "loudnorm=I=\(String(format: "%.0f", CinemaAudioMasteringService.targetLUFS))"
            + ":TP=\(String(format: "%.1f", CinemaAudioMasteringService.targetTruePeak))"
            + ":LRA=\(String(format: "%.0f", CinemaAudioMasteringService.targetLRA))"
    }

    static func measurementArguments(inputURL: URL) -> [String] {
        [
            "-hide_banner",
            "-nostats",
            "-i", inputURL.path,
            "-vn",
            "-af", "\(targetFilterPrefix()):print_format=json",
            "-f", "null",
            "-"
        ]
    }

    static func normalizationArguments(inputURL: URL, outputURL: URL, attempt: Attempt) -> [String] {
        let filter: String
        switch attempt {
        case .linear(let measurement):
            filter = targetFilterPrefix()
                + ":linear=true"
                + ":measured_I=\(Self.format(measurement.inputIntegrated))"
                + ":measured_TP=\(Self.format(measurement.inputTruePeak))"
                + ":measured_LRA=\(Self.format(measurement.inputLoudnessRange))"
                + ":measured_thresh=\(Self.format(measurement.inputThreshold))"
                + ":offset=\(Self.format(measurement.targetOffset))"
                + ":print_format=summary"
        case .dynamic:
            filter = "\(targetFilterPrefix()):print_format=summary"
        case .staticGainDB(let gainDB):
            filter = String(format: "volume=%.2fdB", gainDB)
        }

        return [
            "-hide_banner",
            "-y",
            "-i", inputURL.path,
            "-af", filter,
            // "-c:v copy" обязателен: кадр остаётся bit-exact, поэтому возмущения
            // защиты от Content ID не перекодируются заново, а временный файл равен
            // по размеру рендеру, а не гигабайтам декодированного видео.
            "-c:v", "copy",
            "-c:a", "aac",
            "-b:a", "256k",
            "-ar", "48000",
            "-movflags", "+faststart",
            outputURL.path
        ]
    }

    // MARK: - Выбор попыток

    static func attempts(for measurement: LongformLoudnessMeasurement?) -> [Attempt] {
        guard let measurement else {
            // Измерить нечем: однопроходный динамический loudnorm не требует измеренных значений.
            return [.dynamic]
        }
        var attempts: [Attempt] = []
        if !impliesExcessiveLimiting(measurement) {
            attempts.append(.linear(measurement))
        }
        attempts.append(.dynamic)
        if let gainDB = safeStaticGainDB(measurement) {
            attempts.append(.staticGainDB(gainDB))
        }
        return attempts
    }

    /// Линейный проход допустим, пока требуемый буст не превышает доступный true-peak
    /// headroom сильнее, чем на `maxLimiterAbsorptionDB`.
    static func impliesExcessiveLimiting(_ measurement: LongformLoudnessMeasurement) -> Bool {
        guard measurement.requiredGainDB.isFinite, measurement.truePeakHeadroomDB.isFinite else { return true }
        if measurement.requiredGainDB - measurement.truePeakHeadroomDB > maxLimiterAbsorptionDB { return true }
        guard let ratio = measurement.maximumRatio, ratio.isFinite, ratio >= 0.0, ratio <= 1.0 else {
            // Поле отсутствует или вне диапазона — не угадываем, оставляем линейный проход.
            return false
        }
        return ratio < minAcceptableMaximumRatio
    }

    /// Запасной путь без loudnorm. Статическое усиление САМО ПО СЕБЕ тут недостаточно:
    /// измеренный PLR 17.9 дБ превышает допустимые 12.5 дБ при цели TP -1.5, поэтому
    /// +15.5 дБ одним gain снова обрежет пики — именно поэтому основной метод это
    /// loudnorm со встроенным lookahead-лимитером. Сюда попадаем только когда усиление
    /// гарантированно влезает в true-peak headroom.
    static func safeStaticGainDB(_ measurement: LongformLoudnessMeasurement) -> Double? {
        guard measurement.requiredGainDB <= measurement.truePeakHeadroomDB else { return nil }
        let linearGain = CinemaAudioMasteringService.calculateVolumeGain(
            measuredLUFS: measurement.inputIntegrated,
            target: CinemaAudioMasteringService.targetLUFS
        )
        guard linearGain.isFinite, linearGain > 0.0 else { return nil }
        let gainDB = min(max(20.0 * log10(Double(linearGain)), -maxStaticGainDB), maxStaticGainDB)
        guard abs(gainDB) >= 0.5 else { return nil }
        return gainDB
    }

    // MARK: - Разбор отчётов ffmpeg

    /// Разбирает хвостовой JSON-блок loudnorm. ffmpeg печатает числа строками, поэтому
    /// оба варианта (строка и число) равнодопустимы.
    static func parseMeasurement(from text: String) -> LongformLoudnessMeasurement? {
        guard let openBrace = text.range(of: "{", options: .backwards),
              let closeBrace = text.range(of: "}", options: .backwards),
              closeBrace.upperBound > openBrace.lowerBound else { return nil }

        let json = String(text[openBrace.lowerBound..<closeBrace.upperBound])
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let values = object as? [String: Any] else { return nil }

        func number(_ key: String) -> Double? {
            switch values[key] {
            case let value as NSNumber: return value.doubleValue
            case let value as String: return Double(value.trimmingCharacters(in: .whitespaces))
            default: return nil
            }
        }

        guard let integrated = number("input_i"),
              let truePeak = number("input_tp"),
              let loudnessRange = number("input_lra"),
              let threshold = number("input_thresh"),
              integrated.isFinite, truePeak.isFinite, loudnessRange.isFinite, threshold.isFinite
        else { return nil }

        return LongformLoudnessMeasurement(
            inputIntegrated: integrated,
            inputTruePeak: truePeak,
            inputLoudnessRange: loudnessRange,
            inputThreshold: threshold,
            targetOffset: number("target_offset") ?? 0.0,
            maximumRatio: number("maximum_ratio")
        )
    }

    /// Интегрированная громкость результата из отчёта `print_format=summary`
    /// («Output Integrated:   -14.1 LUFS») — только для журнала «до/после».
    static func parseSummaryIntegratedLoudness(from text: String) -> Double? {
        for line in text.split(separator: "\n") {
            guard let found = line.range(of: "Output Integrated", options: .caseInsensitive) else { continue }
            let tail = line[found.upperBound...]
            guard let start = tail.firstIndex(where: { $0 == "-" || $0.isNumber }) else { return nil }
            let token = tail[start...].prefix(while: { $0 == "-" || $0 == "." || $0.isNumber })
            return Double(token)
        }
        return nil
    }

    private static func logOutcome(
        measurement: LongformLoudnessMeasurement?,
        attempt: Attempt,
        ffmpegLog: String
    ) {
        let before = measurement.map { Self.format($0.inputIntegrated) + " LUFS" } ?? "not measured"
        let requested = Self.format(CinemaAudioMasteringService.targetLUFS)
        let achieved = Self.parseSummaryIntegratedLoudness(from: ffmpegLog).map { Self.format($0) } ?? "≈\(requested)"
        Self.logger.notice(
            "Loudness normalized with \(attempt.label, privacy: .public): before \(before, privacy: .public) → target \(requested, privacy: .public) LUFS (measured output \(achieved, privacy: .public))"
        )
    }

    // MARK: - Файловая дисциплина

    /// Временный файл всегда рядом с результатом: тот же том → атомарный rename.
    static func makeTemporaryURL(for outputURL: URL) -> URL {
        let name = outputURL.deletingPathExtension().lastPathComponent
        let extensionName = outputURL.pathExtension
        let unique = String(UUID().uuidString.prefix(8))
        let fileName = extensionName.isEmpty
            ? "loudnorm_\(name)_\(unique)"
            : "loudnorm_\(name)_\(unique).\(extensionName)"
        return outputURL.deletingLastPathComponent().appendingPathComponent(fileName)
    }

    static func hasEnoughFreeSpace(
        at outputURL: URL,
        sourceSize: Int64,
        provider: @Sendable (URL) -> Int64?
    ) -> Bool {
        guard let capacity = provider(outputURL.deletingLastPathComponent()), capacity > 0 else { return false }
        return Double(capacity) >= Double(sourceSize) * requiredFreeSpaceFactor
    }

    /// Актуальный размер файла. `URL.resourceValues` кэширует значения на объекте NSURL,
    /// а при нескольких попытках один и тот же временный файл перечитывается уже после
    /// записи ffmpeg — старьё отвергало бы успешный проход.
    static func fileSize(of url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Результат принимается только если он непустой и не подозрительно маленький:
    /// при `-c:v copy` размер нормализованного файла ≈ размер исходного рендера.
    static func isPlausibleNormalizedFile(at url: URL, sourceSize: Int64) -> Bool {
        let size = fileSize(of: url)
        guard size >= 1024 else { return false }
        guard sourceSize > 0 else { return true }
        return size >= sourceSize / 2
    }

    /// Публикует результат заменой в пределах тома. Ненормализованный рендер сначала
    /// уходит в служебную копию, поэтому сбой на полпути не может оставить конвейер без файла.
    static func publish(_ temporaryURL: URL, replacing outputURL: URL) throws {
        let backupURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent(".\(outputURL.lastPathComponent).prenorm")
        var movedOriginal = false

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: backupURL)
            try FileManager.default.moveItem(at: outputURL, to: backupURL)
            movedOriginal = true
        }

        do {
            try FileManager.default.moveItem(at: temporaryURL, to: outputURL)
        } catch {
            if movedOriginal {
                try? FileManager.default.moveItem(at: backupURL, to: outputURL)
            }
            throw error
        }

        try? FileManager.default.removeItem(at: backupURL)
    }

    // MARK: - Soft dependency на ffmpeg

    /// Свободное место, которое ffmpeg реально получит на томе результата.
    static func availableCapacity(for directoryURL: URL) -> Int64? {
        let values = try? directoryURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}
