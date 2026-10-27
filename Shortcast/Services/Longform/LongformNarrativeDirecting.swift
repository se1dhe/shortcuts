import Foundation

/// Протокол режиссера сквозной 4-актной драматургической арки для длинного ролика
protocol LongformNarrativeDirecting: Sendable {
    /// Строит 4-актную арку сцен из полного транскрипта фильма с целевой длительностью (7-10 мин / 420-600с)
    /// - Parameters:
    ///   - transcript: Полный транскрипт фильма
    ///   - concept: Главная тема эссе, выбранная LLM
    ///   - selectedMoments: Конкретные моменты (сцены), выбранные LLM для эссе
    ///   - movieTitle: Название фильма
    ///   - targetDuration: Целевая длительность эссе в секундах
    ///   - essayPlan: План эссе от Director (хук, CTA, фокус актов). nil — старая 4-актная арка.
    func buildArc(
        from transcript: Transcript,
        concept: ThematicConcept,
        selectedMoments: [SelectedMoment],
        movieTitle: String,
        targetDuration: Double,
        essayPlan: EssayPlan?
    ) async throws -> LongformNarrativeArc
}
