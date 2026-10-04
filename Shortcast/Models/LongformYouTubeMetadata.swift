import Foundation

/// Упаковка и метаданные YouTube для длинного ролика Shortcast Cinema
struct LongformYouTubeMetadata: Codable, Equatable, Sendable {
    /// Вирусный кликбейтный, но глубокий заголовок от 2-го лица ("Ты...", "Иногда, чтобы...")
    var title: String
    
    /// Философское описание-манифест из коротких смысловых абзацев + дисклеймер Fair Use
    var description: String
    
    /// Высокочастотные и тематические теги
    var tags: [String]
    
    /// Закрепленный комментарий с призывом к дискуссии
    var pinnedComment: String

    init(
        title: String,
        description: String,
        tags: [String],
        pinnedComment: String
    ) {
        self.title = title
        self.description = description
        self.tags = tags
        self.pinnedComment = pinnedComment
    }

    /// Стандартный дисклеймер добросовестного использования для длинных эссе
    static let standardFairUseDisclaimer = """
    Disclaimer: This video is intended for commentary, motivational and entertainment purposes only. It does not promote or encourage illegal, dangerous, harmful or unethical behavior. The material is edited and presented to discuss the themes, characters and ideas of the film.
    """
}
