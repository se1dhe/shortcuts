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

    struct Attempt: Sendable, Identifiable {
        let id: Int
        let message: String
        let accepted: Bool
    }

    struct Outcome: Sendable {
        let arc: LongformNarrativeArc
        let attempts: [Attempt]
        let changes: [SceneChange]
    }

    struct SceneChange: Sendable, Identifiable {
        let id: String
        let act: Int
        let scene: Int
        let oldRange: TimeSegment
        let newRange: TimeSegment
        let reason: String
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
    ВИПРАВ УСІ ПОТОЧНІ ЗАУВАЖЕННЯ, ДЕ Є БЕЗПЕЧНИЙ ВАРІАНТ МЕЖ: не залишай їх у notes після виправлення.
    Якщо вихід закінчується одразу за реплікою, обери aftermath, коли він не заходить у наступну сцену.
    Якщо вхід починається без контексту, обери context; якщо попередня репліка змінює зміст — поясни це в notes.
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
        let diagnostics = LongformEditorialSupport.notes(for: arc, transcript: transcript)
        for (actIndex, act) in arc.acts.enumerated() {
            for (sceneIndex, range) in act.segments.enumerated() {
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
                let prefix = "Акт \(actIndex + 1), сцена \(sceneIndex + 1):"
                let sceneNotes = diagnostics.filter { $0.hasPrefix(prefix) }
                blocks.append("""
                SCENE \(number) role=\(act.type.promptKey), мета=\(act.dramaticBeat.prefix(120))
                \(options)
                ДО: \(dialogue(max(0, range.start - 8), range.start, limit: 180))
                ВСЕРЕДИНІ: \(dialogue(range.start, range.end, limit: cap))
                ПІСЛЯ: \(dialogue(range.end, range.end + 8, limit: 180))
                ПОТОЧНІ ЗАУВАЖЕННЯ: \(sceneNotes.isEmpty ? "немає" : sceneNotes.joined(separator: " | "))
                """)
            }
        }
        return "Тема: \(arc.concept.word). Теза: \(arc.thesis ?? arc.concept.philosophicalPremise)\n"
            + "Назва: \(arc.publicationTitle ?? arc.concept.suggestedTitle)\n" + blocks.joined(separator: "\n\n")
    }

    func review(arc: LongformNarrativeArc, transcript: Transcript, coldOpenEnabled: Bool) async -> LongformNarrativeArc {
        let outcome = await reviewDetailed(arc: arc, transcript: transcript, coldOpenEnabled: coldOpenEnabled) { _ in }
        return outcome.arc
    }

    func reviewDetailed(
        arc: LongformNarrativeArc,
        transcript: Transcript,
        coldOpenEnabled: Bool,
        progress: @Sendable (String) -> Void
    ) async -> Outcome {
        var result = arc
        let initialNotes = LongformEditorialSupport.notes(for: arc, transcript: transcript)
        result.editorialNotes = initialNotes
        var attempts: [Attempt] = []
        guard let model, await model.isReady else {
            progress("Редакторская модель не загружена в память; монтаж не менялся.")
            result.editorialNotes = (result.editorialNotes ?? [])
                + ["Редакторская модель не загружена в память. Изменения не применялись."]
            return Outcome(arc: result, attempts: [Attempt(id: 0, message: "Модель не готова в памяти", accepted: false)], changes: [])
        }

        var working = arc
        working.editorialNotes = initialNotes
        var best = arc
        best.editorialNotes = initialNotes
        var bestNoteCount = initialNotes.count
        var repairContext: String?
        var didAccept = false
        let maxAttempts = 4

        for attemptNumber in 1...maxAttempts {
            progress("Попытка \(attemptNumber)/\(maxAttempts) · анализирую замечания, реплики рядом и допустимые границы сцен…")
            let basePrompt = Self.prompt(arc: working, transcript: transcript)
            let memory = correctionMemory.promptExamples(for: basePrompt,
                filmKey: correctionFilmKey, language: correctionLanguage)
            let retry = repairContext.map { "\n\nРЕЗУЛЬТАТ ПРЕДЫДУЩЕЙ ПРОВЕРКИ — ИСПРАВЬ ОТВЕТ, НЕ ПОВТОРЯЙ ОТКЛОНЁННЫЙ ВАРИАНТ:\n\($0)" } ?? ""
            let compactRetry = attemptNumber > 1
                ? "\n\nФОРМАТ ОТВЕТА ПРИ ПОВТОРЕ: верни только JSON с обязательными массивами edits и notes, без title, hook, conclusion и captionSuggestions. Каждый элемент edits должен содержать scene (целое число), option (точный ID из списка именно этой сцены), reason (непустая строка). Не добавляй никакого текста вне JSON."
                : ""
            let prompt = basePrompt + (attemptNumber == 1 ? memory : "") + retry + compactRetry
            DirectorRunLog.write("editorial review: attempt=\(attemptNumber) scenes=\(working.segments.count) promptChars=\(prompt.count)")
            progress("Попытка \(attemptNumber)/\(maxAttempts) · передаю модели список проблем и доступные варианты монтажа…")
            guard let raw = await model.complete(instructions: Self.instructions, prompt: prompt, maxTokens: 3072) else {
                attempts.append(Attempt(id: attemptNumber, message: "Модель не вернула ответ; повторяю запрос с текущими замечаниями.", accepted: false))
                repairContext = "Вызов не вернул текст. Верни полный JSON в требуемом формате."
                progress("Попытка \(attemptNumber)/\(maxAttempts) · ответ не получен; отправляю повторный запрос с теми же сценами.")
                continue
            }
            DirectorRunLog.dumpRaw(raw, stage: "editorial", attempt: attemptNumber)
            progress("Попытка \(attemptNumber)/\(maxAttempts) · ответ получен; проверяю формат, границы, стыки и хронометраж…")
            var reviewed = Self.apply(raw, to: working, transcript: transcript, coldOpenEnabled: coldOpenEnabled)
            if reviewed == nil {
                let issue = Self.validationFeedback(raw, arc: working, transcript: transcript, coldOpenEnabled: coldOpenEnabled)
                progress("Ответ не прошёл проверку: \(issue). Запрашиваю точечное решение по этой сцене…")
                reviewed = await Self.repairInvalidOption(raw, issue: issue, arc: working, transcript: transcript,
                    coldOpenEnabled: coldOpenEnabled, model: model, attempt: attemptNumber, progress: progress)
                if reviewed == nil {
                    attempts.append(Attempt(id: attemptNumber, message: issue, accepted: false))
                    repairContext = "ТВОЙ ПРЕДЫДУЩИЙ ОТВЕТ ОТКЛОНЁН: \(issue)\n\(Self.repairDirective(issue: issue, raw: raw, arc: working, transcript: transcript))\nВерни только корректный JSON с массивами edits и notes. У edits обязательны целые scene, точный option из списка этой сцены и непустой reason. Не используй вариант из отклонённого ответа."
                    progress("Ответ не прошёл проверку: \(issue). Повторю с короткой точечной инструкцией.")
                    continue
                }
                progress("Точечный вариант сцены прошёл проверку; пересчитываю все замечания и стыки…")
            }

            guard let reviewed else { continue }

            let notes = reviewed.editorialNotes ?? []
            let fingerprint = reviewed.segments.map { "\(Int($0.start * 100)):\(Int($0.end * 100))" }.joined(separator: ",")
            let currentFingerprint = working.segments.map { "\(Int($0.start * 100)):\(Int($0.end * 100))" }.joined(separator: ",")
            let changed = fingerprint != currentFingerprint
            let improved = notes.count <= bestNoteCount
            if improved {
                best = reviewed
                bestNoteCount = notes.count
            }
            attempts.append(Attempt(id: attemptNumber,
                message: changed ? "Вариант прошёл проверку; замечаний осталось: \(notes.count)." : "Вариант прошёл проверку, границы не изменились; замечаний осталось: \(notes.count).",
                accepted: true))
            let adjustedScenes = zip(working.segments, reviewed.segments).filter { $0.0 != $0.1 }.count
            working = reviewed
            didAccept = true
            progress("Попытка \(attemptNumber)/\(maxAttempts) · вариант прошёл все технические проверки; изменено сцен: \(adjustedScenes), осталось замечаний: \(notes.count).")

            if notes.isEmpty {
                result = reviewed
                progress("Все замечания устранены; изменения прошли проверку.")
                break
            }
            if attemptNumber < maxAttempts, !notes.isEmpty {
                result = best
                repairContext = "После проверки остаются замечания: \(notes.joined(separator: " | ")). Предыдущий набор границ: \(fingerprint). Сопоставь замечания с предыдущим выбором и найди другой допустимый вариант для проблемных сцен. Не повторяй вариант, который не устранил замечание. Если ни один вариант границ не решает проблему, объясни это конкретно в notes и продолжи искать решение для остальных сцен."
                progress("Проверенный вариант оставил \(notes.count) замечаний; анализирую альтернативы для проблемных сцен…")
            } else {
                result = best
                break
            }
        }
        if attempts.isEmpty {
            result.editorialNotes = initialNotes + ["Модель не сформировала решение после нескольких запросов."]
        } else if didAccept {
            result = best
        }
        if didAccept {
            result.editorialReviewModelID = await model.modelID
            DirectorRunLog.write("editorial review: accepted edits=\(result.sceneEdits?.count ?? 0) attempts=\(attempts.count)")
        }
        var changes: [SceneChange] = []
        for (actIndex, pair) in zip(arc.acts, result.acts).enumerated() {
            for (sceneIndex, ranges) in zip(pair.0.segments, pair.1.segments).enumerated() where ranges.0 != ranges.1 {
                let reason = result.sceneEdits?.first(where: { $0.revised == ranges.1 })?.reason ?? "Граница изменена после редакторской проверки"
                changes.append(SceneChange(id: "act-\(actIndex + 1)-scene-\(sceneIndex + 1)", act: actIndex + 1,
                    scene: sceneIndex + 1, oldRange: ranges.0, newRange: ranges.1, reason: reason))
            }
        }
        let remaining = result.editorialNotes?.count ?? 0
        if didAccept {
            progress(remaining == 0
                ? "Готово: замечания устранены; сохранено изменений границ: \(changes.count)."
                : "Сохранил лучший проверенный вариант. Осталось замечаний: \(remaining); завершено попыток: \(attempts.count).")
        } else {
            progress("Модель не получила проверенный вариант за \(attempts.count) попытки. Монтаж сохранён без изменений; причины указаны в журнале.")
        }
        return Outcome(arc: result, attempts: attempts, changes: changes)
    }

    private static func validationFeedback(_ raw: String, arc: LongformNarrativeArc,
                                           transcript: Transcript, coldOpenEnabled: Bool) -> String {
        guard let json = JSONVariantParser.extractJSONObject(from: raw),
              let data = json.data(using: .utf8),
              let reply = try? JSONDecoder().decode(Reply.self, from: data) else {
            return "Ответ не соответствует JSON-схеме. Нужен объект с массивами edits и notes; в каждом edit обязательны целые scene, option и непустой reason."
        }
        let placements = arc.acts.enumerated().flatMap { ai, act in act.segments.indices.map { (ai, $0) } }
        var seen = Set<Int>()
        for edit in reply.edits {
            guard edit.scene > 0, edit.scene <= placements.count else {
                return "Номер сцены \(edit.scene) отсутствует. Допустимые номера: 1–\(placements.count)."
            }
            guard seen.insert(edit.scene).inserted else { return "Сцена \(edit.scene) указана повторно. Укажи её один раз." }
            let (ai, si) = placements[edit.scene - 1]
            let range = arc.acts[ai].segments[si]
            let available = options(for: range, transcript: transcript).map(\.id).joined(separator: ", ")
            guard options(for: range, transcript: transcript).contains(where: { $0.id == edit.option }) else {
                return "Для сцены \(edit.scene) выбран вариант «\(edit.option)», которого нет в списке. Разрешены: \(available). Выбери один из них."
            }
        }
        if let applied = apply(raw, to: arc, transcript: transcript, coldOpenEnabled: coldOpenEnabled) {
            return "Границы прошли техническую проверку, но замечания остаются: \((applied.editorialNotes ?? []).joined(separator: " | ")). Предложи другие допустимые варианты, чтобы устранить их."
        }
        return "Выбранные диапазоны конфликтуют: не допускаются пересечения сцен и итоговая длительность эссе должна быть 4–8 минут. Пересчитай комбинацию вариантов; доступные варианты для каждой сцены перечислены в исходном запросе."
    }

    private static func repairDirective(issue: String, raw: String, arc: LongformNarrativeArc,
                                        transcript: Transcript) -> String {
        guard let json = JSONVariantParser.extractJSONObject(from: raw),
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let edits = object["edits"] as? [[String: Any]],
              let edit = edits.first(where: { candidate in
                  guard let scene = candidate["scene"] as? Int, let id = candidate["option"] as? String,
                        let (ai, si) = placement(scene, in: arc) else { return false }
                  return !options(for: arc.acts[ai].segments[si], transcript: transcript).contains { $0.id == id }
              }),
              let scene = edit["scene"] as? Int,
              let (ai, si) = placement(scene, in: arc) else {
            return "Верни строго: {\"edits\":[],\"notes\":[\"конкретное решение\"]}. Не добавляй title, hook и captionSuggestions."
        }
        let range = arc.acts[ai].segments[si]
        let options = Self.options(for: range, transcript: transcript)
            .map { "\($0.id) = \(String(format: "%.2f", $0.range.start))–\(String(format: "%.2f", $0.range.end))" }
            .joined(separator: "; ")
        let nearby = transcript.segments.filter { $0.end > range.start - 8 && $0.start < range.end + 8 }
            .map { "\(String(format: "%.2f", $0.start))–\(String(format: "%.2f", $0.end)): \($0.text)" }
            .joined(separator: "\n")
        return "Проблема: \(issue)\nИСПРАВЬ ТОЛЬКО SCENE \(scene). Допустимые варианты именно этой сцены: \(options). Контекст реплик:\n\(nearby)\nОтклонённый ответ: \(String(json.prefix(1200)))"
    }

    private static func repairInvalidOption(_ raw: String, issue: String, arc: LongformNarrativeArc,
                                            transcript: Transcript, coldOpenEnabled: Bool,
                                            model: any LongformActTitleModeling, attempt: Int,
                                            progress: @Sendable (String) -> Void) async -> LongformNarrativeArc? {
        guard issue.contains("выбран вариант") || issue.contains("списке"),
              let json = JSONVariantParser.extractJSONObject(from: raw),
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let edits = object["edits"] as? [[String: Any]],
              let invalidEdit = edits.first(where: { edit in
                  guard let scene = edit["scene"] as? Int, let id = edit["option"] as? String,
                        let (ai, si) = placement(scene, in: arc) else { return false }
                  return !options(for: arc.acts[ai].segments[si], transcript: transcript).contains { $0.id == id }
              }),
              let scene = invalidEdit["scene"] as? Int,
              let (ai, si) = placement(scene, in: arc) else { return nil }

        let range = arc.acts[ai].segments[si]
        let allAvailable = options(for: range, transcript: transcript)
        // A focused repair exists because the current scene has an active note.
        // Ask the model for a real alternative; keeping the same broken boundary
        // would only turn a rejected edit into a silent no-op.
        let alternatives = allAvailable.filter { $0.id != "keep" }
        let available = alternatives.isEmpty ? allAvailable : alternatives
        let rejectedOption = invalidEdit["option"] as? String ?? "неизвестный ID"
        guard available.count > 1 else { return nil }
        let optionList = available.map {
            "{\"option\":\"\($0.id)\",\"start\":\(String(format: "%.2f", $0.range.start)),\"end\":\(String(format: "%.2f", $0.range.end))}"
        }.joined(separator: ", ")
        let dialogue = transcript.segments.filter { $0.end > range.start - 8 && $0.start < range.end + 8 }
            .map { "\(String(format: "%.2f", $0.start))–\(String(format: "%.2f", $0.end)): \($0.text)" }
            .joined(separator: "\n")
        let prompt = """
        Виправ лише одне редакторське рішення для кіноесе.
        Для сцени \(scene) попередня модель вибрала неіснуючий варіант «\(rejectedOption)». Не повторюй його. Сама оціни контекст реплік і вибери найкращий варіант зі списку. Не використовуй жодного іншого ID і не обирай межу навмання.
        Зауваження: \(issue)
        Тема: \(arc.concept.word). Функція акта: \(arc.acts[ai].dramaticBeat)
        ДОСТУПНІ ВАРІАНТИ: [\(optionList)]
        РЕПЛІКИ ДОВКОЛА СЦЕНИ:
        \(dialogue)
        Поверни тільки JSON виду {"scene":\(scene),"option":"точний ID зі списку","reason":"короткое обоснование"}.
        """
        progress("Попытка \(attempt) · отдельный запрос для сцены \(scene): модель сравнивает \(available.count) допустимых вариантов…")
        let focusedInstructions = "Ты — монтажный редактор киноэссе. Оцени реплики и смысл замечания. Выбери лучший вариант только из переданного списка. Верни строго один JSON-объект {\"scene\":integer,\"option\":string,\"reason\":string}; никакого текста до или после JSON. Не создавай ID, таймкоды или варианты от себя."
        guard let focusedRaw = await model.complete(instructions: focusedInstructions, prompt: prompt, maxTokens: 512) else { return nil }
        DirectorRunLog.dumpRaw(focusedRaw, stage: "editorial-focused-repair", attempt: attempt)
        guard let focusedJSON = JSONVariantParser.extractJSONObject(from: focusedRaw),
              let focusedData = focusedJSON.data(using: .utf8),
              let choice = try? JSONSerialization.jsonObject(with: focusedData) as? [String: Any],
              (choice["scene"] as? Int) == scene,
              let id = choice["option"] as? String,
              let reason = choice["reason"] as? String, !reason.trimmed.isEmpty,
              let selected = available.first(where: { $0.id == id }) else { return nil }
        var revised = arc
        revised.acts[ai].segments[si] = selected.range
        let sorted = revised.segments.sorted { $0.start < $1.start }
        guard zip(sorted, sorted.dropFirst()).allSatisfy({ $0.end <= $1.start }),
              EssayDurationPolicy.rendered.contains(LongformTimeline(arc: revised, coldOpenEnabled: coldOpenEnabled).duration)
        else { return nil }
        revised = protectingActionTails(in: revised, transcript: transcript, coldOpenEnabled: coldOpenEnabled)
        revised.sceneEdits = LongformEditorialSupport.recordingEdits(from: arc, acts: revised.acts,
            reason: String(reason.prefix(200)))
        revised.editorialNotes = LongformEditorialSupport.notes(for: revised, transcript: transcript)
        return revised
    }

    private static func placement(_ number: Int, in arc: LongformNarrativeArc) -> (Int, Int)? {
        let placements = arc.acts.enumerated().flatMap { ai, act in act.segments.indices.map { (ai, $0) } }
        guard number > 0, number <= placements.count else { return nil }
        return placements[number - 1]
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
