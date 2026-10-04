import Foundation

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

    init(
        word: String,
        tagline: String,
        philosophicalPremise: String,
        suggestedTitle: String,
        accentColorHex: String = "#F5D020",
        isPrimaryChoice: Bool = false,
        aiReasoning: String? = nil
    ) {
        self.word = word
        self.tagline = tagline
        self.philosophicalPremise = philosophicalPremise
        self.suggestedTitle = suggestedTitle
        self.accentColorHex = accentColorHex
        self.isPrimaryChoice = isPrimaryChoice
        self.aiReasoning = aiReasoning
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
        alternativeConcepts: [ThematicConcept] = []
    ) {
        var primary = primaryConcept
        primary.isPrimaryChoice = true
        if primary.aiReasoning == nil {
            primary.aiReasoning = aiReasoning
        }
        self.primaryConcept = primary
        self.aiReasoning = aiReasoning
        self.alternativeConcepts = alternativeConcepts
    }
}
