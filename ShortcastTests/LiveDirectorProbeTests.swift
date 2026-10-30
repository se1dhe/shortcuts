import Testing
import Foundation
import AVFoundation
@testable import Shortcast

@Suite("Live semantic theme probe", .enabled(if:
    ProcessInfo.processInfo.environment["SHORTCAST_PROBE_SEMANTIC_THEME"] == "1"))
@MainActor
struct LiveSemanticThemeProbeTests {
    @Test func choosesThemeAndSingleHookFromFilm() async throws {
        let project = try #require(try await FilmProjectService.shared.listRecentProjects().first {
            $0.sourceMovieURL.lastPathComponent.contains("Fight.Club") && $0.transcript != nil
        })
        let transcript = try #require(project.transcript)
        let manager = ModelManager()
        try await manager.requireDirector(profile: .gemma12B)
        if let previous = project.thematicAnalysis, previous.primaryConcept.word.uppercased() == "БІДНІСТЬ" {
            do {
                _ = try await manager.momentFinder.reviewThemeAndHook(previous,
                    candidates: previous.allConcepts, transcript: transcript)
                Issue.record("прежняя натянутая тема снова принята независимой проверкой")
            } catch let rejected as EssayThemeRejected {
                print("SEMANTIC_PROBE old rejected: \(rejected.reason); preferred=\(rejected.preferredTheme ?? "nil")")
            }
        }
        let result: ThematicAnalysisResult
        let env = ProcessInfo.processInfo.environment
        if let savedAnalysis = env["SHORTCAST_SEMANTIC_SAVED_ANALYSIS"] {
            let saved = try JSONDecoder().decode(ThematicAnalysisResult.self,
                from: Data(contentsOf: URL(fileURLWithPath: savedAnalysis)))
            #expect(ThematicAnalysisCache.isReusable(saved, transcript: transcript))
            result = try await manager.momentFinder.polishTitleAndHook(saved)
        } else if let candidatesPath = env["SHORTCAST_SEMANTIC_RESUME_CANDIDATES"],
           let rejectionPath = env["SHORTCAST_SEMANTIC_RESUME_REJECTION"] {
            // Продолжение фактического решения модели: не подставляем имя темы из теста.
            let candidates = LongformThematicService.parseThemeCandidates(
                from: try String(contentsOfFile: candidatesPath, encoding: .utf8))
            if let savedPool = env["SHORTCAST_SEMANTIC_SAVED_POOL"] {
                let raw = try String(contentsOfFile: savedPool, encoding: .utf8)
                let object = try #require(JSONVariantParser.extractJSONObject(from: raw))
                let json = try #require(try JSONSerialization.jsonObject(with: Data(object.utf8)) as? [String: Any])
                let primary = try #require(json["primaryConcept"] as? [String: Any])
                let selected = try #require(candidates.first { $0.word == primary["word"] as? String })
                let overview = String((project.tmdbMetadata?.overview.trimmed ?? "").prefix(MomentFinderService.thematicOverviewCharCap))
                let budget = MomentFinderService.essayDigestPlan(movieTitle: "Бійцівський клуб",
                    overview: overview, winner: selected, approvedCandidates: candidates,
                    maxKVSize: nil, catalogueMode: true)
                let catalogue = EssaySceneCatalogue(transcript: transcript)
                let (digest, _) = MomentFinderService.downsampleChronologically(catalogue.digest, to: budget.digestChars)
                let presented = catalogue.presented(in: digest).denselyNumbered()
                var parsed = try LongformThematicService.decodeCatalogueAnalysis(from: raw, catalogue: presented)
                parsed.alternativeConcepts = candidates.filter { $0.word != selected.word }
                parsed.plannedConcept = selected
                try EssaySceneEvidence.validate(parsed, transcript: transcript)
                let reviewed = try await manager.momentFinder.reviewThemeAndHook(parsed,
                    candidates: candidates, transcript: transcript)
                result = ThematicAnalysisCache.binding(reviewed, to: transcript)
            } else {
            let rejection = try String(contentsOfFile: rejectionPath, encoding: .utf8)
            let object = try #require(JSONVariantParser.extractJSONObject(from: rejection))
            let json = try #require(try JSONSerialization.jsonObject(with: Data(object.utf8)) as? [String: Any])
            #expect(json["verdict"] as? String == "strained")
            let preferred = try #require(json["preferredTheme"] as? String)
            let selected = try #require(candidates.first { $0.word == preferred })
            result = try await LongformThematicService().planThematicAnalysis(for: selected,
                candidates: candidates, from: transcript, movieTitle: "Бійцівський клуб",
                movieOverview: project.tmdbMetadata?.overview, modelManager: manager, directorProfile: .gemma12B)
            }
        } else {
            result = try await LongformThematicService().discoverThematicAnalysis(from: transcript,
                movieTitle: "Бійцівський клуб", movieOverview: project.tmdbMetadata?.overview,
                modelManager: manager, directorProfile: .gemma12B)
        }
        #expect(result.primaryConcept.word.uppercased() != "БІДНІСТЬ")
        #expect(result.semanticProof != nil)
        #expect(result.essayPlan?.selectedHook?.source == .llm)
        #expect(result.essayPlan?.hookVariants.count == 1)
        #expect(ThematicAnalysisCache.isReusable(result, transcript: transcript))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(result).write(to: URL(fileURLWithPath: "/private/tmp/shortcast-semantic-choice-analysis.json"))
        let arc = try await LongformNarrativeDirector().buildArc(from: transcript, concept: result.primaryConcept,
            selectedMoments: result.selectedMoments, movieTitle: "Бійцівський клуб", essayPlan: result.essayPlan)
        #expect(arc.hookText == result.essayPlan?.selectedHook?.text)
        try EssaySceneEvidence.validateArc(arc, selectedMoments: result.selectedMoments, coldOpenEnabled: true)
        print("SEMANTIC_PROBE theme=\(result.primaryConcept.word) title=\(result.primaryConcept.suggestedTitle)")
        print("SEMANTIC_PROBE hook=\(result.essayPlan?.selectedHook?.text ?? "nil") reason=\(result.essayPlan?.hookReason ?? "nil")")
    }
}

@Suite("Editorial pilot packaging", .enabled(if:
    ProcessInfo.processInfo.environment["SHORTCAST_FINALIZE_EDITORIAL_PILOT"] == "1"))
@MainActor
struct EditorialPilotPackagingTests {
    @Test func finalizesReviewedPilot() async throws {
        let file = URL(fileURLWithPath: "/private/tmp/shortcast-editorial-render-result.json")
        let rendered = try JSONDecoder().decode(LongformBuildResult.self, from: Data(contentsOf: file))
        var arc = rendered.arc
        // Редакторская формулировка для этого пилота, не словарь тем и не ответ модели.
        arc.publicationTitle = "Бідність духу: коли речі замінюють тебе | Бійцівський клуб"
        let source = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["SHORTCAST_EDITORIAL_RENDER_SOURCE"]))
        let cover = try #require(rendered.thumbnailURL)
        let thumbnail = try await LongformThumbnailGenerator().generateThumbnail(sourceAsset: AVURLAsset(url: source),
            segments: arc.segments, concept: arc.concept, movieTitle: arc.movieTitle, outputURL: cover)
        let metadata = LongformMetadataGenerator.generate(movieTitle: arc.movieTitle, concept: arc.concept, arc: arc)
        let result = LongformBuildResult(outputURL: rendered.outputURL, arc: arc, metadata: metadata,
            duration: rendered.duration, thumbnailURL: thumbnail, validationResult: rendered.validationResult,
            audioSettings: rendered.audioSettings)
        #expect(metadata.title == arc.publicationTitle)
        #expect(metadata.description.contains("Telegram: https://t.me/"))
        #expect(result.validationResult?.isValid == true)
        try JSONEncoder().encode(result).write(to: file, options: .atomic)
        print("EDITORIAL_PILOT title=\(metadata.title) output=\(result.outputURL.path)")
    }
}

/// Опциональный полный экспорт реального пилота. Пишет новый файл; архив проекта не меняется.
@Suite("Editorial render probe", .enabled(if:
    ProcessInfo.processInfo.environment["SHORTCAST_EDITORIAL_RENDER_ARC"] != nil))
@MainActor
struct EditorialRenderProbeTests {
    @Test func rendersReviewedArc() async throws {
        let env = ProcessInfo.processInfo.environment
        let arcPath = try #require(env["SHORTCAST_EDITORIAL_RENDER_ARC"])
        let sourcePath = try #require(env["SHORTCAST_EDITORIAL_RENDER_SOURCE"])
        let project = try #require(try await FilmProjectService.shared.listRecentProjects().first {
            $0.sourceMovieURL.lastPathComponent.contains("Fight.Club") && $0.longformResult != nil
        })
        let transcript = try #require(project.transcript)
        var arc = try JSONDecoder().decode(LongformNarrativeArc.self, from: Data(contentsOf: URL(fileURLWithPath: arcPath)))
        // Единственная вычитанная в разборе однозначная орфографическая правка.
        if let line = transcript.segments.first(where: { $0.text == "Без соня стирає межі реальності." }) {
            arc.captionEdits = [LongformCaptionEdit(start: line.start, end: line.end, original: line.text,
                                                   replacement: "Безсоння стирає межі реальності.")]
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let music = root.appendingPathComponent("Shortcast/Resources/Music/The Day Of Night.mp3")
        let audio = LongformAudioSettings(backgroundMusicURL: music, musicVolume: 0.03, duckingEnabled: false,
                                         originalMusicDucking: 0.8)
        let settings = AppSettings()
        let result = try await LongformPipelineCoordinator(
            discussionURL: LongformEditorialSupport.telegramURL(channelID: settings.telegramChannelId)
        ).buildLongformVideo(sourceURL: URL(fileURLWithPath: sourcePath), movieTitle: project.movieTitle,
            transcript: transcript, concept: arc.concept, selectedMoments: project.thematicAnalysis?.selectedMoments ?? [],
            audioSettings: audio, existingArc: arc, workingDirectory: root.appendingPathComponent("Exports"),
            channelLogoEnabled: settings.channelLogoWatermarkEnabled) { fraction, step in
                print("EDITORIAL_RENDER \(Int(fraction * 100))% \(step)")
            }
        #expect(result.validationResult?.isValid == true)
        #expect(result.audioSettings == audio)
        try JSONEncoder().encode(result).write(to: URL(fileURLWithPath: "/private/tmp/shortcast-editorial-render-result.json"))
        print("EDITORIAL_RENDER result=\(result.outputURL.path) duration=\(result.duration)")
    }
}

/// Явный живой прогон редактора по готовому экспорту; исходный проект не изменяется.
@Suite("Live editorial probe", .enabled(if:
    ProcessInfo.processInfo.environment["SHORTCAST_PROBE_EDITORIAL"] == "1"))
@MainActor
struct LiveEditorialProbeTests {
    @Test func reviewsSavedFilmArc() async throws {
        let project = try #require(try await FilmProjectService.shared.listRecentProjects().first {
            $0.sourceMovieURL.lastPathComponent.contains("Fight.Club") && $0.longformResult != nil
        })
        let transcript = try #require(project.transcript)
        let original = try #require(project.longformResult).arc
        let manager = ModelManager()
        try await manager.requireDirector(profile: .gemma12B)
        let gateway = DirectorChatGateway(readiness: { await manager.momentFinder.isReady },
            identifier: { await manager.momentFinder.profile.modelID },
            completion: { instructions, prompt, maxTokens in
                await manager.momentFinder.completeForActTitles(instructions: instructions, prompt: prompt, maxTokens: maxTokens)
            })
        let start = Date()
        let result = await LongformEditorialReview(model: gateway).review(arc: original, transcript: transcript,
                                                                         coldOpenEnabled: true)
        print("EDITORIAL_PROBE elapsed=\(Date().timeIntervalSince(start)) model=\(result.editorialReviewModelID ?? "nil") edits=\(result.sceneEdits?.count ?? 0) suggestions=\(result.captionSuggestions?.count ?? 0)")
        #expect(result.editorialReviewModelID != nil, "реальный ответ должен пройти проверку")
        if let moments = project.thematicAnalysis?.selectedMoments {
            try EssaySceneEvidence.validateArc(result, selectedMoments: moments, coldOpenEnabled: true)
        }
        let output = URL(fileURLWithPath: "/private/tmp/shortcast-editorial-probe-arc.json")
        try JSONEncoder().encode(result).write(to: output)
        print("EDITORIAL_PROBE hook=\(result.hookText ?? "") conclusion=\(result.conclusionText ?? "") duration=\(LongformTimeline(arc: result).duration)")
    }
}

/// ВРЕМЕННАЯ живая проверка двухэтапного Director на реальном фильме.
/// Запускается только по флагу окружения, потому что поднимает 6.3 ГБ модели
/// и тратит минуты реального времени:
/// `TEST_RUNNER_SHORTCAST_PROBE_DIRECTOR=1 xcodebuild test …`
@Suite(
    "Live director probe",
    .enabled(if: ProcessInfo.processInfo.environment["SHORTCAST_PROBE_DIRECTOR"] == "1")
)
@MainActor
struct LiveDirectorProbeTests {

    @Test func twoStageDirectorOnFightClub() async throws {
        let projects = try await FilmProjectService.shared.listRecentProjects()
        guard let project = projects.first(where: {
            $0.sourceMovieURL.lastPathComponent.contains("Fight.Club")
        }) else {
            Issue.record("нет проекта с Fight Club среди \(projects.count)")
            return
        }
        let transcript = try #require(project.transcript, "в проекте нет транскрипта")
        let digest = LongformThematicService.stratifiedThematicSample(from: transcript)
        print("PROBE segments=\(transcript.segments.count) lang=\(transcript.language) digestChars=\(digest.count)")

        let manager = ModelManager()
        let service = LongformThematicService()

        let loadStart = Date()
        try await manager.requireDirector(profile: .gemma12B)
        print("PROBE modelLoadSeconds=\(Int(Date().timeIntervalSince(loadStart)))")

        let directorStart = Date()
        let result = try await service.discoverThematicAnalysis(
            from: transcript,
            movieTitle: "Бійцівський клуб",
            movieOverview: project.tmdbMetadata?.overview,
            modelManager: manager,
            directorProfile: .gemma12B
        )
        let directorSeconds = Int(Date().timeIntervalSince(directorStart))
        print("PROBE directorSeconds=\(directorSeconds) theme='\(result.primaryConcept.word)' source=\(result.source.rawValue) completeness=\(result.replyCompleteness.rawValue) moments=\(result.selectedMoments.count) alternatives=\(result.alternativeConcepts.count)")
        print("PROBE tagline=\(result.primaryConcept.tagline)")
        print("PROBE title=\(result.primaryConcept.suggestedTitle)")
        print("PROBE hook=\(result.essayPlan?.chosenHookVariant?.text ?? "nil") source=\(String(describing: result.essayPlan?.chosenHookVariant?.source))")
        for (index, candidate) in result.alternativeConcepts.enumerated() {
            print("PROBE runner-up[\(index)] '\(candidate.word)' source=\(candidate.source.rawValue)")
        }

        let poolSeconds = result.selectedMoments.reduce(0) { $0 + ($1.endTime - $1.startTime) }
        print("PROBE poolSeconds=\(Int(poolSeconds)) window=\(Int(EssayDurationPolicy.renderedTarget(poolSeconds: poolSeconds)))")

        let arc = try await LongformNarrativeDirector().buildArc(
            from: transcript,
            concept: result.primaryConcept,
            selectedMoments: result.selectedMoments,
            movieTitle: "Бійцівський клуб",
            essayPlan: result.essayPlan,
            sourceMovieURL: project.sourceMovieURL
        )
        let content = arc.acts.reduce(0.0) { $0 + $1.duration }
        print("PROBE acts=\(arc.acts.count) contentSeconds=\(Int(content)) hookText=\(arc.hookText ?? "nil") cta=\(arc.ctaText ?? "nil") degradation=\(arc.degradationReason ?? "none")")
        for act in arc.acts {
            print("PROBE   \(act.type.rawValue): scenes=\(act.segments.count) seconds=\(Int(act.duration)) beat=\(act.dramaticBeat)")
        }
        let rendered = content
            + EssayDurationPolicy.fixedPadding
            + EssayDurationPolicy.intraActGap * Double(max(0, Int(arc.acts.count) - 1))
        print("PROBE estimatedRenderedSeconds=\(Int(rendered)) insideCorridor=\(EssayDurationPolicy.rendered.contains(rendered))")
    }
}

/// Повторная приёмка уже полученного живого ответа без ещё одной загрузки LLM.
/// Пути передаются явно; обычный suite не читает пользовательские архивы/логи.
@Suite("Saved director catalogue probe", .enabled(if:
    ProcessInfo.processInfo.environment["SHORTCAST_SAVED_DIRECTOR_REPLY"] != nil))
@MainActor
struct SavedDirectorCatalogueProbeTests {
    @Test func savedReplyUsesActualFilmCatalogue() async throws {
        let env = ProcessInfo.processInfo.environment
        let replyPath = try #require(env["SHORTCAST_SAVED_DIRECTOR_REPLY"])
        let candidatesPath = try #require(env["SHORTCAST_SAVED_DIRECTOR_CANDIDATES"])
        let projects = try await FilmProjectService.shared.listRecentProjects()
        let project = try #require(projects.first {
            $0.sourceMovieURL.lastPathComponent.contains("Fight.Club")
        })
        let transcript = try #require(project.transcript)
        let candidatesText = try String(contentsOfFile: candidatesPath, encoding: .utf8)
        let stems = DirectorArtifactGate.groundingStems(
            from: LongformThematicService.stratifiedThematicSample(from: transcript))
        let candidates = LongformThematicService.parseThemeCandidates(from: candidatesText).filter {
            if case .rejected = DirectorArtifactGate.concept($0, in: stems) { return false }
            return true
        }
        let winner = try #require(candidates.first)
        let catalogue = EssaySceneCatalogue(transcript: transcript)
        let plan = MomentFinderService.essayDigestPlan(
            movieTitle: "Бійцівський клуб", overview: project.tmdbMetadata?.overview ?? "",
            winner: winner, approvedCandidates: candidates, maxKVSize: nil, catalogueMode: true)
        let (digest, _) = MomentFinderService.downsampleChronologically(catalogue.digest, to: plan.digestChars)
        let presented = catalogue.presented(in: digest)
        let reply = try String(contentsOfFile: replyPath, encoding: .utf8)
        #expect(DirectorReply(text: reply, info: nil, maxTokens: 5_120).completeness.isAcceptable)
        var analysis = try LongformThematicService.decodeCatalogueAnalysis(from: reply, catalogue: presented)
        analysis = ThematicAnalysisCache.binding(analysis, to: transcript)
        analysis.plannedConcept = winner
        analysis.alternativeConcepts = candidates.filter { $0.word != winner.word }
        #expect(MomentFinderService.essayThemeMismatch(analysis, approved: winner) == nil)
        try EssaySceneEvidence.validate(analysis, transcript: transcript)
        #expect(ThematicAnalysisCache.hasMatchingSource(analysis, transcript: transcript))
        let arc = try await LongformNarrativeDirector().buildArc(
            from: transcript, concept: analysis.primaryConcept,
            selectedMoments: analysis.selectedMoments, movieTitle: "Бійцівський клуб",
            essayPlan: analysis.essayPlan)
        try EssaySceneEvidence.validateArc(arc, selectedMoments: analysis.selectedMoments, coldOpenEnabled: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("shortcast-essay-pilot-analysis.json")
        try encoder.encode(analysis).write(to: output, options: .atomic)
        let arcOutput = output.deletingLastPathComponent().appendingPathComponent("shortcast-essay-pilot-arc.json")
        try encoder.encode(arc).write(to: arcOutput, options: .atomic)
        // Только явный флаг ручного восстановления; обычные тесты архивы не меняют.
        if env["SHORTCAST_PROBE_SAVE_ANALYSIS"] == "1" {
            let archive = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Shortcast/Projects")
                .appendingPathComponent("\(project.id.uuidString).shortcastproj")
            let backup = FileManager.default.temporaryDirectory
                .appendingPathComponent("shortcast-project-backup-\(UUID().uuidString).shortcastproj")
            try FileManager.default.copyItem(at: archive, to: backup)
            var updated = project
            updated.thematicAnalysis = analysis
            updated.discoveredConcepts = analysis.allConcepts
            updated.selectedConcept = analysis.primaryConcept
            try await FilmProjectService.shared.saveProject(updated)
            print("SAVED_PROBE restored validated analysis; backup=\(backup.path)")
        }
        print("SAVED_PROBE theme=\(analysis.primaryConcept.word) scenes=\(analysis.selectedMoments.count) contentSeconds=\(arc.totalDuration) analysis=\(output.path) arc=\(arcOutput.path)")
    }
}
