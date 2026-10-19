import Foundation

/// Ошибки поиска темы. Раньше вместо них pipeline молча возвращал
/// хардкод-таблицу, и под «выбором ИИ» скрывалась строка из кода.
enum ThematicDiscoveryError: Error, LocalizedError {
    case transcriptEmpty
    case directorUnavailable(String)
    case modelReturnedNoText
    case unparseableOutput(String)

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
        }
    }
}

/// Протокол сервиса выявления философских лейтмотивов фильма для длинных видео (SOLID)
protocol ThematicConceptDiscovering: Sendable {
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
