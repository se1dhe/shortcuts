import Foundation

/// Tolerant parser for the model's JSON output. The model is asked for clean
/// JSON, but small models drift — this strips fences / thinking blocks, finds
/// the first balanced object, and accepts a few key spellings.
enum JSONVariantParser {

    /// Deserializes a JSON object string, repairing the JSON-breaking glitches
    /// small models occasionally emit before giving up. Returns the parsed value
    /// (object or array) or nil.
    static func deserializeTolerant(_ jsonString: String) -> Any? {
        if let data = jsonString.data(using: .utf8),
           let root = try? JSONSerialization.jsonObject(with: data) {
            return root
        }
        let repaired = repairDrift(jsonString)
        if repaired.count != jsonString.count {
            log("tolerant parse kept the reply only after repair: \(jsonString.count) → \(repaired.count) chars")
        }
        if let data = repaired.data(using: .utf8),
           let root = try? JSONSerialization.jsonObject(with: data) {
            return root
        }
        return nil
    }

    /// Fixes glitches that break otherwise-good model JSON:
    /// - Key missing its closing quote (`  "endTime: 812.3,` → `"endTime": 812.3,`)
    /// - Key missing its opening quote (`  foo": …` → `  "foo": …`)
    /// - Duplicate commas inside lists/objects (`,,` or `, ,` → `,`)
    /// - Leading commas after opening brackets (`[,` or `{,` → `[` or `{`)
    /// - Trailing commas before closing braces/brackets (`,}` or `,]` → `}` or `]`)
    static func repairDrift(_ json: String) -> String {
        var s = json
        // Ключ без закрывающей кавычки. Живое свидетельство 28.10.2026: этап 2
        // выдал закрытый ответ (`complete=complete`, `stop != length`), в котором
        // две строки были напечатаны как `"dramaticWeight: 0.8,` — `JSONSerialization`
        // спотыкался о перевод строки внутри «строки» и весь эссе-ответ считался
        // нечитаемым. Заякорено на всю строку и на скаляр после двоеточия, поэтому
        // значение с двоеточием внутри (`"Ціна: все",`) под правило не попадает:
        // чинится синтаксис, а не слова модели.
        s = restoreMissingClosingQuoteOnKeys(s)
        // Key missing its opening quote (after `{`, `,` or a newline).
        s = regexReplace(s, #"([\n\r{,]\s*)([A-Za-z_][A-Za-z0-9_]*)("\s*:)"#, with: "$1\"$2$3")
        // A scene entry occasionally loses both its opening object brace and
        // the `id` key prefix, leaving a bare string before the remaining fields:
        //   "S020",
        //   "role": "psychology",
        // Restore only this unambiguous scene-object shape. A valid string array
        // item cannot be followed by a sibling `role` property in this layout.
        s = restoreMissingSceneObjectStart(s)
        // Duplicate commas inside lists or objects: `,,` or `, ,` -> `,`
        s = regexReplace(s, #",(?:\s*,)+"#, with: ",")
        // Leading comma after an opening bracket/brace: `[,` or `{,` -> `[` or `{`
        s = regexReplace(s, #"(\[|\{)\s*,"#, with: "$1")
        // Trailing comma before a closing brace/bracket: `,]` or `,}` -> `]` or `}`
        s = regexReplace(s, #",(\s*[}\]])"#, with: "$1")
        return s
    }

    /// Вставляет кавычку, которую модель забыла закрыть после имени ключа, и
    /// пишет в лог, сколько строк пришлось чинить: правка ответа модели никогда
    /// не должна проходить молча.
    private static func restoreMissingClosingQuoteOnKeys(_ json: String) -> String {
        let pattern = #"(?m)^([ \t]*)"([A-Za-z_][A-Za-z0-9_]*)\s*:\s*("[^"\\\n]*"|-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?|true|false|null)\s*(,?)[ \t]*$"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return json }
        let range = NSRange(json.startIndex..., in: json)
        let hits = re.matches(in: json, range: range)
        guard !hits.isEmpty else { return json }
        let repaired = re.stringByReplacingMatches(
            in: json, range: range, withTemplate: "$1\"$2\": $3$4")
        log("restored \(hits.count) missing key quote(s) — syntax only, no words changed")
        return repaired
    }

    private static func restoreMissingSceneObjectStart(_ json: String) -> String {
        let pattern = #"(?m)^([ \t]*)"([A-Za-z0-9_-]+)"[ \t]*,[ \t]*\r?\n([ \t]*)"role"[ \t]*:"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return json }
        let range = NSRange(json.startIndex..., in: json)
        let hits = re.numberOfMatches(in: json, range: range)
        guard hits > 0 else { return json }
        let repaired = re.stringByReplacingMatches(
            in: json,
            range: range,
            withTemplate: "$1{\"id\": \"$2\",\n$3\"role\":"
        )
        log("restored \(hits) missing scene object start(s) and id key(s)")
        return repaired
    }

    private static func regexReplace(_ s: String, _ pattern: String, with template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        return re.stringByReplacingMatches(
            in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }

    /// Same as `parse(_:)` but for an already-deserialized JSON value — lets the
    /// Director's combined output reuse this when captions arrive inline per clip.
    /// Returns the first balanced `{ ... }` block, ignoring everything else
    /// (markdown fences, thinking text, trailing commentary).
    static func extractJSONObject(from raw: String) -> String? {
        let cleaned = cleanRawOutput(raw)
        guard let start = cleaned.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < cleaned.endIndex {
            let char = cleaned[index]
            if inString {
                if escaped {
                    escaped = false
                } else if char == "\\" {
                    escaped = true
                } else if char == "\"" {
                    inString = false
                }
            } else {
                switch char {
                case "\"": inString = true
                case "{":  depth += 1
                case "}":
                    depth -= 1
                    if depth == 0 { return String(cleaned[start...index]) }
                default: break
                }
            }
            index = cleaned.index(after: index)
        }
        return nil
    }

    /// Strips common model wrappers (markdown fences, thinking blocks, tool calls)
    /// so `extractJSONObject` sees clean JSON.
    private static func cleanRawOutput(_ raw: String) -> String {
        var s = raw

        // Strip markdown code fences and keep only the inner content.
        s = regexReplace(s, #"```(?:json)?\s*\n([\s\S]*?)```"#, with: "$1")
        s = regexReplace(s, #"```(?:json)?\s*([\s\S]*?)```"#, with: "$1")

        // Strip known model wrapper tags that contain non-JSON prose or special tokens.
        s = regexReplace(s, #"<image\|?>|<image>|<start_of_turn>|<end_of_turn>"#, with: "")
        s = regexReplace(s, #"<thinking>[\s\S]*?</thinking>"#, with: "")
        s = regexReplace(s, #"<reasoning>[\s\S]*?</reasoning>"#, with: "")
        s = regexReplace(s, #"<tool_call>[\s\S]*?</tool_call>"#, with: "")
        s = regexReplace(s, #"<tool>[\s\S]*?</tool>"#, with: "")

        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func log(_ message: String) {
        FileHandle.standardError.write(Data("[shortcast/json] \(message)\n".utf8))
    }

}
