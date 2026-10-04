import Foundation

/// Доменная модель проекта полного фильма в Shortcast Cinema (SOLID: Single Responsibility).
/// Инкапсулирует полное состояние обработки фильма: транскрипцию Whisper, детекцию сцен,
/// сгенерированные концепты эссе, готовое длинное видео и набор вирусных шортсов.
public struct FilmProject: Identifiable, Codable, Sendable {

    public let id: UUID
    public let sourceMovieURL: URL
    public var movieFileName: String
    public var movieTitle: String
    public var movieYear: String?
    public var durationSeconds: Double

    /// Метаданные TMDB (постер, синопсис, жанры)
    public var tmdbMetadata: MovieIdentity?

    /// Полная пословная транскрипция WhisperKit
    public var transcript: Transcript?

    /// Обнаруженные границы кинематографических сцен
    public var scenes: [DetectedScene]

    /// Сгенерированные философские концепты для видео-эссе
    public var discoveredConcepts: [ThematicConcept]

    /// Выбранный пользователем концепт эссе
    public var selectedConcept: ThematicConcept?

    /// Результат сборки 16:9 эссе (файл, таймлайн, метаданные YouTube)
    public var longformResult: LongformBuildResult?

    /// Отобранные вирусные кандидаты для коротких видео (Shorts / Reels / TikTok)
    public var candidates: [ClipCandidate]

    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        sourceMovieURL: URL,
        movieFileName: String,
        movieTitle: String,
        movieYear: String? = nil,
        durationSeconds: Double = 0,
        tmdbMetadata: MovieIdentity? = nil,
        transcript: Transcript? = nil,
        scenes: [DetectedScene] = [],
        discoveredConcepts: [ThematicConcept] = [],
        selectedConcept: ThematicConcept? = nil,
        longformResult: LongformBuildResult? = nil,
        candidates: [ClipCandidate] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.sourceMovieURL = sourceMovieURL
        self.movieFileName = movieFileName
        self.movieTitle = movieTitle
        self.movieYear = movieYear
        self.durationSeconds = durationSeconds
        self.tmdbMetadata = tmdbMetadata
        self.transcript = transcript
        self.scenes = scenes
        self.discoveredConcepts = discoveredConcepts
        self.selectedConcept = selectedConcept
        self.longformResult = longformResult
        self.candidates = candidates
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Проверяет, готов ли полный анализ фильма для мгновенного создания шортсов без повторного анализа
    public var isAnalysisReady: Bool {
        transcript != nil && !scenes.isEmpty
    }
}
