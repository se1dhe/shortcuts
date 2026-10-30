import Foundation
import AppKit
import Testing
@testable import Shortcast

private func editorialArc() -> LongformNarrativeArc {
    let concept = ThematicConcept(word: "СВОБОДА", tagline: "Ціна власного вибору",
        philosophicalPremise: "Свобода потребує відповідальності", suggestedTitle: "Ціна вибору", source: .llm)
    var number = 0
    let acts = LongformActType.canonicalAnalyticOrder.map { role in
        let ranges = (0..<3).map { _ -> TimeSegment in
            defer { number += 1 }
            return TimeSegment(start: Double(number * 60 + 10), end: Double(number * 60 + 35))
        }
        return LongformAct(type: role, title: role.promptKey, dramaticBeat: "Що доводить акт", segments: ranges)
    }
    return LongformNarrativeArc(id: "editorial-test", movieTitle: "Фільм", concept: concept,
                               acts: acts, summary: "", mood: "dramatic")
}

private func editorialTranscript() -> Transcript {
    var lines: [TranscriptSegment] = []
    for index in 0..<15 {
        let base = Double(index * 60)
        lines += [TranscriptSegment(start: base + 7, end: base + 9, text: "Попередня думка."),
                  TranscriptSegment(start: base + 10, end: base + 14, text: "Чому це важливо?"),
                  TranscriptSegment(start: base + 15, end: base + 35, text: "Людина відповідає за власний вибір."),
                  TranscriptSegment(start: base + 43, end: base + 45, text: "Наступна думка.")]
    }
    return Transcript(segments: lines, language: "uk")
}

@Suite("Longform editorial regression")
struct LongformEditorialTests {
    @Test("Chapters use the render timeline including act gaps and disabled intro")
    func exactChapters() {
        let arc = editorialArc()
        let timeline = LongformTimeline(arc: arc, coldOpenEnabled: false)
        #expect(timeline.start(ofAct: 0) == 0)
        #expect(timeline.start(ofAct: 1) == 75.8)
        #expect(abs((timeline.start(ofAct: 4) ?? 0) - 303.2) < 0.001)
        #expect(abs(timeline.duration - 382.2) < 0.001)
        let metadata = LongformMetadataGenerator.generate(movieTitle: arc.movieTitle, concept: arc.concept,
                                                          arc: arc, timeline: timeline)
        #expect(metadata.description.contains("01:15 — Акт II:"))
        #expect(metadata.description.contains("05:03 — Акт V:"))
        #expect(!metadata.description.contains("00:00 — Вступ"))
    }

    @Test("Empty acts add neither phantom gaps nor chapter markers")
    func emptyActs() {
        var arc = editorialArc()
        arc.acts[1].segments = []
        let timeline = LongformTimeline(arc: arc)
        #expect(timeline.start(ofAct: 1) == nil)
        #expect(timeline.start(ofAct: 2) == 78.3)
        let metadata = LongformMetadataGenerator.generate(movieTitle: arc.movieTitle, concept: arc.concept, arc: arc)
        #expect(!metadata.description.contains("Акт II:"))
        #expect(metadata.description.contains("01:18 — Акт III:"))
    }

    @Test("Fades inside an act preserve exact source duration without extra black pauses")
    func directCuts() {
        let timeline = LongformTimeline(arc: editorialArc())
        #expect(timeline.placements[1].start == timeline.placements[0].end)
        #expect(timeline.placements[1].gapBefore == 0)
        #expect(timeline.placements[3].gapBefore == 0.8)
    }

    @Test("Every intra-act cut dips to black and returns; act pauses stay black")
    func allSceneFades() throws {
        let cuts = [LongformCutTransition(sceneEndTime: 12, nextSceneStartTime: 12, isInterAct: false),
                    LongformCutTransition(sceneEndTime: 24, nextSceneStartTime: 24.8, isInterAct: true)]
        let ramps = LongformTransitionPlan.ramps(intro: 2.5, speechEnd: 50, cuts: cuts)
        let down = try #require(ramps.first { $0.to == 0 && $0.end == 12 })
        let up = try #require(ramps.first { $0.from == 0 && abs($0.start - 12.001) < 0.0001 })
        #expect(abs(down.start - 11.72) < 0.0001)
        #expect(up.end == 12.32)
        #expect(ramps.contains { $0.to == 0 && $0.end == 24 })
        #expect(ramps.contains { $0.from == 0 && $0.start == 24.8 })
    }

    @Test("Short shots cannot overlap opacity ramps or extend beyond the timeline", arguments: [0.0, 2.5])
    func boundedFades(intro: Double) {
        let cuts = stride(from: intro + 0.05, through: intro + 3, by: 0.05).map {
            LongformCutTransition(sceneEndTime: $0, nextSceneStartTime: $0, isInterAct: false)
        }
        let ramps = LongformTransitionPlan.ramps(intro: intro, speechEnd: intro + 3.01, cuts: cuts)
        #expect(ramps.allSatisfy { $0.start >= 0 && $0.end <= intro + 3.01 && $0.end > $0.start })
        #expect(zip(ramps, ramps.dropFirst()).allSatisfy { $0.end < $1.start })
        #expect(LongformTransitionPlan.ramps(intro: intro, speechEnd: .nan, cuts: cuts).isEmpty)
    }

    @Test("Caption corrections retain source text, confidence and analysis fingerprint")
    func captionOverrides() throws {
        let source = TranscriptSegment(start: 1, end: 4, text: "Без соня стирає межі.",
                                       avgLogprob: -0.25, noSpeechProb: 0.01)
        let original = Transcript(segments: [source], language: "uk")
        let fingerprint = ThematicAnalysisCache.fingerprint(of: original)
        let edits = LongformEditorialSupport.captionEdits(original: original.segments,
            updated: [TranscriptSegment(start: 1, end: 4, text: "Безсоння стирає межі.")])
        let captions = LongformEditorialSupport.captions(original.segments, edits: edits)
        #expect(captions.first?.text == "Безсоння стирає межі.")
        #expect(captions.first?.avgLogprob == -0.25)
        #expect(original.segments.first?.text == "Без соня стирає межі.")
        #expect(ThematicAnalysisCache.fingerprint(of: original) == fingerprint)
        let changedSource = [TranscriptSegment(start: 1, end: 4, text: "Інший дубляж.")]
        #expect(LongformEditorialSupport.captions(changedSource, edits: edits) == changedSource)
    }

    @Test("Local model edits are limited to provided options and retain their anchor")
    func groundedEdit() throws {
        let arc = editorialArc()
        let reply = #"{"edits":[{"scene":1,"option":"context","reason":"Повернути питання"}],"notes":[],"hook":"Чого коштує вибір?","conclusion":"Свобода починається з відповідальності."}"#
        let revised = try #require(LongformEditorialReview.apply(reply, to: arc,
            transcript: editorialTranscript(), coldOpenEnabled: true))
        #expect(revised.acts[0].segments[0].start == 7)
        #expect(revised.acts.map(\.type) == arc.acts.map(\.type))
        #expect(revised.sceneEdits?.first?.original == arc.acts[0].segments[0])
        #expect(revised.sceneEdits?.first?.reason == "Повернути питання")
        #expect(revised.conclusionText == "Свобода починається з відповідальності.")
    }

    @Test("Local montage review preserves the approved model title and hook")
    func preservesSemanticChoice() throws {
        var arc = editorialArc()
        arc.hookText = "Хто відповідає за твій вибір?"
        let reply = #"{"edits":[],"notes":[],"title":"Інша назва","hook":"Інше питання?"}"#
        let reviewed = try #require(LongformEditorialReview.apply(reply, to: arc,
            transcript: editorialTranscript(), coldOpenEnabled: true))
        #expect(reviewed.hookText == arc.hookText)
        #expect(reviewed.publicationTitle == arc.concept.suggestedTitle)
        arc.publicationTitle = "Редакторська назва"
        let manual = try #require(LongformEditorialReview.apply(reply, to: arc,
            transcript: editorialTranscript(), coldOpenEnabled: true))
        #expect(manual.publicationTitle == arc.publicationTitle)
    }

    @Test("Unknown options, scene IDs and repeated edits reject the whole model reply", arguments: [
        #"{"edits":[{"scene":1,"option":"invented","reason":"x"}],"notes":[]}"#,
        #"{"edits":[{"scene":99,"option":"keep","reason":"x"}],"notes":[]}"#,
        #"{"edits":[{"scene":1,"option":"keep","reason":"x"},{"scene":1,"option":"context","reason":"x"}],"notes":[]}"#
    ])
    func rejectsBadPatch(reply: String) {
        #expect(LongformEditorialReview.apply(reply, to: editorialArc(),
            transcript: editorialTranscript(), coldOpenEnabled: true) == nil)
    }

    @Test("Aftermath option includes silent action after the last spoken line")
    func silentAftermath() throws {
        let options = LongformEditorialReview.options(for: TimeSegment(start: 10, end: 35),
                                                     transcript: editorialTranscript())
        #expect(try #require(options.first { $0.id == "aftermath" }).range.end == 41)
        #expect(options.allSatisfy { LongformEditorialSupport.allowed($0.range, around: TimeSegment(start: 10, end: 35)) })
    }

    @Test("Scene gate accepts recorded context edits and rejects unrecorded or excessive expansion")
    func sceneGate() throws {
        let arc = editorialArc()
        let moments = arc.acts.flatMap { act in act.segments.map {
            SelectedMoment(startTime: $0.start, endTime: $0.end, reason: "Матеріал", dramaticWeight: 0.8,
                           actRole: act.type, supports: "Теза", evidenceQuote: "Слова матеріалу")
        } }
        var revised = arc
        revised.acts[0].segments[0] = TimeSegment(start: 7, end: 35)
        #expect(throws: (any Error).self) {
            try EssaySceneEvidence.validateArc(revised, selectedMoments: moments, coldOpenEnabled: true)
        }
        revised.sceneEdits = LongformEditorialSupport.recordingEdits(from: arc, acts: revised.acts)
        try EssaySceneEvidence.validateArc(revised, selectedMoments: moments, coldOpenEnabled: true)
        revised.acts[0].segments[0] = TimeSegment(start: 0, end: 35)
        revised.sceneEdits = LongformEditorialSupport.recordingEdits(from: arc, acts: revised.acts)
        #expect(throws: (any Error).self) {
            try EssaySceneEvidence.validateArc(revised, selectedMoments: moments, coldOpenEnabled: true)
        }
    }

    @Test("Subtitle suggestions are saved separately and never silently applied")
    func suggestions() throws {
        let reply = #"{"edits":[],"notes":[],"captionSuggestions":[{"line":1,"text":"Виправлена репліка?","reason":"Перевірити слово"},{"line":999,"text":"Вигадана репліка","reason":"x"}]}"#
        let transcript = editorialTranscript()
        let result = try #require(LongformEditorialReview.apply(reply, to: editorialArc(),
            transcript: transcript, coldOpenEnabled: true))
        #expect(result.captionSuggestions?.count == 1)
        #expect(result.captionEdits == nil)
        #expect(transcript.segments[1].text == "Чому це важливо?")
    }

    @Test("Missing model produces visible editorial notes instead of claiming a review")
    func noModel() async {
        let result = await LongformEditorialReview(model: nil).review(arc: editorialArc(),
            transcript: editorialTranscript(), coldOpenEnabled: true)
        #expect(result.acts == editorialArc().acts)
        #expect(result.editorialNotes?.contains(where: { $0.contains("недоступен") }) == true)
    }

    @Test("CTA has an actionable destination and final text gets enough reading time")
    func finalCard() {
        #expect(LongformEditorialSupport.actionableCTA("Обговоріть у нашому Telegram: що є свобода?")
                == "Напишіть у коментарях: що є свобода?")
        #expect(LongformEditorialSupport.actionableCTA("Приєднуйся: t.me/example") == "Приєднуйся: t.me/example")
        #expect(LongformEditorialSupport.finalCardDuration(text: "") == 4)
        var arc = editorialArc()
        arc.conclusionText = "Свобода починається з відповідальності за власний вибір."
        arc.ctaText = "Обговоріть у нашому Telegram: що для вас означає свобода?"
        let timeline = LongformTimeline(arc: arc)
        #expect(timeline.outroDuration > 4)
        #expect(LongformEditorialSupport.finalCard(for: arc).contains("Напишіть у коментарях"))
        #expect(LongformEditorialSupport.telegramURL(channelID: "@valid_channel") == "https://t.me/valid_channel")
        #expect(LongformEditorialSupport.telegramURL(channelID: "-1001234567890") == nil)
        #expect(LongformEditorialSupport.telegramURL(channelID: "https://evil.example/channel") == nil)
        arc.discussionURL = "https://t.me/valid_channel"
        #expect(LongformEditorialSupport.finalCard(for: arc).contains("https://t.me/valid_channel"))
        #expect(LongformMetadataGenerator.generate(movieTitle: arc.movieTitle, concept: arc.concept, arc: arc)
            .description.contains("Telegram: https://t.me/valid_channel"))
    }

    @Test("Silent catharsis tail is bounded and never crosses the next scene")
    func actionTailProtection() {
        let arc = editorialArc()
        let protected = LongformEditorialReview.protectingActionTails(in: arc,
            transcript: editorialTranscript(), coldOpenEnabled: true)
        #expect(protected.acts.last?.segments.first?.end == (arc.acts.last?.segments.first?.end ?? 0) + 6)
        let twice = LongformEditorialReview.protectingActionTails(in: protected,
            transcript: editorialTranscript(), coldOpenEnabled: true)
        #expect(twice == protected, "повторный проход не должен наращивать один и тот же хвост")
        #expect(protected.segments.allSatisfy { $0.duration <= 40 })
    }

    @Test("String line IDs are normalized; service markup is not displayed")
    func lineAliasesAndMarkup() throws {
        let raw = #"{"edits":[],"notes":[],"hook":"Що залиша<image|>ється?","captionSuggestions":[{"line":"L1","text":"Виправлена репліка?","reason":"Перевірити"}]}"#
        let result = try #require(LongformEditorialReview.apply(raw, to: editorialArc(),
            transcript: editorialTranscript(), coldOpenEnabled: true))
        #expect(result.hookText == "Що залишається?")
        #expect(result.captionSuggestions?.count == 1)
        #expect(result.captionEdits == nil)
    }

    @Test("Editorial fields survive a project round trip")
    func persistence() throws {
        var arc = editorialArc()
        arc.publicationTitle = "Вичитана назва"
        arc.conclusionText = "Підсумок."
        arc.captionEdits = [LongformCaptionEdit(start: 1, end: 2, original: "помилка", replacement: "правка")]
        arc.editorialNotes = ["Перевірте межі"]
        let decoded = try JSONDecoder().decode(LongformNarrativeArc.self, from: JSONEncoder().encode(arc))
        #expect(decoded == arc)
        let settings = LongformAudioSettings(backgroundMusicURL: URL(fileURLWithPath: "/tmp/test.mp3"), musicVolume: 0.03)
        let result = LongformBuildResult(outputURL: URL(fileURLWithPath: "/tmp/test.mp4"), arc: arc,
            metadata: LongformMetadataGenerator.generate(movieTitle: arc.movieTitle, concept: arc.concept, arc: arc),
            duration: 390, audioSettings: settings)
        let restored = try JSONDecoder().decode(LongformBuildResult.self, from: JSONEncoder().encode(result))
        #expect(restored.audioSettings == settings)
    }

    @Test("Preview uses the export caption band below the central word")
    @MainActor func previewGeometry() throws {
        let arc = editorialArc()
        let size = CGSize(width: 1920, height: 1080)
        let frame = LongformSubtitleRenderer.captionRect(textWidth: 700, textHeight: 42,
            renderSize: size, conceptY: 500, k: 1)
        #expect(frame.minY >= size.height * 0.25)
        #expect(abs(frame.maxY - 460) < 0.001)
        let multiline = LongformSubtitleRenderer.captionRect(textWidth: 700, textHeight: 126,
            renderSize: size, conceptY: 500, k: 1)
        #expect(multiline.maxY == frame.maxY)
        #expect(multiline.minY < frame.minY)
        let image = try #require(LongformSubtitleRenderer().renderPreviewImage(renderSize: size,
            concept: arc.concept, currentPhrase: "Ти не твоя робота"))
        let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: "/private/tmp/shortcast-editorial-preview.png"))
    }
}
