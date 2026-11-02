import Foundation

/// Одна шкала времени для монтажа, глав и проверки длительности.
struct LongformTimeline: Sendable {
    static let intro: Double = 2.5
    static let outro: Double = 4
    static let interActGap: Double = 0.8
    static let intraActGap: Double = 0

    struct Placement: Sendable {
        let actIndex: Int
        let sceneIndex: Int
        let source: TimeSegment
        let start: Double
        var end: Double { start + source.duration }
        let gapBefore: Double
        let isInterAct: Bool
    }

    let placements: [Placement]
    let introDuration: Double
    let speechEnd: Double
    let outroDuration: Double
    var duration: Double { speechEnd + outroDuration }
    let supportExtraDuration: Double

    init(arc: LongformNarrativeArc, coldOpenEnabled: Bool = true) {
        introDuration = coldOpenEnabled ? Self.intro : 0
        var cursor = introDuration
        var result: [Placement] = []
        for (ai, act) in arc.acts.enumerated() {
            for (si, segment) in act.segments.enumerated() {
                let interAct = result.last.map { $0.actIndex != ai } ?? false
                let gap = result.isEmpty ? 0 : (interAct ? Self.interActGap : Self.intraActGap)
                cursor += gap
                result.append(Placement(actIndex: ai, sceneIndex: si, source: segment,
                                        start: cursor, gapBefore: gap, isInterAct: interAct))
                cursor += segment.duration
            }
        }
        placements = result
        speechEnd = cursor
        let finale = LongformEditorialSupport.finalCard(for: arc)
        let baseFinale = LongformEditorialSupport.finalCardDuration(text: finale)
        outroDuration = arc.support?.finaleDuration(text: finale) ?? baseFinale
        supportExtraDuration = max(0, outroDuration - baseFinale)
    }

    func start(ofAct index: Int) -> Double? {
        placements.first { $0.actIndex == index }?.start
    }
}

/// Рампы не добавляют времени: внутри акта кадр уходит в чёрный на самой
/// склейке и сразу проявляется. Все интервалы строго раздельны для AVFoundation.
enum LongformTransitionPlan {
    struct Ramp: Equatable, Sendable {
        let from: Float
        let to: Float
        let start: Double
        let end: Double
    }

    static func ramps(intro: Double, speechEnd: Double, cuts: [LongformCutTransition]) -> [Ramp] {
        guard speechEnd.isFinite, speechEnd > 0 else { return [] }
        var result: [Ramp] = []
        func append(_ from: Float, _ to: Float, _ start: Double, _ end: Double) {
            guard start.isFinite, end.isFinite else { return }
            let lower = max(0, start, (result.last?.end ?? -0.001) + 0.001)
            let upper = min(end, speechEnd)
            guard upper - lower >= 0.02 else { return }
            result.append(Ramp(from: from, to: to, start: lower, end: upper))
        }
        append(0, 1, intro, intro + (intro > 0 ? 1.5 : 1.2))
        for cut in cuts.sorted(by: { $0.sceneEndTime < $1.sceneEndTime }) {
            guard cut.sceneEndTime.isFinite, cut.nextSceneStartTime.isFinite,
                  cut.nextSceneStartTime >= cut.sceneEndTime else { continue }
            append(1, 0, max(intro + 0.5, cut.sceneEndTime - (cut.isInterAct ? 0.35 : 0.28)), cut.sceneEndTime)
            append(0, 1, cut.nextSceneStartTime, cut.nextSceneStartTime + (cut.isInterAct ? 0.45 : 0.32))
        }
        append(1, 0, max(intro + 2, speechEnd - 1.2), speechEnd)
        return result
    }
}

/// Saved with each essay so changing channel defaults never silently changes an export.
struct EssaySupport: Codable, Equatable, Sendable {
    static let defaultURL = "https://donatello.to/kadr_sens"
    var donatelloURL: String = defaultURL
    var creditsEnabled = false
    var nicknames: [String] = []

    static func normalizedURL(_ text: String) -> String? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", url.host?.lowercased() == "donatello.to",
              url.user == nil, url.password == nil, url.path != "", url.path != "/" else { return nil }
        return url.absoluteString
    }

    static func names(from text: String) -> [String] {
        var seen = Set<String>()
        return text.components(separatedBy: .newlines).compactMap { line in
            let name = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let key = name.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "@"))
            guard !name.isEmpty, seen.insert(key).inserted else { return nil }
            return name
        }
    }

    var validationIssue: String? {
        if !donatelloURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           Self.normalizedURL(donatelloURL) == nil { return "Укажите ссылку вида https://donatello.to/ваш_канал" }
        if creditsEnabled {
            if nicknames.isEmpty { return "Добавьте хотя бы один ник или выключите благодарности." }
            if nicknames.count > 24 { return "В финальные титры помещается до 24 ников. Разделите список между выпусками." }
            if nicknames.contains(where: { $0.count > 40 || $0.contains(where: \.isNewline) }) {
                return "Каждый ник должен занимать одну строку длиной до 40 символов."
            }
        }
        return nil
    }

    var showsCredits: Bool { creditsEnabled && !nicknames.isEmpty && validationIssue == nil }
    func finaleDuration(text: String) -> Double {
        let base = LongformEditorialSupport.finalCardDuration(text: text)
        guard showsCredits else { return base }
        let rows = ceil(Double(nicknames.count) / 2)
        return max(base, min(18, max(8, (rows + 3) * 0.95 + 1.2)))
    }
}
