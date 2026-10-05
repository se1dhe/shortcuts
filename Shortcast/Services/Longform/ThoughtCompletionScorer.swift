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

    /// Слова паники, крика или обрывочных реплик перепалки, недопустимые в финале видеоэссе
    private static let panicRetortKeywords = [
        "заткнись", "стреляй", "убью", "быстрее", "черт", "сука", "бля", "вали",
        "дела плохие", "бойся меня", "бойся", "куда", "стой", "паника", "помогите",
        "отвечай", "пять секунд", "не лезь", "не трогай"
    ]

    /// Открытые подчинительные союзы и частицы, указывающие на оборванное предложение
    private static let openConjunctions = [
        "что", "чтобы", "потому что", "так как", "если", "когда", "где", "куда",
        "хотя", "но", "а", "то", "как", "будто", "словно"
    ]

    /// Философские маркеры катарсиса, глубокого вывода или монолога-откровения
    private static let philosophicalResolutionMarkers = [
        "он — это ты", "он это ты", "разводка", "иллюзия", "ложь", "правда",
        "поверить", "правило", "игра", "победил", "выбор", "смысл", "жизнь",
        "человек", "всегда", "никогда", "понял", "усвоил", "свободен", "разум",
        "враг", "контроль", "победа", "судьба", "время", "покойник", "убить",
        "настоящий", "единственный", "главный"
    ]

    /// Оценивает, насколько реплика подходит в качестве закрывающего финального аккорда фильма/эссе
    public static func evaluateConcludingPhrase(
        _ text: String,
        isFinaleAct: Bool = true
    ) -> Evaluation {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return Evaluation(scoreModifier: -500.0, isCompleteThought: false, reason: "Пустой текст")
        }

        let lower = trimmed.lowercased()

        // 1. Проверка на открытые незаконченные союзы в конце фразы («в том, что...», «потому что...»)
        let words = lower.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        if let lastWord = words.last, openConjunctions.contains(lastWord) {
            return Evaluation(
                scoreModifier: -800.0,
                isCompleteThought: false,
                reason: "Предложение обрывается на союзе '\(lastWord)'"
            )
        }

        // 2. Проверка на знаки препинания: многоточие без завершения мысли
        let closingChars = CharacterSet(charactersIn: "\"')]}»”’›")
        let stripped = trimmed.trimmingCharacters(in: closingChars)

        if stripped.hasSuffix(",") || stripped.hasSuffix(";") || stripped.hasSuffix("—") || stripped.hasSuffix("-") {
            return Evaluation(
                scoreModifier: -800.0,
                isCompleteThought: false,
                reason: "Предложение обрывается запятой или тире"
            )
        }

        // 3. Вопросительный знак в качестве финала эссе (незакрытый диалог)
        if stripped.hasSuffix("?") {
            return Evaluation(
                scoreModifier: -450.0,
                isCompleteThought: false,
                reason: "Финал не должен заканчиваться повисшим вопросом"
            )
        }

        // 4. Панические крики и реплики бытовых перепалок (например «Дела плохие!», «Заткнись!»)
        for pw in panicRetortKeywords {
            if lower.contains(pw) {
                return Evaluation(
                    scoreModifier: isFinaleAct ? -700.0 : -200.0,
                    isCompleteThought: false,
                    reason: "Панический выкрик или незаконченная ссора ('\(pw)')"
                )
            }
        }

        // 5. Оценка философского катарсиса (бонус за глубокую итоговую мысль)
        var resolutionBonus: Double = 0.0
        for marker in philosophicalResolutionMarkers {
            if lower.contains(marker) {
                resolutionBonus += 150.0
            }
        }

        // Ограничиваем бонус разумным максимумом
        resolutionBonus = min(resolutionBonus, 400.0)

        // Завершенная мысль с точкой или многоточием
        let hasTerminal = stripped.hasSuffix(".") || stripped.hasSuffix("...") || stripped.hasSuffix("…") || stripped.hasSuffix("!")
        if hasTerminal {
            if words.count >= 4 {
                resolutionBonus += 100.0 // Развернутая фраза
            }
            return Evaluation(
                scoreModifier: resolutionBonus + 100.0,
                isCompleteThought: true,
                reason: "Завершенная мысль с точкой"
            )
        }

        return Evaluation(
            scoreModifier: -300.0,
            isCompleteThought: false,
            reason: "Нет закрывающего знака препинания"
        )
    }
}
