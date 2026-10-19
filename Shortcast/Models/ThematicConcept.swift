import Foundation

/// Откуда взялась тема. Нужен потому, что pipeline умеет деградировать без
/// модели, а пользователь имеет право знать, кто написал то, что он смотрит.
/// `unknown` — темы, сохранённые до появления поля: им нельзя доверять,
/// они подлежат перегенерации.
enum ThematicSource: String, Codable, Sendable {
    case llm
    case manual
    case unknown

    var isTrustworthy: Bool { self == .llm || self == .manual }
}

/// Философский концепт / лейтмотив фильма для длинного видео (Shortcast Cinema Engine)
struct ThematicConcept: Codable, Identifiable, Equatable, Hashable, Sendable {
    var id: String { word }
    
    /// Одно центральное слово крупными буквами, например "Эго", "Терпение", "Гениальность", "Характер", "Жалость"
    var word: String
    
    /// Короткий смысловой слоган, отражающий суть конфликта
    var tagline: String
    
    /// Философская предпосылка / тезис ролика
    var philosophicalPremise: String
    
    /// Рекомендуемый вирусный заголовок для YouTube от 2-го лица ("Ты...", "Иногда, чтобы...")
    var suggestedTitle: String
    
    /// Акцентный цвет субтитров реплик ("#F5D020" золотой или "#E50914" красный)
    var accentColorHex: String

    /// Флаг главного выбора нейросети (100% фокус эссе, выбранный моделью)
    var isPrimaryChoice: Bool

    /// Обоснование выбора от лица режиссера-ИИ на основе сценария
    var aiReasoning: String?

    /// Провенанс: действительно ли эту тему выдала модель
    var source: ThematicSource

    init(
        word: String,
        tagline: String,
        philosophicalPremise: String,
        suggestedTitle: String,
        accentColorHex: String = "#F5D020",
        isPrimaryChoice: Bool = false,
        aiReasoning: String? = nil,
        source: ThematicSource = .unknown
    ) {
        self.word = word
        self.tagline = tagline
        self.philosophicalPremise = philosophicalPremise
        self.suggestedTitle = suggestedTitle
        self.accentColorHex = accentColorHex
        self.isPrimaryChoice = isPrimaryChoice
        self.aiReasoning = aiReasoning
        self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case word, tagline, philosophicalPremise, suggestedTitle
        case accentColorHex, isPrimaryChoice, aiReasoning, source
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        word = try c.decode(String.self, forKey: .word)
        tagline = try c.decode(String.self, forKey: .tagline)
        philosophicalPremise = try c.decode(String.self, forKey: .philosophicalPremise)
        suggestedTitle = try c.decode(String.self, forKey: .suggestedTitle)
        accentColorHex = try c.decodeIfPresent(String.self, forKey: .accentColorHex) ?? "#F5D020"
        isPrimaryChoice = try c.decodeIfPresent(Bool.self, forKey: .isPrimaryChoice) ?? false
        aiReasoning = try c.decodeIfPresent(String.self, forKey: .aiReasoning)
        source = try c.decodeIfPresent(ThematicSource.self, forKey: .source) ?? .unknown
    }
}

/// Результат глубокого анализа сценария и драматургии фильма моделью Director (SOLID: Single Responsibility)
struct ThematicAnalysisResult: Codable, Sendable, Equatable {
    /// ОДНА главная тема, выбранная моделью как смысловое ядро фильма
    var primaryConcept: ThematicConcept

    /// Драматургический и психологический разбор сценария: почему модель выбрала именно эту тему
    var aiReasoning: String

    /// Альтернативные философские грани и темы, выявленные в диалогах
    var alternativeConcepts: [ThematicConcept]

    /// Провенанс всего анализа. `.unknown` / не-`.llm` означает, что тему
    /// выбирала не модель, и такой анализ нельзя кэшировать как результат.
    var source: ThematicSource

    /// Все концепты в едином списке, где главный выбор всегда идет первым
    var allConcepts: [ThematicConcept] {
        var list = [primaryConcept]
        for alt in alternativeConcepts where alt.word.caseInsensitiveCompare(primaryConcept.word) != .orderedSame {
            list.append(alt)
        }
        return list
    }

    init(
        primaryConcept: ThematicConcept,
        aiReasoning: String,
        alternativeConcepts: [ThematicConcept] = [],
        source: ThematicSource = .unknown
    ) {
        var primary = primaryConcept
        primary.isPrimaryChoice = true
        if primary.aiReasoning == nil {
            primary.aiReasoning = aiReasoning
        }
        if primary.source == .unknown {
            primary.source = source
        }
        self.primaryConcept = primary
        self.aiReasoning = aiReasoning
        self.alternativeConcepts = alternativeConcepts
        self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case primaryConcept, aiReasoning, alternativeConcepts, source
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        primaryConcept = try c.decode(ThematicConcept.self, forKey: .primaryConcept)
        aiReasoning = try c.decode(String.self, forKey: .aiReasoning)
        alternativeConcepts = try c.decodeIfPresent([ThematicConcept].self, forKey: .alternativeConcepts) ?? []
        source = try c.decodeIfPresent(ThematicSource.self, forKey: .source) ?? .unknown
    }
}
