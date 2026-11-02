import Foundation
import Testing
@testable import Shortcast

@Suite("Confirmed subtitle correction memory")
struct SubtitleCorrectionMemoryTests {
    private let edit = LongformCaptionEdit(start: 1, end: 2, original: "Столипелько!", replacement: "Стули пельку!")

    @Test("Exact phrases in the same film are reused at new timestamps, without changing ASR")
    func exactReuse() {
        var memory = SubtitleCorrectionMemory()
        memory.importEdits([edit], filmKey: "fight", language: "uk")
        let source = [TranscriptSegment(start: 100, end: 102, text: edit.original)]
        let fingerprint = ThematicAnalysisCache.fingerprint(of: Transcript(segments: source, language: "uk"))
        let edits = memory.edits(for: source, filmKey: "fight", language: "uk")
        #expect(edits.first?.start == 100)
        #expect(LongformEditorialSupport.captions(source, edits: edits).first?.text == edit.replacement)
        #expect(source.first?.text == edit.original)
        #expect(ThematicAnalysisCache.fingerprint(of: Transcript(segments: source, language: "uk")) == fingerprint)
        #expect(memory.edits(for: source, filmKey: "other-film", language: "uk").isEmpty)
        #expect(memory.edits(for: source, filmKey: "fight", language: "en").isEmpty)
    }

    @Test("Contextual words are suggested across films, never silently replaced")
    func contextualWord() throws {
        var memory = SubtitleCorrectionMemory()
        memory.importEdits([LongformCaptionEdit(start: 1, end: 2, original: "Ви геній, сир.", replacement: "Ви геній, сер.")],
            filmKey: "fight", language: "uk")
        let source = [TranscriptSegment(start: 1, end: 2, text: "Купи сир.")]
        #expect(memory.edits(for: source, filmKey: "fight", language: "uk").isEmpty)
        let suggestion = try #require(memory.suggestions(for: "Так точно, сир!", filmKey: "other", language: "uk").first)
        #expect(suggestion.text == "Так точно, сер!")
        #expect(memory.suggestions(for: "Сироп готовий.", filmKey: "fight", language: "uk").isEmpty)
        #expect(memory.suggestions(for: "Так точно, сир!", filmKey: "fight", language: "en").isEmpty)
    }

    @Test("Split and joined words are recovered as examples")
    func wordBoundaries() {
        var memory = SubtitleCorrectionMemory()
        memory.importEdits([edit, LongformCaptionEdit(start: 3, end: 4,
            original: "Нічого, гісінько.", replacement: "Нічогісінько.")], filmKey: "fight", language: "uk")
        #expect(memory.suggestions(for: "Ну, Столипелько!", filmKey: "other", language: "uk").first?.text == "Ну, Стули пельку!")
        #expect(memory.edits(for: [TranscriptSegment(start: 3, end: 4, text: "Нічого, гісінько.")],
            filmKey: "fight", language: "uk").first?.replacement == "Нічогісінько.")
    }

    @Test("Conflicting corrections are not auto-applied")
    func conflicts() {
        var memory = SubtitleCorrectionMemory()
        memory.importEdits([edit, LongformCaptionEdit(start: 3, end: 4, original: edit.original, replacement: "Інша репліка.")],
            filmKey: "fight", language: "uk")
        let source = [TranscriptSegment(start: 1, end: 2, text: edit.original)]
        #expect(memory.edits(for: source, filmKey: "fight", language: "uk").isEmpty)
    }

    @Test("Resetting to ASR forgets the auto-correction; stale archives cannot overwrite newer edits")
    func explicitReset() {
        var memory = SubtitleCorrectionMemory()
        let source = [TranscriptSegment(start: 1, end: 2, text: edit.original)]
        memory.importEdits([edit], filmKey: "fight", language: "uk")
        memory.record(original: source, updated: [TranscriptSegment(start: 1, end: 2, text: "Замовкни!")],
            filmKey: "fight", language: "uk")
        memory.importEdits([edit], filmKey: "fight", language: "uk")
        #expect(memory.edits(for: source, filmKey: "fight", language: "uk").first?.replacement == "Замовкни!")
        memory.record(original: source, updated: source, filmKey: "fight", language: "uk")
        memory.importEdits([edit], filmKey: "fight", language: "uk")
        #expect(memory.edits(for: source, filmKey: "fight", language: "uk").isEmpty)
    }

    @Test("Unchanged occurrences veto automatic generalisation from a corrected occurrence")
    func unchangedVeto() {
        var memory = SubtitleCorrectionMemory()
        let source = [TranscriptSegment(start: 1, end: 2, text: "Сир."), TranscriptSegment(start: 3, end: 4, text: "Сир.")]
        memory.record(original: source, updated: [TranscriptSegment(start: 1, end: 2, text: "Сер."), source[1]],
            filmKey: "fight", language: "uk")
        #expect(memory.edits(for: source, filmKey: "fight", language: "uk").isEmpty)
    }

    @Test("Memory survives restart and corrupt data is never overwritten")
    @MainActor func persistence() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        try SubtitleCorrectionStore(url: url).update { $0.importEdits([edit], filmKey: "fight", language: "uk") }
        #expect(try SubtitleCorrectionStore(url: url).load().examples.count == 1)
        let broken = Data("damaged-memory".utf8)
        try broken.write(to: url)
        #expect(throws: (any Error).self) {
            try SubtitleCorrectionStore(url: url).update { $0.importEdits([edit], filmKey: "fight", language: "uk") }
        }
        #expect(try Data(contentsOf: url) == broken)
    }

    @Test("Relevant corrections enter the editorial prompt as data, with no source rewrite")
    func modelExamples() {
        var memory = SubtitleCorrectionMemory()
        memory.importEdits([edit], filmKey: "fight", language: "uk")
        let prompt = memory.promptExamples(for: "L10: Столипелько!", filmKey: "fight", language: "uk")
        #expect(prompt.contains(edit.original) && prompt.contains(edit.replacement))
        #expect(prompt.contains("captionSuggestions"))
        #expect(memory.promptExamples(for: "Зовсім інший текст.", filmKey: "fight", language: "uk").isEmpty)
    }
}

@Suite("Phrase-isolated subtitle correction")
struct PhraseIsolatedSubtitleCorrectionTests {
    private actor Model: LongformActTitleModeling {
        enum Mode { case valid, wrongFirstID, contextLeak }
        let mode: Mode
        private(set) var requests: [LongformSubtitleCorrectionInput] = []
        private(set) var prompts: [String] = []
        init(_ mode: Mode = .valid) { self.mode = mode }
        var isReady: Bool { get async { true } }
        var modelID: String? { get async { "fixture" } }
        func complete(instructions: String, prompt: String, maxTokens: Int) async -> String? {
            let marker = prompt.range(of: "ЦЕЛЕВАЯ РЕПЛИКА", options: .backwards)
                ?? prompt.range(of: "ЦІЛЬОВА РЕПЛІКА", options: .backwards)
            guard let marker,
                  let json = JSONVariantParser.extractJSONObject(from: String(prompt[marker.upperBound...])),
                  let row = try? JSONDecoder().decode(LongformSubtitleCorrectionInput.self, from: Data(json.utf8)) else { return nil }
            requests.append(row); prompts.append(prompt)
            let id = mode == .wrongFirstID && row.id == 1 ? 999 : row.id
            let replacement = mode == .contextLeak ? row.text + " " + row.after : row.text + " corrected"
            let value: [String: Any] = ["edits": [["id": id, "replacement": replacement, "reason": "ASR correction"]]]
            return (try? JSONSerialization.data(withJSONObject: value)).flatMap { String(data: $0, encoding: .utf8) }
        }
    }
    private func row(_ id: Int) -> LongformSubtitleCorrectionInput {
        .init(id: id, act: "Act", timecode: "00:10", before: "An earlier line for reference.",
              text: "Target line \(id).", after: "A later line for reference.")
    }
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }

    @Test func bulkUsesExactlyTheSameRequestAsTheSinglePhraseButton() async throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let input = (1...20).map(row)
        let batchModel = Model()
        let bulk = try await LongformSubtitleCorrectionService(model: batchModel, logDirectory: folder)
            .correct(input, movieTitle: "Fixture", language: "en") { _ in }
        let singleModel = Model()
        let singleService = LongformSubtitleCorrectionService(model: singleModel, logDirectory: folder)
        var individual: [LongformSubtitleCorrectionSuggestion] = []
        for phrase in input {
            individual += try await singleService.correct([phrase], movieTitle: "Fixture", language: "en") { _ in }.suggestions
        }
        #expect(await batchModel.requests.map(\.id) == Array(1...20))
        #expect(await batchModel.prompts == singleModel.prompts)
        #expect(bulk.suggestions == individual)
        #expect(bulk.checkedCount == 20)
    }

    @Test func aWrongPhraseIDCannotStealAnotherCaptionsEditOrLoseGoodResults() async throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let model = Model(.wrongFirstID)
        let result = try await LongformSubtitleCorrectionService(model: model, logDirectory: folder)
            .correct([row(1), row(2)], movieTitle: "Fixture", language: "en") { _ in }
        #expect(await model.requests.map(\.id) == [1, 1, 2])
        #expect(result.suggestions.map(\.id) == [2])
        #expect(result.checkedCount == 1)
        #expect(result.failedPhraseCount == 1)
    }

    @Test func neighboursCannotBeAppendedToTheCorrectedCaption() async throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let result = try await LongformSubtitleCorrectionService(model: Model(.contextLeak), logDirectory: folder)
            .correct([row(1)], movieTitle: "Fixture", language: "en") { _ in }
        #expect(result.suggestions.isEmpty)
        #expect(result.failedPhraseCount == 1)
    }

    @Test func stoppingRetainsAlreadyCheckedSuggestions() async throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let model = Model()
        let task = Task {
            try await LongformSubtitleCorrectionService(model: model, logDirectory: folder)
                .correct([row(1), row(2)], movieTitle: "Fixture", language: "en") { message in
                    if message.hasPrefix("Фраза 2/2") { withUnsafeCurrentTask { $0?.cancel() } }
                }
        }
        let result = try await task.value
        #expect(result.wasCancelled)
        #expect(result.suggestions.map(\.id) == [1])
        #expect(result.checkedCount == 1)
        #expect(await model.requests.count == 1)
    }

    @Test func contextStaysInsideTheSameScene() {
        let concept = ThematicConcept(word: "ВИБІР", tagline: "", philosophicalPremise: "", suggestedTitle: "Тест")
        let acts = [LongformAct(type: .form, title: "Form", dramaticBeat: "", segments: [.init(start: 10, end: 20), .init(start: 50, end: 60)]),
                    LongformAct(type: .psychology, title: "Psychology", dramaticBeat: "", segments: [.init(start: 65, end: 75)])]
        let arc = LongformNarrativeArc(movieTitle: "Fixture", concept: concept, acts: acts, summary: "")
        func phrase(_ id: Int, _ act: Int, _ start: Double) -> EditableSubtitlePhrase {
            EditableSubtitlePhrase(id: UUID(), originalSegmentIndex: id, actIndex: act, actTitle: acts[act].title,
                actType: acts[act].type, start: start, end: start + 2, text: "Line \(id)", originalText: "Line \(id)")
        }
        let rows = EditableSubtitlePhrase.correctionInputs(from: [phrase(1, 0, 10), phrase(2, 0, 14), phrase(3, 0, 50), phrase(4, 1, 65)], arc: arc)
        #expect(rows[0].before.isEmpty)
        #expect(rows[0].after == "Line 2")
        #expect(rows[1].before == "Line 1")
        #expect(rows[1].after.isEmpty)
        #expect(rows[2].before.isEmpty && rows[2].after.isEmpty)
        #expect(rows[3].before.isEmpty)
    }
}
