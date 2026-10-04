import Foundation

typealias DetectedScene = SceneDetectionService.Scene

/// Доменная модель проекта полного фильма в Shortcast Cinema (SOLID: Single Responsibility).
/// Инкапсулирует полное состояние обработки фильма: транскрипцию Whisper, детекцию сцен,
/// сгенерированные концепты эссе, готовое длинное видео и набор вирусных шортсов.
struct FilmProject: Identifiable, Codable, Sendable {

    let id: UUID
    let sourceMovieURL: URL
    var movieFileName: String
    var movieTitle: String
    var movieYear: String?
    var durationSeconds: Double

    /// Метаданные TMDB (постер, синопсис, жанры)
    var tmdbMetadata: MovieIdentity?

    /// Полная пословная транскрипция WhisperKit
    var transcript: Transcript?

    /// Обнаруженные границы кинематографических сцен
    var scenes: [DetectedScene]

    /// Сгенерированные философские концепты для видео-эссе
    var discoveredConcepts: [ThematicConcept]

    /// Выбранный пользователем концепт эссе
    var selectedConcept: ThematicConcept?

    /// Результат сборки 16:9 эссе (файл, таймлайн, метаданные YouTube) - сессионный объект в памяти
    var longformResult: LongformBuildResult?

    /// Отобранные вирусные кандидаты для коротких видео (Shorts / Reels / TikTok)
    var candidates: [ClipCandidate]

    var createdAt: Date
    var updatedAt: Date

    init(
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

    enum CodingKeys: String, CodingKey {
        case id, sourceMovieURL, movieFileName, movieTitle, movieYear, durationSeconds
        case tmdbMetadata, transcript, scenes, discoveredConcepts, selectedConcept
        case candidates, createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        sourceMovieURL = try container.decode(URL.self, forKey: .sourceMovieURL)
        movieFileName = try container.decode(String.self, forKey: .movieFileName)
        movieTitle = try container.decode(String.self, forKey: .movieTitle)
        movieYear = try container.decodeIfPresent(String.self, forKey: .movieYear)
        durationSeconds = try container.decode(Double.self, forKey: .durationSeconds)
        tmdbMetadata = try container.decodeIfPresent(MovieIdentity.self, forKey: .tmdbMetadata)
        transcript = try container.decodeIfPresent(Transcript.self, forKey: .transcript)
        scenes = try container.decode([DetectedScene].self, forKey: .scenes)
        discoveredConcepts = try container.decode([ThematicConcept].self, forKey: .discoveredConcepts)
        selectedConcept = try container.decodeIfPresent(ThematicConcept.self, forKey: .selectedConcept)
        candidates = try container.decode([ClipCandidate].self, forKey: .candidates)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        longformResult = nil
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(sourceMovieURL, forKey: .sourceMovieURL)
        try container.encode(movieFileName, forKey: .movieFileName)
        try container.encode(movieTitle, forKey: .movieTitle)
        try container.encodeIfPresent(movieYear, forKey: .movieYear)
        try container.encode(durationSeconds, forKey: .durationSeconds)
        try container.encodeIfPresent(tmdbMetadata, forKey: .tmdbMetadata)
        try container.encodeIfPresent(transcript, forKey: .transcript)
        try container.encode(scenes, forKey: .scenes)
        try container.encode(discoveredConcepts, forKey: .discoveredConcepts)
        try container.encodeIfPresent(selectedConcept, forKey: .selectedConcept)
        try container.encode(candidates, forKey: .candidates)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }

    /// Проверяет, готов ли полный анализ фильма для мгновенного создания шортсов без повторного анализа
    var isAnalysisReady: Bool {
        transcript != nil && !scenes.isEmpty
    }
}
