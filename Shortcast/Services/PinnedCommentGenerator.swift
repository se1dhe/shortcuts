import Foundation

/// Generates the text for a pinned comment advertising the RedQueen Security bot.
/// Template-based — no AI call needed. `promoCode` is accepted for call-site
/// compatibility and is not used.
enum PinnedCommentGenerator {

    /// Returns the full pinned comment text, ready to paste or upload.
    static func generate(promoCode: String = "") -> String {
        return """
        🛡 RedQueen Security — умная AI-модерация для Telegram-чатов.

        Капча от ботов, антифлуд, анти-скам и объяснимый AI-карантин — всё настраивается в пару кликов.

        👉 @RedQueenSecurity_Bot — защити свой чат.

        #telegram #модерация #antispam
        """
    }
}
