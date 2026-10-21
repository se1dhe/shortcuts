import Testing
import Foundation
@testable import Shortcast

/// Тесты сохранения longformResult/transcript и проброса модели в LongformActTitleService.
/// Все тесты герметичны: ни модель, ни Whisper не вызываются.
@MainActor
@Suite("Persistence & Model Injection Tests")
struct PersistenceAndModelInjectionTests {

    // MARK: - Утилиты

    /// Временный каталог для архива проектов; удаляется в конце теста.
    private static func makeTempStorage() -> (URL, FilmProjectService) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return (tempDir, FilmProjectService(storageDirectory: tempDir))
    }

    private static func concept(word: String = "ТЕРПЕНИЕ") -> ThematicConcept {
        ThematicConcept(
            word: word,
            tagline: "Испытание временем",
            philosophicalPremise: "Время — самое безжалостное измерение",
            suggestedTitle: "Почему время не ждёт",
            accentColorHex: "#F5D020"
        )
    }

    private static func transcript() -> Transcript {
        Transcript(
            segments: [
                TranscriptSegment(start: 0.0, end: 5.0, text: "Первая реплика", words: []),
                TranscriptSegment(start: 5.0, end: 10.0, text: "Вторая реплика", words: [])
            ],
            language: "ru",
            provenance: .whisper
        )
    }

    private static func buildResult(concept: ThematicConcept) -> LongformBuildResult {
        let act = LongformAct(
            type: .hook,
            title: "Начало",
            dramaticBeat: "Завязка",
            segments: [TimeSegment(start: 0, end: 30)]
        )
        let arc = LongformNarrativeArc(
            movieTitle: "Бегущий по лезвию 2049",
            concept: concept,
            acts: [act],
            summary: "Тестовая арка"
        )
        return LongformBuildResult(
            outputURL: URL(fileURLWithPath: "/tmp/export.mp4"),
            arc: arc,
            metadata: LongformYouTubeMetadata(title: "", description: "", tags: [], pinnedComment: ""),
            duration: 300.0,
            thumbnailURL: nil
        )
    }

    // MARK: - Тест 1: после reopen проекта longformResult восстанавливается

    @Test("longformResult survives save → load cycle")
    func testLongformResultPersistence() async throws {
        let (tempDir, service) = Self.makeTempStorage()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourceURL = URL(fileURLWithPath: "/movies/blade_runner_2049.mp4")
        let concept = Self.concept()
        let result = Self.buildResult(concept: concept)
        let transcript = Self.transcript()

        // Сохраняем проект с longformResult и transcript
        var project = FilmProject(
            sourceMovieURL: sourceURL,
            movieFileName: "blade_runner_2049.mp4",
            movieTitle: "Бегущий по лезвию 2049",
            durationSeconds: 10140.0
        )
        project.longformResult = result
        project.transcript = transcript
        project.thematicAnalysis = ThematicAnalysisResult(
            primaryConcept: concept,
            aiReasoning: "Тестовый анализ",
            source: .llm
        )
        try await service.saveProject(project)

        // Перезагружаем — longformResult и transcript обязаны восстановиться
        let loaded = try await service.loadProject(for: sourceURL)
        #expect(loaded != nil)
        #expect(loaded?.longformResult != nil, "longformResult должен восстанавливаться после reopen")
        #expect(loaded?.longformResult?.outputURL == result.outputURL)
        #expect(loaded?.longformResult?.duration == result.duration)
        #expect(loaded?.transcript != nil, "transcript должен восстанавливаться после reopen")
        #expect(loaded?.transcript?.segments.count == transcript.segments.count)
        #expect(loaded?.thematicAnalysis?.source == .llm)
    }

    // MARK: - Тест 2: после редактирования субтитров правки сохраняются на диск

    @Test("edited subtitles persist through project save/load")
    func testEditedSubtitlesPersistence() async throws {
        let (tempDir, service) = Self.makeTempStorage()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourceURL = URL(fileURLWithPath: "/movies/movie.mp4")
        let originalTranscript = Self.transcript()

        var project = FilmProject(
            sourceMovieURL: sourceURL,
            movieFileName: "movie.mp4",
            movieTitle: "Фильм",
            durationSeconds: 6000.0
        )
        project.transcript = originalTranscript
        try await service.saveProject(project)

        // Имитируем редактирование субтитров: обновляем transcript и сохраняем
        let editedSegments = [
            TranscriptSegment(start: 0.0, end: 5.0, text: "ИСПРАВЛЕННАЯ первая реплика", words: []),
            TranscriptSegment(start: 5.0, end: 10.0, text: "ИСПРАВЛЕННАЯ вторая реплика", words: [])
        ]
        let editedTranscript = Transcript(
            segments: editedSegments,
            language: originalTranscript.language,
            provenance: originalTranscript.provenance
        )

        var loaded = try await service.loadProject(for: sourceURL)
        #expect(loaded != nil)
        loaded?.transcript = editedTranscript
        if let updated = loaded {
            try await service.saveProject(updated)
        }

        // Финальная перезагрузка: правки обязаны сохраниться
        let reloaded = try await service.loadProject(for: sourceURL)
        #expect(reloaded?.transcript?.segments.first?.text == "ИСПРАВЛЕННАЯ первая реплика")
        #expect(reloaded?.transcript?.segments.last?.text == "ИСПРАВЛЕННАЯ вторая реплика")
    }

    // MARK: - Тест 3: LongformActTitleService получает модель и генерирует LLM-заголовки

    @Test("LongformActTitleService uses injected model for LLM titles")
    func testActTitleServiceModelInjection() async {
        // Заглушка модели: возвращает валидный JSON с четырьмя актами
        struct InjectedStubModel: LongformActTitleModeling {
            var isReady: Bool { get async { true } }
            var modelID: String? { get async { "injected-stub-9b" } }
            func complete(instructions: String, prompt: String, maxTokens: Int) async -> String? {
                """
                {"acts":[
                  {"type":"hook","title":"Начало пути","dramaticBeat":"Герой входит в игру","quotedLine":"Первая реплика"},
                  {"type":"downfall","title":"Крах иллюзий","dramaticBeat":"Всё рушится","quotedLine":"Вторая реплика"},
                  {"type":"struggle","title":"Борьба","dramaticBeat":"Сопротивление","quotedLine":"Третья реплика"},
                  {"type":"catharsis","title":"Очищение","dramaticBeat":"Финал","quotedLine":"Четвёртая реплика"}
                ]}
                """
            }
        }

        let service = LongformActTitleService(model: InjectedStubModel())

        // Минимальная арка с четырьмя актами и диалогом, который модель может «найти»
        let concept = Self.concept()
        var acts: [LongformAct] = []
        var segments: [TranscriptSegment] = []
        let actTypes: [LongformActType] = [.hook, .downfall, .struggle, .catharsis]
        let lines = ["Первая реплика", "Вторая реплика", "Третья реплика", "Четвёртая реплика"]
        let starts: [Double] = [600, 2200, 4400, 7700]

        for (index, type) in actTypes.enumerated() {
            let start = starts[index]
            segments.append(TranscriptSegment(
                start: start, end: start + 10.0, text: lines[index], words: []
            ))
            acts.append(LongformAct(
                type: type,
                title: "Заготовка",
                dramaticBeat: "",
                segments: [TimeSegment(start: start, end: start + 60.0)]
            ))
        }
        let arc = LongformNarrativeArc(
            movieTitle: "Тестовый фильм",
            concept: concept,
            acts: acts,
            summary: "Тест"
        )
        let transcript = Transcript(segments: segments, language: "ru", provenance: .whisper)

        let outcome = await service.applyTitles(
            to: arc,
            transcript: transcript,
            movieTitle: "Тестовый фильм",
            progress: nil
        )

        // Модель была инжектирована и готова — все четыре акта должны получить LLM-заголовки
        let llmActs = outcome.arc.acts.filter { $0.titleProvenance?.source == .llm }
        #expect(llmActs.count == 4, "Все 4 акта должны получить LLM-заголовки от инжектированной модели")
        #expect(outcome.arc.acts[0].title == "Начало пути")
        #expect(outcome.arc.acts[3].title == "Очищение")
        #expect(outcome.summary.contains("injected-stub-9b"), "В summary должен быть идентификатор модели")
    }

    // MARK: - Тест 4: persistThemeState записывает transcript в проект

    @Test("persistThemeState writes transcript to project archive")
    func testPersistThemeStateWritesTranscript() async throws {
        let (tempDir, service) = Self.makeTempStorage()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourceURL = URL(fileURLWithPath: "/movies/test.mp4")
        let concept = Self.concept()
        let transcript = Self.transcript()
        let result = Self.buildResult(concept: concept)

        let workspace = WorkspaceModel(filmProjectService: service)
        workspace.currentProject = FilmProject(
            sourceMovieURL: sourceURL,
            movieFileName: "test.mp4",
            movieTitle: "Тест",
            durationSeconds: 100.0
        )
        workspace.storedTranscript = transcript
        workspace.thematicAnalysis = ThematicAnalysisResult(
            primaryConcept: concept,
            aiReasoning: "Тест",
            source: .llm
        )
        workspace.selectedConcept = concept
        workspace.longformResult = result

        await workspace.persistThemeState(reason: "test")

        let loaded = try await service.loadProject(for: sourceURL)
        #expect(loaded != nil)
        #expect(loaded?.transcript != nil, "persistThemeState обязан сохранить transcript")
        #expect(loaded?.transcript?.segments.count == transcript.segments.count)
        #expect(loaded?.longformResult != nil, "persistThemeState обязан сохранить longformResult")
        #expect(loaded?.thematicAnalysis?.source == .llm)
    }
}
