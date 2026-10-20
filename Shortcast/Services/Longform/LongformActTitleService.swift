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
    /// (`LongformSubtitleRenderer.resolvedActTitlePointSize` держит две строки).
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
        progress?("Называю акты по их собственным диалогам…")

        let dialogue = arc.acts.map { LongformActTitleService.actDialogue(act: $0, transcript: transcript) }
        let materials = arc.acts.enumerated().map { index, act in
            LongformActTitleService.actMaterialBlock(
                actIndex: index,
                act: act,
                lines: dialogue[index],
                cap: Self.actMaterialCapChars
            )
        }
        let templates = LongformNarrativeDirector().adaptiveActDescriptors(for: arc.concept)

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
                    concept: arc.concept
                )
                if proposals.isEmpty {
                    notes.append("модель не вернула разбор за \(Self.maxAttempts) попыток")
                }
            } else {
                notes.append("Director не прогрет: loading ради титулов запрещён политикой RAM")
            }
        } else {
            notes.append("шлюз к модели не подключён")
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
                notes.append("акт \(index + 1): quotedLine не из диалога этого акта либо title > \(Self.maxTitleGraphemes) знаков")
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
        var summary = "Названия актов: модель «\(modelID ?? "нет")» llm=\(llmCount) репликой=\(lineCount) "
            + "шаблоном=\(templateCount) из \(titledActs.count); материал \(rawChars)→\(sentChars) знаков "
            + "(прорежено актов: \(thinned), cap \(Self.actMaterialCapChars)/акт)"
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
        var lines: [String] = []
        for phrase in transcript.segments {
            guard act.segments.contains(where: { phrase.end > $0.start && phrase.start < $0.end })
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
        let romanNumerals = ["I", "II", "III", "IV"]
        let roman = actIndex < romanNumerals.count ? romanNumerals[actIndex] : "\(actIndex + 1)"
        let header = "АКТ \(roman) (\(act.type.rawValue)):"
        guard !lines.isEmpty else {
            return ("\(header)\n(в этом акте нет реплик)", 1)
        }
        let (thinned, stride) = MomentFinderService.downsampleChronologically(
            lines.joined(separator: "\n"),
            to: max(1, cap)
        )
        return ("\(header)\n\(thinned)", stride)
    }

    // MARK: - Промпт

    static func actTitlesSystemPrompt(movieTitle: String, concept: ThematicConcept) -> String {
        """
        Ты — драматург Shortcast Cinema. Эссе «\(concept.word)» по фильму «\(movieTitle)» уже смонтировано.
        Ниже — МАТЕРИАЛЫ АКТОВ: реальные реплики тех сцен, которые вошли в каждый акт, в хронологическом порядке.
        Слоган темы: \(concept.tagline)
        Философский тезис: \(concept.philosophicalPremise)

        Дай каждому акту название, ВЫВЕДЕННОЕ ИЗ РЕПЛИК ИМЕННО ЭТОГО АКТА. Название акта видит зритель,
        поэтому оно обязано быть про этот монтаж, а не про жанр:
        - title: 2-5 слов, не длиннее \(maxTitleGraphemes) знаков, без слова «Акт», без кавычек и без ««»»;
        - dramaticBeat: до \(maxBeatChars) знаков — что РЕАЛЬНО происходит в отобранных сценах этого акта;
        - quotedLine: ОДНА реплика из материала этого акта, скопированная ДОСЛОВНО, символ в символ.
          Это доказательство: если такой строки нет в материале именно этого акта, название отвергается целиком.
        - ЗАПРЕЩЕНО выдумывать реплики, имена и события, которых нет в материалах актов.
        - ЗАПРЕЩЕНО брать реплику из материала другого акта.
        - Типы актов строго в заданном порядке: hook, downfall, struggle, catharsis.

        ФОРМАТ — СТРОГО валидный JSON без markdown, без пояснений и без текста до или после:
        {"acts":[{"type":"hook","title":"...","dramaticBeat":"...","quotedLine":"..."},{"type":"downfall","title":"...","dramaticBeat":"...","quotedLine":"..."},{"type":"struggle","title":"...","dramaticBeat":"...","quotedLine":"..."},{"type":"catharsis","title":"...","dramaticBeat":"...","quotedLine":"..."}]}
        """
    }

    static func actTitlesUserPrompt(materials: [String], movieTitle: String, concept: ThematicConcept) -> String {
        var parts: [String] = ["Фильм: «\(movieTitle)». Тема эссе: «\(concept.word)».", "МАТЕРИАЛЫ АКТОВ:"]
        parts.append(contentsOf: materials)
        parts.append("""
        Назови все четыре акта по их собственным репликам. Верни СТРОГО валидный JSON-объект \
        с полем "acts" из четырёх элементов в каноническом порядке типов.
        """)
        return parts.joined(separator: "\n\n")
    }

    /// Пинание при невалидном ответе — ровно форма `analyzeThematicCore`
    static func invalidOutputNudge(_ prompt: String) -> String {
        prompt + "\n\nВНИМАНИЕ: предыдущий ответ был невалидным. Ответь ТОЛЬКО валидным JSON-объектом "
            + "без markdown, без пояснений и без текста до или после объекта."
    }

    // MARK: - Вызов модели

    private static func requestProposals(
        from model: any LongformActTitleModeling,
        materials: [String],
        movieTitle: String,
        concept: ThematicConcept
    ) async -> [LongformActType: ActTitleProposal] {
        let instructions = actTitlesSystemPrompt(movieTitle: movieTitle, concept: concept)
        let basePrompt = actTitlesUserPrompt(materials: materials, movieTitle: movieTitle, concept: concept)

        for attempt in 1...maxAttempts {
            let prompt = attempt == 1 ? basePrompt : invalidOutputNudge(basePrompt)
            guard let raw = await model.complete(
                instructions: instructions,
                prompt: prompt,
                maxTokens: titlingMaxTokens
            ) else { continue }
            if let parsed = parseActTitleProposals(from: raw) {
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
    static func parseActTitleProposals(from jsonText: String) -> [ActTitleProposal]? {
        guard let rows = actsArray(from: jsonText), rows.count == 4 else { return nil }
        let canonicalOrder: [LongformActType] = [.hook, .downfall, .struggle, .catharsis]
        var proposals: [ActTitleProposal] = []
        for (row, expectedType) in zip(rows, canonicalOrder) {
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
        case "hook", "хук", "хук и тезис": return .hook
        case "downfall", "падение", "падение и испытание": return .downfall
        case "struggle", "борьба", "борьба и упорство": return .struggle
        case "catharsis", "катарсис", "катарсис и прорыв": return .catharsis
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
              proposal.title.count <= maxTitleGraphemes
        else { return nil }
        let needle = normalizedGrounding(proposal.quotedLine)
        guard !needle.isEmpty else { return nil }
        return actDialogue.first { normalizedGrounding($0).contains(needle) }
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
        var bestText: String?
        var bestHits = -1
        var bestCompletion = -Double.greatestFiniteMagnitude
        for line in lines {
            let lower = line.lowercased()
            var hits = 0
            for keyword in keywords where lower.contains(keyword) { hits += 1 }
            let completion = ThoughtCompletionScorer
                .evaluateConcludingPhrase(line, isFinaleAct: act.type == .catharsis)
                .scoreModifier
            if hits > bestHits || (hits == bestHits && completion > bestCompletion) {
                bestText = line
                bestHits = hits
                bestCompletion = completion
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

    /// Обрезка так, чтобы влезло в карточку акта: \(maxTitleGraphemes) знаков вместе с «…»
    static func truncateToTitleCards(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxTitleGraphemes else { return trimmed }
        let head = String(trimmed.prefix(maxTitleGraphemes - 1))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return head + "…"
    }
}
