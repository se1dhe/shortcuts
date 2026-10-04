import Foundation

/// Сервис сохранения истории сгенерированных тем и кино-эссе по фильмам (SRP).
/// Позволяет отслеживать, какие философские концепты уже были смонтированы,
/// и помечать их в интерфейсе выбора бейджем «Уже смонтировано ✓».
public final class LongformHistoryService: @unchecked Sendable {

    public static let shared = LongformHistoryService()

    private let defaultsKey = "shortcast.longform.generated_concepts"
    private let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    private func normalizedKey(for movieTitle: String) -> String {
        movieTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Проверяет, было ли уже смонтировано эссе по данному слову для указанного фильма
    public func isConceptGenerated(movieTitle: String, conceptWord: String) -> Bool {
        let key = normalizedKey(for: movieTitle)
        guard !key.isEmpty else { return false }
        let store = userDefaults.dictionary(forKey: defaultsKey) as? [String: [String]] ?? [:]
        let words = store[key] ?? []
        let cleanWord = conceptWord.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return words.contains(cleanWord)
    }

    /// Помечает тему как смонтированную для данного фильма
    public func markConceptGenerated(movieTitle: String, conceptWord: String) {
        let key = normalizedKey(for: movieTitle)
        guard !key.isEmpty else { return }
        var store = userDefaults.dictionary(forKey: defaultsKey) as? [String: [String]] ?? [:]
        var words = store[key] ?? []
        let cleanWord = conceptWord.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !words.contains(cleanWord) {
            words.append(cleanWord)
            store[key] = words
            userDefaults.set(store, forKey: defaultsKey)
        }
    }

    /// Возвращает множество всех уже смонтированных слов для данного фильма
    public func generatedConceptWords(movieTitle: String) -> Set<String> {
        let key = normalizedKey(for: movieTitle)
        guard !key.isEmpty else { return [] }
        let store = userDefaults.dictionary(forKey: defaultsKey) as? [String: [String]] ?? [:]
        let words = store[key] ?? []
        return Set(words.map { $0.lowercased() })
    }
}
