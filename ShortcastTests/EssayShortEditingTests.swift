import Foundation
import Testing
@testable import Shortcast

@Suite("Essay short editing")
struct EssayShortEditingTests {
    private func fixture() -> (LongformNarrativeArc, EssayShort) {
        let concept = ThematicConcept(word: "ВИБІР", tagline: "Ціна свободи",
            philosophicalPremise: "Вибір має наслідки", suggestedTitle: "Ціна вибору")
        let arc = LongformNarrativeArc(movieTitle: "Фільм", concept: concept,
            acts: [LongformAct(type: .hook, title: "Вибір", dramaticBeat: "Початок",
                              segments: [.init(start: 10, end: 60), .init(start: 90, end: 130)])], summary: "Тема")
        let short = EssayShort(id: "short1", angle: "Ціна свободи", hook: "Хто обирає?", title: "Вибір",
            why: "Діалог", payoffQuote: "Це твій вибір", question: "Яка ціна?", segments: [.init(start: 12, end: 52)])
        return (arc, short)
    }

    @Test("Edited scenes stay in the approved essay and reject broken ranges")
    func validatesCuts() throws {
        let (arc, short) = fixture()
        try EssayShortEditing.validate(short, arc: arc, sourceDuration: 150)
        for range in [TimeSegment(start: .nan, end: 50), .init(start: 50, end: 12),
                      .init(start: 12, end: 14), .init(start: 55, end: 95), .init(start: -1, end: 35)] {
            var edited = short; edited.segments = [range]
            #expect(throws: EssayReleaseError.self) {
                try EssayShortEditing.validate(edited, arc: arc, sourceDuration: 150)
            }
        }
        var tooLong = short; tooLong.segments = [.init(start: 10, end: 60), .init(start: 90, end: 120)]
        #expect(throws: EssayReleaseError.self) { try EssayShortEditing.validate(tooLong, arc: arc, sourceDuration: 150) }
    }

    @Test("Short caption edits survive saving and do not change essay or sibling captions")
    func persistsIndependentCaptions() throws {
        let (arc, short) = fixture()
        let line = TranscriptSegment(start: 15, end: 20, text: "Початкова репліка")
        var edited = short
        edited.captionEdits = [.init(start: 15, end: 20, original: line.text, replacement: "Виправлена репліка")]
        var sibling = short; sibling.id = "short2"
        let release = EssayRelease(essayKey: EssayRelease.key(for: arc), shorts: [edited, sibling])
        let loaded = try JSONDecoder().decode(EssayRelease.self, from: JSONEncoder().encode(release))
        #expect(loaded.shorts[0].captionEdits == edited.captionEdits)
        #expect(loaded.shorts[1].captionEdits == nil)
        #expect(arc.captionEdits == nil)
        #expect(LongformEditorialSupport.captions([line], edits: loaded.shorts[0].captionEdits)[0].text == "Виправлена репліка")
        #expect(LongformEditorialSupport.captions([line], edits: loaded.shorts[1].captionEdits)[0].text == line.text)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(edited)) as? [String: Any])
        json.removeValue(forKey: "captionEdits")
        #expect(try JSONDecoder().decode(EssayShort.self, from: JSONSerialization.data(withJSONObject: json)).captionEdits == nil)
    }

    @Test("Existing deliveries protect their short but do not lock an unpublished sibling")
    func protectsDeliveries() {
        let (arc, short) = fixture()
        var release = EssayRelease(essayKey: EssayRelease.key(for: arc), shorts: [short])
        release.receipts["essay.youtube"] = .init(state: .published, message: "done")
        release.receipts["short2.youtube"] = .init(state: .published, message: "done")
        #expect(EssayShortEditing.canEdit(short, in: release))
        for state in [EssayRelease.Receipt.State.sending, .published, .needsReview] {
            release.receipts["short1.youtube"] = .init(state: state, message: "check")
            #expect(!EssayShortEditing.canEdit(short, in: release))
        }
        release.receipts["short1.youtube"] = .init(state: .failed, message: "retry")
        #expect(EssayShortEditing.canEdit(short, in: release))
    }
}
