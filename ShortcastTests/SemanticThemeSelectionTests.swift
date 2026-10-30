import Foundation
import Testing
@testable import Shortcast

@Suite("Semantic theme and single hook")
struct SemanticThemeSelectionTests {
    private func material(word: String = "ІДЕНТИЧНІСТЬ") -> (ThematicAnalysisResult, Transcript) {
        let roles = LongformActType.canonicalAnalyticOrder
        let lines = (0..<14).map { index in
            TranscriptSegment(start: Double(index * 50), end: Double(index * 50 + 30),
                text: "Рішення номер \(index) змінює життя героя. Він обирає власний шлях.")
        }
        let moments = lines.enumerated().map { index, line in
            SelectedMoment(startTime: line.start, endTime: line.end, reason: "Зміна героя", dramaticWeight: 0.8,
                actRole: index == 0 ? .hook : roles[1 + (index - 1) % 4], supports: "Рішення має наслідки",
                evidenceQuote: "Рішення номер \(index) змінює життя героя")
        }
        let concept = ThematicConcept(word: word, tagline: "Ким стає людина", philosophicalPremise: "Власний вибір змінює людину",
                                      suggestedTitle: "Власний шлях", source: .llm)
        let plan = EssayPlan(thesis: "Рішення змінює людину", actFocus: Dictionary(uniqueKeysWithValues: roles.dropFirst().map {
            ($0.promptKey, "Герой бачить наслідки вибору")
        }))
        return (ThematicAnalysisResult(primaryConcept: concept, aiReasoning: "Арка вибору", selectedMoments: moments,
            essayPlan: plan, source: .llm), Transcript(segments: lines, language: "uk"))
    }

    private var acceptedReply: String {
        #"{"verdict":"direct","preferredTheme":null,"reason":"Тема описує зміну героя через його рішення.","title":"Коли вибір змінює тебе","hook":"Хто ти після власного вибору?","hookReason":"Початок ставить питання, фінал показує відповідальність.","evidence":[{"scene":1,"line":0},{"scene":2,"line":1},{"scene":5,"line":4}]}"#
    }

    @Test("A meaningful topic need not be spoken literally; one hook has explicit model authorship")
    func directTopicAndHook() throws {
        let (analysis, transcript) = material()
        #expect(!transcript.segments.contains { $0.text.contains("ІДЕНТИЧНІСТЬ") })
        let reviewed = try EssaySemanticSelection.apply(acceptedReply, to: analysis,
            candidates: [analysis.primaryConcept], transcript: transcript, modelID: "test-model")
        #expect(reviewed.essayPlan?.hookVariants.count == 1)
        #expect(reviewed.essayPlan?.selectedHook?.source == .llm)
        #expect(reviewed.essayPlan?.selectedHook?.text == "Хто ти після власного вибору?")
        #expect(reviewed.primaryConcept.suggestedTitle == "Коли вибір змінює тебе")
        #expect(ThematicAnalysisCache.isReusable(ThematicAnalysisCache.binding(reviewed, to: transcript), transcript: transcript))
    }

    @Test("A strained topic is replaced only by the candidate named by the model")
    func strainedTopic() throws {
        let (analysis, transcript) = material(word: "БІДНІСТЬ")
        var alternative = analysis.primaryConcept
        alternative.word = "СПОЖИВАННЯ"
        let raw = #"{"verdict":"strained","preferredTheme":"СПОЖИВАННЯ","reason":"Слово обіцяє іншу тему й потребує переозначення.","title":"","hook":"","hookReason":"","evidence":[]}"#
        do {
            _ = try EssaySemanticSelection.apply(raw, to: analysis, candidates: [analysis.primaryConcept, alternative],
                                                 transcript: transcript, modelID: "test-model")
            Issue.record("натянутая тема принята")
        } catch let error as EssayThemeRejected {
            #expect(error.preferredTheme == "СПОЖИВАННЯ")
        }
    }

    @Test("No theme blacklist: the same word can be accepted for different film material")
    func noBlacklist() throws {
        let (analysis, transcript) = material(word: "БІДНІСТЬ")
        let reviewed = try EssaySemanticSelection.apply(acceptedReply, to: analysis,
            candidates: [analysis.primaryConcept], transcript: transcript, modelID: "test-model")
        #expect(reviewed.primaryConcept.word == "БІДНІСТЬ")
    }

    @Test("Unknown replacement is never invented or mapped to the first alternative")
    func unknownReplacement() throws {
        let (analysis, transcript) = material()
        let raw = #"{"verdict":"strained","preferredTheme":"ВИГАДАНЕ","reason":"Не підходить."}"#
        do {
            _ = try EssaySemanticSelection.apply(raw, to: analysis, candidates: [analysis.primaryConcept],
                                                 transcript: transcript, modelID: "test-model")
            Issue.record("неизвестная тема принята")
        } catch let error as EssayThemeRejected { #expect(error.preferredTheme == nil) }
    }

    @Test("Literal quotes, distinct acts and the ending are required", arguments: [
        ("\"scene\":5", "\"scene\":99"),
        ("\"scene\":5", "\"scene\":2"),
        ("\"scene\":5", "\"scene\":3")
    ])
    func evidenceGate(replacement: (String, String)) {
        let (analysis, transcript) = material()
        let raw = acceptedReply.replacingOccurrences(of: replacement.0, with: replacement.1)
        #expect(throws: (any Error).self) {
            try EssaySemanticSelection.apply(raw, to: analysis, candidates: [analysis.primaryConcept],
                                             transcript: transcript, modelID: "test-model")
        }
    }

    @Test("Evidence uses exact source lines and cannot cite a hidden line")
    func sourceLineWhitelist() throws {
        let (analysis, transcript) = material()
        let prompt = EssaySemanticSelection.prompt(analysis: analysis,
            candidates: [analysis.primaryConcept], transcript: transcript, materialChars: 10_000)
        let ids = EssaySemanticSelection.presentedLineIDs(in: prompt)
        #expect(ids == Set(transcript.segments.indices))
        let reviewed = try EssaySemanticSelection.apply(acceptedReply, to: analysis,
            candidates: [analysis.primaryConcept], transcript: transcript, modelID: "test-model",
            presentedLineIDs: ids)
        #expect(reviewed.semanticProof?.evidence.first?.quote == transcript.segments[0].text)
        #expect(throws: (any Error).self) {
            try EssaySemanticSelection.apply(acceptedReply, to: analysis,
                candidates: [analysis.primaryConcept], transcript: transcript, modelID: "test-model",
                presentedLineIDs: ids.subtracting([4]))
        }
    }

    @Test("Scene references accept unambiguous model labels, never unknown text")
    func sceneReferenceLabels() throws {
        let (analysis, transcript) = material()
        let raw = acceptedReply.replacingOccurrences(of: "\"scene\":1", with: "\"scene\":\"SCENE 1\"")
        #expect(try EssaySemanticSelection.apply(raw, to: analysis, candidates: [analysis.primaryConcept],
            transcript: transcript, modelID: "test-model").semanticProof?.evidence.first?.scene == 1)
        let invalid = raw.replacingOccurrences(of: "SCENE 1", with: "OTHER 1")
        #expect(throws: (any Error).self) {
            try EssaySemanticSelection.apply(invalid, to: analysis, candidates: [analysis.primaryConcept],
                transcript: transcript, modelID: "test-model")
        }
    }

    @Test("Language polish preserves proof and refuses an unrelated rewrite")
    func languagePolish() throws {
        let (analysis, transcript) = material()
        let reviewed = try EssaySemanticSelection.apply(acceptedReply, to: analysis,
            candidates: [analysis.primaryConcept], transcript: transcript, modelID: "test-model")
        let raw = #"{"title":"Коли власний вибір змінює тебе","hook":"Хто ти після свого власного вибору?"}"#
        let polished = try EssaySemanticSelection.applyingLanguagePolish(raw, to: reviewed)
        #expect(polished.semanticProof?.evidence == reviewed.semanticProof?.evidence)
        #expect(polished.semanticProof?.hook == polished.essayPlan?.selectedHook?.text)
        #expect(polished.essayPlan?.hookVariants.count == 1)
        #expect(throws: (any Error).self) {
            try EssaySemanticSelection.applyingLanguagePolish(
                #"{"title":"Зовсім інша тема фільму","hook":"Коли прийде нова епоха?"}"#, to: reviewed)
        }
    }

    @Test("Legacy lists never silently select the first hook")
    func noImplicitFirstHook() {
        let first = EssayPlan.TextVariant(text: "Перший варіант.", source: .llm)
        let plan = EssayPlan(hookVariants: [first, .init(text: "Інший варіант.", source: .llm)])
        #expect(plan.chosenHookVariant == nil)
        #expect(plan.confirming(hookText: nil, ctaText: nil).chosenHookVariant == nil)
    }

    @Test("Source fingerprint alone cannot restore an old theme and menu of hooks")
    func oldCacheIsInvalid() {
        var (analysis, transcript) = material()
        analysis.essayPlan?.hookVariants = [.init(text: "Старий варіант.", source: .llm)]
        let bound = ThematicAnalysisCache.binding(analysis, to: transcript)
        #expect(ThematicAnalysisCache.hasMatchingSource(bound, transcript: transcript))
        #expect(!ThematicAnalysisCache.isReusable(bound, transcript: transcript))
    }

    @Test("New parser records an explicit single hook; old arrays remain undecided")
    func parserChoice() throws {
        let plan = try #require(LongformThematicService.parseEssayPlan([
            "hook": "Хто ти після власного вибору?", "thesis": "Вибір змінює людину"
        ]))
        #expect(plan.selectedHook?.source == .llm)
        #expect(plan.hookVariants.count == 1)
        let legacy = try #require(LongformThematicService.parseEssayPlan(["hookVariants": ["Перший", "Другий"]]))
        #expect(legacy.selectedHook == nil)
    }
}
