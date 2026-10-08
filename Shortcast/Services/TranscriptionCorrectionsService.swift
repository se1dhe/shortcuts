import Foundation
import Observation

/// Self-learning dictionary for on-device transcription. Every time the user
/// fixes a subtitle phrase in the editor, we remember `original → corrected`
/// and feed the corrected vocabulary back into Whisper as a conditioning prompt
/// (`DecodingOptions.promptTokens`) on the next run, so recurring names and
/// terms stop being mis-heard.
@MainActor
@Observable
final class TranscriptionCorrectionsService {

    static let shared = TranscriptionCorrectionsService()

    private(set) var corrections: [String: String] = [:]

    private let defaults: UserDefaults
    private static let storageKey = "shortcast.transcription.corrections"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            corrections = decoded
        }
    }

    /// Stores a correction when the texts genuinely differ.
    func recordCorrection(original: String, corrected: String) {
        let source = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let fixed = corrected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, !fixed.isEmpty, source != fixed else { return }
        corrections[source] = fixed
        persist()
    }

    func removeCorrection(for original: String) {
        guard corrections.removeValue(forKey: original) != nil else { return }
        persist()
    }

    func clearAll() {
        guard !corrections.isEmpty else { return }
        corrections.removeAll()
        persist()
    }

    /// Builds the Whisper conditioning prompt from the most useful corrections:
    /// the corrected (target) vocabulary, longest first, capped at `limit`
    /// entries and a safe character budget. Whisper trims to its own max prompt
    /// length, so this stays well under it.
    func buildInitialPrompt(limit: Int = 50) -> String {
        guard !corrections.isEmpty else { return "" }
        let values = corrections.values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let unique = Array(Set(values))
            .sorted { $0.count > $1.count }
            .prefix(limit)
        var joined = unique.joined(separator: ", ")
        if joined.count > 900 { joined = String(joined.prefix(900)) }
        return joined
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(corrections) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    // MARK: - CSV export / import

    func exportCSV(to url: URL) throws {
        var csv = "original,corrected\n"
        for key in corrections.keys.sorted() {
            csv += "\(Self.csvField(key)),\(Self.csvField(corrections[key] ?? ""))\n"
        }
        try csv.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    /// Merges a CSV file (`original,corrected` with an optional header) into the
    /// dictionary. Uses a small state machine so quoted fields may contain
    /// commas, newlines and doubled quotes.
    func importCSV(from url: URL) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        let rows = Self.parseCSV(text)
        var added = 0
        for (index, row) in rows.enumerated() {
            guard row.count >= 2 else { continue }
            let original = row[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let corrected = row[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if index == 0 && original.lowercased() == "original" && corrected.lowercased() == "corrected" {
                continue
            }
            guard !original.isEmpty, !corrected.isEmpty, original != corrected else { continue }
            corrections[original] = corrected
            added += 1
        }
        if added > 0 { persist() }
    }

    private static func csvField(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }

    private static func parseCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = text.makeIterator()
        while let char = iterator.next() {
            if inQuotes {
                if char == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" { field.append("\"") }
                        else { inQuotes = false; if next == "\n" { row.append(field); field = ""; rows.append(row); row = [] } else if next == "," { row.append(field); field = "" } else { field.append(next) } }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(char)
                }
            } else {
                switch char {
                case "\"": inQuotes = true
                case ",": row.append(field); field = ""
                case "\n": row.append(field); field = ""; rows.append(row); row = []
                case "\r": break
                default: field.append(char)
                }
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows.filter { $0.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) }
    }
}
