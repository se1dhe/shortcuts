import AppKit

/// Только подсветка сомнительных слов. Имена и разговорная речь могут быть
/// корректными: словарь не имеет права переписывать дубляж автоматически.
@MainActor
enum UkrainianTextReview {
    static func themeSpellingIssue(_ word: String) -> String? {
        guard let spelling = suspiciousWords(in: word).first else { return nil }
        return "Перевір українське написання слова теми «\(word)»: словник позначив «\(spelling)». Виправ описку або обери правильно написане слово. Не змінюй зміст теми заради формату відповіді."
    }

    static func suspiciousWords(in text: String) -> [String] {
        guard let language = NSSpellChecker.shared.availableLanguages.first(where: { $0.hasPrefix("uk") }) else { return [] }
        // Document 0 is shared with the UI and can retain its automatic language
        // selection. An isolated document prevents correct Ukrainian words from
        // being checked against another editor's dictionary.
        let document = NSSpellChecker.uniqueSpellDocumentTag()
        defer { NSSpellChecker.shared.closeSpellDocument(withTag: document) }
        let input = text.lowercased() as NSString
        var cursor = 0
        var words: [String] = []
        while cursor < input.length && words.count < 6 {
            let range = NSSpellChecker.shared.checkSpelling(of: input as String, startingAt: cursor,
                language: language, wrap: false, inSpellDocumentWithTag: document, wordCount: nil)
            guard range.location != NSNotFound, range.length > 0 else { break }
            let word = input.substring(with: range)
            if !words.contains(word) { words.append(word) }
            cursor = NSMaxRange(range)
        }
        return words
    }
}
