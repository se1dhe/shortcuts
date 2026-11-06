import Foundation
import AppKit
import AVFoundation
import QuartzCore
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
    @Test("A saved montage from another theme is refused before any media processing")
    func refusesStaleThemeDraft() async throws {
        let arc = editorialArc()
        var selected = arc.concept; selected.word = "БОРГ"
        do {
            _ = try await LongformPipelineCoordinator().buildLongformVideo(
                sourceURL: URL(fileURLWithPath: "/private/tmp/nonexistent-stale-theme.mp4"), movieTitle: arc.movieTitle,
                transcript: editorialTranscript(), concept: selected, audioSettings: .init(),
                existingArc: arc, channelLogoEnabled: false)
            Issue.record("A draft of another theme was accepted")
        } catch {
            #expect(error.localizedDescription.contains("другой теме"))
        }
    }
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
        #expect(result.editorialNotes?.contains(where: { $0.contains("не загружена") }) == true)
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
        let routed = LongformEditorialSupport.actionableCTA("Напишіть у коментарях: що є свобода?", destination: "https://t.me/valid_channel")
        #expect(routed?.contains("у Telegram") == true)
        #expect(routed?.contains("у коментарях") == false)
        #expect(routed?.contains("що є свобода?") == true)
        #expect(routed?.contains("https://t.me/valid_channel") == true)
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

@Suite("Donor credits")
struct EssaySupportCreditsTests {
    @MainActor
    @Test func realFinalCardKeepsTrailingTelegramURLVisibleWithCredits() throws {
        var arc = editorialArc()
        arc.conclusionText = "Вихід із ілюзії вимагає відмови від безпечного сценарію заради болісної, але автентичної реальності."
        arc.ctaText = "Обговоріть у Telegram: чи готові ви зруйнувати свій комфорт заради істини?"
        arc.discussionURL = "https://t.me/kadr_sens"
        let text = LongformEditorialSupport.finalCard(for: arc)
        #expect(text.hasSuffix("https://t.me/kadr_sens"))
        for canvas in [CGSize(width: 1920, height: 1080), CGSize(width: 1280, height: 720)] {
            let k = canvas.height / 1080
            let size = CGSize(width: canvas.width * 0.76, height: canvas.height * 0.24)
            let value = DonorCreditsRenderer.fittedCTA(text, in: size, scale: k)
            #expect(value.string == text)
            #expect((value.attribute(.kern, at: 0, effectiveRange: nil) as? NSNumber)?.doubleValue == Double(0.7 * k))
            let measured = value.boundingRect(with: CGSize(width: size.width, height: 100_000), options: [.usesLineFragmentOrigin, .usesFontLeading])
            #expect(ceil(measured.height) <= size.height - 12 * k)
            let storage = NSTextStorage(attributedString: value)
            let layout = NSLayoutManager()
            let container = NSTextContainer(size: CGSize(width: size.width, height: size.height - 12 * k))
            container.lineFragmentPadding = 0
            storage.addLayoutManager(layout); layout.addTextContainer(container)
            let visibleGlyphs = layout.glyphRange(for: container)
            #expect(NSMaxRange(visibleGlyphs) == layout.numberOfGlyphs)
            let url = (text as NSString).range(of: "https://t.me/kadr_sens")
            let urlGlyphs = layout.glyphRange(forCharacterRange: url, actualCharacterRange: nil)
            #expect(NSMaxRange(urlGlyphs) <= NSMaxRange(visibleGlyphs))
        }
    }

    @Test func donationLinkAndCreditsSurviveArchives() throws {
        var arc = editorialArc()
        arc.support = EssaySupport(creditsEnabled: true, nicknames: ["@NazarOrbit", "@MavkaMoon", "@KinoVoyager", "@TykhyiKosmos", "@ZorianyiLis", "@NebulaFox"])
        let restored = try JSONDecoder().decode(LongformNarrativeArc.self, from: JSONEncoder().encode(arc))
        #expect(restored.support == arc.support)
        let metadata = LongformMetadataGenerator.generate(movieTitle: arc.movieTitle, concept: arc.concept, arc: arc)
        #expect(metadata.description.contains("https://donatello.to/kadr_sens"))
        #expect(EssaySupport.names(from: "@Alpha\n alpha \n\n@Beta") == ["@Alpha", "@Beta"])
        #expect(EssaySupport.normalizedURL("https://donatello.to.evil.example/kadr_sens") == nil)
        let withCredits = LongformTimeline(arc: arc)
        arc.support?.creditsEnabled = false
        let without = LongformTimeline(arc: arc)
        #expect(withCredits.placements.map(\.start) == without.placements.map(\.start))
        #expect(withCredits.speechEnd == without.speechEnd)
        #expect(withCredits.outroDuration >= 8)
        #expect(without.supportExtraDuration == 0)
    }

    @MainActor
    @Test func realAnimationExport() async throws {
        guard let source = ProcessInfo.processInfo.environment["SHORTCAST_CREDITS_SMOKE_SOURCE"] else { return }
        let support = EssaySupport(creditsEnabled: true, nicknames: ["@NazarOrbit", "@MavkaMoon", "@KinoVoyager", "@TykhyiKosmos", "@ZorianyiLis", "@NebulaFox"])
        let canvas = CGSize(width: 1280, height: 720)
        let card = DonorCreditsRenderer.makeLayer(support: support,
            ctaText: "Обговорімо це есе в Telegram. Долучайтеся до розмови — посилання в описі.",
            theme: "ВІДПОВІДАЛЬНІСТЬ", start: 0, duration: 8, canvas: canvas)
        let viewport = try #require(card.sublayers?.first(where: { $0.name == "donorViewport" }))
        let names = try #require(viewport.sublayers?.first)
        #expect(names.sublayers?.count == 6)
        let animation = try #require(names.animation(forKey: "donorScroll") as? CAKeyframeAnimation)
        #expect(animation.duration == 8)
        let asset = AVURLAsset(url: URL(fileURLWithPath: source))
        let composition = AVMutableVideoComposition(propertiesOf: asset)
        composition.renderSize = canvas
        composition.frameDuration = CMTime(value: 1, timescale: 24)
        let parent = CALayer(); parent.frame = CGRect(origin: .zero, size: canvas)
        let video = CALayer(); video.frame = parent.bounds
        parent.addSublayer(video); parent.addSublayer(card)
        composition.animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: video, in: parent)
        let output = URL(fileURLWithPath: "/private/tmp/shortcast-donor-finale-preview.mp4")
        try? FileManager.default.removeItem(at: output)
        let exporter = try #require(AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality))
        exporter.videoComposition = composition
        try await exporter.export(to: output, as: .mp4)
        let rendered = AVURLAsset(url: output)
        let duration = try await rendered.load(.duration).seconds
        #expect(abs(duration - 8) < 0.1)
        let generator = AVAssetImageGenerator(asset: rendered)
        for second in [2, 4, 6] {
            let (image, _) = try await generator.image(at: CMTime(seconds: Double(second), preferredTimescale: 600))
            let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: "/private/tmp/shortcast-donor-preview-\(second).png"))
        }
    }
}

@Suite("Editorial review regressions")
struct EditorialReviewRegressionTests {
    private actor Model: LongformActTitleModeling {
        let reply: String
        private(set) var calls = 0
        init(_ reply: String) { self.reply = reply }
        var isReady: Bool { get async { true } }
        var modelID: String? { get async { "regression-fixture" } }
        func complete(instructions: String, prompt: String, maxTokens: Int) async -> String? {
            calls += 1
            return reply
        }
    }
    private func fixture() -> (LongformNarrativeArc, Transcript) {
        var arc = editorialArc()
        for index in arc.acts.indices where arc.acts[index].type == .catharsis {
            arc.acts[index].segments = arc.acts[index].segments.map { TimeSegment(start: $0.start, end: $0.end + 1) }
        }
        arc.acts[2].segments[1] = TimeSegment(start: 2107.38, end: 2142.86)
        let actualLines = [
            TranscriptSegment(start: 2101.94, end: 2104.98, text: "Головна складність колонізації — генетичне різноманіття."),
            TranscriptSegment(start: 2105.44, end: 2106.52, text: "А це все вирішує."),
            TranscriptSegment(start: 2107.38, end: 2108.94, text: "А що буде з людьми на землі?"),
            TranscriptSegment(start: 2110.24, end: 2112.96, text: "Кинете їх помирати? І моїх дітей?"),
            TranscriptSegment(start: 2113.04, end: 2116.48, text: "Саме тому план А привабливіший."),
            TranscriptSegment(start: 2141.04, end: 2142.86, text: "Даю тебе слово.")]
        let transcript = Transcript(segments: (editorialTranscript().segments + actualLines).sorted { $0.start < $1.start }, language: "uk")
        return (arc, transcript)
    }

    @Test func conjunctionIsNotAnUnresolvedReference() {
        #expect(!LongformEditorialSupport.openingNeedsContext("А що буде з людьми на землі?"))
        #expect(!LongformEditorialSupport.openingNeedsContext("Але люди ще можуть обрати майбутнє."))
        #expect(LongformEditorialSupport.openingNeedsContext("А це все вирішує."))
        #expect(LongformEditorialSupport.openingNeedsContext("Але він уже вирішив."))
    }

    @Test func repeatedRegressingContextDoesNotReplaceTheSelfContainedQuestion() async {
        let (arc, transcript) = fixture()
        #expect(LongformEditorialSupport.notes(for: arc, transcript: transcript).isEmpty)
        let model = Model(#"{"edits":[{"scene":8,"option":"context","reason":"Додати контекст"}],"notes":[]}"#)
        let outcome = await LongformEditorialReview(model: model).reviewDetailed(arc: arc, transcript: transcript, coldOpenEnabled: true) { _ in }
        #expect(await model.calls == 2)
        #expect(outcome.changes.isEmpty)
        #expect(outcome.arc.segments == arc.segments)
        #expect(outcome.arc.editorialNotes?.isEmpty == true)
        #expect(outcome.attempts.allSatisfy { !$0.accepted })
        #expect(outcome.summary.contains("Сохранено изменений сцен: 0"))
    }

    @Test func unresolvedKeepStopsAndExplainsTheActualProblem() async {
        let (arc, original) = fixture()
        var lines = original.segments
        let first = lines.firstIndex(where: { $0.start == 10 })!
        let originalLine = lines[first]
        lines[first] = TranscriptSegment(start: originalLine.start, end: originalLine.end, text: "Він уже обрав свою долю.")
        let transcript = Transcript(segments: lines, language: "uk")
        let model = Model(#"{"edits":[],"notes":["Потрібна звірка зі звуком: попередник займенника не визначений."]}"#)
        let outcome = await LongformEditorialReview(model: model).reviewDetailed(arc: arc, transcript: transcript, coldOpenEnabled: true) { _ in }
        #expect(await model.calls == 1)
        #expect(outcome.changes.isEmpty)
        #expect(!outcome.attempts[0].resolved)
        #expect(outcome.summary.contains("Потрібна звірка зі звуком"))
    }

    @Test func aRealContextImprovementIsStillApplied() async {
        let (arc, original) = fixture()
        var lines = original.segments
        let first = lines.firstIndex(where: { $0.start == 10 })!
        let originalLine = lines[first]
        lines[first] = TranscriptSegment(start: originalLine.start, end: originalLine.end, text: "Він уже обрав свою долю.")
        let transcript = Transcript(segments: lines, language: "uk")
        let model = Model(#"{"edits":[{"scene":1,"option":"context","reason":"Відновити попереднє питання"}],"notes":[]}"#)
        let outcome = await LongformEditorialReview(model: model).reviewDetailed(arc: arc, transcript: transcript, coldOpenEnabled: true) { _ in }
        #expect(await model.calls == 1)
        #expect(outcome.changes.count == 1)
        #expect(outcome.arc.editorialNotes?.isEmpty == true)
        #expect(outcome.attempts[0].resolved)
    }

    @Test func cachedFalseWarningIsRefreshedWithoutLosingSemanticAdvice() {
        let (original, transcript) = fixture()
        var arc = original
        let savedScene = arc.segments[7]
        arc.editorialNotes = ["Акт 3, сцена 2: вход может требовать предыдущего контекста: «А що буде з людьми на землі?».",
                              "Звірте мотивацію героя з діалогом."]
        let notes = LongformEditorialSupport.refreshedNotes(for: arc, transcript: transcript)
        #expect(notes == ["Звірте мотивацію героя з діалогом."])
        #expect(arc.segments[7] == savedScene)
    }

    @Test func noOpEditsAreNotReportedAsSavedChanges() {
        var (arc, _) = fixture()
        let range = arc.acts[0].segments[0]
        arc.sceneEdits = [LongformSceneEdit(role: .hook, original: range, revised: range, reason: "Вернули исходную границу")]
        #expect(LongformEditorialSupport.recordingEdits(from: arc, acts: arc.acts).isEmpty)
    }
}
