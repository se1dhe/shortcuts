import Testing
import Foundation
@testable import Shortcast

/// Гейт честности: он умеет только отклонять. Тесты закрепляют обе стороны —
/// что настоящая тема проходит, а местоимение/латиница/обрыв не проходят.
@Suite("DirectorArtifactGate")
struct DirectorArtifactGateTests {

    private func accepted(_ word: String) -> Bool {
        if case .accepted = DirectorArtifactGate.theme(word) { return true }
        return false
    }

    private func rejection(_ word: String) -> (String, DirectorArtifactGate.GateCode)? {
        if case .rejected(let reason, let code) = DirectorArtifactGate.theme(word) {
            return (reason, code)
        }
        return nil
    }

    /// Обязательный набор реальных тем: части речи Ukrainian NLTagger не различает,
    /// а `NLLanguageRecognizer` на одном слове путает «СТРАХ» с болгарским, поэтому
    /// единственные рабочие отсекатели — письменность, длина, стоп-лист и наличие
    /// слова в фильме. Ни один из них не имеет права отклонять настоящую тему.
    @Test("real Ukrainian theme words are accepted", arguments: [
        "СВОБОДА", "ОБМАН", "СТРАХ", "ТЕРПІННЯ", "ГЕНІАЛЬНІСТЬ", "ВЛАДА", "ІСТИНА",
        "ГОРДИНЯ", "САМОТНІСТЬ", "ЗРАДА", "ХАРАКТЕР", "ІЛЮЗІЯ", "ПАМ'ЯТЬ", "ВИБІР",
        "ЗБАВИТИ", "ВРЯТУВАТИ", "ВІДПОВІДАЛЬНІСТЬ",
    ])
    func acceptsRealThemes(word: String) {
        #expect(accepted(word), "гейт отклонил настоящую тему «\(word)»")
    }

    /// Именно это и произошло с «Бойцовський клуб»: местоимение с бейджем «ВЫБОР ИИ».
    @Test("pronouns and service words are rejected", arguments: [
        "ЕГО", "ЙОГО", "ИХ", "ЇХ", "МЕНІ", "ТОБІ", "ЩО", "ВІН", "АЛЕ", "НЕ", "В", "НА",
    ])
    func rejectsServiceWords(word: String) {
        let verdict = rejection(word)
        #expect(verdict != nil, "гейт пропустил служебное слово «\(word)»")
        if let (_, code) = verdict {
            #expect(
                code == .functionWord || code == .tooShort,
                "«\(word)» отклонён по неожиданной причине: \(code.rawValue)")
        }
    }

    @Test("latin, oversized, empty and multi-word themes are rejected")
    func rejectsMalformedThemes() {
        #expect(rejection("Freedom")?.1 == .notCyrillic)
        #expect(rejection("СУПЕРСУПЕРДОВГЕСЛОВО")?.1 == .tooLong)
        #expect(rejection("   ")?.1 == .empty)
        #expect(rejection("123")?.1 == .empty)
        #expect(rejection("СВОБОДА ВОЛІ")?.1 == .notSingleWord)
    }

    @Test("whitespace around a theme is a repair, not a substitution")
    func trimsThemeWhitespace() {
        let verdict = DirectorArtifactGate.theme("  СВОБОДА  ")
        guard case .repaired(let word, _) = verdict else {
            Issue.record("ожидали .repaired, получили \(verdict)")
            return
        }
        #expect(word == "СВОБОДА")
    }

    /// Тема обязана звучать в фильме: слово, которого нет в транскрипте, —
    /// галлюцинация, каким бы красивым оно ни было.
    @Test("a theme that never occurs in the transcript is rejected")
    func rejectsUngroundedTheme() {
        // «свободи» — другой падеж той же основы: гейт обязан принять, иначе
        // любая косвенная форма убивала бы настоящую тему.
        let stems = DirectorArtifactGate.groundingStems(
            from: "Сніданок за кілька годин. Свободи тут немає.")
        switch DirectorArtifactGate.theme("СВОБОДА", in: stems) {
        case .accepted, .repaired: break
        case .rejected(let reason, let code):
            Issue.record("«СВОБОДА» отклонена по grounding, хотя в фильме есть «свободи»: \(code.rawValue) — \(reason)")
        }

        if case .rejected(let reason, let code) = DirectorArtifactGate.theme("ГЕНІАЛЬНІСТЬ", in: stems) {
            #expect(code == .notInFilm, "чужое слово отклонено не по grounding: \(reason)")
        } else {
            Issue.record("слово, которого нет в фильме, прошло гейт")
        }
    }

    /// Апостроф — не разделитель: «пам'ять» обязана находиться по основе
    /// «памят», а не распадаться на «пам» + «ять» короче порога.
    @Test("apostrophe themes ground against the transcript")
    func groundsApostropheTheme() {
        let stems = DirectorArtifactGate.groundingStems(from: "Їхня пам'ять тримає цей дім.")
        #expect(stems.contains(DirectorArtifactGate.groundingKey("память")))
        switch DirectorArtifactGate.theme("ПАМ'ЯТЬ", in: stems) {
        case .accepted, .repaired: break
        case .rejected(let reason, let code):
            Issue.record("«ПАМ'ЯТЬ» отклонена: \(code.rawValue) — \(reason)")
        }
    }

    @Test("concept requires the model's own prose")
    func conceptNeedsProse() {
        let complete = ThematicConcept(
            word: "СВОБОДА",
            tagline: "Він вільний, поки вірить.",
            philosophicalPremise: "Свобода — це вибір ціни.",
            suggestedTitle: "Свобода | СВОБОДА",
            source: .llm
        )
        if case .rejected(let reason, _) = DirectorArtifactGate.concept(complete) {
            Issue.record("полный концепт отклонён: \(reason)")
        }

        let silent = ThematicConcept(
            word: "СВОБОДА",
            tagline: "",
            philosophicalPremise: "Тез",
            suggestedTitle: "Назва",
            source: .llm
        )
        if case .rejected(_, let code) = DirectorArtifactGate.concept(silent) {
            #expect(code == .missingProse)
        } else {
            Issue.record("концепт без теглайна прошёл гейт")
        }
    }

    /// Пустой тезис — честное отсутствие, а не повод отбивать тему и вставлять
    /// в слот чужую строку. Гейт обязан пропустить такой концепт и не менять его.
    @Test("an empty premise is honest absence, not a rejection")
    func emptyPremisePassesUntouched() {
        let noPremise = ThematicConcept(
            word: "СВОБОДА",
            tagline: "Він вільний, поки вірить.",
            philosophicalPremise: "",
            suggestedTitle: "Свобода | СВОБОДА",
            source: .llm
        )
        switch DirectorArtifactGate.concept(noPremise) {
        case .accepted(let passed):
            #expect(passed.philosophicalPremise.isEmpty)
            #expect(passed.tagline == noPremise.tagline)
        case .repaired(_, let reason):
            Issue.record("гейт «починил» пустой тезис: \(reason)")
        case .rejected(let reason, let code):
            Issue.record("тема отклонена из-за пустого тезиса: \(code.rawValue) — \(reason)")
        }
    }

    /// Обрезанный ответ — не успех. Раньше его «долечивал» парсер.
    @Test("truncated reply is rejected")
    func rejectsTruncatedReply() {
        let moments = (0..<18).map { index in
            SelectedMoment(
                startTime: Double(index) * 30,
                endTime: Double(index) * 30 + 25,
                reason: "Сцена \(index)",
                dramaticWeight: 0.8)
        }
        let result = ThematicAnalysisResult(
            primaryConcept: ThematicConcept(
                word: "СВОБОДА",
                tagline: "Теглайн",
                philosophicalPremise: "Тез",
                suggestedTitle: "Назва",
                source: .llm),
            aiReasoning: "Розбір",
            selectedMoments: moments,
            source: .llm)

        if case .rejected(_, let code) = DirectorArtifactGate.analysis(
            result, completeness: .truncated) {
            #expect(code == .incompleteReply)
        } else {
            Issue.record("обрезанный ответ принят гейтом")
        }

        switch DirectorArtifactGate.analysis(result, completeness: .complete) {
        case .accepted, .repaired: break
        case .rejected(let reason, let code):
            Issue.record("полный анализ отклонён: \(code.rawValue) — \(reason)")
        }
    }

    /// Длина эссе рождается из материала, поэтому тонкий пул — не провал: 9 честных
    /// сцен дают эссе у нижней границы коридора. Отклоняем только пустоту и развал
    /// ответа (пул больше контракта — модель перестала выбирать и начала выписывать фильм).
    private func analysis(poolSize: Int) -> ThematicAnalysisResult {
        ThematicAnalysisResult(
            primaryConcept: ThematicConcept(
                word: "СВОБОДА",
                tagline: "Теглайн",
                philosophicalPremise: "Тез",
                suggestedTitle: "Назва",
                source: .llm),
            aiReasoning: "Розбір",
            selectedMoments: (0..<poolSize).map { index in
                SelectedMoment(
                    startTime: Double(index) * 30,
                    endTime: Double(index) * 30 + 25,
                    reason: "Сцена \(index)",
                    dramaticWeight: 0.8)
            },
            source: .llm)
    }

    @Test("pool gate rejects emptiness and runaway, accepts thin")
    func poolRangeRules() {
        if case .rejected(_, let code) = DirectorArtifactGate.analysis(analysis(poolSize: 0), completeness: .complete) {
            #expect(code == .empty)
        } else {
            Issue.record("пустой пул принят")
        }

        if case .rejected(_, let code) = DirectorArtifactGate.analysis(analysis(poolSize: 23), completeness: .complete) {
            #expect(code == .poolOutOfRange)
        } else {
            Issue.record("развалившийся пул из 23 сцен принят")
        }

        switch DirectorArtifactGate.analysis(analysis(poolSize: 9), completeness: .complete) {
        case .accepted, .repaired: break
        case .rejected(let reason, let code):
            Issue.record("тонкий пул отклонён: \(code.rawValue) — \(reason)")
        }
    }

    /// Молчаливый `hookVariants.first` — не «выбор ИИ».
    @Test("hook provenance must be recorded or the user must have chosen")
    func hookNeedsProvenance() {
        let unsourced = EssayPlan.TextVariant(text: "Перший варіант хука.", source: .unknown)
        if case .rejected(_, let code) = DirectorArtifactGate.screenText(unsourced, chosenByUser: false, label: "хук") {
            #expect(code == .notModelAuthorship)
        } else {
            Issue.record("хук без провенанса выдан за выбор модели")
        }

        if case .rejected = DirectorArtifactGate.screenText(nil, chosenByUser: false, label: "хук") {
        } else {
            Issue.record("пустой хук принят")
        }

        let manual = EssayPlan.TextVariant(text: "Мій хук.", source: .manual)
        if case .accepted = DirectorArtifactGate.screenText(manual, chosenByUser: true, label: "хук") {
        } else {
            Issue.record("хук, выбранный пользователем, отклонён")
        }
    }

    /// HARD RULE: гейт не подставляет. Ни одна проверка не может вернуть
    /// слово, которого не было на входе.
    @Test("gate never invents a theme")
    func gateNeverSubstitutes() {
        for candidate in ["ЕГО", "ЙОГО", "Freedom", "", "  ", "ЩО", "123"] {
            let verdict = DirectorArtifactGate.theme(candidate)
            if case .repaired(let word, _) = verdict {
                #expect(
                    word.lowercased().contains(
                        candidate.trimmingCharacters(in: .whitespaces).lowercased())
                        || candidate.trimmingCharacters(in: .whitespaces).isEmpty,
                    "гейт підставив замість «\(candidate)» слово «\(word)»")
            }
        }
    }
}
