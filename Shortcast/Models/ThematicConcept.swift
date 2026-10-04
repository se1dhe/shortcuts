import Foundation

/// Философский концепт / лейтмотив фильма для длинного видео (Shortcast Cinema Engine)
struct ThematicConcept: Codable, Identifiable, Equatable, Hashable, Sendable {
    var id: String { word }
    
    /// Одно центральное слово крупными буквами, например "Терпение", "Гениальность", "Характер", "Жалость"
    var word: String
    
    /// Короткий смысловой слоган, отражающий суть конфликта
    var tagline: String
    
    /// Философская предпосылка / тезис ролика
    var philosophicalPremise: String
    
    /// Рекомендуемый вирусный заголовок для YouTube от 2-го лица ("Ты...", "Иногда, чтобы...")
    var suggestedTitle: String
    
    /// Акцентный цвет субтитров реплик ("#F5D020" золотой или "#E50914" красный)
    var accentColorHex: String

    init(
        word: String,
        tagline: String,
        philosophicalPremise: String,
        suggestedTitle: String,
        accentColorHex: String = "#F5D020"
    ) {
        self.word = word
        self.tagline = tagline
        self.philosophicalPremise = philosophicalPremise
        self.suggestedTitle = suggestedTitle
        self.accentColorHex = accentColorHex
    }
}
