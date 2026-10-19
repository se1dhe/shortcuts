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
    var fileSizeBytes: Int64?

    /// Метаданные TMDB (постер, синопсис, жанры)
    var tmdbMetadata: MovieIdentity?

    /// Полная пословная транскрипция WhisperKit
    var transcript: Transcript?

    /// Обнаруженные границы кинематографических сцен
    var scenes: [DetectedScene]

    /// Сгенерированные философские концепты для видео-эссе
    var discoveredConcepts: [ThematicConcept]

    /// Полный структурированный анализ фильма с ОДНОЙ главной темой и разбором ИИ
    var thematicAnalysis: ThematicAnalysisResult?

    /// Выбранный пользователем концепт эссе
    var selectedConcept: ThematicConcept?

    /// Результат сборки 16:9 эссе (файл, таймлайн, метаданные YouTube)
    var longformResult: LongformBuildResult?

    /// Отобранные вирусные кандидаты для коротких видео (Shorts / Reels / TikTok)
    var candidates: [ClipCandidate]

    var createdAt: Date
    var updatedAt: Date

    /// Ключи, которые не удалось прочитать при загрузке архива. Проект при этом
    /// остаётся рабочим, но молча терять данные нельзя: хранилище по этому списку
    /// пишет в лог и считает повреждённые архивы.
    private(set) var decodeDamage: [String] = []

    init(
        id: UUID = UUID(),
        sourceMovieURL: URL,
        movieFileName: String,
        movieTitle: String,
        movieYear: String? = nil,
        durationSeconds: Double = 0,
        fileSizeBytes: Int64? = nil,
        tmdbMetadata: MovieIdentity? = nil,
        transcript: Transcript? = nil,
        scenes: [DetectedScene] = [],
        discoveredConcepts: [ThematicConcept] = [],
        thematicAnalysis: ThematicAnalysisResult? = nil,
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
        self.fileSizeBytes = fileSizeBytes
        self.tmdbMetadata = tmdbMetadata
        self.transcript = transcript
        self.scenes = scenes
        self.discoveredConcepts = discoveredConcepts
        self.thematicAnalysis = thematicAnalysis
        self.selectedConcept = selectedConcept
        self.longformResult = longformResult
        self.candidates = candidates
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, sourceMovieURL, movieFileName, movieTitle, movieYear, durationSeconds, fileSizeBytes
        case tmdbMetadata, transcript, scenes, discoveredConcepts, thematicAnalysis, selectedConcept
        case longformResult, candidates, createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        sourceMovieURL = try container.decode(URL.self, forKey: .sourceMovieURL)
        movieFileName = try container.decode(String.self, forKey: .movieFileName)
        movieTitle = try container.decode(String.self, forKey: .movieTitle)
        movieYear = try container.decodeIfPresent(String.self, forKey: .movieYear)
        durationSeconds = try container.decode(Double.self, forKey: .durationSeconds)
        fileSizeBytes = try container.decodeIfPresent(Int64.self, forKey: .fileSizeBytes)
        tmdbMetadata = try container.decodeIfPresent(MovieIdentity.self, forKey: .tmdbMetadata)
        transcript = try container.decodeIfPresent(Transcript.self, forKey: .transcript)
        // Один битый массив не имеет права «съедать» весь фильм: поле становится
        // пустым, а ключ попадает в decodeDamage — хранилище его логирует и считает.
        var damage: [String] = []
        scenes = Self.readArray([DetectedScene].self, forKey: .scenes, in: container, damage: &damage)
        discoveredConcepts = Self.readArray([ThematicConcept].self, forKey: .discoveredConcepts, in: container, damage: &damage)
        thematicAnalysis = try container.decodeIfPresent(ThematicAnalysisResult.self, forKey: .thematicAnalysis)
        selectedConcept = try container.decodeIfPresent(ThematicConcept.self, forKey: .selectedConcept)
        longformResult = Self.read(LongformBuildResult.self, forKey: .longformResult, in: container, damage: &damage)
        candidates = Self.readArray([ClipCandidate].self, forKey: .candidates, in: container, damage: &damage)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        decodeDamage = damage
    }

    /// Ключ отсутствует — нормально (старый архив). Ключ есть, но не читается —
    /// повреждение: возвращаем nil и помечаем его в `damage`.
    private static func read<T: Decodable>(
        _ type: T.Type,
        forKey key: CodingKeys,
        in container: KeyedDecodingContainer<CodingKeys>,
        damage: inout [String]
    ) -> T? {
        guard container.contains(key) else { return nil }
        if let value = try? container.decode(T.self, forKey: key) { return value }
        damage.append(key.rawValue)
        return nil
    }

    private static func readArray<T: Decodable>(
        _ type: [T].Type,
        forKey key: CodingKeys,
        in container: KeyedDecodingContainer<CodingKeys>,
        damage: inout [String]
    ) -> [T] {
        read(type, forKey: key, in: container, damage: &damage) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(sourceMovieURL, forKey: .sourceMovieURL)
        try container.encode(movieFileName, forKey: .movieFileName)
        try container.encode(movieTitle, forKey: .movieTitle)
        try container.encodeIfPresent(movieYear, forKey: .movieYear)
        try container.encode(durationSeconds, forKey: .durationSeconds)
        try container.encodeIfPresent(fileSizeBytes, forKey: .fileSizeBytes)
        try container.encodeIfPresent(tmdbMetadata, forKey: .tmdbMetadata)
        try container.encodeIfPresent(transcript, forKey: .transcript)
        try container.encode(scenes, forKey: .scenes)
        try container.encode(discoveredConcepts, forKey: .discoveredConcepts)
        try container.encodeIfPresent(thematicAnalysis, forKey: .thematicAnalysis)
        try container.encodeIfPresent(selectedConcept, forKey: .selectedConcept)
        try container.encodeIfPresent(longformResult, forKey: .longformResult)
        try container.encode(candidates, forKey: .candidates)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }

    /// Проверяет, готов ли полный анализ фильма для мгновенного создания шортсов без повторного анализа
    var isAnalysisReady: Bool {
        transcript != nil && !scenes.isEmpty
    }
}
