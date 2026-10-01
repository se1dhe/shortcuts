import Foundation

/// Loads TikTok Community & Recommendation Guidelines from the app bundle and
/// optionally fetches the latest version from TikTok's official page.
enum TikTokGuidelinesService {

    /// A single guideline entry — one actionable rule.
    struct Rule: Sendable, Codable, Equatable {
        var category: String
        var rule: String
    }

    /// A structured section that maps to one analysis criterion.
    struct Section: Sendable, Codable, Equatable {
        var title: String
        var rules: [Rule]
    }

    /// Loads guidelines from the built-in markdown resource.
    static func loadBuiltIn() -> [Section] {
        guard let url = Bundle.main.url(forResource: "tiktok-guidelines", withExtension: "md"),
              let markdown = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        return parse(markdown)
    }

    /// Fetches the latest guidelines from TikTok's official Community Guidelines page.
    static func fetchLatest() async throws -> [Section] {
        let url = URL(string: "https://www.tiktok.com/community-guidelines")!
        var request = URLRequest(url: url)
        request.setValue("Shortcast/1.0", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let html = String(data: data, encoding: .utf8) else {
            throw GuidelinesError.fetchFailed
        }
        return parseHTML(html)
    }

    enum GuidelinesError: LocalizedError {
        case fetchFailed
        case parseFailed

        var errorDescription: String? {
            switch self {
            case .fetchFailed: String(localized: "Could not download TikTok guidelines.")
            case .parseFailed: String(localized: "Could not read TikTok guidelines.")
            }
        }
    }

    // MARK: - Markdown parser (for the built-in resource)

    private static func parse(_ markdown: String) -> [Section] {
        var sections: [Section] = []
        var currentTitle = ""
        var currentRules: [Rule] = []

        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("### ") {
                if !currentTitle.isEmpty {
                    sections.append(Section(title: currentTitle, rules: currentRules))
                }
                currentTitle = String(trimmed.dropFirst(4))
                currentRules = []
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                let rule = String(trimmed.dropFirst(2))
                if !rule.isEmpty {
                    currentRules.append(Rule(category: currentTitle, rule: rule))
                }
            }
        }
        if !currentTitle.isEmpty {
            sections.append(Section(title: currentTitle, rules: currentRules))
        }
        return sections
    }

    // MARK: - HTML parser for TikTok's official page

    private static func parseHTML(_ html: String) -> [Section] {
        var sections: [Section] = []
        var currentTitle = ""
        var currentRules: [Rule] = []

        let lines = html.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmed.hasPrefix("<h2") || trimmed.hasPrefix("<h3") {
                if let start = trimmed.range(of: ">")?.upperBound,
                   let end = trimmed.range(of: "</h")?.lowerBound {
                    let title = String(trimmed[start..<end])
                        .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                        .trimmingCharacters(in: .whitespaces)
                    if !title.isEmpty {
                        if !currentTitle.isEmpty {
                            sections.append(Section(title: currentTitle, rules: currentRules))
                        }
                        currentTitle = title
                        currentRules = []
                    }
                }
            } else if trimmed.hasPrefix("<li") || trimmed.hasPrefix("<p") {
                let text = trimmed
                    .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
                if !text.isEmpty && text.count > 20 {
                    currentRules.append(Rule(category: currentTitle, rule: text))
                }
            }
        }
        if !currentTitle.isEmpty {
            sections.append(Section(title: currentTitle, rules: currentRules))
        }
        return sections
    }
}
