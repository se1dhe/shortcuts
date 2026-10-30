import Foundation

/// Ошибки поиска темы. Раньше вместо них pipeline молча возвращал
/// хардкод-таблицу, и под «выбором ИИ» скрывалась строка из кода.
enum ThematicDiscoveryError: Error, LocalizedError {
    case transcriptEmpty
    case directorUnavailable(String)
    case modelReturnedNoText
    case unparseableOutput(String)
    case noGroundedTheme(String)
    case invalidEssaySelection(String)
    /// Модель не дописала ответ (упёрлась в лимит токенов или оборвала объект).
    /// Раньше этот случай молча «долечивал» парсер и выдавал обрыв за готовый анализ.
    case replyTruncated(tokens: Int, cap: Int?)

    var errorDescription: String? {
        switch self {
        case .transcriptEmpty:
            return "Транскрипт пуст — модели нечего анализировать. Сначала прогоните Whisper."
        case .directorUnavailable(let detail):
            return "Director не загрузился (\(detail)). Тему для эссе выбирает только он."
        case .modelReturnedNoText:
            return "Director вернул пустой ответ."
        case .unparseableOutput(let preview):
            return "Director не выдал валидный JSON темы: \(preview)"
        case .noGroundedTheme(let detail):
            return "Ни одна тема, предложенная моделью, не прошла проверку честности: \(detail). "
                + "Тему мы не придумываем — перезапустите анализ или выберите другую тему-кандидата из тех, что уже есть."
        case .invalidEssaySelection(let detail):
            return "Темы найдены, но план сцен не прошёл проверку: \(detail) Повторите подбор сцен."
        case .replyTruncated(let tokens, let cap):
            let capText = cap.map { ", ліміт \($0)" } ?? ""
            return "Director не дописал ответ (\(tokens) токенов\(capText)) — эссе из обрыва не собирается. Повторите анализ."
        }
    }
}

/// Протокол сервиса выявления философских лейтмотивов фильма для длинных видео (SOLID)
protocol ThematicConceptDiscovering: Sendable {
    func planThematicAnalysis(
        for concept: ThematicConcept,
        candidates: [ThematicConcept],
        from transcript: Transcript,
        movieTitle: String,
        movieOverview: String?,
        modelManager: ModelManager,
        directorProfile: ChatModelProfile
    ) async throws -> ThematicAnalysisResult

    /// Глубоко анализирует полный сценарий фильма моделью Director и возвращает
    /// структурированный результат: ОДНУ главную тему, обоснование выбора и
    /// альтернативные грани. Если тема не получена от модели — бросает ошибку:
    /// тихой подмены на заготовку больше нет.
    func discoverThematicAnalysis(
        from transcript: Transcript,
        movieTitle: String,
        movieOverview: String?,
        modelManager: ModelManager,
        directorProfile: ChatModelProfile
    ) async throws -> ThematicAnalysisResult
}

extension ThematicConceptDiscovering {
    func planThematicAnalysis(
        for concept: ThematicConcept,
        candidates: [ThematicConcept],
        from transcript: Transcript,
        movieTitle: String,
        movieOverview: String?,
        modelManager: ModelManager,
        directorProfile: ChatModelProfile
    ) async throws -> ThematicAnalysisResult {
        throw ThematicDiscoveryError.directorUnavailable("сервис не поддерживает анализ выбранной темы")
    }

    func discoverThematicAnalysis(
        from transcript: Transcript,
        movieTitle: String,
        modelManager: ModelManager,
        directorProfile: ChatModelProfile
    ) async throws -> ThematicAnalysisResult {
        try await discoverThematicAnalysis(
            from: transcript,
            movieTitle: movieTitle,
            movieOverview: nil,
            modelManager: modelManager,
            directorProfile: directorProfile
        )
    }
}
