import Foundation
import os

/// Второй LLM-проход: режиссёрское ревью драматургической арки.
/// Оценивает целостность: есть ли экспозиция, развитие, катарсис.
/// Предлагает перестановку актов если нужно. Fallback — оставить как есть.
actor DirectorReviewService {
    
    private static let logger = Logger(subsystem: "app.shortcast", category: "DirectorReview")
    
    struct ReviewResult {
        let arc: LongformNarrativeArc
        let suggestions: [String]
        let wasModified: Bool
    }
    
    private let momentFinder: MomentFinderService
    
    init(momentFinder: MomentFinderService) {
        self.momentFinder = momentFinder
    }
    
    /// Ревьюит арку и предлагает улучшения
    func review(
        arc: LongformNarrativeArc,
        transcript: Transcript,
        concept: ThematicConcept,
        movieTitle: String
    ) async -> ReviewResult {
        // Собираем информацию об арке для промпта
        let arcSummary = buildArcSummary(arc: arc, concept: concept)
        let prompt = buildReviewPrompt(arcSummary: arcSummary, movieTitle: movieTitle)
        let instructions = "Ти — експерт з драматургії та монтажу документальних есе. Відповідай СУВОРО у форматі JSON."
        
        // Вызываем LLM через MomentFinder
        guard let response = await momentFinder.completeForActTitles(
            instructions: instructions,
            prompt: prompt,
            maxTokens: 1024
        ) else {
            Self.logger.warning("Director review: model not available, keeping original arc")
            return ReviewResult(arc: arc, suggestions: [], wasModified: false)
        }
        
        // Парсим ответ
        if let review = parseReviewResponse(response, originalArc: arc) {
            Self.logger.info("Director review: arc modified=\(review.wasModified), suggestions=\(review.suggestions.count)")
            return review
        } else {
            Self.logger.warning("Director review: failed to parse response, keeping original arc")
            return ReviewResult(arc: arc, suggestions: [], wasModified: false)
        }
    }
    
    private func buildArcSummary(arc: LongformNarrativeArc, concept: ThematicConcept) -> String {
        var summary = "Тема есе: \(concept.word)\n\n"
        summary += "Структура арки:\n"
        
        for (index, act) in arc.acts.enumerated() {
            summary += "\nАкт \(index + 1) (\(act.type.rawValue)):\n"
            summary += "Назва: \(act.title)\n"
            summary += "Драматургічний біт: \(act.dramaticBeat)\n"
            summary += "Тривалість: \(String(format: "%.1f", act.duration)) с\n"
            summary += "Сегменти:\n"
            for segment in act.segments {
                summary += "  - [\(String(format: "%.1f", segment.start))-\(String(format: "%.1f", segment.end))]\n"
            }
        }
        
        summary += "\nЗагальна тривалість: \(String(format: "%.1f", arc.totalDuration)) с"
        
        return summary
    }
    
    private func buildReviewPrompt(arcSummary: String, movieTitle: String) -> String {
        return """
        Ти — досвідчений режисер-документаліст. Оціни драматургічну арку есе за фільмом «\(movieTitle)».
        
        \(arcSummary)
        
        ОЦІНИ:
        1. Чи є чітка експозиція на початку (хук, зав'язка)?
        2. Чи є розвиток дії в середині (нарастання напруги)?
        3. Чи є катарсис/розв'язка в кінці?
        4. Чи логічний порядок актів?
        5. Чи розкривається тема послідовно?
        
        Якщо арка потребує покращення, запропонуй:
        - Які акти варто переставити (якщо потрібно)
        - Як покращити драматургію
        
        Поверни JSON у форматі:
        {
          "score": 0-10 (оцінка якості арки),
          "hasExposition": true/false,
          "hasDevelopment": true/false,
          "hasCatharsis": true/false,
          "suggestions": ["порада 1", "порада 2"],
          "shouldReorder": true/false,
          "reorderedActs": [0, 1, 2] (якщо shouldReorder=true, новий порядок актів)
        }
        
        Якщо арка хороша, поверни score >= 7 і порожній масив suggestions.
        """
    }
    
    private func parseReviewResponse(_ response: String, originalArc: LongformNarrativeArc) -> ReviewResult? {
        // Извлекаем JSON из ответа
        guard let jsonRange = response.range(of: #"\{[\s\S]*\}"#, options: .regularExpression) else {
            return nil
        }
        
        let jsonString = String(response[jsonRange])
        
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        
        let score = json["score"] as? Int ?? 5
        let suggestions = json["suggestions"] as? [String] ?? []
        let shouldReorder = json["shouldReorder"] as? Bool ?? false
        
        var modifiedArc = originalArc
        var wasModified = false
        
        // Если LLM предлагает перестановку и оценка низкая — применяем
        if shouldReorder, let reorderedIndices = json["reorderedActs"] as? [Int], score < 7 {
            var newActs: [LongformAct] = []
            for index in reorderedIndices where index < originalArc.acts.count {
                newActs.append(originalArc.acts[index])
            }
            if newActs.count == originalArc.acts.count {
                modifiedArc.acts = newActs
                wasModified = true
            }
        }
        
        return ReviewResult(
            arc: modifiedArc,
            suggestions: suggestions,
            wasModified: wasModified
        )
    }
}
