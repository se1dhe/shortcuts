import Foundation
import NaturalLanguage

/// Семантическая валидация таймкодов: проверяет что транскрипт в указанном диапазоне
/// содержит ключевые слова из обоснования выбора сцены (reason).
/// Если слова не найдены — помечает момент как "низкая уверенность".
struct SemanticTimecodeValidator {
    
    struct ValidationResult {
        let moment: SelectedMoment
        let confidence: Confidence
        let matchedKeywords: [String]
        let missingKeywords: [String]
        
        enum Confidence {
            case high      // >70% ключевых слов найдено
            case medium    // 30-70% найдено
            case low       // <30% найдено
        }
    }
    
    /// Валидирует один момент
    func validate(
        moment: SelectedMoment,
        transcript: Transcript
    ) -> ValidationResult {
        // Извлекаем ключевые слова из reason
        let keywords = extractKeywords(from: moment.reason)
        guard !keywords.isEmpty else {
            return ValidationResult(
                moment: moment,
                confidence: .medium,
                matchedKeywords: [],
                missingKeywords: []
            )
        }
        
        // Находим сегменты транскрипта в диапазоне момента
        let overlappingText = transcript.segments
            .filter { $0.end > moment.startTime && $0.start < moment.endTime }
            .map { $0.text }
            .joined(separator: " ")
            .lowercased()
        
        // Проверяем наличие ключевых слов
        var matched: [String] = []
        var missing: [String] = []
        
        for keyword in keywords {
            if overlappingText.contains(keyword.lowercased()) {
                matched.append(keyword)
            } else {
                missing.append(keyword)
            }
        }
        
        // Определяем уверенность
        let matchRatio = keywords.isEmpty ? 0 : Double(matched.count) / Double(keywords.count)
        let confidence: ValidationResult.Confidence
        if matchRatio > 0.7 {
            confidence = .high
        } else if matchRatio > 0.3 {
            confidence = .medium
        } else {
            confidence = .low
        }
        
        return ValidationResult(
            moment: moment,
            confidence: confidence,
            matchedKeywords: matched,
            missingKeywords: missing
        )
    }
    
    /// Валидирует все моменты
    func validateAll(
        moments: [SelectedMoment],
        transcript: Transcript
    ) -> [ValidationResult] {
        return moments.map { validate(moment: $0, transcript: transcript) }
    }
    
    /// Извлекает ключевые слова из текста (существительные, глаголы, прилагательные)
    private func extractKeywords(from text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        
        var keywords: [String] = []
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text
        
        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex,
            unit: .word,
            scheme: .lexicalClass,
            options: [.omitPunctuation, .omitWhitespace]
        ) { tag, range in
            if let tag = tag, isContentWord(tag) {
                let word = String(text[range])
                if word.count > 2 { // Пропускаем слишком короткие слова
                    keywords.append(word)
                }
            }
            return true
        }
        
        return Array(Set(keywords)) // Уникальные слова
    }
    
    /// Проверяет что часть речи — контентная (существительное, глагол, прилагательное)
    private func isContentWord(_ tag: NLTag) -> Bool {
        switch tag {
        case .noun, .verb, .adjective, .adverb:
            return true
        default:
            return false
        }
    }
}
