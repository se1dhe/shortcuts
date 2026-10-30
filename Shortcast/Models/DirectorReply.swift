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

    /// Закрыт ли верхний уровень объекта — спрашиваем у парсера, а не считаем
    /// скобки здесь: определение «закрытого» должно быть одним и тем же.
    var completeness: ReplyCompleteness {
        guard !hitTokenCap, JSONVariantParser.extractJSONObject(from: text) != nil else {
            return .truncated
        }
        return .complete
    }

    /// Одна строка в director.log вместо мнения: «не обрезано» = число.
    var logLine: String {
        "generatedTokens=\(generatedTokens) cap=\(maxTokens.map(String.init) ?? "none") promptTokens=\(promptTokens) "
            + "stop=\(stopReason) genTime=\(String(format: "%.1f", generateSeconds))s "
            + "complete=\(completeness.rawValue)"
    }
}
