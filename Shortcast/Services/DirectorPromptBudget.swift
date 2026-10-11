import Foundation

/// Жёсткий бюджет префилла промпта Director-модели.
///
/// `Qwen35.prepare` (и Gemma-загрузчик) считают весь промпт ОДНИМ eval'ом и
/// возвращают логиты для всех позиций: для промпта ~13k токенов это логиты
/// [13k × 152k vocab] ≈ 4 ГБ плюс полносеквенционные промежуточные активации
/// 36 слоёв — десятки ГБ transient-памяти. Итог — `_mlx_error` →
/// `_assertionFailure` → SIGTRAP, процесс умирает целиком (краш
/// 2026-10-11 08:22 в `TokenIterator.prepare`, анализ тем «Шоу Трумана»).
/// RotatingKVCache (maxKVSize 8192) переполнение префилла переживёт, память — нет.
///
/// 6000 токенов ≈ 18k символов русского текста — безопасно для 18 ГБ RAM
/// и оставляет окно KV на system-prompt и ответ.
enum DirectorPromptBudget {
    static let maxPromptTokens = 6000
    /// Консервативная оценка для русского текста в Qwen-токенизаторе (~3 симв/токен).
    static let charsPerToken = 3
    static var maxPromptChars: Int { maxPromptTokens * charsPerToken }

    /// Равномерно прореживает строки по всей хронологии до бюджета, сохраняя
    /// покрытие сюжета (не обрезает хвост, как prefix).
    static func downsample(_ text: String) -> String {
        let budget = maxPromptChars
        guard text.count > budget else { return text }
        let lines = text.components(separatedBy: "\n")
        let targetLines = max(1, lines.count * budget / text.count)
        let step = max(1, lines.count / targetLines)
        let sampled = stride(from: 0, to: lines.count, by: step).map { lines[$0] }
        return String(sampled.joined(separator: "\n").prefix(budget))
    }
}
