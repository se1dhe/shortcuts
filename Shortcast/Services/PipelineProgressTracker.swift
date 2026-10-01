import Foundation
import Observation

/// Tracks multi-stage pipeline progress and calculates accurate, smooth ETA.
/// Follows Single Responsibility Principle (SRP) for all progress reporting.
@MainActor
@Observable
final class PipelineProgressTracker {

    enum PipelineStage: String, CaseIterable, Sendable {
        case detectingMovie   = "Определение фильма и рейтингов"
        case transcribing     = "Транскрипция диалогов"
        case analyzingStory   = "Режиссерский анализ и поиск арок"
        case renderingClips   = "Монтаж 1:1, сабы и сведение звука"
        case completed        = "Готово к публикации"

        var weight: Double {
            switch self {
            case .detectingMovie: return 0.05
            case .transcribing:   return 0.45
            case .analyzingStory: return 0.20
            case .renderingClips: return 0.30
            case .completed:      return 0.0
            }
        }

        var cumulativeBase: Double {
            switch self {
            case .detectingMovie: return 0.00
            case .transcribing:   return 0.05
            case .analyzingStory: return 0.50
            case .renderingClips: return 0.70
            case .completed:      return 1.00
            }
        }
    }

    private(set) var currentStage: PipelineStage = .detectingMovie
    private(set) var stageProgress: Double = 0.0
    private(set) var overallProgress: Double = 0.0
    private(set) var statusMessage: String = "Инициализация..."
    private(set) var detailedMetrics: String = ""
    private(set) var estimatedSecondsRemaining: Double?
    private(set) var formattedETA: String = "Вычисление..."
    private(set) var processingSpeedLabel: String?

    // Timing tracking
    private var pipelineStartTime: Date?
    private var stageStartTime: Date?
    private var totalVideoDurationSeconds: Double = 0

    // Exponential moving average for ETA smoothing
    private var smoothedETA: Double?

    // MARK: - Lifecycle

    func reset(totalVideoDuration: Double = 0) {
        currentStage = .detectingMovie
        stageProgress = 0.0
        overallProgress = 0.0
        statusMessage = "Определение фильма..."
        detailedMetrics = ""
        estimatedSecondsRemaining = nil
        formattedETA = "Вычисление..."
        processingSpeedLabel = nil
        totalVideoDurationSeconds = totalVideoDuration
        pipelineStartTime = Date()
        stageStartTime = Date()
        smoothedETA = nil
    }

    // MARK: - Stage 1: Movie Detection (5%)

    func updateMovieDetection(title: String, year: String, imdb: String?, rottenTomatoes: String?) {
        currentStage = .detectingMovie
        stageProgress = 1.0
        overallProgress = PipelineStage.detectingMovie.cumulativeBase + (PipelineStage.detectingMovie.weight * 1.0)
        
        var ratingsStr = ""
        if let imdb, !imdb.isEmpty { ratingsStr += "★ IMDb \(imdb)  " }
        if let rottenTomatoes, !rottenTomatoes.isEmpty { ratingsStr += "🍅 RT \(rottenTomatoes)" }
        
        statusMessage = "Фильм определен: \(title) (\(year))"
        detailedMetrics = ratingsStr.isEmpty ? "Метаданные получены" : ratingsStr
    }

    // MARK: - Stage 2: WhisperKit Transcription (45%)

    func startTranscription(totalSeconds: Double) {
        currentStage = .transcribing
        stageProgress = 0.0
        totalVideoDurationSeconds = totalSeconds
        stageStartTime = Date()
        statusMessage = "Транскрипция аудиодорожки..."
        detailedMetrics = "Подготовка WhisperKit..."
    }

    func updateTranscriptionProgress(processedSeconds: Double) {
        guard totalVideoDurationSeconds > 0 else { return }
        currentStage = .transcribing
        
        let fraction = min(max(processedSeconds / totalVideoDurationSeconds, 0.0), 1.0)
        stageProgress = fraction
        overallProgress = PipelineStage.transcribing.cumulativeBase + (PipelineStage.transcribing.weight * fraction)

        let elapsed = max(Date().timeIntervalSince(stageStartTime ?? Date()), 0.5)
        let speedX = processedSeconds / elapsed
        processingSpeedLabel = String(format: "%.1fx", speedX)

        let remainingVideoSec = max(totalVideoDurationSeconds - processedSeconds, 0)
        let rawETA = speedX > 0 ? (remainingVideoSec / speedX) : nil

        if let rawETA {
            // Factor in remaining stages (Director ~30s, Render ~45s)
            let totalRemaining = rawETA + 75.0
            updateSmoothedETA(totalRemaining)
        }

        let curMin = Int(processedSeconds) / 60
        let totMin = Int(totalVideoDurationSeconds) / 60
        statusMessage = "Транскрипция диалогов"
        detailedMetrics = "\(curMin) из \(totMin) мин · скорость \(processingSpeedLabel ?? "1.0x")"
    }

    // MARK: - Stage 3: Story Arc Director (20%)

    func startStoryAnalysis() {
        currentStage = .analyzingStory
        stageProgress = 0.0
        overallProgress = PipelineStage.analyzingStory.cumulativeBase
        stageStartTime = Date()
        statusMessage = "Режиссерский анализ и поиск арок"
        detailedMetrics = "Qwen / Gemma анализирует сценарий..."
    }

    func updateStoryAnalysis(fraction: Double, arcFound: String? = nil) {
        currentStage = .analyzingStory
        stageProgress = min(max(fraction, 0.0), 1.0)
        overallProgress = PipelineStage.analyzingStory.cumulativeBase + (PipelineStage.analyzingStory.weight * stageProgress)

        let elapsed = max(Date().timeIntervalSince(stageStartTime ?? Date()), 1.0)
        if stageProgress > 0.05 {
            let estTotal = elapsed / stageProgress
            let remInStage = max(estTotal - elapsed, 0)
            updateSmoothedETA(remInStage + 45.0) // 45s for clip render
        }

        if let arcFound {
            detailedMetrics = "Найдена арка: «\(arcFound)»"
        } else {
            detailedMetrics = "Кластеризация персонажей и конфликтов..."
        }
    }

    // MARK: - Stage 4: Clip Rendering (30%)

    func startRendering(totalClips: Int) {
        currentStage = .renderingClips
        stageProgress = 0.0
        overallProgress = PipelineStage.renderingClips.cumulativeBase
        stageStartTime = Date()
        statusMessage = "Монтаж 1:1, сабы и сведение звука"
        detailedMetrics = "Подготовка \(totalClips) кинематографических эдитов..."
    }

    func updateRenderingProgress(clipIndex: Int, totalClips: Int, clipName: String) {
        currentStage = .renderingClips
        guard totalClips > 0 else { return }
        
        let fraction = min(max(Double(clipIndex) / Double(totalClips), 0.0), 1.0)
        stageProgress = fraction
        overallProgress = PipelineStage.renderingClips.cumulativeBase + (PipelineStage.renderingClips.weight * fraction)

        let elapsed = max(Date().timeIntervalSince(stageStartTime ?? Date()), 1.0)
        if fraction > 0.1 {
            let estTotal = elapsed / fraction
            let rem = max(estTotal - elapsed, 0)
            updateSmoothedETA(rem)
        }

        statusMessage = "Сборка эдита \(clipIndex + 1) из \(totalClips)"
        detailedMetrics = "«\(clipName)» · 1:1 кадрирование, глубина сабов"
    }

    func finish() {
        currentStage = .completed
        stageProgress = 1.0
        overallProgress = 1.0
        estimatedSecondsRemaining = 0
        formattedETA = "Завершено"
        statusMessage = "Все эдиты готовы к публикации!"
        detailedMetrics = "Выберите клип для просмотра или автопостинга"
    }

    // MARK: - Private Helpers

    private func updateSmoothedETA(_ rawSeconds: Double) {
        if let current = smoothedETA {
            // Smooth jitter: 70% current, 30% new
            smoothedETA = (current * 0.7) + (rawSeconds * 0.3)
        } else {
            smoothedETA = rawSeconds
        }
        estimatedSecondsRemaining = smoothedETA
        formattedETA = Self.formatDuration(smoothedETA ?? rawSeconds)
    }

    private static func formatDuration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s <= 5 { return "менее 10 сек" }
        let mins = s / 60
        let secs = s % 60
        if mins == 0 {
            return "~\(secs) сек"
        } else if mins < 60 {
            return "~\(mins) мин \(secs > 0 ? "\(secs) сек" : "")"
        } else {
            let hours = mins / 60
            let remMins = mins % 60
            return "~\(hours) ч \(remMins) мин"
        }
    }
}
