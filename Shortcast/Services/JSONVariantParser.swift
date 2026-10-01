import Foundation

enum JSONVariantParserError: LocalizedError {
    case noJSONObject
    case noVariants

    var errorDescription: String? {
        switch self {
        case .noJSONObject:
            return "The model didn't return readable JSON."
        case .noVariants:
            return "The model's response had no usable platform variants."
        }
    }
}

/// Tolerant parser for the model's JSON output. The model is asked for clean
/// JSON, but small models drift — this strips fences / thinking blocks, finds
/// the first balanced object, and accepts a few key spellings.
enum JSONVariantParser {

    static func parse(_ raw: String) throws -> GenerationResult {
        let cleaned = cleanRawOutput(raw)
        guard let jsonString = extractJSONObject(from: cleaned),
              let root = deserializeTolerant(jsonString)
        else {
            Self.log("JSON parse failed. Raw output (\(raw.count) chars):\n\(raw)")
            throw JSONVariantParserError.noJSONObject
        }
        return try parse(object: root)
    }

    /// Deserializes a JSON object string, repairing the JSON-breaking glitches
    /// small models occasionally emit before giving up. Returns the parsed value
    /// (object or array) or nil.
    static func deserializeTolerant(_ jsonString: String) -> Any? {
        if let data = jsonString.data(using: .utf8),
           let root = try? JSONSerialization.jsonObject(with: data) {
            return root
        }
        let repaired = repairDrift(jsonString)
        if let data = repaired.data(using: .utf8),
           let root = try? JSONSerialization.jsonObject(with: data) {
            return root
        }
        return nil
    }

    /// Fixes the two glitches that break otherwise-good model JSON: a property
    /// name that dropped its opening quote (`  foo": …` → `  "foo": …`, a token
    /// the model sometimes mis-samples) and trailing commas before `}`/`]`.
    static func repairDrift(_ json: String) -> String {
        var s = json
        // Key missing its opening quote (after `{`, `,` or a newline).
        s = regexReplace(s, #"([\n\r{,]\s*)([A-Za-z_][A-Za-z0-9_]*)("\s*:)"#, with: "$1\"$2$3")
        // Trailing comma before a closing brace/bracket.
        s = regexReplace(s, #",(\s*[}\]])"#, with: "$1")
        return s
    }

    private static func regexReplace(_ s: String, _ pattern: String, with template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        return re.stringByReplacingMatches(
            in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }

    /// Same as `parse(_:)` but for an already-deserialized JSON value — lets the
    /// Director's combined output reuse this when captions arrive inline per clip.
    static func parse(object root: Any) throws -> GenerationResult {
        var rawVariants: [[String: Any]] = []
        var language: String?

        if let object = root as? [String: Any] {
            language = object["language"] as? String
            if let array = object["variants"] as? [[String: Any]] {
                rawVariants = array
            } else {
                // Object keyed directly by platform name (e.g. the Director's
                // inline `captions` block). Inject the platform key into each
                // entry so `makeVariant` — which requires a "platform" field —
                // can build them.
                rawVariants = SocialPlatform.allCases.compactMap { platform in
                    guard var dict = object[platform.rawValue] as? [String: Any] else { return nil }
                    dict["platform"] = platform.rawValue
                    return dict
                }
            }
        } else if let array = root as? [[String: Any]] {
            rawVariants = array
        }

        var byPlatform: [SocialPlatform: PostVariant] = [:]
        for entry in rawVariants {
            if let variant = makeVariant(from: entry) {
                byPlatform[variant.platform] = variant
            }
        }

        let ordered = SocialPlatform.allCases.compactMap { byPlatform[$0] }
        guard !ordered.isEmpty else { throw JSONVariantParserError.noVariants }
        return GenerationResult(variants: ordered, detectedLanguage: language)
    }

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

    private static func makeVariant(from entry: [String: Any]) -> PostVariant? {
        guard let platformRaw = (entry["platform"] as? String)?.lowercased(),
              let platform = SocialPlatform(rawValue: platformRaw)
        else { return nil }

        let hook = string(entry, "hook", "title", "headline").sanitizedModelText
        let summary = string(entry, "description", "caption", "summary", "body").sanitizedModelText
        let hashtags = normalizeHashtags(from: entry)
        return PostVariant(platform: platform, hook: hook, summary: summary, hashtags: hashtags, pinnedComment: "")
    }

    /// First non-empty string value among the given keys.
    private static func string(_ entry: [String: Any], _ keys: String...) -> String {
        for key in keys {
            if let value = (entry[key] as? String)?.trimmed, !value.isEmpty {
                return value
            }
        }
        return ""
    }

    private static func normalizeHashtags(from entry: [String: Any]) -> [String] {
        let value = entry["hashtags"] ?? entry["tags"] ?? entry["hashtag"] ?? entry["tag"]
        let rawList: [String]
        if let array = value as? [String] {
            rawList = array
        } else if let array = value as? [Any] {
            rawList = array.compactMap { $0 as? String }
        } else if let joined = value as? String {
            rawList = joined.split(whereSeparator: { " ,\n".contains($0) }).map(String.init)
        } else {
            rawList = []
        }
        let cleaned = rawList
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "# ")) }
            .filter { !$0.isEmpty }

        var seen = Set<String>()
        return cleaned.filter { seen.insert($0.lowercased()).inserted }
    }
}
