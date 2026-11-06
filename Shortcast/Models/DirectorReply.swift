import Foundation
import MLXLMCommon

/// Полнота ответа Director — часть контракта, а не оценка качества.
///
/// `.truncated` означает «гейт обязан отклонить»: модель не закрыла JSON-объект
/// сама или упёрлась в лимит токенов. Раньше такой ответ засчитывался успехом
/// (хвост доклеивал парсер), и эссе собиралось из обрыва.
enum ReplyCompleteness: String, Codable, Sendable {
    case complete
    case truncated

    var isAcceptable: Bool { self == .complete }
}

/// Сырой ответ Director вместе с метриками генерации.
///
/// Без этих чисел «ответ не обрезан» остаётся мнением: `generationTokenCount` и
/// `stopReason` — единственное доказательство того, что модель дописала объект
/// сама, а не была остановлена на середине.
struct DirectorReply: Sendable {
    let text: String
    let promptTokens: Int
    let generatedTokens: Int
    /// `length` — модель упёрлась в лимит токенов, то есть обрыв.
    let stopReason: String
    let generateSeconds: Double
    /// Лимит, с которым генерировали (`GenerateParameters.maxTokens`, там опциональный).
    let maxTokens: Int?

    init(text: String, info: GenerateCompletionInfo?, maxTokens: Int?) {
        self.text = text
        self.promptTokens = info?.promptTokenCount ?? 0
        self.generatedTokens = info?.generationTokenCount ?? 0
        self.generateSeconds = info?.generateTime ?? 0
        self.maxTokens = maxTokens
        switch info?.stopReason {
        case .length: self.stopReason = "length"
        case .cancelled: self.stopReason = "cancelled"
        case .stop: self.stopReason = "stop"
        case nil: self.stopReason = "unknown"
        }
    }

    var hitTokenCap: Bool { stopReason == "length" }

    /// Explain transport/format failures without presenting them as a model's
    /// editorial verdict. In particular, a literal JSON null is not truncation.
    var rejectionReason: String? {
        if stopReason == "cancelled" { return "генерация отменена" }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "модель вернула пустой ответ" }
        if hitTokenCap { return "достигнут лимит ответа (\(generatedTokens)/\(maxTokens ?? generatedTokens) токенов)" }
        if text.trimmingCharacters(in: .whitespacesAndNewlines) == "null" { return "модель вернула JSON null вместо объекта" }
        if JSONVariantParser.extractJSONObject(from: text) == nil { return "ответ не содержит завершённого объекта JSON" }
        return nil
    }

    /// Закрыт ли верхний уровень объекта — спрашиваем у парсера, а не считаем
    /// скобки здесь: определение «закрытого» должно быть одним и тем же.
    var completeness: ReplyCompleteness {
        rejectionReason == nil ? .complete : .truncated
    }

    /// Одна строка в director.log вместо мнения: «не обрезано» = число.
    var logLine: String {
        "generatedTokens=\(generatedTokens) cap=\(maxTokens.map(String.init) ?? "none") promptTokens=\(promptTokens) "
            + "stop=\(stopReason) genTime=\(String(format: "%.1f", generateSeconds))s "
            + "complete=\(completeness.rawValue)"
    }
}
