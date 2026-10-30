import Foundation

/// Правка отображения не меняет ASR-источник и цитаты, которыми обоснован выбор сцен.
struct LongformCaptionEdit: Codable, Equatable, Sendable {
    let start: Double
    let end: Double
    let original: String
    let replacement: String
}

struct LongformSceneEdit: Codable, Equatable, Sendable {
    let role: LongformActType
    let original: TimeSegment
    let revised: TimeSegment
    let reason: String
}

struct LongformCaptionSuggestion: Codable, Equatable, Sendable {
    let start: Double
    let end: Double
    let original: String
    let replacement: String
    let reason: String
}

enum LongformEditorialSupport {
    static let contextAllowance: Double = 8

    static func anchor(for range: TimeSegment, role: LongformActType, in arc: LongformNarrativeArc) -> TimeSegment {
        arc.sceneEdits?.first(where: { $0.role == role && $0.revised == range })?.original ?? range
    }

    static func recordingEdits(from arc: LongformNarrativeArc, acts: [LongformAct],
                               reason: String = "Границы изменены пользователем в монтажном столе") -> [LongformSceneEdit] {
        var edits = arc.sceneEdits ?? []
        for (oldAct, newAct) in zip(arc.acts, acts) {
            for (original, revised) in zip(oldAct.segments, newAct.segments) where original != revised {
                let anchor = anchor(for: original, role: oldAct.type, in: arc)
                edits.removeAll { $0.role == oldAct.type && $0.original == anchor }
                edits.append(LongformSceneEdit(role: oldAct.type, original: anchor, revised: revised,
                                              reason: reason))
            }
        }
        return edits
    }

    static func finalCard(for arc: LongformNarrativeArc) -> String {
        [arc.conclusionText, actionableCTA(arc.ctaText, destination: arc.discussionURL)]
            .compactMap { $0 }.filter { !$0.trimmed.isEmpty }.joined(separator: "\n\n")
    }

    static func finalCardDuration(text: String) -> Double {
        guard !text.trimmed.isEmpty else { return 4 }
        return min(18, max(4, Double(text.split(whereSeparator: \.isWhitespace).count) / 3 + 1.5))
    }

    static func allowed(_ revised: TimeSegment, around original: TimeSegment) -> Bool {
        revised.start.isFinite && revised.end.isFinite && revised.start >= 0
            && EssayDurationPolicy.sceneLength.contains(revised.duration)
            && abs(revised.start - original.start) <= contextAllowance
            && abs(revised.end - original.end) <= contextAllowance
            && min(revised.end, original.end) - max(revised.start, original.start) >= 10
    }

    static func captionEdits(original: [TranscriptSegment], updated: [TranscriptSegment]) -> [LongformCaptionEdit] {
        // Сопоставляем по времени, а не позиции: редактор может показывать только часть фильма.
        original.compactMap { source in
            guard let edited = updated.first(where: { $0.start == source.start && $0.end == source.end }),
                  edited.text != source.text else { return nil }
            return LongformCaptionEdit(start: source.start, end: source.end,
                                       original: source.text, replacement: edited.text)
        }
    }

    static func captions(_ segments: [TranscriptSegment], edits: [LongformCaptionEdit]?) -> [TranscriptSegment] {
        segments.map { segment in
            guard let edit = edits?.first(where: {
                $0.start == segment.start && $0.end == segment.end && $0.original == segment.text
            }) else { return segment }
            return TranscriptSegment(start: segment.start, end: segment.end, text: edit.replacement,
                                     words: [], avgLogprob: segment.avgLogprob, noSpeechProb: segment.noSpeechProb)
        }
    }

    /// Никакого придуманного адреса: без назначения задаём вопрос в комментариях.
    static func telegramURL(channelID: String) -> String? {
        let clean = channelID.trimmed
        let name: String
        if clean.hasPrefix("@") { name = String(clean.dropFirst()) }
        else if let url = URL(string: clean), url.scheme == "https", url.host == "t.me" {
            name = String(url.path.dropFirst())
        } else { return nil }
        guard name.range(of: #"^[A-Za-z][A-Za-z0-9_]{3,31}$"#, options: .regularExpression) != nil else { return nil }
        return "https://t.me/" + name
    }

    static func actionableCTA(_ text: String?, destination: String? = nil) -> String? {
        guard let text, !text.trimmed.isEmpty else { return nil }
        let lower = text.lowercased()
        guard lower.contains("telegram") || lower.contains("телеграм") else { return text }
        if lower.contains("t.me/") || lower.range(of: #"@[a-z][a-z0-9_]{3,31}"#, options: .regularExpression) != nil { return text }
        if let destination, telegramURL(channelID: destination) != nil { return text + "\n" + destination }
        let parts = text.components(separatedBy: ":")
        if parts.count > 1 {
            return "Напишіть у коментарях: " + parts.dropFirst().joined(separator: ":").trimmed
        }
        return "Обговорімо в коментарях. " + text
            .replacingOccurrences(of: "Telegram", with: "коментарях", options: .caseInsensitive)
            .replacingOccurrences(of: "Телеграм", with: "коментарях", options: .caseInsensitive)
    }

    static func notes(for arc: LongformNarrativeArc, transcript: Transcript) -> [String] {
        let lines = transcript.segments.sorted { $0.start < $1.start }
        var notes: [String] = []
        for (ai, act) in arc.acts.enumerated() {
            for (si, scene) in act.segments.enumerated() {
                let speech = lines.filter { $0.end > scene.start && $0.start < scene.end }
                guard let first = speech.first, let last = speech.last else { continue }
                let prefix = "Акт \(ai + 1), сцена \(si + 1): "
                if first.start < scene.start - 0.05 || last.end > scene.end + 0.05 {
                    notes.append(prefix + "граница пересекает реплику — проверьте вход и выход на слух.")
                }
                let head = first.text.trimmed.lowercased()
                if ["а ", "але ", "тому ", "бо ", "знаєш, чому", "він ", "вона ", "це "].contains(where: head.hasPrefix) {
                    notes.append(prefix + "вход может требовать предыдущего контекста: «\(first.text.prefix(90))».")
                }
                if act.type == .catharsis && scene.end - last.end < 0.3 {
                    notes.append(prefix + "выход сразу после слов: проверьте, не осталось ли действие за склейкой.")
                }
            }
        }
        return notes
    }
}
