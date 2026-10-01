import Foundation

extension String {
    /// Whitespace/newline-trimmed copy.
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    /// User-visible transcript text without Whisper timestamp/control tokens.
    var cleanedTranscriptText: String {
        var value = self
        let patterns = [
            #"(?im)^\s*(WEBVTT|NOTE|Kind:\s*\w+|Language:\s*[A-Za-z-]+)\s*$"#,
            #"(?im)^\s*(?:\d+\s*)?(?:\d{1,2}:)?\d{1,2}:\d{2}(?:[,.]\d{1,3})?\s*-->\s*(?:\d{1,2}:)?\d{1,2}:\d{2}(?:[,.]\d{1,3})?.*$"#,
            #"<\|[^|]+\|>"#,
            #"<[0-9]+(?:\.[0-9]+)?>"#,
            #"\|[0-9]+(?:\.[0-9]+)?\|"#,
            #"\[(?:Music|Applause|Laughter|Silence|Noise|Background noise|inaudible|музыка|аплодисменты|смех|тишина|шум|неразборчиво)\]"#,
            #"(?i)\bendoftext\b"#,
            // Strip HTML/VTT tags like <c>, <i>, <c.colorE5E5E5>, </c>, <v Speaker>
            #"<[^>]+>"#,
        ]
        for pattern in patterns {
            value = value.replacingOccurrences(
                of: pattern,
                with: "",
                options: .regularExpression)
        }
        return value
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmed
    }

    var cleanedForHighlight: String {
        replacingOccurrences(of: #"[\p{P}\p{S}]"#, with: "", options: .regularExpression)
            .trimmed
    }

    /// Removes special tokens/models artifacts that sometimes leak into
    /// generated hooks and captions (e.g. `<image|>`, `<|image|>`, `<image>`).
    /// Keeps the surrounding text intact and collapses leftover whitespace.
    var sanitizedModelText: String {
        let patterns = [
            #"<\|[^|]+\|>"#,
            #"<[A-Za-z_][A-Za-z0-9_]*\|>"#,
            #"<[A-Za-z_][A-Za-z0-9_]*>"#,
        ]
        var value = self
        for pattern in patterns {
            value = value.replacingOccurrences(
                of: pattern,
                with: "",
                options: .regularExpression)
        }
        return value
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmed
    }

    /// Truncates to the given character limit, preferring to stop on a word
    /// boundary (space or punctuation) so the thought stays complete.
    func truncatingToHook(limit: Int = 50) -> String {
        guard count > limit else { return self }

        let separators: Set<Character> = [" ", "-", ".", ",", "!", "?", ":", ";", "…"]
        let prefix = String(self.prefix(limit))

        if let lastSepIdx = prefix.lastIndex(where: separators.contains) {
            let result = String(prefix[..<lastSepIdx])
                .trimmingCharacters(in: .whitespaces)
            if result.count >= 3 { return result }
        }

        // Fallback: hard cut with ellipsis
        return String(prefix.prefix(max(0, limit - 1))) + "…"
    }
}
