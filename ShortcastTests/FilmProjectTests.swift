import Testing
import Foundation
@testable import Shortcast

@Suite("FilmProject Tests")
struct FilmProjectTests {

    @Test("Project serialization and deserialization preserves full state")
    func testSerialization() throws {
        let testURL = URL(fileURLWithPath: "/tmp/interstellar.mp4")
        let concept = ThematicConcept(
            word: "ТЕРПІННЯ",
            tagline: "Испытание расстоянием и временем",
            philosophicalPremise: "Идеально раскрывает лейтмотив Купера через жертву временем",
            suggestedTitle: "Почему время — самое безжалостное измерение",
            accentColorHex: "#F5D020"
        )

        let candidate = ClipCandidate(
            start: 120.0,
            end: 175.0,
            why: "Кульминационный диалог о гравитации",
            hook: "Он понял это только спустя 20 лет...",
            overlay: "Тайная комната"
        )

        let project = FilmProject(
            sourceMovieURL: testURL,
            movieFileName: "interstellar.mp4",
            movieTitle: "Интерстеллар",
            movieYear: "2014",
            durationSeconds: 10140.0,
            discoveredConcepts: [concept],
            selectedConcept: concept,
            candidates: [candidate]
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(project)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(FilmProject.self, from: data)

        #expect(restored.movieTitle == "Интерстеллар")
        #expect(restored.movieYear == "2014")
        #expect(restored.discoveredConcepts.count == 1)
        #expect(restored.discoveredConcepts.first?.word == "ТЕРПІННЯ")
        #expect(restored.candidates.count == 1)
        #expect(restored.candidates.first?.hook == "Он понял это только спустя 20 лет...")
    }

    @Test("FilmProjectService can save, load, and delete projects in custom storage")
    func testServiceStorage() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let service = FilmProjectService(storageDirectory: tempDir)

        let testURL = URL(fileURLWithPath: "/movies/whiplash.mkv")
        let project = FilmProject(
            sourceMovieURL: testURL,
            movieFileName: "whiplash.mkv",
            movieTitle: "Одержимость",
            durationSeconds: 6400.0
        )

        try await service.saveProject(project)

        let loaded = try await service.loadProject(for: testURL)
        #expect(loaded != nil)
        #expect(loaded?.movieTitle == "Одержимость")

        let all = try await service.listRecentProjects()
        #expect(all.count == 1)

        try await service.deleteProject(id: project.id)
        let afterDelete = try await service.loadProject(for: testURL)
        #expect(afterDelete == nil)

        try? FileManager.default.removeItem(at: tempDir)
    }

    @Test("FilmProjectService loads project even if sourceMovieURL was deleted or file moved")
    func testMovedFileLoad() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let service = FilmProjectService(storageDirectory: tempDir)

        let oldURL = URL(fileURLWithPath: "/old/temp/input/Revolver.mkv")
        let project = FilmProject(
            sourceMovieURL: oldURL,
            movieFileName: "Revolver",
            movieTitle: "Револьвер",
            durationSeconds: 6700.0,
            fileSizeBytes: 8589934592
        )
        try await service.saveProject(project)

        // Incoming file is at completely different path
        let newURL = URL(fileURLWithPath: "/Users/se1dhe/Movies/Revolver.mkv")
        let loaded = try await service.loadProject(for: newURL)
        #expect(loaded != nil)
        #expect(loaded?.movieTitle == "Револьвер")

        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Helpers

    private func tempStorage() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func concept(_ word: String, reasoning: String, source: ThematicSource = .llm) -> ThematicConcept {
        ThematicConcept(
            word: word,
            tagline: "Сквозной лейтмотив «\(word)».",
            philosophicalPremise: "Цена «\(word)» измеряется только потерей.",
            suggestedTitle: "Ты поймёшь «\(word)», когда станет поздно.",
            aiReasoning: reasoning,
            source: source
        )
    }

    private func renderResult() -> LongformBuildResult {
        let essayConcept = concept("СУБ'ЄКТИВНІСТЬ", reasoning: "Герой путает наблюдение с участием.")
        let arc = LongformNarrativeArc(
            movieTitle: "Суб'єктивність",
            concept: essayConcept,
            acts: [
                LongformAct(type: .hook, title: "Хук и Тезис", dramaticBeat: "Тезис", segments: [TimeSegment(start: 0, end: 12.5)]),
                LongformAct(type: .catharsis, title: "Катарсис и Прорыв", dramaticBeat: "Прорыв", segments: [TimeSegment(start: 180.0, end: 193.6)])
            ],
            summary: "Эссе о том, что наблюдатель всегда соучастник."
        )
        return LongformBuildResult(
            outputURL: URL(fileURLWithPath: "/Exports/Субъективность/longform_субъективность_262965.mp4"),
            arc: arc,
            metadata: LongformYouTubeMetadata(
                title: "Ты наблюдаешь — и уже участвуешь",
                description: "Эссе о субъективности.",
                tags: ["кино-эссе", "суб'єктивність"],
                pinnedComment: "А ты заметил, что выбираешь кадр, а не сюжет?"
            ),
            duration: 193.6,
            thumbnailURL: URL(fileURLWithPath: "/Exports/Субъективность/thumbnail_субъективность_262965.jpg")
        )
    }

    // MARK: - D6: последний рендер обязан переживать сохранение

    @Test("longformResult round trips through the project archive")
    func testLongformResultRoundTrip() async throws {
        let tempDir = tempStorage()
        let service = FilmProjectService(storageDirectory: tempDir)
        let movieURL = URL(fileURLWithPath: "/movies/subjektivnost.mp4")
        let result = renderResult()
        let analysis = ThematicAnalysisResult(
            primaryConcept: result.arc.concept,
            aiReasoning: "Герой путает наблюдение с участием.",
            source: .llm
        )

        let project = FilmProject(
            sourceMovieURL: movieURL,
            movieFileName: "subjektivnost",
            movieTitle: "Суб'єктивність",
            durationSeconds: 6000,
            thematicAnalysis: analysis,
            selectedConcept: result.arc.concept,
            longformResult: result
        )
        try await service.saveProject(project)

        let loaded = try await service.loadProject(for: movieURL)
        let restored = try #require(loaded)
        let restoredResult = try #require(restored.longformResult)
        #expect(restoredResult == result)
        #expect(restoredResult.arc == result.arc)
        #expect(restoredResult.duration == 193.6)
        #expect(restoredResult.thumbnailURL == result.thumbnailURL)
        #expect(restoredResult.outputURL == result.outputURL)
        #expect(restored.decodeDamage.isEmpty)
        #expect(service.corruptedProjectCount == 0)

        try? FileManager.default.removeItem(at: tempDir)
    }

    @Test("an archive without a longformResult key still decodes exactly as before")
    func testLegacyArchiveWithoutLongformResultKey() async throws {
        let tempDir = tempStorage()
        let service = FilmProjectService(storageDirectory: tempDir)
        let movieURL = URL(fileURLWithPath: "/movies/subjektivnost.mp4")

        let project = FilmProject(
            sourceMovieURL: movieURL,
            movieFileName: "subjektivnost",
            movieTitle: "Суб'єктивність",
            durationSeconds: 6000
        )
        try await service.saveProject(project)

        let archiveURL = tempDir.appendingPathComponent("\(project.id.uuidString).shortcastproj")
        let raw = try String(data: Data(contentsOf: archiveURL), encoding: .utf8)
        #expect(raw?.contains("\"longformResult\"") == false)

        let loaded = try await service.loadProject(for: movieURL)
        let restored = try #require(loaded)
        #expect(restored.longformResult == nil)
        #expect(restored.decodeDamage.isEmpty)
        #expect(service.corruptedProjectCount == 0)

        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - D5: битый архив не имеет права исчезать молча

    @Test("a missing scenes key is legacy, a broken scenes value is damage the project survives")
    func testScenesArrayCannotEraseTheProject() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let withoutScenes = """
        {
          "id": "ED083F8F-DDA9-47B6-B701-ACF61C7D675D",
          "sourceMovieURL": "file:///movies/subjektivnost.mp4",
          "movieFileName": "subjektivnost",
          "movieTitle": "Суб'єктивність",
          "durationSeconds": 6000,
          "candidates": [],
          "createdAt": "2026-10-05T10:00:00Z",
          "updatedAt": "2026-10-05T10:05:00Z"
        }
        """
        let legacy = try decoder.decode(FilmProject.self, from: Data(withoutScenes.utf8))
        #expect(legacy.movieTitle == "Суб'єктивність")
        #expect(legacy.scenes.isEmpty)
        #expect(legacy.decodeDamage.isEmpty)

        let brokenScenes = """
        {
          "id": "ED083F8F-DDA9-47B6-B701-ACF61C7D675D",
          "sourceMovieURL": "file:///movies/subjektivnost.mp4",
          "movieFileName": "subjektivnost",
          "movieTitle": "Суб'єктивність",
          "durationSeconds": 6000,
          "scenes": "здесь должен был быть массив сцен",
          "candidates": [],
          "createdAt": "2026-10-05T10:00:00Z",
          "updatedAt": "2026-10-05T10:05:00Z"
        }
        """
        let damaged = try decoder.decode(FilmProject.self, from: Data(brokenScenes.utf8))
        #expect(damaged.scenes.isEmpty)
        #expect(damaged.movieTitle == "Суб'єктивність")
        #expect(damaged.decodeDamage == ["scenes"])
    }

    @Test("a damaged archive is counted by the service instead of vanishing from it")
    func testDamagedArchiveIsCountedAndListed() async throws {
        let tempDir = tempStorage()
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let service = FilmProjectService(storageDirectory: tempDir)

        let movieURL = URL(fileURLWithPath: "/movies/subjektivnost.mp4")
        let good = FilmProject(
            sourceMovieURL: movieURL,
            movieFileName: "subjektivnost",
            movieTitle: "Суб'єктивність",
            durationSeconds: 6000
        )
        try await service.saveProject(good)

        let damagedID = UUID()
        let damagedJSON = """
        {
          "id": "\(damagedID.uuidString)",
          "sourceMovieURL": "file:///movies/other.mp4",
          "movieFileName": "other",
          "movieTitle": "Другой фильм",
          "durationSeconds": 5200,
          "scenes": {"не": "массив"},
          "discoveredConcepts": [],
          "candidates": [],
          "createdAt": "2026-10-05T10:00:00Z",
          "updatedAt": "2026-10-05T10:05:00Z"
        }
        """
        try Data(damagedJSON.utf8).write(to: tempDir.appendingPathComponent("\(damagedID.uuidString).shortcastproj"))

        let all = try await service.listRecentProjects()
        #expect(all.count == 2)
        let damaged = try #require(all.first { $0.id == damagedID })
        #expect(damaged.scenes.isEmpty)
        #expect(damaged.decodeDamage == ["scenes"])
        #expect(service.corruptedProjectCount == 1)

        try? FileManager.default.removeItem(at: tempDir)
    }

    @Test("one unreadable archive does not take the readable project down with it")
    func testTruncatedArchiveIsLoggedAndCounted() async throws {
        let tempDir = tempStorage()
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let service = FilmProjectService(storageDirectory: tempDir)

        let movieURL = URL(fileURLWithPath: "/movies/whiplash.mkv")
        let good = FilmProject(
            sourceMovieURL: movieURL,
            movieFileName: "whiplash",
            movieTitle: "Одержимость",
            durationSeconds: 6400
        )
        try await service.saveProject(good)

        let truncatedID = UUID()
        let full = try JSONEncoder().encode(good)
        try Data(full.prefix(40)).write(to: tempDir.appendingPathComponent("\(truncatedID.uuidString).shortcastproj"))

        let all = try await service.listRecentProjects()
        #expect(all.count == 1)
        #expect(all.first?.movieTitle == "Одержимость")
        #expect(service.corruptedProjectCount == 1)

        try? FileManager.default.removeItem(at: tempDir)
    }

    @Test("an unreadable archive still blocks a blank project from overwriting it")
    func testUnreadableArchiveIsStillAStoredProject() async throws {
        let tempDir = tempStorage()
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let service = FilmProjectService(storageDirectory: tempDir)
        let movieURL = URL(fileURLWithPath: "/movies/subjektivnost.mp4")

        let noneStored = await service.hasStoredProjectFile(matching: movieURL)
        #expect(noneStored == false)

        // Одно нераскладываемое поле — и весь проект раньше пропадал из списка.
        let brokenID = UUID()
        let brokenJSON = """
        {
          "id": "\(brokenID.uuidString)",
          "sourceMovieURL": "file:///movies/subjektivnost.mp4",
          "movieFileName": "subjektivnost",
          "movieTitle": "Суб'єктивність",
          "durationSeconds": "не число",
          "scenes": [],
          "candidates": [],
          "createdAt": "2026-10-05T10:00:00Z",
          "updatedAt": "2026-10-05T10:05:00Z"
        }
        """
        try Data(brokenJSON.utf8).write(to: tempDir.appendingPathComponent("\(brokenID.uuidString).shortcastproj"))

        let loaded = try await service.loadProject(for: movieURL)
        #expect(loaded == nil)
        let stillStored = await service.hasStoredProjectFile(matching: movieURL)
        #expect(stillStored == true)
        #expect(service.corruptedProjectCount == 1)

        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - D5: единый источник правды о теме

    @Test("persisted theme state can no longer contradict itself (D5 repro)")
    @MainActor
    func testThemeStateIsPersistedAsOnePiece() async throws {
        let tempDir = tempStorage()
        let service = FilmProjectService(storageDirectory: tempDir)
        let movieURL = URL(fileURLWithPath: "/movies/subjektivnost.mp4")
        let seed = FilmProject(
            sourceMovieURL: movieURL,
            movieFileName: "subjektivnost",
            movieTitle: "Суб'єктивність",
            durationSeconds: 6000
        )
        try await service.saveProject(seed)

        // Генерация A — разбор, который лежит в архиве.
        let analysisA = ThematicAnalysisResult(
            primaryConcept: concept("Ілюзія", reasoning: "Разбор A: наблюдатель соучастник."),
            aiReasoning: "Разбор A: наблюдатель соучастник.",
            alternativeConcepts: [concept("ПАМЯТЬ", reasoning: "Разбор A: память переписывает выбор.")],
            source: .llm
        )
        // Генерация B — тема из другого прогона Director.
        let conceptB = concept("ГЕНИАЛЬНОСТЬ", reasoning: "Разбор B: талант как наказание.")

        let workspace = WorkspaceModel(filmProjectService: service)
        let stored = try await service.loadProject(for: movieURL)
        workspace.currentProject = try #require(stored)
        workspace.thematicAnalysis = analysisA
        workspace.selectedConcept = conceptB

        // Производные переменные больше не могут жить своей жизнью.
        #expect(workspace.thematicReasoning == analysisA.aiReasoning)
        #expect(workspace.discoveredConcepts == analysisA.allConcepts)

        await workspace.persistThemeState(reason: "тест D5")

        let archived = try await service.loadProject(for: movieURL)
        let reloaded = try #require(archived)
        #expect(reloaded.thematicAnalysis == analysisA)
        #expect(reloaded.selectedConcept == conceptB)
        #expect(reloaded.discoveredConcepts == analysisA.allConcepts)
        #expect(reloaded.longformResult == nil)

        // Модель, собранная вокруг этого архива, отвечает тем же анализом.
        let restored = WorkspaceModel(filmProjectService: service)
        restored.thematicAnalysis = reloaded.thematicAnalysis
        restored.selectedConcept = reloaded.selectedConcept
        #expect(restored.thematicReasoning == analysisA.aiReasoning)
        #expect(restored.discoveredConcepts == analysisA.allConcepts)
        #expect(restored.thematicAnalysis?.source.isTrustworthy == true)

        try? FileManager.default.removeItem(at: tempDir)
    }

    @Test("startOver clears the essay so the next film cannot inherit its theme")
    @MainActor
    func testStartOverClearsEssayState() {
        let workspace = WorkspaceModel(filmProjectService: FilmProjectService(storageDirectory: tempStorage()))
        let analysis = ThematicAnalysisResult(
            primaryConcept: concept("Ілюзія", reasoning: "Разбор A."),
            aiReasoning: "Разбор A.",
            source: .llm
        )
        workspace.thematicAnalysis = analysis
        workspace.selectedConcept = analysis.primaryConcept
        workspace.longformResult = renderResult()
        workspace.stagedConcept = analysis.primaryConcept
        workspace.stagedConfirmedMovieTitle = "Суб'єктивність"
        workspace.stagedAudioSettings = LongformAudioSettings()
        workspace.stagedArc = renderResult().arc
        workspace.currentProject = FilmProject(
            sourceMovieURL: URL(fileURLWithPath: "/movies/subjektivnost.mp4"),
            movieFileName: "subjektivnost",
            movieTitle: "Суб'єктивність"
        )

        workspace.startOver()

        #expect(workspace.phase == .empty)
        #expect(workspace.thematicAnalysis == nil)
        #expect(workspace.selectedConcept == nil)
        #expect(workspace.longformResult == nil)
        #expect(workspace.thematicReasoning == nil)
        #expect(workspace.discoveredConcepts.isEmpty)
        #expect(workspace.stagedConcept == nil)
        #expect(workspace.stagedConfirmedMovieTitle == nil)
        #expect(workspace.stagedAudioSettings == nil)
        #expect(workspace.stagedArc == nil)
        #expect(workspace.currentProject == nil)
    }

    @Test("nothing invents a theme, a reasoning or a provenance the Director has not produced")
    @MainActor
    func testNoInventedProvenance() async throws {
        #expect(ThematicSource.llm.isTrustworthy == true)
        #expect(ThematicSource.manual.isTrustworthy == true)
        #expect(ThematicSource.unknown.isTrustworthy == false)

        let decoder = JSONDecoder()
        let legacyConceptJSON = """
        {
          "word": "ДОЛГ",
          "tagline": "Выбор, который ты не делал, но от которого не отвертишься.",
          "philosophicalPremise": "Свобода без ответственности — это малодушие.",
          "suggestedTitle": "Ты думаешь, что выбрал. Тебя выбрали."
        }
        """
        let legacy = try decoder.decode(ThematicConcept.self, from: Data(legacyConceptJSON.utf8))
        #expect(legacy.source == .unknown)
        #expect(legacy.source.isTrustworthy == false)

        let tempDir = tempStorage()
        let service = FilmProjectService(storageDirectory: tempDir)
        let movieURL = URL(fileURLWithPath: "/movies/subjektivnost.mp4")
        let workspace = WorkspaceModel(filmProjectService: service)
        workspace.currentProject = FilmProject(
            sourceMovieURL: movieURL,
            movieFileName: "subjektivnost",
            movieTitle: "Суб'єктивність",
            durationSeconds: 6000
        )

        // Без анализа экрану нечем соврать: ни разбора, ни тем.
        #expect(workspace.thematicAnalysis == nil)
        #expect(workspace.thematicReasoning == nil)
        #expect(workspace.discoveredConcepts.isEmpty)

        await workspace.persistThemeState(reason: "тест провенанса")

        let archived = try await service.loadProject(for: movieURL)
        let reloaded = try #require(archived)
        #expect(reloaded.thematicAnalysis == nil)
        #expect(reloaded.selectedConcept == nil)
        #expect(reloaded.discoveredConcepts.isEmpty)
        #expect(reloaded.longformResult == nil)

        try? FileManager.default.removeItem(at: tempDir)
    }
}
