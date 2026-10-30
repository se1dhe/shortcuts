import Testing
import Foundation
@testable import Shortcast

/// Контракт двухэтапного Director: этап 1 отдаёт только темы-кандидаты, этап 2
/// пишет эссе вокруг уже проверенной темы. Ни один из этапов не имеет права
/// выдать тему, которой нет в фильме, и засчитать обрыв успеха.
@Suite("Two-stage Director contract")
struct TwoStageDirectorTests {

    /// Дайджест этапа 1: все пять слов реально звучат в фильме, иначе гейт
    /// отклонит кандидатов и тест будет проверять не то.
    private static let filmDigest = """
        [120.0] Свобода тут записана на стіні камери.
        [980.5] Обман працює, лише коли його купують.
        [1420.0] Страх — це просто вага, яку ти носиш.
        [2100.4] Терпіння вимірюють не хвилинами, а ціною.
        [2680.0] Влада тримається на тому, хто мовчить.
        """

    private func candidateJSON(words: [String]) -> String {
        let items = words.map { word in
            """
            {"word":"\(word)","tagline":"Теглайн теми \(word)","why":"Це слово тримає сюжет.","title":"\(word) | тест","evidenceTimecodes":[120.0, 980.5, 2100.4]}
            """
        }.joined(separator: ",")
        return "{\"candidates\":[\(items)]}"
    }

    @Test("stage 1 returns the five candidates the model actually printed")
    func parsesFiveCandidates() {
        let words = ["СВОБОДА", "ОБМАН", "СТРАХ", "ТЕРПІННЯ", "ВЛАДА"]
        let parsed = LongformThematicService.parseThemeCandidates(from: candidateJSON(words: words))
        #expect(parsed.map(\.word) == words)
        // Провенанс `.llm` здесь честен: текст этого прохода лежит в raw-дампе.
        #expect(parsed.allSatisfy { $0.source == .llm })
    }

    /// Кандидат-объект без `why` — не кандидат: слоган и обоснование обязана
    /// дать модель, дописывать их мы не умеем.
    @Test("a candidate without the model's own prose is dropped, not completed")
    func dropsProselessCandidate() {
        let raw = """
        {"candidates":[
          {"word":"СВОБОДА","tagline":"Т","why":"Ч","title":"Н","evidenceTimecodes":[1.0]},
          {"word":"ОБМАН","tagline":"Т","title":"Н"}
        ]}
        """
        let parsed = LongformThematicService.parseThemeCandidates(from: raw)
        #expect(parsed.map(\.word) == ["СВОБОДА"])
    }

    /// Тема обязана звучать в фильме: кандидата, которого нет в дайджесте,
    /// гейт отклоняет, и из пяти слов остаются только четыре.
    @Test("stage 1 keeps only candidates grounded in the film")
    func groundsEveryCandidate() {
        let stems = DirectorArtifactGate.groundingStems(from: Self.filmDigest)
        let parsed = LongformThematicService.parseThemeCandidates(
            from: candidateJSON(words: ["СВОБОДА", "ГЕНІАЛЬНІСТЬ", "ОБМАН", "СТРАХ", "ТЕРПІННЯ"]))
        var accepted: [String] = []
        var rejected: [String] = []
        for concept in parsed {
            switch DirectorArtifactGate.concept(concept, in: stems) {
            case .accepted(let passed), .repaired(let passed, _): accepted.append(passed.word)
            case .rejected: rejected.append(concept.word)
            }
        }
        #expect(accepted == ["СВОБОДА", "ОБМАН", "СТРАХ", "ТЕРПІННЯ"])
        #expect(rejected == ["ГЕНІАЛЬНІСТЬ"])
    }

    /// Если не прошёл ни один кандидат, у конвейера нет темы — и нет права её
    /// придумать. Проверяем именно это: гейт отклоняет всех, а не подставляет.
    @Test("when no candidate passes the gate nothing is left to invent from")
    func emptyGroundedSetLeavesNoWinner() {
        let stems = DirectorArtifactGate.groundingStems(
            from: "[10.0] тут немає жодного з цих слів")
        let parsed = LongformThematicService.parseThemeCandidates(
            from: candidateJSON(words: ["СВОБОДА", "ОБМАН", "СТРАХ", "ТЕРПІННЯ", "ВЛАДА"]))
        let passed = parsed.filter {
            if case .accepted = DirectorArtifactGate.concept($0, in: stems) { return true }
            return false
        }
        #expect(passed.isEmpty)
    }

    @Test("stage 1 asks for five candidates and never offers a theme menu")
    func stageOneInstructionsDemandDiscoveryNotAChoice() throws {
        let instructions = DirectorStagedAnalysis.candidatesInstructions(movieTitle: "Бійцівський клуб")
        #expect(instructions.contains("П'ЯТЬ"))
        #expect(instructions.contains("\"candidates\""))
        // Формальные требования вместо списка тем:
        #expect(instructions.contains("називний відмінок"))
        #expect(instructions.contains("займенник"))
        #expect(instructions.contains("4 літери"))
        // Ни одного подсказанного слова-темы.
        for word in ["СВОБОДА", "ОБМАН", "СТРАХ", "ТЕРПІННЯ", "ВЛАДА", "ГЕНІАЛЬНІСТЬ", "ЕГО", "ЙОГО"] {
            #expect(!instructions.contains("«\(word)»"), "инструкция этапа 1 подсовывает тему «\(word)»")
        }
        // Обещание, что пример — это формат, а не содержимое.
        #expect(instructions.contains("ФОРМАТУ, а НЕ змісту"))

        let prompt = DirectorStagedAnalysis.candidatesPrompt(
            movieTitle: "Бійцівський клуб", overview: "", digest: Self.filmDigest)
        #expect(prompt.contains("Фільм: «Бійцівський клуб»"))
        #expect(prompt.contains("[120.0]"))
    }

    @Test("stage 2 works on the approved theme and stops proposing new ones")
    func stageTwoFocusesOnTheWinner() {
        let focus = DirectorStagedAnalysis.stage2Focus(
            winner: "СВОБОДА", runnersUp: ["ОБМАН", "СТРАХ"])
        #expect(focus.contains("«СВОБОДА»"))
        #expect(focus.contains("ОБМАН, СТРАХ"))
        // Альтернативные грани уже найдены этапом 1: этап 2 их не сочиняет.
        #expect(focus.contains("alternativeConcepts"))
        #expect(focus.contains("порожній масив"))
        #expect(focus.contains("primaryConcept → essayPlan → selectedMoments"))
    }

    /// Обрыв — не ответ. Незакрытый объект считается truncated, и гейт его
    /// отклоняет, даже когда тема в хвосте уже видна.
    @Test("an unclosed reply is truncated by definition and the gate refuses it")
    func truncatedReplyNeverCountsAsSuccess() throws {
        let closed = Self.candidateClosure(json: candidateJSON(words: ["СВОБОДА"]))
        #expect(closed.completeness == .complete)
        #expect(closed.completeness.isAcceptable)

        let cut = candidateJSON(words: ["СВОБОДА", "ОБМАН"])
        let truncated = DirectorReply(
            text: String(cut.prefix(cut.count - 12)), info: nil, maxTokens: 1_024)
        #expect(truncated.completeness == .truncated)
        #expect(truncated.completeness.isAcceptable == false)

        let parsed = LongformThematicService.parseThemeCandidates(from: truncated.text)
        #expect(parsed.isEmpty, "парсер доклеил хвост там, где модель остановилась")
    }

    /// Дайджест прореживается равным шагом по всей хронологии: начало и финал
    /// фильма обязаны доходить до модели, иначе акт вывода строится по памяти.
    @Test("the thinned digest keeps the head and the tail of the film")
    func digestPreservesBothEnds() {
        let lines = (0..<400).map { index in
            "[\(Double(index) * 20)] Репліка \(index) про вибір і ціну."
        }
        let sample = lines.joined(separator: "\n")
        let budget = 6_000
        let (digest, stride) = MomentFinderService.downsampleChronologically(sample, to: budget)
        #expect(digest.count <= budget)
        #expect(stride > 1)
        #expect(digest.contains(lines.first!))
        #expect(digest.contains(lines.last!))
        // Прореживание равномерное: из середины картины тоже что-то осталось,
        // иначе третий акт модель строила бы по первым и последним репликам.
        let timecodes = digest.split(separator: "\n").compactMap { line -> Double? in
            guard let bracket = line.firstIndex(of: "]") else { return nil }
            return Double(line[line.index(after: line.firstIndex(of: "[") ?? line.startIndex)..<bracket])
        }
        #expect(timecodes.contains { $0 > 2_600 && $0 < 5_400 })
        // Порядок — хронологія фільма, без дублів: інакше «зріз» був би набором
        // рядків, а не сюжетом, і третій акт будувався б по пам'яті.
        let kept = digest.split(separator: "\n").map(String.init)
        #expect(Array(Set(kept)).count == kept.count, "прореювання здублювало рядки")
        #expect(timecodes == timecodes.sorted(), "прореювання зіпсувало хронологію")
        #expect(kept.first == lines.first! && kept.last == lines.last!)
        // Зріз, що вміщується в бюджет, не чіпаємо взагалі.
        let (untouched, noStride) = MomentFinderService.downsampleChronologically(sample, to: 100_000)
        #expect(untouched == sample)
        #expect(noStride == 1)
    }

    @Test("stage 1 caps its answer so it closes instead of running over")
    func stageOneAnswerIsDeliberatelySmall() {
        #expect(DirectorStagedAnalysis.stage1MaxTokens < DirectorStagedAnalysis.stage2MaxTokens)
        #expect(DirectorStagedAnalysis.stage1DigestChars <= 20_000)
    }

    /// Промпт этапа 2 и потолок KV — одна арифметика, порахована з тих самих рядків,
    /// що йдуть у модель. Живий прогін 28.10.2026: 11 376 prompt tokens
    /// при зрізі 16 669 знаків; зі стелею генерації 5 120 це 16 496 > 16 384, і
    /// спробу обрізало `stop=length`. Причина: оверхед вважався константою «1 500»,
    /// тоді як одні інструкції важать ~3 900 токенів.
    @Test("the stage-2 digest budget fits the KV cap we hand to MLX")
    func stage2BudgetFitsTheKVCap() {
        let winner = Self.concept("СВОБОДА")
        let approved = [winner, Self.concept("ОБМАН"), Self.concept("СТРАХ"), Self.concept("ТЕРПІННЯ")]
        // Найгірший захід: синопсис на ввесь дозволений обсяг (`thematicOverviewCharCap`).
        let overview = String(repeating: "а", count: MomentFinderService.thematicOverviewCharCap)

        let plan = MomentFinderService.essayDigestPlan(
            movieTitle: Self.movieTitle,
            overview: overview,
            winner: winner,
            approvedCandidates: approved,
            maxKVSize: nil)  // gemma12B без `maxKVSize`: саме `unboundedKVTokenBudget` піде в MLX
        let digestTokens = Self.tokens(of: plan.digestChars)
        let total = plan.promptOverheadTokens + digestTokens + DirectorStagedAnalysis.stage2MaxTokens
        #expect(total <= MomentFinderService.unboundedKVTokenBudget,
                "этап 2 знову просить більше токенів, ніж стеля KV: \(total) > \(MomentFinderService.unboundedKVTokenBudget)")
        // 18 ГБ RAM і 6.3 ГБ ваг: дайджест не має вирости за межу, що її тримає этап 1.
        #expect(plan.digestChars <= 20_000, "дайджест этапа 2 виріс до \(plan.digestChars) знаків")

        // Оверхед виведено з рядків, а не з константи: інструкції самі по собі
        // перевищують стару «1 500» на весь промпт, і бюджет мусить це бачити.
        let instructions = MomentFinderService.essayInstructions(
            movieTitle: Self.movieTitle, winner: winner, approvedCandidates: approved)
        #expect(MomentFinderService.estimatedTokens(of: instructions) > 1_500,
                "інструкції этапа 2 вищі за константу — отже константа була нижчою за правду")
        #expect(plan.promptOverheadTokens >= MomentFinderService.estimatedTokens(of: instructions))

        // ...і цифра рухається за промптом: довший синопсис = менший дайджест.
        let bareOverview = MomentFinderService.essayDigestPlan(
            movieTitle: Self.movieTitle, overview: "", winner: winner,
            approvedCandidates: approved, maxKVSize: nil)
        #expect(bareOverview.promptOverheadTokens < plan.promptOverheadTokens)
        #expect(bareOverview.digestChars > plan.digestChars)
    }

    /// Той самий розрахунок для этапа 1: його 18 000 — власна стеля, але вона
    /// має влізти в ту саму стелю KV, а не сподіватися на авось.
    @Test("the stage-1 digest fits the same KV arithmetic and tightens with the cap")
    func stage1BudgetFitsTheKVCap() {
        let overview = String(repeating: "а", count: MomentFinderService.thematicOverviewCharCap)
        let plan = MomentFinderService.candidatesDigestPlan(
            movieTitle: Self.movieTitle, overview: overview, maxKVSize: nil)
        let total = plan.promptOverheadTokens + Self.tokens(of: plan.digestChars)
            + DirectorStagedAnalysis.stage1MaxTokens
        #expect(total <= MomentFinderService.unboundedKVTokenBudget,
                "этап 1 просить \(total) токенів при стелі \(MomentFinderService.unboundedKVTokenBudget)")
        // На 16 384 KV місця більше, ніж потребує этап 1: стеля `stage1DigestChars`
        // лишається чинною, а не ілюзорною.
        #expect(plan.digestChars == DirectorStagedAnalysis.stage1DigestChars,
                "етап 1 раптом бере \(plan.digestChars) замість своїх \(DirectorStagedAnalysis.stage1DigestChars)")

        // Вужчий профиль KV має різати дайджест, а не промпт мовчки.
        let tight = MomentFinderService.candidatesDigestPlan(
            movieTitle: Self.movieTitle, overview: overview, maxKVSize: 8_192)
        #expect(tight.digestChars < plan.digestChars)
        #expect(tight.promptOverheadTokens + Self.tokens(of: tight.digestChars)
                    + DirectorStagedAnalysis.stage1MaxTokens <= 8_192)
    }

    /// Оцінка знаків→токенів мусить залишатися похмурішою за живі виміри, інакше
    /// бюджет знову станеться мрією: `director.log` 28.10.2026, stage=essay
    /// attempt=1 — 11 376 prompt tokens при зрізі 16 669 знаків (реально ~2.30
    /// знаки/токен разом із чат-шаблоном), тобто `approxCharsPerToken = 2.0` має
    /// давати більше, ніж 11 376.
    @Test("the token estimate stays pessimistic against the live measurement")
    func estimateNeverUnderestimatesTheLivePrompt() {
        let measuredPromptTokens = 11_376
        let winner = Self.concept("БІЛЬ")
        let approved = [winner, Self.concept("СМЕРТЬ"), Self.concept("ВІДЧУТТЯ")]
        let instructions = MomentFinderService.essayInstructions(
            movieTitle: Self.movieTitle, winner: winner, approvedCandidates: approved)
        let prompt = DirectorStagedAnalysis.essayPrompt(
            movieTitle: Self.movieTitle,
            overview: String(repeating: "а", count: 567),      // синопсис живого прогону
            theme: winner.word,
            tagline: winner.tagline,
            digest: String(repeating: "а", count: 16_669))     // зріз живого прогону
        let estimated = MomentFinderService.estimatedTokens(of: instructions + prompt)
        #expect(estimated >= measuredPromptTokens,
                "оцінка стала оптимістичнішою за живі дані: \(estimated) < \(measuredPromptTokens)")
        // Але й не абсурдно похмура: інакше діалоги голодують, а есе пишилося б по початку
        // і фіналу фільма.
        #expect(estimated <= measuredPromptTokens * 3 / 2,
                "оцінка перевищила живий вимір упівтора раза — \(estimated): дайджест штучно морять")
    }

    /// Этап 2 не має права перевибирати тему. Гейт перевіряє слово на «звучить у
    /// фільмі», а не на «це той, що схвалив этап 1»: без цієї рівності есе могло
    /// будуватися навколо іншого слова, а провенанс «ІІ ВИБІР / знайдено етапом 1»
    /// усе одно виходив би на екран.
    @Test("stage 2 must write about the theme the gate approved")
    func stage2RejectsARePickedTheme() {
        let winner = Self.concept("СВОБОДА")
        // Той самий ключ, що й у гейта: trim + casefold — регістр і пробіли не
        // підстава відхиляти чесну відповідь.
        #expect(MomentFinderService.essayThemeMismatch(
            Self.analysis(theme: " свобода "), approved: winner) == nil)
        #expect(MomentFinderService.essayThemeMismatch(
            Self.analysis(theme: "СВОБОДА"), approved: winner) == nil)

        let reason = MomentFinderService.essayThemeMismatch(
            Self.analysis(theme: "ОБМАН"), approved: winner)
        #expect(reason != nil, "етап 2 переобрав тему — спробу маємо відхилити")
        #expect(reason?.contains("СВОБОДА") == true, "причина не називає схвалену тему")
        #expect(reason?.contains("ОБМАН") == true, "причина не називає нав'язану тему")
        // Провенанс етапу 1 при невідповідності не заявляємо: жодного третього слова
        // ані виправлення «під winner» тут немає.
        #expect(reason?.contains("провенанс етапу 1 не заявляємо") == true)
    }

    @Test("theme comparison normalises the same way the gate does")
    func themeKeyTrimAndCasefolds() {
        #expect(MomentFinderService.themeKey("  Свобода\n") == MomentFinderService.themeKey("СВОБОДА"))
        #expect(MomentFinderService.themeKey("Свобода") != MomentFinderService.themeKey("Свободу"))
    }
}

private extension TwoStageDirectorTests {

    static let movieTitle = "Бійцівський клуб"

    /// Концепт форми, яку гейт пропустив би: слово + проза, нічого зашитого.
    static func concept(_ word: String) -> ThematicConcept {
        ThematicConcept(
            word: word,
            tagline: "Теглайн теми \(word)",
            philosophicalPremise: "Тезис \(word)",
            suggestedTitle: "\(word) | тест",
            source: .llm)
    }

    /// Ответ этапа 2 с указанной темой — рівно та форма, що й у справжнього парсингу:
    /// і схвалена тема, і переобрана.
    static func analysis(theme: String) -> ThematicAnalysisResult {
        ThematicAnalysisResult(
            primaryConcept: concept(theme),
            aiReasoning: "Розбір драматургії.",
            selectedMoments: [SelectedMoment(
                startTime: 120.0, endTime: 155.0,
                reason: "Сцена-хук", dramaticWeight: 0.8, actRole: .hook)],
            source: .llm)
    }

    /// Скільки токенів займе дайджест з `chars` знаків — та сама оцінка, з якої
    /// рахується бюджет.
    static func tokens(of chars: Int) -> Int {
        MomentFinderService.estimatedTokens(of: String(repeating: "а", count: chars))
    }
}

private extension TwoStageDirectorTests {
    /// Закрытый JSON-объект ответа этапа 1.
    static func candidateClosure(json: String) -> DirectorReply {
        DirectorReply(text: json, info: nil, maxTokens: 1_024)
    }
}
