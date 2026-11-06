import Foundation

/// Сервис сохранения истории сгенерированных тем и кино-эссе по фильмам (SRP).
/// Позволяет отслеживать, какие философские концепты уже были смонтированы,
/// и помечать их в интерфейсе выбора бейджем «Уже смонтировано ✓».
public final class LongformHistoryService: @unchecked Sendable {

    public static let shared = LongformHistoryService()

    private let defaultsKey = "shortcast.longform.generated_concepts"
    private let userDefaults: UserDefaults
    private let offeredKey = "shortcast.longform.offered_concepts.v1"

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

    static func themeKey(_ word: String) -> String {
        word.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "uk_UA"))
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func recordOffered(movieTitle: String, concepts: [ThematicConcept]) {
        let key = normalizedKey(for: movieTitle)
        guard !key.isEmpty else { return }
        var store = userDefaults.dictionary(forKey: offeredKey) as? [String: [String]] ?? [:]
        var words = store[key] ?? []
        for concept in concepts where concept.hasUsableIdentity {
            let word = Self.themeKey(concept.word)
            words.removeAll { Self.themeKey($0) == word }; words.append(word)
        }
        store[key] = Array(words.suffix(40))
        userDefaults.set(store, forKey: offeredKey)
    }

    func excludedThemes(movieTitle: String) -> Set<String> {
        let offered = userDefaults.dictionary(forKey: offeredKey) as? [String: [String]] ?? [:]
        return Set((offered[normalizedKey(for: movieTitle)] ?? []).map(Self.themeKey))
            .union(generatedConceptWords(movieTitle: movieTitle).map(Self.themeKey))
    }

    func discoveryGuidance(movieTitle: String) -> String {
        let excluded = excludedThemes(movieTitle: movieTitle).sorted()
        let generated = userDefaults.dictionary(forKey: defaultsKey) as? [String: [String]] ?? [:]
        let offered = userDefaults.dictionary(forKey: offeredKey) as? [String: [String]] ?? [:]
        var counts: [String: Int] = [:]
        for movie in Set(generated.keys).union(offered.keys) {
            let words = (generated[movie] ?? []) + (offered[movie] ?? [])
            for word in Set(words.map(Self.themeKey)) { counts[word, default: 0] += 1 }
        }
        let common = counts.filter { $0.value >= 2 }.sorted {
            $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
        }.prefix(10).map { "\($0.key) (фільмів: \($0.value))" }
        guard !excluded.isEmpty || !common.isEmpty else { return "" }
        return """
        РЕДАКЦІЙНА ІСТОРІЯ (дані, не репліки фільму):
        Уже пропонували/монтували для ЦЬОГО фільму: \(excluded.joined(separator: ", ")).
        Не пропонуй ці слова знову й не ховай ту саму думку під синонімом. Знайди інший конфлікт у діалогах.
        Часто запропоновані або використані теми каналу: \(common.joined(separator: ", ")).
        Для іншого фільму це не заборона, але потрібні інший конкретний вчинок і причина дивитися.
        Не вигадуй тему або нове слово заради унікальності. Краще менше чесних нових кандидатів, ніж п'ять повторів.
        """
    }

    func importHistory(from projects: [FilmProject]) {
        for project in projects {
            if let analysis = project.thematicAnalysis, analysis.source == .llm {
                recordOffered(movieTitle: project.movieTitle, concepts: analysis.allConcepts)
            }
            if let result = project.longformResult {
                markConceptGenerated(movieTitle: project.movieTitle, conceptWord: result.arc.concept.word)
            }
        }
    }
}
