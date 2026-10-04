import Foundation

/// Протокол режиссера сквозной 4-актной драматургической арки для длинного ролика
protocol LongformNarrativeDirecting: Sendable {
    /// Строит 4-актную арку сцен из полного транскрипта фильма с целевой длительностью (300-480с)
    func buildArc(
        from transcript: Transcript,
        concept: ThematicConcept,
        movieTitle: String,
        targetDuration: Double
    ) async throws -> LongformNarrativeArc
}
