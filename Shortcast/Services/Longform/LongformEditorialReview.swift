import Foundation

/// Проход по реальным диалогам и соседним репликам. Модель выбирает готовые
/// варианты локального монтажа; новые сцены и свободные таймкоды не принимаются.
struct LongformEditorialReview: Sendable {
    let model: (any LongformActTitleModeling)?
    var correctionMemory = SubtitleCorrectionMemory()
    var correctionFilmKey = ""
    var correctionLanguage = "uk"

    struct Option: Sendable {
        let id: String
        let range: TimeSegment
    }

    static func options(for range: TimeSegment, transcript: Transcript) -> [Option] {
        let lines = transcript.segments.sorted { $0.start < $1.start }
        let filmEnd = lines.map(\.end).max() ?? range.end
        var result = [Option(id: "keep", range: range)]
        func add(_ id: String, start: Double, end: Double) {
            let candidate = TimeSegment(start: max(0, start), end: min(end, filmEnd))
            guard LongformEditorialSupport.allowed(candidate, around: range),
                  !result.contains(where: { $0.range == candidate }) else { return }
            result.append(Option(id: id, range: candidate))
        }
        if let previous = lines.last(where: { $0.start < range.start - 0.05 && $0.start >= range.start - 8 }) {
            add("context", start: previous.start, end: range.end)
        }
        if let next = lines.first(where: { $0.start > range.start + 1 && $0.start <= range.start + 8 }) {
            add("tighterIn", start: next.start, end: range.end)
        }
        if let previous = lines.last(where: { $0.end < range.end - 0.05 && $0.end >= range.end - 8 }) {
            add("tighterOut", start: range.start, end: previous.end)
        }
        if let next = lines.first(where: { $0.end > range.end + 0.05 && $0.end <= range.end + 8 }) {
            add("completeLine", start: range.start, end: next.end)
        }
        // Действие может продолжаться без реплик: модель видит вариант с хвостом,
        // но не получает выдуманного описания того, что в нём изображено.
        let tailEnd = min(range.end + 6, lines.first(where: { $0.start > range.end })?.start ?? filmEnd)
        if tailEnd > range.end + 0.5 { add("aftermath", start: range.start, end: tailEnd) }
        return result
    }

    static let instructions = """
    Ти — редактор українського кіноесе. Аналізуй лише надані репліки, не пам'ять про фільм.
    Мета: зрозумілий хук → аргумент → суперечність → відповідь на тезу.
    Перевір самодостатність входів, зайві повтори, відступи від теми та причинну розв'язку.
    Початок «а він», «знаєш чому» без контексту — ризик. Кінець речення не завжди кінець дії.
    У кожної сцени є ID і готові варіанти меж: обирай лише наданий option.
    aftermath означає 6 секунд реального матеріалу після слів, а НЕ підтвердження певної дії.
    Не переставляй акти, не додавай нових сцен, не змінюй тему, не переписуй репліки дубляжу.
    Якщо бачиш явну помилку ASR, запропонуй виправлення в captionSuggestions за номером L.
    Це лише пропозиція для звірки зі звуком. Не змінюй стиль персонажа, не цензуруй лайку.
    Номер line — ціле число без префікса L. Обирай лише L з ВСЕРЕДИНІ вибраних сцен.
    Порожнє ДО/ПІСЛЯ означає відсутність розпізнаної мови у вікні 8 секунд, а не втрату відео.
    Якщо матеріал слабкий і варіант меж не допомагає, напиши конкретну пораду в notes.
    У title виправляй лише очевидні помилки початкової назви, без нового клікбейту.
    hook — конкретне запитання теми. conclusion — відповідь на нього, підтверджена репліками.
    Тексти короткі, українські, без згадок інструкцій. Поверни лише JSON:
    {"edits":[{"scene":1,"option":"context","reason":"коротка причина"}],
    "notes":["конкретна невирішена проблема"],"title":"вичитана початкова назва",
    "hook":"одне запитання","conclusion":"підсумок до 140 символів",
    "captionSuggestions":[{"line":0,"text":"пропозиція виправлення","reason":"причина"}]}
    """

    static func prompt(arc: LongformNarrativeArc, transcript: Transcript) -> String {
        var blocks: [String] = []
        var number = 0
        let cap = max(260, 10_000 / max(1, arc.segments.count))
        for act in arc.acts {
            for range in act.segments {
                number += 1
                let options = options(for: range, transcript: transcript).map {
                    "\($0.id)=\(String(format: "%.2f", $0.range.start))–\(String(format: "%.2f", $0.range.end))"
                }.joined(separator: "; ")
                func dialogue(_ lower: Double, _ upper: Double, limit: Int) -> String {
                    let text = transcript.segments.enumerated().filter { $0.element.end > lower && $0.element.start < upper }
                        .map { "L\($0.offset): \($0.element.text)" }.joined(separator: " ")
                    if text.count <= limit { return text }
                    return String(text.prefix(limit / 2)) + " […] " + String(text.suffix(limit / 2))
                }
                blocks.append("""
                SCENE \(number) role=\(act.type.promptKey), мета=\(act.dramaticBeat.prefix(120))
                \(options)
                ДО: \(dialogue(max(0, range.start - 8), range.start, limit: 180))
                ВСЕРЕДИНІ: \(dialogue(range.start, range.end, limit: cap))
                ПІСЛЯ: \(dialogue(range.end, range.end + 8, limit: 180))
                """)
            }
        }
        return "Тема: \(arc.concept.word). Теза: \(arc.thesis ?? arc.concept.philosophicalPremise)\n"
            + "Назва: \(arc.publicationTitle ?? arc.concept.suggestedTitle)\n" + blocks.joined(separator: "\n\n")
    }

    func review(arc: LongformNarrativeArc, transcript: Transcript, coldOpenEnabled: Bool) async -> LongformNarrativeArc {
        var result = arc
        result.editorialNotes = LongformEditorialSupport.notes(for: arc, transcript: transcript)
        guard let model, await model.isReady else {
            result.editorialNotes = (result.editorialNotes ?? [])
                + ["Редакторский проход модели недоступен или ответ не прошёл проверку; монтаж сохранён."]
            return result
        }
        let basePrompt = Self.prompt(arc: arc, transcript: transcript)
        let prompt = basePrompt + correctionMemory.promptExamples(for: basePrompt,
            filmKey: correctionFilmKey, language: correctionLanguage)
        DirectorRunLog.write("editorial review: scenes=\(arc.segments.count) promptChars=\(prompt.count)")
        guard let raw = await model.complete(instructions: Self.instructions, prompt: prompt, maxTokens: 1536) else {
            result.editorialNotes = (result.editorialNotes ?? []) + ["Редакторская модель не вернула ответ; монтаж сохранён."]
            return result
        }
        DirectorRunLog.dumpRaw(raw, stage: "editorial", attempt: 1)
        guard var reviewed = Self.apply(raw, to: arc, transcript: transcript, coldOpenEnabled: coldOpenEnabled) else {
            DirectorRunLog.write("editorial review: reply rejected; original arc retained")
            result.editorialNotes = (result.editorialNotes ?? []) + ["Правки модели не прошли проверку; монтаж сохранён."]
            return result
        }
        reviewed.editorialReviewModelID = await model.modelID
        DirectorRunLog.write("editorial review: accepted edits=\(reviewed.sceneEdits?.count ?? 0) captions=\(reviewed.captionSuggestions?.count ?? 0)")
        return reviewed
    }

    static func apply(_ raw: String, to arc: LongformNarrativeArc,
                      transcript: Transcript, coldOpenEnabled: Bool) -> LongformNarrativeArc? {
        guard let json = JSONVariantParser.extractJSONObject(from: raw),
              let data = json.data(using: .utf8),
              let reply = try? JSONDecoder().decode(Reply.self, from: data) else { return nil }
        var result = arc
        var seen = Set<Int>()
        var notes = Array(reply.notes.prefix(8)).map { String($0.prefix(240)) }
        let placements = arc.acts.enumerated().flatMap { ai, act in
            act.segments.indices.map { (ai, $0) }
        }
        for edit in reply.edits {
            guard edit.scene > 0, edit.scene <= placements.count, seen.insert(edit.scene).inserted,
                  !edit.reason.trimmed.isEmpty else { return nil }
            let (ai, si) = placements[edit.scene - 1]
            let original = arc.acts[ai].segments[si]
            guard let option = options(for: original, transcript: transcript).first(where: { $0.id == edit.option })
            else { return nil }
            if option.id == "keep" { continue }
            let anchor = LongformEditorialSupport.anchor(for: original, role: arc.acts[ai].type, in: arc)
            guard LongformEditorialSupport.allowed(option.range, around: anchor) else { return nil }
            result.acts[ai].segments[si] = option.range
        }
        let ranges = result.segments.sorted { $0.start < $1.start }
        guard zip(ranges, ranges.dropFirst()).allSatisfy({ $0.end <= $1.start }),
              EssayDurationPolicy.rendered.contains(LongformTimeline(arc: result, coldOpenEnabled: coldOpenEnabled).duration)
        else { return nil }
        result = protectingActionTails(in: result, transcript: transcript, coldOpenEnabled: coldOpenEnabled)
        result.sceneEdits = LongformEditorialSupport.recordingEdits(from: arc, acts: result.acts,
            reason: "Сохранён немой хвост развязки после последней реплики (до 6 с)").map { recorded in
            guard let edit = reply.edits.first(where: {
                let (ai, si) = placements[$0.scene - 1]
                return result.acts[ai].type == recorded.role && result.acts[ai].segments[si] == recorded.revised
            }) else { return recorded }
            return LongformSceneEdit(role: recorded.role, original: recorded.original,
                                     revised: recorded.revised, reason: String(edit.reason.prefix(200)))
        }
        // Назва і хук уже схвалені при виборі теми; локальний монтаж їх не перевибирає.
        result.publicationTitle = arc.publicationTitle
            ?? (arc.concept.suggestedTitle.trimmed.isEmpty ? cleanText(reply.title, max: 120) : arc.concept.suggestedTitle)
        result.hookText = arc.hookText ?? cleanText(reply.hook, max: 180)
        // Вывод показывается перед CTA, а не остаётся исключительно в описании.
        result.conclusionText = cleanText(reply.conclusion, max: 140) ?? arc.conclusionText
        var suggestionIDs = Set<Int>()
        result.captionSuggestions = (reply.captionSuggestions ?? []).prefix(12).compactMap { suggestion in
            guard transcript.segments.indices.contains(suggestion.line),
                  suggestionIDs.insert(suggestion.line).inserted,
                  let text = cleanText(suggestion.text, max: 240) else { return nil }
            let line = transcript.segments[suggestion.line]
            guard result.segments.contains(where: { $0.start < line.end && $0.end > line.start }),
                  text != line.text else { return nil }
            return LongformCaptionSuggestion(start: line.start, end: line.end, original: line.text,
                replacement: text, reason: String(suggestion.reason.prefix(160)))
        }
        notes += LongformEditorialSupport.notes(for: result, transcript: transcript)
        result.editorialNotes = notes
        guard EssayDurationPolicy.rendered.contains(LongformTimeline(arc: result, coldOpenEnabled: coldOpenEnabled).duration)
        else { return nil }
        return result
    }

    private static func cleanText(_ text: String?, max: Int) -> String? {
        guard let text, !text.trimmed.isEmpty, text.count <= max,
              !text.contains("<"), !text.contains("\n") else { return nil }
        return text.trimmed
    }

    private struct Reply: Decodable {
        struct Edit: Decodable { let scene: Int; let option: String; let reason: String }
        let edits: [Edit]
        let notes: [String]
        let title: String?
        let hook: String?
        let conclusion: String?
        struct CaptionSuggestion: Decodable {
            let line: Int
            let text: String
            let reason: String
            private enum CodingKeys: String, CodingKey { case line, text, reason }
            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                if let number = try? values.decode(Int.self, forKey: .line) { line = number }
                else {
                    let raw = try values.decode(String.self, forKey: .line).trimmed
                    let digits = raw.hasPrefix("L") ? String(raw.dropFirst()) : raw
                    guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }),
                          let number = Int(digits) else {
                        throw DecodingError.dataCorruptedError(forKey: .line, in: values, debugDescription: "Invalid line ID")
                    }
                    line = number
                }
                text = try values.decode(String.self, forKey: .text)
                reason = try values.decode(String.self, forKey: .reason)
            }
        }
        let captionSuggestions: [CaptionSuggestion]?
    }

    /// Диалоговый ASR не видит немые действия. В развязке оставляем до 6 с
    /// реального кадра после последней реплики, не заходя в следующую реплику,
    /// другую выбранную сцену или за пределы 40 с / 8 минут.
    static func protectingActionTails(in arc: LongformNarrativeArc, transcript: Transcript,
                                      coldOpenEnabled: Bool) -> LongformNarrativeArc {
        var result = arc
        let filmEnd = transcript.segments.map(\.end).max() ?? 0
        for (ai, act) in arc.acts.enumerated() where act.type == .catharsis {
            for (si, range) in act.segments.enumerated() {
                let lastSpeech = transcript.segments.filter { $0.start < range.end && $0.end > range.start }
                    .map(\.end).max() ?? range.end
                guard abs(lastSpeech - range.end) < 0.3 else { continue }
                let nextSpeech = transcript.segments.filter { $0.start >= range.end }.map(\.start).min() ?? filmEnd
                let nextSelected = arc.segments.filter { $0.start >= range.end }.map(\.start).min() ?? filmEnd
                let end = min(range.end + 6, nextSpeech, nextSelected, filmEnd, range.start + 40)
                let candidate = TimeSegment(start: range.start, end: end)
                let anchor = LongformEditorialSupport.anchor(for: range, role: act.type, in: arc)
                guard end - range.end >= 1, LongformEditorialSupport.allowed(candidate, around: anchor) else { continue }
                result.acts[ai].segments[si] = candidate
                if !EssayDurationPolicy.rendered.contains(LongformTimeline(arc: result, coldOpenEnabled: coldOpenEnabled).duration) {
                    result.acts[ai].segments[si] = range
                }
            }
        }
        return result
    }
}
