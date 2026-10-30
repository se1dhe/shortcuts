import Foundation
import OSLog

/// Название акта вместе с репликой-основанием, как их вернула модель
struct ActTitleProposal: Equatable, Sendable {
    var type: LongformActType
    var title: String
    var dramaticBeat: String
    /// Реплика, которую модель обязалась процитировать ДОСЛОВНО
    var quotedLine: String
}

/// Второй LLM-проход: названия актов из РЕАЛЬНОГО диалога, вошедшего в каждый акт.
///
/// Почему это отдельный проход, а не часть `buildArc`: режиссёр-арка — чистая эвристика
/// без единого обращения к модели, а название акта зритель судит как «работу ИИ».
/// Значит либо модель называет и мы это честно помечаем, либо детерминированный
/// запасной путь из реальной строки Whisper — и тоже помеченный. Молчаливый шаблон
/// вместо ИИ здесь запрещён: именно он был единственное, что видел зритель раньше.
///
/// Один вызов модели на все четыре акта: prefill (материал актов) — дорогая часть
/// прогона, повторять его четыре раза значит вчетверо увеличить время и риск
/// ротации KV-кэша. Модель переиспользуется УЖЕ прогретая: холодная загрузка
/// ради четырёх заголовков на 18-гигабайтной машине запрещена политикой RAM.
final class LongformActTitleService: LongformActTitling, Sendable {

    private static let logger = Logger(subsystem: "app.shortcast", category: "LongformActTitleService")

    // MARK: - Политика (языковая и типографская, не фильмная)

    /// Кап материала на акт: четыре блока по 2500 знаков вместе с инструкциями и
    /// JSON-скелетом влезает в KV-окно прогретого Director'а без потери головных актов.
    static let actMaterialCapChars: Int = 2_500
    /// Порог доверия и типографики: название длиннее не влезает в карточку акта
    /// в результате и таймкодах (на видео название не выводится).
    static let maxTitleGraphemes: Int = 44
    /// Потолок dramaticBeat
    static let maxBeatChars: Int = 160
    /// JSON из четырёх объектов с четырьмя полями: 1024 токена с запасом
    static let titlingMaxTokens: Int = 1_024
    /// Форма та же, что у `analyzeThematicCore`: модель иногда отвечает прозой — пинать и повторять
    static let maxAttempts: Int = 3

    /// Шлюз к прогретому Director'у. nil — модели нет принципиально (тесты, оффлайн-сборка):
    /// тогда весь проход идёт детерминированным запасным путём и ЧЕСТНО это пишет.
    private let model: (any LongformActTitleModeling)?

    init(model: (any LongformActTitleModeling)? = nil) {
        self.model = model
    }

    // MARK: - Точка входа

    func applyTitles(
        to arc: LongformNarrativeArc,
        transcript: Transcript,
        movieTitle: String,
        progress: (@Sendable (String) -> Void)?
    ) async -> TitlingOutcome {
        progress?("Називаю акти за їхніми власними діалогами…")

        let dialogue = arc.acts.map { LongformActTitleService.actDialogue(act: $0, transcript: transcript) }
        let materials = arc.acts.enumerated().map { index, act in
            LongformActTitleService.actMaterialBlock(
                actIndex: index,
                act: act,
                lines: dialogue[index],
                cap: Self.actMaterialCapChars
            )
        }
        let templates = {
            let director = LongformNarrativeDirector()
            return arc.acts.map { director.adaptiveActDescriptor(for: $0.type, concept: arc.concept) }
        }()
        let expectedTypes = arc.acts.map(\.type)

        var notes: [String] = []
        var proposals: [LongformActType: ActTitleProposal] = [:]
        var modelID: String?

        if let model {
            if await model.isReady {
                modelID = await model.modelID
                proposals = await Self.requestProposals(
                    from: model,
                    materials: materials.map { $0.block },
                    movieTitle: movieTitle,
                    concept: arc.concept,
                    expectedTypes: expectedTypes
                )
                if proposals.isEmpty {
                    notes.append("модель не повернула розбір за \(Self.maxAttempts) спроби")
                }
            } else {
                notes.append("Director не прогрітий: loading заради титулів заборонений політикою RAM")
            }
        } else {
            notes.append("шлюз до моделі не підключений")
        }

        var titledActs: [LongformAct] = []
        var llmCount = 0
        var lineCount = 0
        var templateCount = 0

        for (index, act) in arc.acts.enumerated() {
            let actLines = dialogue[index]
            let template = index < templates.count ? templates[index] : (title: act.title, beat: act.dramaticBeat)

            if let proposal = proposals[act.type],
               let evidence = Self.groundingEvidence(proposal: proposal, actDialogue: actLines) {
                var titled = act
                titled.title = proposal.title
                if !proposal.dramaticBeat.isEmpty {
                    titled.dramaticBeat = String(proposal.dramaticBeat.prefix(Self.maxBeatChars))
                } else {
                    notes.append("акт \(index + 1): модель не дала dramaticBeat — лишається значення з плану")
                }
                titled.titleProvenance = ActTitleProvenance(
                    source: .llm,
                    evidence: evidence,
                    modelID: modelID
                )
                titledActs.append(titled)
                llmCount += 1
                continue
            }

            if proposals[act.type] != nil {
                notes.append("акт \(index + 1): quotedLine не з діалогу цього акту або title > \(Self.maxTitleGraphemes) знаків")
            }

            let fallback = Self.deterministicFallback(act: act, lines: actLines, template: template)
            var titled = act
            titled.title = fallback.title
            titled.titleProvenance = fallback.provenance
            titledActs.append(titled)
            switch fallback.provenance.source {
            case .transcriptLine: lineCount += 1
            case .template: templateCount += 1
            default: break
            }
        }

        var updated = arc
        updated.acts = titledActs

        let rawChars = dialogue.reduce(0) { total, lines in total + lines.reduce(0) { $0 + $1.count } }
        let sentChars = materials.reduce(0) { $0 + $1.block.count }
        let thinned = materials.filter { $0.stride > 1 }.count
        var summary = "Назви актів: модель «\(modelID ?? "немає")» llm=\(llmCount) реплікою=\(lineCount) "
            + "шаблоном=\(templateCount) з \(titledActs.count); матеріал \(rawChars)→\(sentChars) знаків "
            + "(проріджено актів: \(thinned), cap \(Self.actMaterialCapChars)/акт)"
        if !notes.isEmpty {
            summary += "; " + notes.joined(separator: "; ")
        }
        Self.logger.notice("\(summary, privacy: .public)")
        progress?(summary)

        return TitlingOutcome(arc: updated, summary: summary)
    }

    // MARK: - Материал акта (только то, что реально вошло в монтаж)

    /// Реплики Whisper, попавшие в сегменты акта, в хронологическом порядке транскрипта.
    /// Тот же интервальный тест, что у пайплайна для timed-фраз: пересечение, а не
    /// вложенность — реплика на стыке двух сегментов не имеет права выпасть из обоих.
    static func actDialogue(act: LongformAct, transcript: Transcript) -> [String] {
        guard !act.segments.isEmpty else { return [] }
        let gate = TranscriptQualityGate(segments: transcript.segments)
        var lines: [String] = []
        for phrase in transcript.segments {
            guard act.segments.contains(where: { phrase.end > $0.start && phrase.start < $0.end }),
                  gate.isUsable(phrase)
            else { continue }
            let text = phrase.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { lines.append(text) }
        }
        return lines
    }

    /// Блок материала акта для промпта: заголовок с римской цифрой + прореженные реплики.
    /// Прореживание — ХРОНОЛОГИЧЕСКИЙ stride (`MomentFinderService.downsampleChronologically`),
    /// никогда не `prefix(_:)`: отсечение хвоста оставило бы модель только с началом фильма,
    /// и акт IV никогда не получил бы название по своему материалу (причина задокументирована
    /// в `analyzeThematicCore`).
    static func actMaterialBlock(
        actIndex: Int,
        act: LongformAct,
        lines: [String],
        cap: Int
    ) -> (block: String, stride: Int) {
        let romanNumerals = ["I", "II", "III", "IV", "V", "VI"]
        let roman = actIndex < romanNumerals.count ? romanNumerals[actIndex] : "\(actIndex + 1)"
        let header = "АКТ \(roman) (\(act.type.displayName)):"
        guard !lines.isEmpty else {
            return ("\(header)\n(у цьому акті немає реплік)", 1)
        }
        let (thinned, stride) = MomentFinderService.downsampleChronologically(
            lines.joined(separator: "\n"),
            to: max(1, cap)
        )
        return ("\(header)\n\(thinned)", stride)
    }

    // MARK: - Промпт

    static func actTitlesSystemPrompt(
        movieTitle: String,
        concept: ThematicConcept,
        expectedTypes: [LongformActType] = [.hook, .downfall, .struggle, .catharsis]
    ) -> String {
        let typeList = expectedTypes.map(\.promptKey).joined(separator: ", ")
        let skeleton = expectedTypes
            .map { #"{"type":"\#($0.promptKey)","title":"...","dramaticBeat":"...","quotedLine":"..."}"# }
            .joined(separator: ",")
        return """
        Ти — драматург Shortcast Cinema. Есе «\(concept.word)» за фільмом «\(movieTitle)» вже змонтовано.
        Нижче — МАТЕРІАЛИ АКТІВ: реальні репліки тих сцен, які увійшли до кожного акту, у хронологічному порядку.
        Слоган теми: \(concept.tagline)
        Філософський тез: \(concept.philosophicalPremise)

        Дай кожному акту назву, ВИВЕДЕНУ З РЕПЛІК САМЕ ЦЬОГО АКТУ. Назву акту бачить глядач,
        тому вона зобов'язана бути про цей монтаж, а не про жанр:
        - title: 2-5 слів, не довше \(maxTitleGraphemes) знаків, без слова «Акт», без лапок і без ««»»;
        - dramaticBeat: до \(maxBeatChars) знаків — що РЕАЛЬНО відбувається у відібраних сценах цього акту;
        - quotedLine: ОДНА репліка з матеріалу цього акту, скопійована ДОСЛІВНО, символ у символ.
          Це доказ: якщо такого рядка немає в матеріалі саме цього акту, назву відхилено повністю.
        - ЗАБОРОНЕНО вигадувати репліки, імена та події, яких немає в матеріалах актів.
        - ЗАБОРОНЕНО брати репліку з матеріалу іншого акту.
        - Типи актів строго у заданому порядку: \(typeList).

        ФОРМАТ — СУВОРО валідний JSON без markdown, без пояснень і без тексту до або після:
        {"acts":[\(skeleton)]}
        """
    }

    static func actTitlesUserPrompt(
        materials: [String],
        movieTitle: String,
        concept: ThematicConcept,
        expectedTypes: [LongformActType] = [.hook, .downfall, .struggle, .catharsis]
    ) -> String {
        var parts: [String] = ["Фільм: «\(movieTitle)». Тема есе: «\(concept.word)».", "МАТЕРІАЛИ АКТІВ:"]
        parts.append(contentsOf: materials)
        parts.append("""
        Назви всі \(expectedTypes.count) актів за їхніми власними репліками. Поверни СУВОРО валідний JSON-об'єкт \
        з полем "acts" з \(expectedTypes.count) елементів у канонічному порядку типів: \
        \(expectedTypes.map(\.promptKey).joined(separator: ", ")).
        """)
        return parts.joined(separator: "\n\n")
    }

    /// Пинание при невалидном ответе — ровно форма `analyzeThematicCore`
    static func invalidOutputNudge(_ prompt: String) -> String {
        prompt + "\n\nУВАГА: попередня відповідь була невалідною. Відповідь ТІЛЬКИ валідним JSON-об'єктом "
            + "без markdown, без пояснень і без тексту до або після об'єкта."
    }

    // MARK: - Вызов модели

    private static func requestProposals(
        from model: any LongformActTitleModeling,
        materials: [String],
        movieTitle: String,
        concept: ThematicConcept,
        expectedTypes: [LongformActType]
    ) async -> [LongformActType: ActTitleProposal] {
        let instructions = actTitlesSystemPrompt(
            movieTitle: movieTitle, concept: concept, expectedTypes: expectedTypes)
        let basePrompt = actTitlesUserPrompt(
            materials: materials, movieTitle: movieTitle, concept: concept, expectedTypes: expectedTypes)

        for attempt in 1...maxAttempts {
            let prompt = attempt == 1 ? basePrompt : invalidOutputNudge(basePrompt)
            guard let raw = await model.complete(
                instructions: instructions,
                prompt: prompt,
                maxTokens: titlingMaxTokens
            ) else { continue }
            if let parsed = parseActTitleProposals(from: raw, expectedTypes: expectedTypes) {
                var byType: [LongformActType: ActTitleProposal] = [:]
                for proposal in parsed { byType[proposal.type] = proposal }
                return byType
            }
        }
        return [:]
    }

    // MARK: - Парсер

    /// Принимает и `{"acts":[...]}`, и голый массив `[...]`. Требует ровно 4 акта
    /// в каноническом порядке типов и непустые title/quotedLine — иначе nil
    /// («модель не справилась»), а не частичный ответ, который пришлось бы
    /// молча латать шаблоном. Толерантность — через `JSONVariantParser`, как в
    /// `LongformThematicService.parseThematicAnalysis`.
    static func parseActTitleProposals(
        from jsonText: String,
        expectedTypes: [LongformActType] = [.hook, .downfall, .struggle, .catharsis]
    ) -> [ActTitleProposal]? {
        guard let rows = actsArray(from: jsonText), rows.count == expectedTypes.count else { return nil }
        var proposals: [ActTitleProposal] = []
        for (row, expectedType) in zip(rows, expectedTypes) {
            let rawType = (row["type"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() ?? ""
            guard actType(forKey: rawType) == expectedType,
                  let title = nonEmptyString(row["title"]),
                  let quotedLine = nonEmptyString(row["quotedLine"])
            else { return nil }
            proposals.append(ActTitleProposal(
                type: expectedType,
                title: title,
                dramaticBeat: nonEmptyString(row["dramaticBeat"]) ?? "",
                quotedLine: quotedLine
            ))
        }
        return proposals
    }

    private static func actsArray(from jsonText: String) -> [[String: Any]]? {
        if let object = JSONVariantParser.extractJSONObject(from: jsonText),
           let root = JSONVariantParser.deserializeTolerant(object) as? [String: Any],
           let acts = root["acts"] as? [[String: Any]],
           !acts.isEmpty {
            return acts
        }
        // Модель иногда отвечает массивом вместо объекта
        guard let start = jsonText.firstIndex(of: "[") else { return nil }
        return JSONVariantParser.deserializeTolerant(String(jsonText[start...])) as? [[String: Any]]
    }

    private static func actType(forKey key: String) -> LongformActType? {
        switch key {
        case "hook", "хук", "хук і тезис", "гак", "гак і теза": return .hook
        case "downfall", "падение", "падение и испытание", "падіння", "падіння і випробування": return .downfall
        case "struggle", "борьба", "борьба и упорство", "боротьба", "боротьба й наполегливість": return .struggle
        case "catharsis", "катарсис", "катарсис и прорыв", "катарсис і прорив": return .catharsis
        case "form", "форма", "аналіз форми", "анализ формы": return .form
        case "psychology", "психологія", "психология", "психологія героя": return .psychology
        case "philosophy", "філософія", "философия", "філософський підтекст": return .philosophy
        default: return nil
        }
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Гейты доверия (независимо для каждого акта)

    /// nil — акт уходит на запасной путь. Основанием считается ДОСЛОВНАЯ строка
    /// транскрипта: если модель прислала её с другим регистром или переносом,
    /// в provenance кладём именно строку из Whisper, а не её пересказ.
    private static func groundingEvidence(
        proposal: ActTitleProposal,
        actDialogue: [String]
    ) -> String? {
        guard !proposal.title.isEmpty,
              proposal.title.count <= maxTitleGraphemes,
              isTitleInMaterialLanguage(proposal.title, quotedLine: proposal.quotedLine)
        else { return nil }
        let needle = normalizedGrounding(proposal.quotedLine)
        guard !needle.isEmpty else { return nil }
        return actDialogue.first { normalizedGrounding($0).contains(needle) }
    }

    /// Название акта видит украинский зритель: английское слово поверх украинской
    /// реплики или русская орфография (ы/э/ъ/ё) — это чужой язык, а не название.
    static func isTitleInMaterialLanguage(_ title: String, quotedLine: String) -> Bool {
        let hasLetter = title.contains { $0.isLetter }
        guard hasLetter else { return false }
        if title.contains(where: { $0.isNumber }) && title.contains(":") { return false }
        let lower = title.lowercased()
        if genericTitleWords.contains(lower.trimmingCharacters(in: .punctuationCharacters)) { return false }

        let quoteIsCyrillic = quotedLine.contains { character in
            character.unicodeScalars.contains { TextUtilities.isCyrillic($0) }
        }
        let titleHasCyrillic = title.contains { character in
            character.unicodeScalars.contains { TextUtilities.isCyrillic($0) }
        }
        if quoteIsCyrillic, !titleHasCyrillic { return false }

        if isUkrainianFlavored(quotedLine), lower.contains(where: { russianOnlyLetters.contains($0) }) {
            return false
        }
        return true
    }

    /// Название — это авторская формулировка, а не цитата: доказывает его
    /// `quotedLine`, а не совпадение слов с названием.

    private static let russianOnlyLetters: Set<Character> = ["ы", "э", "ъ", "ё"]

    private static let genericTitleWords: Set<String> = [
        "акт", "сцена", "частина", "фрагмент", "уривок", "act", "scene", "part", "clip",
    ]

    /// Украинская орфография без русских маркеров — только тогда русские буквы в
    /// названии означают чужой язык; для русского диалога такое название законно.
    private static func isUkrainianFlavored(_ text: String) -> Bool {
        let lower = text.lowercased()
        let hasUkrainian = lower.contains { "іїєґ".contains($0) }
        let hasRussian = lower.contains(where: { russianOnlyLetters.contains($0) })
        return hasUkrainian && !hasRussian
    }

    /// Сравнение: регистр и последовательности пробелов — не изменение реплики;
    /// обрамляющие кавычки и многоточие тоже. Слова при этом обязаны совпасть все.
    private static func normalizedGrounding(_ text: String) -> String {
        let ignorable: Set<Character> = ["«", "»", "\"", "“", "”", "'", "‘", "’", "…"]
        var out = ""
        var previousWasSpace = true
        for character in text.lowercased() {
            if character.isWhitespace || ignorable.contains(character) {
                if !previousWasSpace {
                    out.append(" ")
                    previousWasSpace = true
                }
            } else {
                out.append(character)
                previousWasSpace = false
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Детерминированный запасной путь

    /// Самая сильная РЕАЛЬНАЯ строка Whisper внутри сегментов акта. Ничего не сочиняется:
    /// название — это и есть реплика, обрезанная по типографскому порогу карточки акта.
    private static func deterministicFallback(
        act: LongformAct,
        lines: [String],
        template: (title: String, beat: String)
    ) -> (title: String, provenance: ActTitleProvenance) {
        guard !lines.isEmpty else {
            // Синтетическая арка: диалогов не существует, врать про «реплику акта» нельзя
            return (template.title, ActTitleProvenance(source: .template, evidence: nil, modelID: nil))
        }
        let keywords = LongformNarrativeDirector().actDramaticKeywords(for: act.type)
        let isFinale = act.type == .catharsis
        var bestText: String?
        var bestScore = -Double.greatestFiniteMagnitude
        for line in lines {
            let score = fallbackLineScore(line, keywords: keywords, isFinaleAct: isFinale)
            if score > bestScore {
                bestText = line
                bestScore = score
            }
        }
        guard let winner = bestText else {
            return (template.title, ActTitleProvenance(source: .template, evidence: nil, modelID: nil))
        }
        return (
            truncateToTitleCards(winner),
            ActTitleProvenance(source: .transcriptLine, evidence: winner, modelID: nil)
        )
    }

    /// Реплика как заголовок: законченная мысль, на языке эссе и в размер карточки.
    /// Ключи акта — только бонус: русская техническая строка с ключом не имеет
    /// права обойти живую украинскую реплику без ключа.
    static func fallbackLineScore(
        _ line: String,
        keywords: [String],
        isFinaleAct: Bool
    ) -> Double {
        var score = ThoughtCompletionScorer
            .evaluateConcludingPhrase(line, isFinaleAct: isFinaleAct)
            .scoreModifier
        let lower = line.lowercased()
        for keyword in keywords where lower.contains(keyword) { score += 60 }

        let wordCount = lower.split(whereSeparator: { !$0.isLetter }).count
        if wordCount < 3 { score -= 80 }
        if wordCount > 14 { score -= 60 }
        if line.count <= maxTitleGraphemes { score += 80 }

        let hasUkrainian = lower.contains { "іїєґ".contains($0) }
        let hasRussian = lower.contains(where: { russianOnlyLetters.contains($0) })
        if hasUkrainian && !hasRussian { score += 150 }
        if hasRussian { score -= 250 }
        return score
    }

    /// Обрезка так, чтобы влезло в карточку акта: \(maxTitleGraphemes) знаков вместе с «…»
    /// Режется по границе слова: «исчеза…» — это обрубок, а не название.
    static func truncateToTitleCards(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxTitleGraphemes else { return trimmed }
        let head = String(trimmed.prefix(maxTitleGraphemes - 1))
        guard let lastSpace = head.lastIndex(where: { $0.isWhitespace }) else {
            // Одно длинное слово: другой границы, кроме буквенной, не существует
            return head + "…"
        }
        let cut = String(head[..<lastSpace])
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(
                CharacterSet(charactersIn: ",;:—–-")))
        guard !cut.isEmpty else { return head + "…" }
        return cut + "…"
    }
}
