import Foundation

/// Упаковка и метаданные YouTube для длинного ролика Shortcast Cinema
struct LongformYouTubeMetadata: Codable, Equatable, Sendable {
    /// Заголовок конкретного эссе с названием фильма.
    var title: String
    
    /// Хук, тезис и вывод эссе, главы, обсуждение и атрибуция исходного материала.
    var description: String
    
    /// Keyword tags API: не хештеги описания.
    var tags: [String]
    
    /// Закрепленный комментарий с призывом к дискуссии
    var pinnedComment: String
    
    /// Опрос для Telegram (если CTA содержит вопрос)
    var telegramPoll: TelegramPoll? = nil
    
    /// Отдельно от keyword tags API: готовые токены для описания и копирования.
    var hashtagTokens: [String]? = nil
    var packagingVersion: Int? = nil
    var hashtags: [String] {
        hashtagTokens ?? Array(tags.prefix(5)).compactMap(LongformMetadataGenerator.hashtag)
    }
    var hashtagText: String { hashtags.joined(separator: " ") }

    struct TelegramPoll: Codable, Equatable, Sendable {
        let question: String
        let options: [String]
    }

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

    /// Нейтральная атрибуция; не заявление о гарантированной правовой защите.
    static let standardFairUseDisclaimer = """
    Українське кіноесе з аналізом тем і персонажів фільму. Фрагменти використано для критичного обговорення; права на вихідні матеріали належать їхнім правовласникам.
    """
}
