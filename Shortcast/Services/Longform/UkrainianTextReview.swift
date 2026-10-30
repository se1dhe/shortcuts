import AppKit

/// Только подсветка сомнительных слов. Имена и разговорная речь могут быть
/// корректными: словарь не имеет права переписывать дубляж автоматически.
@MainActor
enum UkrainianTextReview {
    static func suspiciousWords(in text: String) -> [String] {
        guard let language = NSSpellChecker.shared.availableLanguages.first(where: { $0.hasPrefix("uk") }) else { return [] }
        let input = text.lowercased() as NSString
        var cursor = 0
        var words: [String] = []
        while cursor < input.length && words.count < 6 {
            let range = NSSpellChecker.shared.checkSpelling(of: input as String, startingAt: cursor,
                language: language, wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
            guard range.location != NSNotFound, range.length > 0 else { break }
            let word = input.substring(with: range)
            if !words.contains(word) { words.append(word) }
            cursor = NSMaxRange(range)
        }
        return words
    }
}
