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
