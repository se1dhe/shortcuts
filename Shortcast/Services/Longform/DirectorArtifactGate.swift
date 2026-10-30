import Foundation

/// Приёмочный гейт артефактов Director.
///
/// HARD RULE: гейт умеет только **отклонять** (и помечать правку, которую над
/// текстом уже сделали до него). Ни одна его ветка не рождает тему из эвристики:
/// не прошло проверку — отклонено, а не заменено придуманным нами словом.
///
/// Граница, которую держит этот файл: лингвистические правила (письменность,
/// служебные слова, длина, наличие слова в фильме) остаются, данные о содержимом
/// конкретного фильма сюда не попадают вовсе — список «правильных тем» был бы
/// подстановкой, а не выбором модели, и именно он когда-то выдал «ЙОГО» с
/// бейджем «ВЫБОР ИИ».
///
/// Что здесь НЕ работает и потому отсутствует (проверено на этой ОС, а не
/// угадано): `NLTagger(.lexicalClass)` для украинского помечает служебное слово
/// как `OtherWord` — то есть часть речи отсечь нельзя; `NLLanguageRecognizer`
/// на одном слове даёт «СТРАХ» → `bg`, «ХАРАКТЕР» → `ru`, поэтому проверка
/// «это украинский?» убивала бы настоящие темы. Украинскость слова доказывает
/// транскрипт: тема обязана звучать в этом фильме (`Grounding`).
enum DirectorArtifactGate {

    enum GateCode: String, Sendable {
        case empty
        case notSingleWord
        case tooShort
        case tooLong
        case notCyrillic
        case functionWord
        case notInFilm
        case missingProse
        case incompleteReply
        case poolOutOfRange
        case notModelAuthorship
    }

    enum GateVerdict<T> {
        case accepted(T)
        /// Текст уже был изменён до гейта (trim, отброшенное альтернативное
        /// слово). `reason` обязан попасть в лог; если правка меняла авторство,
        /// провенанс даунгрейдит вызывающая сторона.
        case repaired(T, reason: String)
        case rejected(reason: String, code: GateCode)
    }

    /// 4 буквы — порог, который уже стоит в `contentStems`: короткие служебные
    /// слова отсекаются вместе с содержательными однобуквенниками.
    static let minThemeLetters = 4
    /// Потолок guarded by measurement, not by taste: в живом прогоне «Бійцівського
    /// клубу» (28.10.2026, етап 1) модель предложила тему «Відповідальність» — 16
    /// букв, существительное, звучит в фильме. limite 14 отклонял её только за
    /// длину, то есть резал честные темы. 18 прикрывает украинские абстракции на
    /// -ість/-ування и по-прежнему не пропускает обрывки фраз.
    static let maxThemeLetters = 18

    // MARK: - Тема

    /// Слово темы. `transcriptStems` — основы слов транскрипта фильма
    /// (`groundingStems(from:)`); если они переданы, тема обязана реально
    /// звучать в этом фильме.
    static func theme(
        _ rawWord: String,
        in transcriptStems: Set<String>? = nil
    ) -> GateVerdict<String> {
        let word = rawWord.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else {
            return .rejected(reason: "тема пуста", code: .empty)
        }
        guard !word.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            return .rejected(reason: "тема должна быть одним словом: «\(word)»", code: .notSingleWord)
        }

        let letters = String(word.lowercased().filter { $0.isLetter })
        guard !letters.isEmpty else {
            return .rejected(reason: "в теме нет букв: «\(word)»", code: .empty)
        }
        guard letters.count >= minThemeLetters else {
            return .rejected(reason: "тема короче \(minThemeLetters) букв: «\(word)»", code: .tooShort)
        }
        guard letters.count <= maxThemeLetters else {
            return .rejected(reason: "тема длиннее \(maxThemeLetters) букв: «\(word)»", code: .tooLong)
        }

        guard TextUtilities.dominantScript(word) == "Cyrillic" else {
            return .rejected(reason: "тема не кириллицей: «\(word)»", code: .notCyrillic)
        }

        // Служебные слова: тот же стоп-лист, что ищет развязку хука в репликах,
        // и тот же список, который кинетические субтитры считают мелочью.
        // Оба умеют только отклонять, никогда не выбирать. Апостроф убираем до
        // сравнения: иначе «пам'ять» распадается на «пам» + «ять», обе части
        // короче порога, и настоящая тема падает как служебное слово.
        let matchable = Self.dropApostrophes(word.lowercased())
        guard !LongformNarrativeDirector.contentStems(matchable).isEmpty else {
            return .rejected(reason: "«\(word)» — служебное слово, а не тема", code: .functionWord)
        }
        guard !SubtitleRenderer.minorWords.contains(matchable.uppercased()) else {
            return .rejected(reason: "«\(word)» — служебное слово, а не тема", code: .functionWord)
        }

        if let stems = transcriptStems, !stems.contains(groundingKey(letters)) {
            return .rejected(
                reason: "тема «\(word)» не звучит в фильме — основа «\(groundingKey(letters))» не найдена в транскрипте",
                code: .notInFilm)
        }

        if word != rawWord {
            return .repaired(word, reason: "обрезаны пробелы вокруг темы")
        }
        return .accepted(word)
    }

    /// Ключ проверки «слово есть в фильме»: первые 5 букв, та же длина основы,
    /// что использует `contentStems`, поэтому падежные формы («свободи»,
    /// «свободу») совпадают с темой, а выдуманное слово — нет.
    static func groundingKey(_ lettersLower: String) -> String {
        String(lettersLower.prefix(5))
    }

    /// Основы слов транскрипта для проверки темы. Один источник нормализации на
    /// обе стороны сравнения — иначе апостроф и дефис расходились бы молча.
    static func groundingStems(from transcript: String) -> Set<String> {
        Set(LongformNarrativeDirector.contentStems(Self.dropApostrophes(transcript.lowercased())))
    }

    static func dropApostrophes(_ text: String) -> String {
        text.replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "’", with: "")
    }

    // MARK: - Концепт

    static func concept(
        _ concept: ThematicConcept,
        in transcriptStems: Set<String>? = nil
    ) -> GateVerdict<ThematicConcept> {
        switch theme(concept.word, in: transcriptStems) {
        case .rejected(let reason, let code):
            return .rejected(reason: reason, code: code)
        case .accepted, .repaired:
            break
        }

        // Требуем тот текст, который действительно выходит на экран и в описание.
        // `philosophicalPremise` — обязательным не является: пустой слот честен
        // («модель не написала тезис»), а отбивать из-за него всю тему означало бы
        // ждать повторную попытку этапа из-за косметики и в итоге клонировать в него
        // чужую строку — ровно то, от чего этот гейт и был заведён.
        for (field, value) in [
            ("tagline", concept.tagline),
            ("suggestedTitle", concept.suggestedTitle),
        ] {
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .rejected(reason: "у темы нет \(field): модель не дала текст", code: .missingProse)
            }
        }

        let trimmedWord = concept.word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedWord != concept.word else { return .accepted(concept) }
        var repaired = concept
        repaired.word = trimmedWord
        return .repaired(repaired, reason: "обрезаны пробелы вокруг темы")
    }

    // MARK: - Текст на экране (хук и призыв)

    /// Текст, который выйдет на экран: хук или CTA. `chosenByUser` — выбор в
    /// sheet: тогда провенанс `.manual` честен и не нужен. Молчаливый
    /// `hookVariants.first` без выбора — не «выбор ИИ», а наше решение, поэтому
    /// он отклоняется.
    static func screenText(
        _ variant: EssayPlan.TextVariant?,
        chosenByUser: Bool,
        label: String
    ) -> GateVerdict<EssayPlan.TextVariant?> {
        guard let variant else {
            return .rejected(reason: "\(label) отсутствует: модель не предложила вариант и его не выбрали", code: .empty)
        }
        let text = variant.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return .rejected(reason: "\(label) пуст", code: .empty)
        }
        guard chosenByUser || variant.source == .llm else {
            return .rejected(
                reason: "\(label) не записан как выбор модели (source=\(variant.source.rawValue))",
                code: .notModelAuthorship)
        }
        guard text.count <= 240 else {
            return .rejected(reason: "\(label) длинный для экрана (\(text.count) знаков)", code: .tooLong)
        }

        guard text != variant.text else { return .accepted(variant) }
        var trimmed = variant
        trimmed.text = text
        return .repaired(trimmed, reason: "обрезаны пробелы в тексте «\(label)»")
    }

    // MARK: - Весь анализ

    static func analysis(
        _ result: ThematicAnalysisResult,
        completeness: ReplyCompleteness,
        in transcriptStems: Set<String>? = nil
    ) -> GateVerdict<ThematicAnalysisResult> {
        guard completeness.isAcceptable else {
            return .rejected(
                reason: "ответ модели не завершён (\(completeness.rawValue)) — обрезок не принимаем",
                code: .incompleteReply)
        }
        switch concept(result.primaryConcept, in: transcriptStems) {
        case .rejected(let reason, let code):
            return .rejected(reason: reason, code: code)
        case .accepted, .repaired:
            break
        }
        // Пустой пул — это не «бедная тема», а отсутствие монтажа: отдать его
        // significало бы собрать эссе из ничего.
        guard !result.selectedMoments.isEmpty else {
            return .rejected(reason: "модель не выбрала ни одной сцены", code: .empty)
        }
        guard EssayDurationPolicy.pool.contains(result.selectedMoments.count) else {
            return .rejected(
                reason: "модель выбрала \(result.selectedMoments.count) сцен; требуется "
                    + "\(EssayDurationPolicy.pool.lowerBound)–\(EssayDurationPolicy.pool.upperBound)"
                    + " с явным развитием мысли по всем пяти актам",
                code: .poolOutOfRange)
        }
        let roleCounts = Dictionary(grouping: result.selectedMoments.compactMap(\.actRole), by: { $0 })
            .mapValues(\.count)
        guard roleCounts.values.reduce(0, +) == result.selectedMoments.count else {
            return .rejected(reason: "у каждой выбранной сцене должна быть назначена роль акта", code: .poolOutOfRange)
        }
        guard roleCounts[.hook, default: 0] == 1 else {
            return .rejected(reason: "роль hook должна быть назначена ровно одной сцене", code: .poolOutOfRange)
        }
        let missingRoles = LongformActType.canonicalAnalyticOrder.compactMap { role -> String? in
            let count = roleCounts[role, default: 0]
            let minimum = role == .hook ? 1 : 3
            return count < minimum ? "\(role.promptKey): \(count)/\(minimum)" : nil
        }
        guard missingRoles.isEmpty else {
            return .rejected(
                reason: "недостаточно сцен по ролям актов (хук — одна, остальные — минимум по три): "
                    + missingRoles.joined(separator: ", "),
                code: .poolOutOfRange)
        }

        var kept: [ThematicConcept] = []
        var dropped: [String] = []
        for alternative in result.alternativeConcepts {
            switch concept(alternative, in: transcriptStems) {
            case .accepted(let passed), .repaired(let passed, _):
                kept.append(passed)
            case .rejected(let reason, _):
                dropped.append("\(alternative.word): \(reason)")
            }
        }
        guard dropped.isEmpty else {
            var repaired = result
            repaired.alternativeConcepts = kept
            return .repaired(
                repaired,
                reason: "отклонены альтернативные темы, не прошедшие проверку: \(dropped.joined(separator: "; "))")
        }
        return .accepted(result)
    }
}

extension DirectorArtifactGate.GateVerdict: CustomStringConvertible {
    /// Строка для `director.log`: `accepted(СВОБОДА)` / `rejected(functionWord): …`.
    var description: String {
        switch self {
        case .accepted(let value):
            return "accepted(\(value))"
        case .repaired(let value, let reason):
            return "repaired(\(value)): \(reason)"
        case .rejected(let reason, let code):
            return "rejected(\(code.rawValue)): \(reason)"
        }
    }
}
