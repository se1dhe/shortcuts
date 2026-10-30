import Foundation
import Testing
@testable import Shortcast

@MainActor
@Suite("Essay selection quality")
struct EssaySelectionQualityTests {
    private func uiReplyFixture(_ attempt: Int) throws -> String {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/director-catalogue-ui-attempt\(attempt).txt")
        return try String(contentsOf: path, encoding: .utf8)
    }

    @Test func actualUISecondReplyWithUppercaseIDDecodesWithoutInventingScenes() throws {
        let segments = (0..<180).map { index in
            TranscriptSegment(start: Double(index * 60), end: Double(index * 60 + 30),
                              text: "Кожне рішення номер \(index) має ціну і наслідки.")
        }
        let catalogue = EssaySceneCatalogue(transcript: Transcript(segments: segments, language: "uk"))
        let analysis = try LongformThematicService.decodeCatalogueAnalysis(
            from: uiReplyFixture(2), catalogue: catalogue)
        #expect(analysis.selectedMoments.count == 15)
        #expect(analysis.selectedMoments.first?.startTime == catalogue.scenes[3].start)
        #expect(Set(analysis.selectedMoments.map(\.id)).count == 15)
        for moment in analysis.selectedMoments {
            #expect(catalogue.scenes.contains {
                $0.start == moment.startTime && $0.end == moment.endTime && $0.quote == moment.evidenceQuote
            })
        }
        do {
            _ = try LongformThematicService.decodeCatalogueAnalysis(
                from: uiReplyFixture(1), catalogue: catalogue)
            Issue.record("ответ с повторами сцен принят")
        } catch {
            #expect(error.localizedDescription.contains("повторно"))
        }
    }

    @Test func aliasesDoNotBypassCatalogueMembershipOrAllowAmbiguousIDs() throws {
        let (_, transcript) = fixture()
        let catalogue = EssaySceneCatalogue(transcript: transcript)
        let row: [String: Any] = ["SCENEID": "S0004", "actRole": "hook", "dramaticWeight": 0.9,
                                  "FEATURED": true, "supports": "Герой приймає наслідки"]
        #expect(try catalogue.decodeMoments(from: [row]).first?.startTime == catalogue.scenes[3].start)
        var unknown = row
        unknown["SCENEID"] = "S9999"
        #expect(throws: EssaySceneCatalogue.SelectionError.self) {
            try catalogue.decodeMoments(from: [unknown])
        }
        var ambiguous = row
        ambiguous["id"] = "S0007"
        #expect(throws: EssaySceneCatalogue.SelectionError.self) {
            try catalogue.decodeMoments(from: [ambiguous])
        }
    }
    private func fixture(word: String = "ВИБІР") -> (ThematicAnalysisResult, Transcript) {
        let concept = ThematicConcept(
            word: word, tagline: "Рішення має ціну", philosophicalPremise: "Вчинок змінює людину",
            suggestedTitle: "Ціна рішення", source: .llm)
        let roles = LongformActType.canonicalAnalyticOrder
        let moments: [SelectedMoment] = (0..<14).map { (index: Int) -> SelectedMoment in
            let start = Double(100 + index * 100)
            let role: LongformActType = index == 0 ? .hook : roles[1 + (index - 1) % 4]
            let quote = "Моє рішення номер \(index) має ціну"
            return SelectedMoment(
                startTime: start, endTime: start + 30,
                reason: "Герой приймає наслідки свого вчинку", dramaticWeight: 0.7,
                actRole: role,
                supports: "Рішення героя змінює його ставлення до інших",
                featured: false, evidenceQuote: quote)
        }
        let transcript = Transcript(segments: moments.enumerated().map { index, moment in
            TranscriptSegment(
                start: moment.startTime, end: moment.endTime,
                text: "Моє рішення номер \(index) має ціну. Вибір і відповідальність визначають наслідки.", words: [])
        }, language: "uk", provenance: .whisper)
        var plan = EssayPlan(
            thesis: "Вибір стає справжнім через відповідальність за наслідки",
            hookVariants: [.init(text: "Що змінює цей вчинок?", source: .llm)],
            actFocus: Dictionary(uniqueKeysWithValues: roles.dropFirst().map {
                ($0.promptKey, "Герой відповідає за наслідки рішення")
            }))
        plan.selectedHook = plan.hookVariants.first
        plan.hookReason = "Початок ставить питання, фінал показує наслідки"
        var analysis = ThematicAnalysisResult(
            primaryConcept: concept, aiReasoning: "Розвиток думки через рішення героя",
            selectedMoments: moments, essayPlan: plan, source: .llm,
            plannedConcept: concept)
        analysis.semanticProof = EssaySemanticProof(version: 1, theme: word,
            reason: "Рішення пов'язує початок і наслідки", hook: plan.selectedHook!.text,
            hookReason: plan.hookReason!, evidence: [1, 2, 5].map {
                EssaySemanticProof.Evidence(scene: $0, quote: moments[$0 - 1].evidenceQuote!)
            }, modelID: "test-model")
        return (ThematicAnalysisCache.binding(analysis, to: transcript), transcript)
    }

    @Test func actualQuotesInTheirTimeRangesPass() throws {
        let (analysis, transcript) = fixture()
        try EssaySceneEvidence.validate(analysis, transcript: transcript)
    }

    @Test func realQuoteAtWrongTimeIsRejected() {
        var (analysis, transcript) = fixture()
        let original = analysis.selectedMoments[0]
        analysis.selectedMoments[0] = replacing(original, quote: analysis.selectedMoments[1].evidenceQuote)
        #expect(throws: EssaySceneEvidence.InvalidSelection.self) {
            try EssaySceneEvidence.validate(analysis, transcript: transcript)
        }
    }

    @Test func inventedQuoteIsRejected() {
        var (analysis, transcript) = fixture()
        analysis.selectedMoments[0] = replacing(
            analysis.selectedMoments[0], quote: "Цю репліку ніхто не промовляв")
        #expect(throws: EssaySceneEvidence.InvalidSelection.self) {
            try EssaySceneEvidence.validate(analysis, transcript: transcript)
        }
    }

    @Test func duplicatesAndMissingActEvidenceAreRejected() {
        var (analysis, transcript) = fixture()
        analysis.selectedMoments[1] = analysis.selectedMoments[2]
        #expect(throws: EssaySceneEvidence.InvalidSelection.self) {
            try EssaySceneEvidence.validate(analysis, transcript: transcript)
        }
        analysis.selectedMoments.removeAll { $0.actRole == .philosophy }
        #expect(throws: EssaySceneEvidence.InvalidSelection.self) {
            try EssaySceneEvidence.validate(analysis, transcript: transcript)
        }
    }

    @Test func thinPoolCannotBePaddedWithUnselectedDialogue() {
        var (analysis, transcript) = fixture()
        analysis.selectedMoments = Array(analysis.selectedMoments.prefix(5))
        #expect(throws: EssaySceneEvidence.InvalidSelection.self) {
            try EssaySceneEvidence.validate(analysis, transcript: transcript)
        }
    }

    @Test func alternateThemeRequiresItsOwnPlan() async throws {
        let (cached, transcript) = fixture()
        let (fresh, _) = fixture(word: "ВІДПОВІДАЛЬНІСТЬ")
        var calls = 0
        let resolved = try await SelectedThemeAnalysisResolver.resolve(
            selection: fresh.primaryConcept, cached: cached, transcript: transcript,
            userPlan: cached.essayPlan
        ) {
            calls += 1
            return fresh
        }
        #expect(calls == 1)
        #expect(resolved.primaryConcept.word == fresh.primaryConcept.word)
        #expect(resolved.plannedConcept == fresh.primaryConcept)
    }

    @Test func verifiedPlanIsReusedAndSurvivesArchiveRoundTrip() async throws {
        let (analysis, transcript) = fixture()
        let decoded = try JSONDecoder().decode(
            ThematicAnalysisResult.self, from: JSONEncoder().encode(analysis))
        var replanned = false
        let result = try await SelectedThemeAnalysisResolver.resolve(
            selection: analysis.primaryConcept, cached: decoded, transcript: transcript, userPlan: nil
        ) {
            replanned = true
            return analysis
        }
        #expect(!replanned)
        #expect(result.selectedMoments == analysis.selectedMoments)
        #expect(result.plannedConcept == analysis.plannedConcept)
    }

    @Test func legacyPoolWithoutQuotesMustBeReanalysed() async throws {
        let (fresh, transcript) = fixture()
        var legacy = fresh
        legacy.selectedMoments = fresh.selectedMoments.map { replacing($0, quote: nil) }
        var calls = 0
        _ = try await SelectedThemeAnalysisResolver.resolve(
            selection: fresh.primaryConcept, cached: legacy, transcript: transcript, userPlan: nil
        ) {
            calls += 1
            return fresh
        }
        #expect(calls == 1)
    }

    @Test func plannerCannotSwitchBackToWinnerOrReuseItsHook() async throws {
        let (cached, transcript) = fixture()
        let (fresh, _) = fixture(word: "ВІДПОВІДАЛЬНІСТЬ")
        await #expect(throws: ThematicDiscoveryError.self) {
            try await SelectedThemeAnalysisResolver.resolve(
                selection: fresh.primaryConcept, cached: cached, transcript: transcript, userPlan: nil
            ) { cached }
        }
        var oldPlan = try #require(cached.essayPlan)
        oldPlan.selectedHook = .init(text: "Старий хук іншої теми", source: .llm)
        let result = try await SelectedThemeAnalysisResolver.resolve(
            selection: fresh.primaryConcept, cached: cached, transcript: transcript, userPlan: oldPlan
        ) { fresh }
        #expect(result.essayPlan?.chosenHookVariant?.text != oldPlan.selectedHook?.text)
    }

    @Test func replanningUsesModelHookAndPreservesManualThemeAuthorship() async throws {
        let (fresh, transcript) = fixture()
        var selection = fresh.primaryConcept
        selection.source = .manual
        selection.suggestedTitle = "Моя назва есе"
        let manualPlan = EssayPlan(selectedHook: .init(text: "Мій хук есе", source: .manual))
        let result = try await SelectedThemeAnalysisResolver.resolve(
            selection: selection, cached: nil, transcript: transcript, userPlan: manualPlan
        ) { fresh }
        #expect(result.primaryConcept.source == .manual)
        #expect(result.primaryConcept.suggestedTitle == selection.suggestedTitle)
        #expect(result.essayPlan?.chosenHookVariant == fresh.essayPlan?.selectedHook)
        #expect(result.plannedConcept == selection)
    }

    @Test func movingStrongestFinalSceneDoesNotDuplicateIt() {
        let (analysis, _) = fixture()
        let strongest = analysis.selectedMoments[4]
        let weaker = replacing(analysis.selectedMoments[8], quote: nil)
        // Legacy path used to duplicate the first catharsis scene when moving it.
        let strong = SelectedMoment(
            startTime: strongest.startTime, endTime: strongest.endTime,
            reason: strongest.reason, dramaticWeight: 0.99, actRole: .catharsis, featured: true)
        var buckets: [LongformActType: [SelectedMoment]] = [.catharsis: [strong, weaker]]
        LongformNarrativeDirector.promoteStrongestSceneToCatharsis(&buckets)
        #expect(buckets[.catharsis]?.count == 2)
        #expect(buckets[.catharsis]?.last == strong)
        #expect(buckets[.catharsis]?.reduce(0) { $0 + $1.endTime - $1.startTime } == 60)
    }

    @Test func verifiedScenesKeepTheirRolesAndProvenance() {
        let (analysis, _) = fixture()
        var strong = replacing(analysis.selectedMoments[1], quote: "Ця сцена має іншу роль")
        strong.semanticConfidence = .high
        let clean = LongformNarrativeDirector.sanitizeSelectedMoments([strong], totalMovieDuration: 2000)
        #expect(clean == [strong])
        var buckets: [LongformActType: [SelectedMoment]] = [
            .form: [strong, analysis.selectedMoments[5]],
            .catharsis: [analysis.selectedMoments[4], analysis.selectedMoments[8]]
        ]
        LongformNarrativeDirector.promoteStrongestSceneToCatharsis(&buckets)
        #expect(buckets[.form] == [strong, analysis.selectedMoments[5]])
    }

    @Test func verifiedArcContainsOnlyChosenScenesIncludingTheFilmEnding() async throws {
        let (analysis, transcript) = fixture()
        let arc = try await LongformNarrativeDirector().buildArc(
            from: transcript, concept: analysis.primaryConcept,
            selectedMoments: analysis.selectedMoments, movieTitle: "Тестовий фільм",
            essayPlan: analysis.essayPlan)
        let chosen = analysis.selectedMoments.map { TimeSegment(start: $0.startTime, end: $0.endTime) }
        #expect(arc.segments.sorted { $0.start < $1.start } == chosen.sorted { $0.start < $1.start })
        for act in arc.acts {
            for segment in act.segments {
                #expect(analysis.selectedMoments.contains {
                    $0.startTime == segment.start && $0.endTime == segment.end && $0.actRole == act.type
                })
            }
        }
        try EssaySceneEvidence.validateArc(
            arc, selectedMoments: analysis.selectedMoments, coldOpenEnabled: true)
        try EssaySceneEvidence.validateArc(
            arc, selectedMoments: analysis.selectedMoments, coldOpenEnabled: false)

        var changed = arc
        changed.acts.swapAt(0, 1)
        #expect(throws: EssaySceneEvidence.InvalidSelection.self) {
            try EssaySceneEvidence.validateArc(
                changed, selectedMoments: analysis.selectedMoments, coldOpenEnabled: true)
        }
        changed = arc
        changed.acts[1].segments[0] = TimeSegment(start: 1, end: 31)
        #expect(throws: EssaySceneEvidence.InvalidSelection.self) {
            try EssaySceneEvidence.validateArc(
                changed, selectedMoments: analysis.selectedMoments, coldOpenEnabled: true)
        }
        changed = arc
        let scene = changed.acts[1].segments[0]
        changed.acts[1].segments[0] = TimeSegment(start: scene.start + 2, end: scene.end)
        #expect(throws: EssaySceneEvidence.InvalidSelection.self) {
            try EssaySceneEvidence.validateArc(
                changed, selectedMoments: analysis.selectedMoments, coldOpenEnabled: true)
        }
        try EssaySceneEvidence.validateArc(
            changed, selectedMoments: analysis.selectedMoments, coldOpenEnabled: true,
            allowApprovedTrim: true)
    }

    @Test func parserPreservesTheVerbatimEvidenceQuote() throws {
        let json = """
        {"primaryConcept":{"word":"ВИБІР","tagline":"Кожне рішення має ціну","suggestedTitle":"Ціна рішення"},
         "reasoning":"Герой відповідає за наслідки",
         "selectedMoments":[{"startTime":100,"endTime":130,"reason":"Рішення героя",
         "actRole":"psychology","supports":"Вчинок змінює героя",
         "evidenceQuote":"Моє рішення має ціну"}]}
        """
        let parsed = try #require(LongformThematicService.parseThematicAnalysis(from: json))
        #expect(parsed.selectedMoments.first?.evidenceQuote == "Моє рішення має ціну")
    }

    @Test func continuousDialogueKeepsLocalTimecodeAnchors() {
        let segments = (0..<30).map { index in
            TranscriptSegment(
                start: Double(index * 10), end: Double(index * 10 + 10),
                text: "Це окрема думка героя номер \(index) про ціну рішення.")
        }
        let digest = LongformThematicService.stratifiedThematicSample(
            from: Transcript(segments: segments, language: "uk"))
        #expect(digest.split(separator: "\n").count >= 8)
        #expect(digest.contains("[280.0]"))
        #expect(digest.contains("думка героя номер 29"))
    }

    @Test func catalogueOwnsAllSceneTimecodesAndQuotes() throws {
        let (_, transcript) = fixture()
        let catalogue = EssaySceneCatalogue(transcript: transcript)
        #expect(catalogue.scenes.count == 14)
        let scene = try #require(catalogue.scenes.first)
        let rows: [[Any]] = [[scene.id, "hook", 0.9, true, "Рішення визначає подальшу долю героя"]]
        let moments = try #require(catalogue.moments(from: rows))
        #expect(moments[0].startTime == scene.start)
        #expect(moments[0].endTime == scene.end)
        #expect(moments[0].evidenceQuote == scene.quote)
        #expect(catalogue.moments(from: [["S9999", "hook", 0.9, true, "Вигаданий ID"]]) == nil)
        #expect(catalogue.moments(from: rows + rows) == nil)
    }

    @Test func densePresentedCatalogueKeepsExactSourceMapping() throws {
        let (_, transcript) = fixture()
        let catalogue = EssaySceneCatalogue(transcript: transcript)
        let original = catalogue.scenes[5]
        let presented = catalogue.presented(in: "[\(original.id) ").denselyNumbered()
        #expect(presented.scenes.count == 1)
        #expect(presented.scenes[0].id == "S0001")
        let row: [[Any]] = [["S0001", "hook", 0.9, true, "Рішення героя має наслідки"]]
        let selected = try presented.decodeMoments(from: row)
        #expect(selected[0].startTime == original.start)
        #expect(selected[0].endTime == original.end)
        #expect(selected[0].evidenceQuote == original.quote)
        #expect(throws: (any Error).self) {
            try presented.decodeMoments(from: [[original.id, "hook", 0.9, true, "Інший номер"]])
        }
    }

    @Test func screenshotRegressionRejectsLegacyPronounAndAnotherFilmTitleBeforeShowingCards() {
        let (valid, transcript) = fixture()
        var stale = valid
        stale.primaryConcept.word = "Його"
        stale.primaryConcept.suggestedTitle = "Філософія Револьвера"
        stale.selectedMoments = []
        stale.sourceTranscriptFingerprint = nil
        let project = FilmProject(
            sourceMovieURL: URL(fileURLWithPath: "/films/Fight.Club.mkv"),
            movieFileName: "Fight.Club", movieTitle: "Бійцівський клуб",
            transcript: transcript, thematicAnalysis: stale, selectedConcept: stale.primaryConcept)
        let workspace = WorkspaceModel()
        workspace.restoreFilmProjectState(project)
        #expect(workspace.storedTranscript == transcript)
        #expect(workspace.thematicAnalysis == nil)
        #expect(workspace.selectedConcept == nil)
        #expect(workspace.discoveredConcepts.isEmpty)
        #expect(workspace.currentProject?.transcript == transcript)
        #expect(workspace.currentProject?.thematicAnalysis == nil)
    }

    @Test func openingASecondProjectNeverKeepsTheFirstFilmsAnalysis() {
        let (valid, transcript) = fixture()
        let first = FilmProject(
            sourceMovieURL: URL(fileURLWithPath: "/films/first.mkv"),
            movieFileName: "first", movieTitle: "Перший фільм",
            transcript: transcript, thematicAnalysis: valid)
        let second = FilmProject(
            sourceMovieURL: URL(fileURLWithPath: "/films/second.mkv"),
            movieFileName: "second", movieTitle: "Інший фільм")
        let workspace = WorkspaceModel()
        workspace.restoreFilmProjectState(first)
        #expect(!workspace.discoveredConcepts.isEmpty)
        workspace.stagedEssayPlan = valid.essayPlan
        workspace.stagedConcept = valid.primaryConcept
        workspace.restoreFilmProjectState(second)
        #expect(workspace.currentProject?.id == second.id)
        #expect(workspace.storedTranscript == nil)
        #expect(workspace.thematicAnalysis == nil)
        #expect(workspace.selectedConcept == nil)
        #expect(workspace.detectedMovie == nil)
        #expect(workspace.longformResult == nil)
        #expect(workspace.stagedEssayPlan == nil)
        #expect(workspace.stagedConcept == nil)
        #expect(workspace.discoveredConcepts.isEmpty)
    }

    @Test func evenAValidPlanIsRejectedForADifferentTranscript() {
        let (valid, transcript) = fixture()
        let different = Transcript(segments: transcript.segments + [
            TranscriptSegment(start: 2000, end: 2020, text: "Це вже матеріал іншого фільму.")
        ], language: "uk")
        #expect(ThematicAnalysisCache.isReusable(valid, transcript: transcript))
        #expect(!ThematicAnalysisCache.isReusable(valid, transcript: different))
        var unsigned = valid
        unsigned.sourceTranscriptFingerprint = nil
        #expect(!ThematicAnalysisCache.isReusable(unsigned, transcript: transcript))
    }

    @Test func fingerprintDoesNotBypassTheThemeGate() {
        var (invalid, transcript) = fixture()
        invalid.primaryConcept.word = "Його"
        #expect(!ThematicAnalysisCache.isReusable(invalid, transcript: transcript))
    }

    @Test func replacingTheFileAtTheSameURLDoesNotLoadTheOldProject() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("movie.mp4")
        try Data(repeating: 1, count: 100).write(to: source)
        let service = FilmProjectService(storageDirectory: directory.appendingPathComponent("projects"))
        let project = FilmProject(sourceMovieURL: source, movieFileName: "movie", movieTitle: "Перший фільм")
        try await service.saveProject(project)
        try Data(repeating: 2, count: 200).write(to: source)
        let loaded = try await service.loadProject(for: source)
        #expect(loaded == nil)
    }

    @Test func catalogueRejectsScenesTheModelWasNotShown() throws {
        let (_, transcript) = fixture()
        let catalogue = EssaySceneCatalogue(transcript: transcript)
        let first = try #require(catalogue.scenes.first)
        let last = try #require(catalogue.scenes.last)
        let restricted = catalogue.presented(in: "[\(first.id) \(first.start)] \(first.text)")
        #expect(restricted.scenes.count == 1)
        #expect(restricted.moments(from: [[last.id, "hook", 0.9, true, "Сцена поза матеріалом моделі"]]) == nil)
    }

    @Test func catalogueAcceptsTheObjectShapeObservedInTheLiveReply() throws {
        let (_, transcript) = fixture()
        let catalogue = EssaySceneCatalogue(transcript: transcript)
        let rows: [[String: Any]] = [[
            "id": "S004", "role": "psychology", "weight": 0.9,
            "featured": true, "explanation": "Герой приймає наслідки вчинку"
        ]]
        let selected = try #require(catalogue.moments(from: rows))
        #expect(selected.first?.startTime == catalogue.scenes[3].start)
        #expect(selected.first?.evidenceQuote == catalogue.scenes[3].quote)
        let duplicate: [[Any]] = [
            ["S004", "hook", 0.9, true, "Перша форма ID"],
            ["S0004", "form", 0.8, false, "Повтор того самого номера"]
        ]
        #expect(catalogue.moments(from: duplicate) == nil)
    }

    @Test func catalogueNeverCreatesOverlongOverlappingOrOutOfFilmRanges() {
        let segments = (0..<50).map { index in
            TranscriptSegment(start: Double(index * 3), end: Double(index * 3 + 3),
                              text: "Герой приймає рішення номер \(index).")
        }
        let catalogue = EssaySceneCatalogue(transcript: Transcript(segments: segments, language: "uk"))
        #expect(!catalogue.scenes.isEmpty)
        for (index, scene) in catalogue.scenes.enumerated() {
            #expect((18...40).contains(scene.end - scene.start))
            #expect(scene.start >= 0 && scene.end <= 150)
            if index > 0 { #expect(catalogue.scenes[index - 1].end <= scene.start) }
        }
    }

    @Test func compactCatalogueReplyUsesSourceInsteadOfModelTimecodes() throws {
        let (_, transcript) = fixture()
        let catalogue = EssaySceneCatalogue(transcript: transcript)
        let scene = try #require(catalogue.scenes.first)
        let raw = """
        {"primaryConcept":{"word":"ВИБІР","tagline":"Рішення має ціну","suggestedTitle":"Ціна рішення"},
         "reasoning":"Розбір наслідків вчинку",
         "selection":[["\(scene.id)","hook",0.9,true,"Герой бере відповідальність"]]}
        """
        let parsed = try #require(LongformThematicService.parseCatalogueAnalysis(from: raw, catalogue: catalogue))
        #expect(parsed.selectedMoments.first?.startTime == scene.start)
        #expect(parsed.selectedMoments.first?.evidenceQuote == scene.quote)
    }

    private func replacing(_ moment: SelectedMoment, quote: String?) -> SelectedMoment {
        SelectedMoment(
            startTime: moment.startTime, endTime: moment.endTime,
            reason: moment.reason, dramaticWeight: moment.dramaticWeight,
            actRole: moment.actRole, supports: moment.supports, featured: moment.featured,
            evidenceQuote: quote)
    }
}
