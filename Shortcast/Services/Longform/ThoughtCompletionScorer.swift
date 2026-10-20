import Foundation

/// Оценка смысловой и грамматической завершенности мысли финальной сцены (SOLID: SRP)
public struct ThoughtCompletionScorer: Sendable {

    /// Результат оценки завершенности
    public struct Evaluation: Sendable, Equatable {
        public let scoreModifier: Double
        public let isCompleteThought: Bool
        public let reason: String

        public init(scoreModifier: Double, isCompleteThought: Bool, reason: String) {
            self.scoreModifier = scoreModifier
            self.isCompleteThought = isCompleteThought
            self.reason = reason
        }
    }

    /// Слова паніки, крику або уривчастих реплік перепалки, неприпустимі у фіналі відеоесе
    private static let panicRetortKeywords = [
        "заткнись", "стріляй", "вб'ю", "швидше", "чорт", "сука", "бля", "вали",
        "справи кепські", "бійся мене", "бійся", "куди", "стій", "паніка", "допоможіть",
        "відповідай", "п'ять секунд", "не лізь", "не чіпай"
    ]

    /// Відкриті підрядні сполучники та частки, що вказують на обірване речення
    private static let openConjunctions = [
        "що", "щоб", "тому що", "так як", "якщо", "коли", "де", "куди",
        "хоча", "але", "а", "то", "як", " наче", "мов"
    ]

    /// Філософські маркери катарсису, глибокого висновку або монологу-одкровення
    private static let philosophicalResolutionMarkers = [
        "він — це ти", "він це ти", "ми — це ти", "ми це ти", "розводка", "ілюзія", "брехня", "правда",
        "повірити", "правило", "гра", "переміг", "вибір", "зміст", "життя",
        "людина", "завжди", "ніколи", "зрозумів", "засвоїв", "вільний", "розум",
        "ворог", "контроль", "перемога", "доля", "час", "небіжчик", "вбити",
        "справжній", "єдиний", "головний"
    ]

    /// Оценивает, насколько реплика подходит в качестве закрывающего финального аккорда фильма/эссе
    public static func evaluateConcludingPhrase(
        _ text: String,
        isFinaleAct: Bool = true
    ) -> Evaluation {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return Evaluation(scoreModifier: -100_000.0, isCompleteThought: false, reason: "Пустой текст")
        }

        let lower = trimmed.lowercased()

        // 1. Проверка на открытые незаконченные союзы в конце фразы («в том, что...», «потому что...»)
        let words = lower.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        if let lastWord = words.last, openConjunctions.contains(lastWord) {
            return Evaluation(
                scoreModifier: isFinaleAct ? -100_000.0 : -800.0,
                isCompleteThought: false,
                reason: "Предложение обрывается на союзе '\(lastWord)'"
            )
        }

        // 2. Проверка на знаки препинания: многоточие без завершения мысли
        let closingChars = CharacterSet(charactersIn: "\"')]}»”’›")
        let stripped = trimmed.trimmingCharacters(in: closingChars)

        if stripped.hasSuffix(",") || stripped.hasSuffix(";") || stripped.hasSuffix("—") || stripped.hasSuffix("-") {
            return Evaluation(
                scoreModifier: isFinaleAct ? -100_000.0 : -800.0,
                isCompleteThought: false,
                reason: "Предложение обрывается запятой или тире"
            )
        }

        // 3. Вопросительный знак в качестве финала эссе (незакрытый диалог)
        if stripped.hasSuffix("?") {
            return Evaluation(
                scoreModifier: isFinaleAct ? -100_000.0 : -450.0,
                isCompleteThought: false,
                reason: "Финал не должен заканчиваться повисшим вопросом"
            )
        }

        // 4. Панические крики и реплики бытовых перепалок (например «Дела плохие!», «Заткнись!», «Бойся меня!»)
        for pw in panicRetortKeywords {
            if lower.contains(pw) {
                return Evaluation(
                    scoreModifier: isFinaleAct ? -100_000.0 : -200.0,
                    isCompleteThought: false,
                    reason: "Панический выкрик или незаконченная ссора ('\(pw)')"
                )
            }
        }

        // 5. Оценка философского катарсиса (бонус за глубокую итоговую мысль)
        var resolutionBonus: Double = 0.0
        for marker in philosophicalResolutionMarkers {
            if lower.contains(marker) {
                resolutionBonus += 300.0
            }
        }

        // 6. Проверка на восклицания без философского контекста
        if isFinaleAct && stripped.hasSuffix("!") && resolutionBonus == 0.0 {
            return Evaluation(
                scoreModifier: -50_000.0,
                isCompleteThought: false,
                reason: "Финал не должен завершаться случайным выкриком"
            )
        }

        // Завершенная мысль с точкой, многоточием или сильным катарсисом
        let hasTerminal = stripped.hasSuffix(".") || stripped.hasSuffix("...") || stripped.hasSuffix("…") || stripped.hasSuffix("!")
        if hasTerminal {
            if words.count >= 4 {
                resolutionBonus += 150.0 // Развернутая философская фраза
            }
            return Evaluation(
                scoreModifier: resolutionBonus + 200.0,
                isCompleteThought: true,
                reason: "Завершенная мысль"
            )
        }

        return Evaluation(
            scoreModifier: isFinaleAct ? -100_000.0 : -300.0,
            isCompleteThought: false,
            reason: "Нет закрывающего знака препинания"
        )
    }
}
