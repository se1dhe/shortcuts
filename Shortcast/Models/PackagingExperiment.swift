import Foundation

/// Variants and observations belong to a project, not to a rendered montage's identity.
struct PackagingExperiment: Codable, Equatable, Identifiable, Sendable {
    static let currentCoverVersion = 2
    var id = UUID()
    var createdAt = Date()
    var title: String
    var coverText: String
    var rationale: String
    var coverURL: URL?
    var coverSubject: ThumbnailSubjectEvidence? = nil
    var coverVersion: Int? = nil
    var sourceVariantID: UUID? = nil
    var editorialAngle: String? = nil
    var needsCoverRefresh: Bool { coverVersion != Self.currentCoverVersion || coverURL.map { !FileManager.default.fileExists(atPath: $0.path) } != false }
    var appliedAt: Date?
    var observations: [Observation] = []

    /// Editing packaging creates a new experiment; measurements describe the old presentation.
    func newRevision() -> PackagingExperiment {
        var copy = self
        copy.id = UUID(); copy.createdAt = Date(); copy.sourceVariantID = id
        copy.coverURL = nil; copy.coverSubject = nil; copy.coverVersion = nil
        copy.appliedAt = nil; copy.observations = []
        return copy
    }

    /// A sheet may hold an older snapshot. Appending a measurement must never
    /// replace a newer observation list or restore stale packaging fields.
    func mergingObservations(from snapshot: PackagingExperiment) -> PackagingExperiment {
        var updated = self
        let known = Set(observations.map(\.id))
        updated.observations += snapshot.observations.filter { !known.contains($0.id) }
        updated.observations.sort { $0.date < $1.date }
        return updated
    }

    /// Bounded factual feedback for the editor; no synthetic winner or causal attribution.
    static func measurementContext(_ variants: [PackagingExperiment]) -> String? {
        struct Measurement: Encodable {
            let title: String
            let coverText: String
            let observation: Observation
        }
        let values = variants.flatMap { variant in
            variant.observations.map { observation in
                var bounded = observation
                bounded.source = String(observation.source.prefix(200)); bounded.notes = String(observation.notes.prefix(600))
                return Measurement(title: String(variant.title.prefix(100)), coverText: String(variant.coverText.prefix(24)), observation: bounded)
            }
        }.sorted { $0.observation.date > $1.observation.date }.prefix(8)
        guard !values.isEmpty else { return nil }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(Array(values)) else { return nil }
        return String(data: data, encoding: .utf8)
    }
    struct Observation: Codable, Equatable, Identifiable, Sendable {
        var id = UUID()
        var date = Date()
        var views: Int?
        var impressions: Int?
        var ctr: Double?
        var averageViewSeconds: Double?
        var retentionPercent: Double?
        var source: String
        var notes: String
        var periodStart: Date? = nil
        var periodEnd: Date? = nil
        var claimStatus: ClaimStatus? = nil
        var monetizationStatus: MonetizationStatus? = nil
    }

    enum ClaimStatus: String, Codable, CaseIterable, Sendable {
        case unknown, noKnownClaims, claimed, blocked
        var label: String {
            switch self {
            case .unknown: "Не проверено"
            case .noKnownClaims: "Претензий не обнаружено"
            case .claimed: "Есть претензия"
            case .blocked: "Есть блокировка"
            }
        }
    }
    enum MonetizationStatus: String, Codable, CaseIterable, Sendable {
        case unknown, enabled, limited, disabled
        var label: String {
            switch self {
            case .unknown: "Не проверено"
            case .enabled: "Включена"
            case .limited: "Ограничена"
            case .disabled: "Выключена"
            }
        }
    }
}

enum PackagingVariantParser {
    static func parse(_ text: String) throws -> [PackagingExperiment] {
        struct Reply: Decodable { let variants: [Variant] }
        struct Variant: Decodable { let title: String; let coverText: String; let rationale: String; let angle: String? }
        let json = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
        let reply = try JSONDecoder().decode(Reply.self, from: Data(json.utf8))
        guard reply.variants.count == 3 else { throw EssayReleaseError.invalid("Модель должна вернуть три варианта упаковки.") }
        let variants = reply.variants.map { PackagingExperiment(title: ThematicConcept.cleanTitle($0.title), coverText: ThematicConcept.cleanTitle($0.coverText), rationale: $0.rationale, editorialAngle: $0.angle) }
        let normalizedTitles = variants.map { normalized($0.title) }
        let normalizedCovers = variants.map { normalized($0.coverText) }
        guard Set(normalizedTitles).count == 3,
              Set(normalizedCovers).count == 3,
              variants.allSatisfy({ !$0.title.trimmed.isEmpty && $0.title.count <= 100 && !$0.coverText.trimmed.isEmpty && $0.coverText.count <= 24 && $0.coverText.split(whereSeparator: \.isWhitespace).count <= 3 && !$0.rationale.trimmed.isEmpty }) else {
            throw EssayReleaseError.invalid("Варианты повторяются или текст обложки слишком длинный. Повторите генерацию.")
        }
        return variants
    }

    static func requireDistinctAngles(_ variants: [PackagingExperiment]) throws {
        guard Set(variants.compactMap(\.editorialAngle)) == Set(["viewerChoice", "characterConflict", "decisionCost"]) else {
            throw EssayReleaseError.invalid("Нужны три разных угла: личный выбор, конфликт героя и цена решения.")
        }
    }

    static func requireEditorialApproval(_ text: String) throws {
        struct Review: Decodable { let approved: Bool; let issues: [String] }
        let json = text.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "").trimmed
        let review = try JSONDecoder().decode(Review.self, from: Data(json.utf8))
        guard review.approved && review.issues.isEmpty else {
            let explanation = review.issues.isEmpty ? "варианты не одобрены; повторите генерацию" : String(review.issues.joined(separator: "; ").prefix(700))
            throw EssayReleaseError.invalid("Редактор упаковки: " + explanation)
        }
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "uk_UA"))
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }
}
