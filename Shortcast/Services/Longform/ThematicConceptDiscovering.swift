import Foundation

/// Протокол сервиса выявления философских лейтмотивов фильма для длинных видео
protocol ThematicConceptDiscovering: Sendable {
    /// Анализирует транскрипт или метаданные фильма и генерирует 4–7 концептов
    func discoverConcepts(
        from transcript: Transcript,
        movieTitle: String,
        movieOverview: String?,
        forceAI: Bool,
        modelManager: ModelManager?
    ) async throws -> [ThematicConcept]

    /// Возвращает качественные темы по умолчанию, если модель недоступна или запрос завершился сбоем
    func fallbackConcepts(for movieTitle: String) -> [ThematicConcept]
}

extension ThematicConceptDiscovering {
    func discoverConcepts(
        from transcript: Transcript,
        movieTitle: String,
        modelManager: ModelManager? = nil
    ) async throws -> [ThematicConcept] {
        try await discoverConcepts(
            from: transcript,
            movieTitle: movieTitle,
            movieOverview: nil,
            forceAI: false,
            modelManager: modelManager
        )
    }
}
