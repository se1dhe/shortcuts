import Testing
import Foundation
@testable import Shortcast

/// Названия актов: второй LLM-проход, его гейты и детерминированный запасной путь.
/// Всё герметично: модель подменяется заглушкой, LLM для прогонов не нужен.
@Suite("LongformActTitle Tests")
struct LongformActTitleTests {

    private static let actTypes: [LongformActType] = [.hook, .downfall, .struggle, .catharsis]
    private static let runStarts: [Double] = [600, 2200, 4400, 7700]
    private static let lineSeconds: Double = 10.0

    /// Диалог одного «фильма»: по два запуска на акт
    private static let runs: [[String]] = [
        ["Ты никогда не знаешь главного правила игры.", "Каждый делает выбор сам."],
        ["Нет, ты проиграл, и это твоя ошибка.", "Уходи, пока не поздно."],
        ["Держись и смотри только вперед.", "Выход есть, но он против них."],
        ["Теперь я понимаю цену этой свободе.", "Правда оказалась дороже выигрыша."]
    ]

    private static func concept(word: String = "Иллюзия") -> ThematicConcept {
        ThematicConcept(
            word: word,
            tagline: "Карта не есть территория",
            philosophicalPremise: "Взгляд всегда формирует предмет",
            suggestedTitle: "Слепая линия горизонта",
            accentColorHex: "#F5D020"
        )
    }

    private func fixture(movieTitle: String = "Синтетический полный метр")
        -> (transcript: Transcript, arc: LongformNarrativeArc) {
        var segments: [TranscriptSegment] = []
        var acts: [LongformAct] = []
        for (index, lines) in Self.runs.enumerated() {
            let start = Self.runStarts[index]
            for (lineIndex, text) in lines.enumerated() {
                let lineStart = start + Double(lineIndex) * Self.lineSeconds
                segments.append(TranscriptSegment(
                    start: lineStart,
                    end: lineStart + Self.lineSeconds - 0.4,
                    text: text,
                    words: []
                ))
            }
            acts.append(LongformAct(
                type: Self.actTypes[index],
                title: "Заготовка",
                dramaticBeat: "Заготовка",
                segments: [TimeSegment(start: start, end: start + Double(lines.count) * Self.lineSeconds)]
            ))
        }
        let arc = LongformNarrativeArc(
            movieTitle: movieTitle,
            concept: Self.concept(),
            acts: acts,
            summary: "Арка для проверки нейминга"
        )
        return (Transcript(segments: segments, language: "ru", provenance: .whisper), arc)
    }

    /// Заглушка Director'а: отдаёт заготовленный текст. `ready == false` означает
    /// «модель не в памяти» — если service всё равно её спросит, акты получат
    /// метку `.llm` и тест политики RAM упадёт сам, без счётчика вызовов.
    private struct StubModel: LongformActTitleModeling {
        var ready: Bool
        var response: String?
        var identifier: String? = "stub-9b"

        var isReady: Bool {
            get async { ready }
        }

        var modelID: String? {
            get async { identifier }
        }

        func complete(instructions: String, prompt: String, maxTokens: Int) async -> String? {
            response
        }
    }

    /// Ответ модели с ДОСЛОВНЫМИ репликами своих актов
    private static let groundedJSON = """
        {"acts":[\
        {"type":"hook","title":"Правило игры","dramaticBeat":"Герой впервые слышит закон стола.","quotedLine":"Ты никогда не знаешь главного правила игры."},\
        {"type":"downfall","title":"Своя ошибка","dramaticBeat":"Ставка проиграна, признание поздно.","quotedLine":"Нет, ты проиграл, и это твоя ошибка."},\
        {"type":"struggle","title":"Смотреть вперед","dramaticBeat":"Последний рубеж держат руками.","quotedLine":"Держись и смотри только вперед."},\
        {"type":"catharsis","title":"Цена свободе","dramaticBeat":"Выигрыш обменян на ясность.","quotedLine":"Теперь я понимаю цену этой свободе."}]}
        """

    /// Тот же ответ, но quotedLine выдуманы: таких реплик в актах нет
    private static let fabricatedJSON = """
        {"acts":[\
        {"type":"hook","title":"Правило игры","dramaticBeat":"Герой впервые слышит закон стола.","quotedLine":"Я знаю, что ты вернёшься домой."},\
        {"type":"downfall","title":"Своя ошибка","dramaticBeat":"Ставка проиграна.","quotedLine":"Никогда не садись играть с ним."},\
        {"type":"struggle","title":"Смотреть вперед","dramaticBeat":"Держат рубеж.","quotedLine":"Держись и смотри только вперед."},\
        {"type":"catharsis","title":"Цена свободе","dramaticBeat":"Ясность вместо выигрыша.","quotedLine":"Теперь я понимаю цену этой свободе."}]}
        """

    // MARK: - Гейты доверия

    @Test("Untrusted LLM grounding demotes that act to a real transcript line")
    func testUntrustedLLMGroundingDegradesToTranscriptLine() async throws {
        let film = fixture()
        let service = LongformActTitleService(model: StubModel(ready: true, response: Self.groundedJSON))
        let result = await service.applyTitles(
            to: film.arc,
            transcript: film.transcript,
            movieTitle: "Синтетический полный метр",
            progress: nil
        )
        // Контроль: валидные цитаты берутся моделью
        #expect(result.arc.acts.map(\.effectiveTitleSource) == Array(repeating: ActTitleSource.llm, count: 4))

        // Выдуманные цитаты для актов I и II — те два акта обязаны уйти на реплику,
        // а акты III и IV остаются на модели (гейт независим для каждого акта)
        let service2 = LongformActTitleService(model: StubModel(ready: true, response: Self.fabricatedJSON))
        let demoted = await service2.applyTitles(
            to: film.arc,
            transcript: film.transcript,
            movieTitle: "Синтетический полный метр",
            progress: nil
        )
        #expect(demoted.arc.acts.map(\.effectiveTitleSource) == [
            .transcriptLine, .transcriptLine, .llm, .llm
        ])
        for index in [0, 1] {
            let act = demoted.arc.acts[index]
            let evidence = try #require(act.titleProvenance?.evidence)
            #expect(Self.runs[index].contains(evidence), "Запасное название взято не из реплики акта")
            #expect(act.titleProvenance?.modelID == nil, "Демантованный акт не имеет права ссылаться на модель")
        }
        // Реєстр чесний: llm=2, реплікою=2
        #expect(demoted.summary.contains("llm=2"))
        #expect(demoted.summary.contains("реплікою=2"))
    }

    @Test("An over-long LLM title is demoted act by act even when the quote is real")
    func testTitleLengthGateDemotesAct() async throws {
        // Все цитаты настоящие: падать должен именно гейт длины названия, и только тот акт
        let tooLong = "Никто не знает главного правила этой игры за столом"
        let alsoLong = String(repeating: "Держись и стой на своём рубеже ", count: 4)
        let json = """
            {"acts":[\
            {"type":"hook","title":"\(tooLong)","dramaticBeat":"Герой впервые слышит закон стола.","quotedLine":"\(Self.runs[0][0])"},\
            {"type":"downfall","title":"\(alsoLong)","dramaticBeat":"Ставка проиграна, признание поздно.","quotedLine":"\(Self.runs[1][0])"},\
            {"type":"struggle","title":"Смотреть вперед","dramaticBeat":"Последний рубеж держат руками.","quotedLine":"\(Self.runs[2][0])"},\
            {"type":"catharsis","title":"Цена свободе","dramaticBeat":"Выигрыш обменян на ясность.","quotedLine":"\(Self.runs[3][0])"}]}
            """
        #expect(tooLong.count > LongformActTitleService.maxTitleGraphemes)
        #expect(alsoLong.count > LongformActTitleService.maxTitleGraphemes)

        let film = fixture()
        let outcome = await LongformActTitleService(model: StubModel(ready: true, response: json))
            .applyTitles(to: film.arc, transcript: film.transcript, movieTitle: "X", progress: nil)

        #expect(outcome.arc.acts.map(\.effectiveTitleSource) == [
            .transcriptLine, .transcriptLine, .llm, .llm
        ])
        for act in outcome.arc.acts {
            #expect(!act.title.isEmpty)
            #expect(act.title.count <= LongformActTitleService.maxTitleGraphemes)
        }
        // Демонтированные акты названы их же репликами, а не шаблоном
        #expect(Self.runs[0].contains(where: { $0.hasPrefix(outcome.arc.acts[0].title) }))
        #expect(Self.runs[1].contains(where: { $0.hasPrefix(outcome.arc.acts[1].title) }))
    }

    @Test("Grounded LLM titles keep evidence and model identity")
    func testGroundedLLMTitlesKeepProvenance() async throws {
        let film = fixture()
        let outcome = await LongformActTitleService(model: StubModel(ready: true, response: Self.groundedJSON))
            .applyTitles(to: film.arc, transcript: film.transcript, movieTitle: "X", progress: nil)
        for (index, act) in outcome.arc.acts.enumerated() {
            let provenance = try #require(act.titleProvenance)
            #expect(provenance.source == .llm)
            #expect(provenance.modelID == "stub-9b")
            if let evidence = provenance.evidence {
                #expect(Self.runs[index].contains(evidence))
            } else {
                Issue.record("evidence is nil for act \(index)")
            }
            #expect(act.title == ["Правило игры", "Своя ошибка", "Смотреть вперед", "Цена свободе"][index])
        }
        // markdown-обёртка и «проза вокруг JSON» не ломают разбор
        let wrapped = "Вот результат:\n```json\n" + Self.groundedJSON + "\n```"
        #expect(LongformActTitleService.parseActTitleProposals(from: wrapped) != nil)
    }

    // MARK: - Политика RAM

    @Test("A cold Director is never woken for titles: not-ready model is not called")
    func testNotReadyModelIsNeverUsed() async throws {
        let film = fixture()
        // Заглушка готова ОТДАТЬ валидный ответ, но не «прогрета»: если service всё же
        // её спросит, акты получили бы метку .llm — и этот тест упадёт.
        let outcome = await LongformActTitleService(model: StubModel(ready: false, response: Self.groundedJSON))
            .applyTitles(to: film.arc, transcript: film.transcript, movieTitle: "X", progress: nil)
        #expect(outcome.arc.acts.map(\.effectiveTitleSource)
                == Array(repeating: ActTitleSource.transcriptLine, count: 4))
        #expect(outcome.summary.contains("не прогрітий"))
        // И без подключённого шлюза — то же поведение, молчаливого шаблона нет
        let offline = await LongformActTitleService()
            .applyTitles(to: film.arc, transcript: film.transcript, movieTitle: "X", progress: nil)
        #expect(offline.arc.acts.map(\.effectiveTitleSource)
                == Array(repeating: ActTitleSource.transcriptLine, count: 4))
    }

    @Test("Template tier survives only where the act has no dialogue at all")
    func testActsWithoutDialogueFallToTemplateTier() async throws {
        let empty = Transcript(segments: [], language: "ru", provenance: .whisper)
        let director = LongformNarrativeDirector()
        let synthetic = try await director.buildArc(
            from: empty,
            concept: Self.concept(),
            movieTitle: "Синтетический полный метр",
            targetDuration: 520.0
        )
        let outcome = await LongformActTitleService()
            .applyTitles(to: synthetic, transcript: empty, movieTitle: "X", progress: nil)
        let descriptors = director.adaptiveActDescriptors(for: Self.concept())
        for (index, act) in outcome.arc.acts.enumerated() {
            #expect(act.effectiveTitleSource == .template)
            #expect(act.title == descriptors[index].title)
            #expect(act.titleProvenance?.evidence == nil)
        }
    }

    // MARK: - Материал акта

    @Test("Act material is only its own dialogue, thinned chronologically, never head-cut")
    func testActMaterialCoversWholeActWhenThinned() {
        // Строки РАЗНЫЕ: иначе «хвост выжил» нельзя отличить от `prefix(_:)`
        let lines = (0..<60).map { index in
            "Один \(index). " + String(repeating: "принцип работает без исключений ", count: 5)
        }
        let act = LongformAct(
            type: .struggle,
            title: "Заготовка",
            dramaticBeat: "Заготовка",
            segments: [TimeSegment(start: 0, end: 600)]
        )
        let transcript = Transcript(
            segments: lines.enumerated().map { index, text in
                TranscriptSegment(start: Double(index) * 10, end: Double(index) * 10 + 9.6, text: text, words: [])
            },
            language: "ru",
            provenance: .whisper
        )
        let dialogue = LongformActTitleService.actDialogue(act: act, transcript: transcript)
        let block = LongformActTitleService.actMaterialBlock(
            actIndex: 3,
            act: act,
            lines: dialogue,
            cap: LongformActTitleService.actMaterialCapChars
        )
        #expect(dialogue.count == 60)
        #expect(block.stride > 1)
        #expect(block.block.count <= LongformActTitleService.actMaterialCapChars + 60)
        // Хвост обязано видеть: `prefix(_:)` отрезал бы финал акта и акт IV остался бы без названия
        #expect(block.block.contains("Один 0."))
        #expect(block.block.contains("Один 59."))
        #expect(block.block.contains("АКТ IV"))
        // Акт без диалогов помечен явно, а не оставлен пустым промптом для модели
        let wordless = LongformActTitleService.actMaterialBlock(
            actIndex: 0,
            act: LongformAct(type: .hook, title: "T", dramaticBeat: "B", segments: []),
            lines: [],
            cap: LongformActTitleService.actMaterialCapChars
        )
        #expect(wordless.block.contains("немає реплік"))
    }

    @Test("Act dialogue uses the overlap test, not containment")
    func testActDialogueTakesOverlappingPhrases() {
        let transcript = Transcript(
            segments: [
                TranscriptSegment(start: 95.0, end: 105.0, text: "Реплика на стыке сегментов.", words: []),
                TranscriptSegment(start: 200.0, end: 210.0, text: "Вне акта.", words: [])
            ],
            language: "ru",
            provenance: .whisper
        )
        let act = LongformAct(
            type: .hook,
            title: "Заготовка",
            dramaticBeat: "Заготовка",
            segments: [TimeSegment(start: 100, end: 140)]
        )
        #expect(LongformActTitleService.actDialogue(act: act, transcript: transcript)
                == ["Реплика на стыке сегментов."])
    }

    // MARK: - Парсер

    @Test("Parser demands four canonical acts and returns nil otherwise")
    func testParserRejectsMalformedShapes() {
        #expect(LongformActTitleService.parseActTitleProposals(from: Self.groundedJSON) != nil)
        // Голый массив — тоже валидная форма ответа
        let arrayOnly = Self.groundedJSON
            .replacingOccurrences(of: "{\"acts\":[", with: "[")
            .replacingOccurrences(of: "]}", with: "]")
        #expect(LongformActTitleService.parseActTitleProposals(from: arrayOnly)?.count == 4)
        // Три акта вместо четырёх
        let three = Self.groundedJSON.components(separatedBy: ",{\"type\":\"catharsis\"")[0] + "]}"
        #expect(LongformActTitleService.parseActTitleProposals(from: three) == nil)
        // Нарушенный канонический порядок типов
        let swapped = Self.groundedJSON
            .replacingOccurrences(of: "\"type\":\"hook\"", with: "\"type\":\"catharsis\"")
        #expect(LongformActTitleService.parseActTitleProposals(from: swapped) == nil)
        // Проза вместо JSON
        #expect(LongformActTitleService.parseActTitleProposals(from: "Акты: 1) Хук 2) Падение") == nil)
        // Пустое название
        let emptyTitle = Self.groundedJSON
            .replacingOccurrences(of: "\"title\":\"Правило игры\"", with: "\"title\":\"  \"")
        #expect(LongformActTitleService.parseActTitleProposals(from: emptyTitle) == nil)
        // Нет quotedLine — нечего проверять гейтом
        let noQuote = Self.groundedJSON
            .replacingOccurrences(of: ",\"quotedLine\":\"Теперь я понимаю цену этой свободе.\"", with: "")
        #expect(LongformActTitleService.parseActTitleProposals(from: noQuote) == nil)
    }

    // MARK: - Архивы и идентичность

    @Test("Legacy arc archive without the provenance field decodes as nil, never as LLM")
    func testLegacyArchiveDecodesWithNilProvenance() async throws {
        let film = fixture()
        let outcome = await LongformActTitleService(model: StubModel(ready: true, response: Self.groundedJSON))
            .applyTitles(to: film.arc, transcript: film.transcript, movieTitle: "X", progress: nil)

        let data = try JSONEncoder().encode(outcome.arc)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var stripped = object
        var acts = object["acts"] as? [[String: Any]]
        #expect(acts != nil)
        acts = acts?.map { act in
            var mutable = act
            mutable.removeValue(forKey: "titleProvenance")
            return mutable
        }
        stripped["acts"] = acts
        let legacyData = try JSONSerialization.data(withJSONObject: stripped)
        let decoded = try JSONDecoder().decode(LongformNarrativeArc.self, from: legacyData)

        #expect(decoded.acts.count == 4)
        for act in decoded.acts {
            #expect(act.titleProvenance == nil)
            // nil из архива — это «источник не зафиксирован», а не «его выбрала модель»
            #expect(act.effectiveTitleSource == .unknown)
            #expect(!act.effectiveTitleSource.isTrustworthy)
        }
        // Круг обратно: provenance выживает в encode/decode
        let roundTripped = try JSONDecoder().decode(
            LongformNarrativeArc.self,
            from: try JSONEncoder().encode(outcome.arc)
        )
        #expect(roundTripped.acts.map(\.titleProvenance) == outcome.arc.acts.map(\.titleProvenance))
    }

    @Test("Act identity (`id`) is derived, not encoded, and stable across rebuilds")
    func testActIdentityStableAcrossRebuildPaths() async throws {
        let film = fixture()
        let before = Set(film.arc.acts.map(\.id))
        #expect(before.count == 4)

        let outcome = await LongformActTitleService(model: StubModel(ready: true, response: Self.groundedJSON))
            .applyTitles(to: film.arc, transcript: film.transcript, movieTitle: "X", progress: nil)
        let after = outcome.arc.acts.map(\.id)
        // id = type + title: меняются только вместе с названием, дубли невозможны
        #expect(Set(after).count == 4)
        #expect(after == outcome.arc.acts.map { "\($0.type.rawValue)_\($0.title)" })

        // Путь пересборки в редакторе (правятся только тайминги, название read-only) — идемпотентен
        let rebuilt = outcome.arc.acts.map { act in
            LongformAct(
                type: act.type,
                title: act.title,
                dramaticBeat: act.dramaticBeat,
                segments: act.segments.map { TimeSegment(start: $0.start + 0.5, end: $0.end - 0.5) },
                titleProvenance: act.titleProvenance
            )
        }
        #expect(Set(rebuilt.map(\.id)) == Set(after))
        #expect(rebuilt.map(\.titleProvenance) == outcome.arc.acts.map(\.titleProvenance))
    }

    // MARK: - Детерминированный путь

    @Test("Fallback title is a real line and always fits the act card")
    func testFallbackTitleTruncation() {
        let short = LongformActTitleService.truncateToTitleCards("Короткая реплика.")
        #expect(short == "Короткая реплика.")
        let long = LongformActTitleService.truncateToTitleCards(String(repeating: "а", count: 120))
        #expect(long.count == LongformActTitleService.maxTitleGraphemes)
        #expect(long.hasSuffix("…"))
    }

    @Test("Metadata title selection is stable across processes (no hashValue reseeding)")
    func testMetadataTitleIsDeterministic() {
        let first = LongformMetadataGenerator.stableHash("Иллюзия")
        let second = LongformMetadataGenerator.stableHash("Иллюзия")
        #expect(first == second)
        #expect(first >= 0)
        #expect(LongformMetadataGenerator.stableHash("Жадность") != first)

        let arc = fixture().arc
        let concept = Self.concept(word: "Иллюзия")
        let a = LongformMetadataGenerator.generate(movieTitle: "X", concept: concept, arc: arc)
        let b = LongformMetadataGenerator.generate(movieTitle: "X", concept: concept, arc: arc)
        #expect(a.title == b.title)
        // Чаптеры уже используют act.title — названию акта больше не нужно быть константой
        #expect(a.description.contains(arc.acts[0].title))
    }
}
