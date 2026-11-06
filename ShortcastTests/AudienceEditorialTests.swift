import Foundation
import AppKit
import Testing
@testable import Shortcast

@Suite("Evidence-backed viewer promise")
struct AudienceEditorialTests {
    @Test("Spelling repair changes authored prose without replacing source evidence")
    func scopedSpellingRepair() async throws {
        let (arc, transcript) = fixture()
        let gateway = DirectorChatGateway(readiness: { true }, identifier: { "fixture" }, completion: { _, prompt, _ in
            if prompt.contains("COPY_TO_REVIEW:") { return #"{"approved":true,"issues":[]}"# }
            if prompt.contains("AUTHOR_TEXT:") {
                #expect(prompt.contains("Тепер ми всі в небезпеці."))
                return #"{"text":"Допомога одному ставить під загрозу інших."}"#
            }
            if prompt.contains("МАТЕРІАЛ АКТУ") { return #"{"text":"Допомога має ціну звищ.","line":1}"# }
            return #"{"title":"Чому допомога стає пасткою?","hook":"Чи можна допомогти без ризику?","coverText":"ЦІНА ДОПОМОГИ","openingLine":0}"#
        })
        let result = try await AudienceEditorialService(model: gateway).apply(to: arc, transcript: transcript)
        #expect(result.audienceEditorial?.bridges.first?.text == "Допомога одному ставить під загрозу інших.")
        #expect(result.audienceEditorial?.bridges.first?.quote == "Тепер ми всі в небезпеці.")
    }
    @Test("Editorial verdicts see only the dialogue for the claim being checked")
    func scopedReview() async throws {
        let (arc, transcript) = fixture()
        let gateway = DirectorChatGateway(readiness: { true }, identifier: { "fixture" }, completion: { _, prompt, _ in
            if prompt.contains("COPY_TO_REVIEW:") {
                let source = prompt.components(separatedBy: "END_SOURCE_REFERENCE")[0]
                if prompt.contains("\"form\":") {
                    #expect(source.contains("Тепер ми всі в небезпеці."))
                    #expect(!source.contains("Я хочу тобі допомогти."))
                } else {
                    #expect(source.contains("Я хочу тобі допомогти."))
                    #expect(!source.contains("Тепер ми всі в небезпеці."))
                }
                return #"{"approved":true,"issues":[]}"#
            }
            if prompt.contains("МАТЕРІАЛ АКТУ") {
                #expect(prompt.contains("Q1: Тепер ми всі в небезпеці."))
                return #"{"text":"Допомога одному ставить під загрозу інших.","line":1}"#
            }
            return #"{"title":"Чому допомога стає пасткою?","hook":"Чи можна допомогти без ризику?","coverText":"ЦІНА ДОПОМОГИ","openingLine":0}"#
        })
        let result = try await AudienceEditorialService(model: gateway).apply(to: arc, transcript: transcript)
        #expect(result.audienceEditorial?.approvalSource == "local-model")
    }
    func fixture() -> (LongformNarrativeArc, Transcript) {
        let concept = ThematicConcept(word: "ВИБІР", tagline: "Конфлікт", philosophicalPremise: "Допомога має наслідки", suggestedTitle: "Рішення героя", source: .llm)
        let acts = [LongformAct(type: .hook, title: "Вибір", dramaticBeat: "Допомога", segments: [.init(start: 10, end: 40)]),
                    LongformAct(type: .form, title: "Наслідки", dramaticBeat: "Вчинок змінює інших", segments: [.init(start: 50, end: 80)])]
        let arc = LongformNarrativeArc(movieTitle: "Тест", concept: concept, acts: acts, summary: "Конфлікт")
        let transcript = Transcript(segments: [.init(start: 11, end: 20, text: "Я хочу тобі допомогти."),
                                               .init(start: 52, end: 62, text: "Тепер ми всі в небезпеці.")], language: "uk")
        return (arc, transcript)
    }
    let raw = #"{"title":"Чому допомога стає пасткою?","hook":"Чи можна врятувати когось і не нашкодити іншим?","coverText":"ПАСТКА ДОПОМОГИ","openingQuote":"Я хочу тобі допомогти.","bridges":[{"role":"form","text":"Допомога одному герою ставить під загрозу інших.","quote":"Тепер ми всі в небезпеці."}]}"#

    @Test("The opening promise and every visible argument require their own scene's literal evidence")
    func evidence() throws {
        let (arc, transcript) = fixture()
        _ = try AudienceEditorialService.parse(raw, arc: arc, transcript: transcript)
        for invalid in [raw.replacingOccurrences(of: "Я хочу тобі допомогти.", with: "Тепер ми всі в небезпеці."),
                        raw.replacingOccurrences(of: "Тепер ми всі в небезпеці.", with: "Я хочу тобі допомогти."),
                        raw.replacingOccurrences(of: "\"form\"", with: "\"psychology\"")] {
            #expect(throws: (any Error).self) { try AudienceEditorialService.parse(invalid, arc: arc, transcript: transcript) }
        }
    }

    @Test("New evidence-backed editions start with the scene at zero and no opening blackout")
    func immediateOpening() throws {
        var (arc, transcript) = fixture()
        #expect(LongformTimeline(arc: arc).introDuration == 2.5)
        arc.audienceEditorial = try AudienceEditorialService.parse(raw, arc: arc, transcript: transcript)
        let timeline = LongformTimeline(arc: arc)
        #expect(timeline.placements.first?.start == 0)
        let ramps = LongformTransitionPlan.ramps(intro: 0, speechEnd: timeline.speechEnd, cuts: [], immediateOpening: true)
        #expect(ramps.allSatisfy { $0.start > 0 && $0.from == 1 })
        let decoded = try JSONDecoder().decode(LongformNarrativeArc.self, from: JSONEncoder().encode(arc))
        #expect(decoded.audienceEditorial == arc.audienceEditorial)
    }

    @Test("A promise cannot be justified only by dialogue after the first thirty seconds")
    func earlyEvidence() throws {
        var (arc, transcript) = fixture()
        arc.acts[0].segments = [.init(start: 10, end: 50)]
        transcript = Transcript(segments: [.init(start: 43, end: 47, text: "Я хочу тобі допомогти."),
                                           .init(start: 52, end: 62, text: "Тепер ми всі в небезпеці.")], language: "uk")
        #expect(throws: (any Error).self) { try AudienceEditorialService.parse(raw, arc: arc, transcript: transcript) }
    }

    @Test("Source line IDs resolve verbatim and cannot borrow another act's evidence")
    func lineEvidence() throws {
        let (arc, transcript) = fixture()
        var object = try #require(try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        object.removeValue(forKey: "openingQuote"); object["openingLine"] = 0
        var bridges = try #require(object["bridges"] as? [[String: Any]])
        bridges[0].removeValue(forKey: "quote"); bridges[0]["line"] = 1; object["bridges"] = bridges
        let reply = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        let parsed = try AudienceEditorialService.parse(reply, arc: arc, transcript: transcript)
        #expect(parsed.openingQuote == "Я хочу тобі допомогти.")
        #expect(parsed.bridges[0].quote == "Тепер ми всі в небезпеці.")
        object["openingLine"] = "L0: Я хочу тобі допомогти."
        bridges[0]["line"] = "L1: Тепер ми всі в небезпеці."
        object["bridges"] = bridges
        let labelled = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        #expect(try AudienceEditorialService.parse(labelled, arc: arc, transcript: transcript) == parsed)
        for invalid in ["L0 or L1", "-1", "L9999"] {
            object["openingLine"] = invalid
            let rejected = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
            #expect(throws: (any Error).self) { try AudienceEditorialService.parse(rejected, arc: arc, transcript: transcript) }
        }
        object["openingLine"] = 1
        let wrong = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        #expect(throws: (any Error).self) { try AudienceEditorialService.parse(wrong, arc: arc, transcript: transcript) }
    }

    @MainActor @Test("Shorts opening hook leaves the scene and faces unobstructed")
    func shortOpening() throws {
        let (arc, _) = fixture()
        let metadata = LongformMetadataGenerator.generate(movieTitle: arc.movieTitle, concept: arc.concept, arc: arc)
        let result = LongformBuildResult(outputURL: URL(fileURLWithPath: "/tmp/unused.mp4"), arc: arc, metadata: metadata, duration: 60)
        let short = EssayShort(id: "short1", angle: "Допомога", hook: "Чому допомога стає пасткою?", title: "Рішення героя", why: "Конфлікт", payoffQuote: "Я хочу тобі допомогти.", question: "Що далі?", segments: [.init(start: 10, end: 50)])
        let bitmap = NSBitmapImageRep(cgImage: try ShortBrandArtwork.hookHeader(short: short, result: result))
        for x in stride(from: 100, through: 1000, by: 100) {
            for y in stride(from: 600, through: 1300, by: 100) {
                #expect(bitmap.colorAt(x: x, y: y)?.alphaComponent == 0)
            }
        }
    }

    @Test("A malformed review is not a copy rejection and source ASR cannot be rewritten by the verdict")
    func reviewScope() throws {
        let copy = ["title": "Чому допомога стає пасткою?", "hook": "У героя є п'ять хвилин."]
        #expect(try AudienceEditorialService.reviewIssues(#"{"approved":true,"issues":[]}"#, copy: copy).isEmpty)
        let valid = #"{"approved":false,"issues":[{"field":"title","quote":"допомога","reason":"У джерелі не йдеться про допомогу"}]}"#
        #expect(try AudienceEditorialService.reviewIssues(valid, copy: copy).count == 1)
        for invalid in [#"{"approved":false,"issues":[]}"#,
                        valid.replacingOccurrences(of: "\"title\"", with: "\"source_quote\""),
                        valid.replacingOccurrences(of: "\"quote\":\"допомога\"", with: "\"quote\":\"вигаданий текст\""),
                        valid.replacingOccurrences(of: "false", with: "true")] {
            #expect(throws: (any Error).self) { try AudienceEditorialService.reviewIssues(invalid, copy: copy) }
        }
    }

    @Test("Opening recovery distinguishes an empty black frame from a dark but visible shot")
    func openingBlackout() throws {
        let context = try #require(CGContext(data: nil, width: 160, height: 90, bitsPerComponent: 8,
            bytesPerRow: 640, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 160, height: 90))
        #expect(OpeningFrameRecovery.isBlack(try #require(context.makeImage())))
        context.setFillColor(CGColor(gray: 0.1, alpha: 1)); context.fill(CGRect(x: 30, y: 30, width: 100, height: 30))
        #expect(!OpeningFrameRecovery.isBlack(try #require(context.makeImage())))
    }
}
