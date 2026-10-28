import Foundation
import AVFoundation
import os

/// Анализирует аудио-плотность (dBFS) для определения конца драматического тела фильма.
/// Используется вместо hardcoded 95% для credits guard.
actor AudioDensityAnalyzer {
    
    private static let logger = Logger(subsystem: "app.shortcast", category: "AudioDensity")
    
    /// Находит точку где заканчивается драматическое тело фильма.
    /// Возвращает timestamp в секундах от начала.
    /// 
    /// Алгоритм:
    /// 1. Анализ dBFS по времени (окно 1 секунда)
    /// 2. Найти где громкость падает ниже -40 dBFS на протяжении 30+ секунд
    /// 3. Эта точка = конец драматического тела (начало титров/тишины)
    ///
    /// Fallback: если анализ не удался, возвращает 95% длительности
    func findDramaticBodyEnd(
        videoURL: URL,
        totalDuration: Double,
        silenceThresholdDB: Double = -40.0,
        minSilenceDuration: Double = 30.0
    ) async -> Double {
        guard totalDuration > 0 else { return totalDuration * 0.95 }
        
        do {
            let loudnessTimeline = try await analyzeLoudnessTimeline(
                url: videoURL,
                windowSize: 1.0
            )
            
            // Ищем первую паузу >= minSilenceDuration где громкость < silenceThresholdDB
            var silenceStart: Double? = nil
            for point in loudnessTimeline {
                if point.loudnessDB < silenceThresholdDB {
                    if silenceStart == nil {
                        silenceStart = point.timestamp
                    }
                    let silenceDuration = point.timestamp - (silenceStart ?? point.timestamp)
                    if silenceDuration >= minSilenceDuration {
                        Self.logger.info("Found dramatic body end at \(silenceStart ?? 0)s (silence from \(silenceStart ?? 0)s to \(point.timestamp)s)")
                        return silenceStart ?? (totalDuration * 0.95)
                    }
                } else {
                    silenceStart = nil
                }
            }
            
            // Не нашли достаточно длинную тишину — используем 95%
            Self.logger.info("No long silence found, using 95% fallback")
            return totalDuration * 0.95
            
        } catch {
            Self.logger.warning("Loudness analysis failed: \(error.localizedDescription), using 95% fallback")
            return totalDuration * 0.95
        }
    }
    
    /// Анализирует громкость по времени с заданным окном
    private func analyzeLoudnessTimeline(url: URL, windowSize: Double) async throws -> [LoudnessPoint] {
        let asset = AVURLAsset(url: url)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else {
            throw AnalysisError.noAudioTrack
        }
        
        let duration = try await asset.load(.duration)
        let totalSeconds = CMTimeGetSeconds(duration)
        
        // Используем ffmpeg для анализа громкости по времени
        // ebur128 фильтр выводит loudness по каждому окну
        guard let ffmpegURL = try? await BinaryDownloadService.ensureAvailable(
            .ffmpeg,
            workingDirectory: url.deletingLastPathComponent()
        ) else {
            throw AnalysisError.ffmpegNotAvailable
        }
        
        let args = [
            "-i", url.path,
            "-af", "ebur128=peak=true",
            "-f", "null",
            "-"
        ]
        
        let result = try await ProcessRunner.shared.run(executableURL: ffmpegURL, arguments: args)
        
        // Парсим вывод ebur128
        return parseEbur128Output(result.standardError, totalDuration: totalSeconds, windowSize: windowSize)
    }
    
    /// Парсит вывод ffmpeg ebur128 фильтра
    private func parseEbur128Output(_ output: String, totalDuration: Double, windowSize: Double) -> [LoudnessPoint] {
        var points: [LoudnessPoint] = []
        
        // ebur128 выводит строки вида:
        // t: 1.0 — loudness: -23.5 LUFS
        let lines = output.components(separatedBy: "\n")
        for line in lines {
            guard line.contains("t:") && line.contains("loudness:") else { continue }
            
            // Извлекаем timestamp
            guard let tRange = line.range(of: "t:\\s*([0-9.]+)", options: .regularExpression),
                  let tsString = line[tRange].split(separator: ":").last?.trimmingCharacters(in: .whitespaces),
                  let timestamp = Double(tsString) else { continue }
            
            // Извлекаем loudness
            guard let lRange = line.range(of: "loudness:\\s*([-0-9.]+)", options: .regularExpression),
                  let lString = line[lRange].split(separator: ":").last?.trimmingCharacters(in: .whitespaces),
                  let loudness = Double(lString) else { continue }
            
            points.append(LoudnessPoint(timestamp: timestamp, loudnessDB: loudness))
        }
        
        // Если не удалось распарсить, возвращаем пустой массив (fallback на 95%)
        return points
    }
    
    struct LoudnessPoint {
        let timestamp: Double
        let loudnessDB: Double
    }
    
    enum AnalysisError: LocalizedError {
        case noAudioTrack
        case ffmpegNotAvailable
        
        var errorDescription: String? {
            switch self {
            case .noAudioTrack:
                return "No audio track found"
            case .ffmpegNotAvailable:
                return "FFmpeg not available for loudness analysis"
            }
        }
    }
}
