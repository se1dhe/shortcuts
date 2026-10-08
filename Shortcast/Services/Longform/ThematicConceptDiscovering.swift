import Foundation

/// Протокол сервиса выявления философских лейтмотивов фильма для длинных видео (SOLID)
protocol ThematicConceptDiscovering: Sendable {
    /// Глубоко анализирует полный сценарий фильма и возвращает структурированный результат:
    /// ОДНУ главную тему, обоснование выбора от лица режиссера-ИИ и альтернативные грани
    func discoverThematicAnalysis(
        from transcript: Transcript,
        movieTitle: String,
        movieOverview: String?,
        modelManager: ModelManager?
    ) async throws -> ThematicAnalysisResult

    /// Анализирует транскрипт или метаданные фильма и генерирует концепты
    func discoverConcepts(
        from transcript: Transcript,
        movieTitle: String,
        movieOverview: String?,
        forceAI: Bool,
        modelManager: ModelManager?
    ) async throws -> [ThematicConcept]
}

extension ThematicConceptDiscovering {
    func discoverThematicAnalysis(
        from transcript: Transcript,
        movieTitle: String,
        modelManager: ModelManager? = nil
    ) async throws -> ThematicAnalysisResult {
        try await discoverThematicAnalysis(
            from: transcript,
            movieTitle: movieTitle,
            movieOverview: nil,
            modelManager: modelManager
        )
    }

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
