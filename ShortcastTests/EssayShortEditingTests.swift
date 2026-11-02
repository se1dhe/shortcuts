import Foundation
import AVFoundation
import AppKit
import SwiftUI
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

    @Test("Manual cuts can use the full film, while broken and out-of-source ranges are rejected")
    func validatesCuts() throws {
        let (arc, short) = fixture()
        try EssayShortEditing.validate(short, arc: arc, sourceDuration: 150)
        for range in [TimeSegment(start: .nan, end: 50), .init(start: 50, end: 12),
                      .init(start: 12, end: 14), .init(start: 125, end: 165), .init(start: -1, end: 35)] {
            var edited = short; edited.segments = [range]
            #expect(throws: EssayReleaseError.self) {
                try EssayShortEditing.validate(edited, arc: arc, sourceDuration: 150)
            }
        }
        var extended = short; extended.segments = [.init(start: 55, end: 95)]
        try EssayShortEditing.validate(extended, arc: arc, sourceDuration: 150)
        var tooLong = short; tooLong.segments = [.init(start: 10, end: 60), .init(start: 90, end: 120)]
        #expect(throws: EssayReleaseError.self) { try EssayShortEditing.validate(tooLong, arc: arc, sourceDuration: 150) }
    }

    @Test("Manual edits can shrink or extend model-selected scenes and survive reopening")
    func filmSourceBounds() throws {
        let (arc, original) = fixture()
        var short = original
        short.segments = [.init(start: 200, end: 245)]
        short.selectedSourceSegments = short.segments
        short.selectionVersion = EssayShortDirector.selectionVersion
        let saved = try JSONDecoder().decode(EssayShort.self, from: JSONEncoder().encode(short))
        try EssayShortEditing.validate(saved, arc: arc, sourceDuration: 300)
        short.segments = [.init(start: 205, end: 240)]
        try EssayShortEditing.validate(short, arc: arc, sourceDuration: 300)
        short.segments = [.init(start: 195, end: 250)]
        try EssayShortEditing.validate(short, arc: arc, sourceDuration: 300)
        let reopened = try JSONDecoder().decode(EssayShort.self, from: JSONEncoder().encode(short))
        try EssayShortEditing.validate(reopened, arc: arc, sourceDuration: 300)
        #expect(reopened.segments == short.segments)
        short.selectedSourceSegments = nil
        try EssayShortEditing.validate(short, arc: arc, sourceDuration: 300)
        #expect(original.selectedSourceSegments == nil)
    }

    @Test("A manually trimmed component can be shorter than the essay's 18 second minimum")
    func shortSceneMinimum() throws {
        let (arc, original) = fixture()
        var short = original
        short.segments = [.init(start: 12, end: 24), .init(start: 200, end: 203)]
        try EssayShortEditing.validate(short, arc: arc, sourceDuration: 300)
        short.segments[1].end = 202.9
        #expect(throws: EssayReleaseError.self) { try EssayShortEditing.validate(short, arc: arc, sourceDuration: 300) }
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

@Suite("Editor timeline mapping")
struct EditorTimelineTests {
    private func clips() -> [EditorTimelineClip] {
        [.init(id: UUID(), start: 100, end: 110, isAdded: false),
         .init(id: UUID(), start: 20, end: 25, isAdded: false),
         .init(id: UUID(), start: 100, end: 110, isAdded: true)]
    }

    @Test("Seeking across a cut uses the next scene's source clock, including repeated footage")
    func sourceCuts() throws {
        let clips = clips()
        let first = try #require(EditorTimelineMapping.position(at: 5, clips: clips))
        #expect(first.sourceTime == 105 && first.id == clips[0].id)
        let cut = try #require(EditorTimelineMapping.position(at: 10, clips: clips))
        #expect(cut.sourceTime == 20 && cut.id == clips[1].id)
        let repeated = try #require(EditorTimelineMapping.position(at: 20, clips: clips))
        #expect(repeated.sourceTime == 105 && repeated.id == clips[2].id)
        #expect(EditorTimelineMapping.sequenceTime(sourceTime: 105, clipID: clips[0].id, clips: clips) == 5)
        #expect(EditorTimelineMapping.sequenceTime(sourceTime: 105, clipID: clips[2].id, clips: clips) == 20)
    }

    @Test("Source-time mapping follows clip identity after reordering and trimming")
    func edits() {
        let clips = clips()
        var reordered = [clips[2], clips[1], clips[0]]
        #expect(EditorTimelineMapping.sequenceTime(sourceTime: 105, clipID: clips[2].id, clips: reordered) == 5)
        reordered[0] = .init(id: clips[2].id, start: 103, end: 110, isAdded: true)
        #expect(EditorTimelineMapping.sequenceTime(sourceTime: 105, clipID: clips[2].id, clips: reordered) == 2)
        #expect(EditorTimelineMapping.sequenceTime(sourceTime: 100, clipID: clips[2].id, clips: reordered) == 0)
        #expect(EditorTimelineMapping.sequenceTime(sourceTime: 105, clipID: UUID(), clips: reordered) == nil)
    }

    @Test("The playhead maps correctly through minimum-width clips, gaps and zoom")
    func minimumWidthsAndZoom() {
        let clips = [EditorTimelineClip(id: UUID(), start: 100, end: 101, isAdded: false),
                     .init(id: UUID(), start: 200, end: 209, isAdded: false)]
        let layout = EditorTimelineGeometry(clips: clips, widths: [72, 90], spacing: 2)
        #expect(layout.x(for: 0.5) == 48)
        #expect(layout.x(for: 1) == 86)
        #expect(layout.time(at: 85) == 1)
        #expect(layout.time(at: 131) == 5.5)
        #expect(layout.x(for: 10) == 176)
        for widths: [CGFloat] in [[72, 90], [144, 180], [216, 270]] {
            let zoomed = EditorTimelineGeometry(clips: clips, widths: widths, spacing: 2)
            for time in [0.0, 0.2, 0.9, 1, 1.1, 5.5, 9.9, 10] {
                #expect(abs(zoomed.time(at: zoomed.x(for: time)) - time) < 0.000001)
            }
        }
    }

    @Test("Seeking clamps to the sequence and rejects non-finite positions")
    func edgeCases() {
        let clips = clips()
        #expect(EditorTimelineMapping.position(at: -20, clips: clips)?.sourceTime == 100)
        #expect(EditorTimelineMapping.position(at: 500, clips: clips)?.sourceTime == 110)
        #expect(EditorTimelineMapping.position(at: 500, clips: clips)?.sequenceTime == 25)
        #expect(EditorTimelineMapping.position(at: .nan, clips: clips) == nil)
        #expect(EditorTimelineMapping.position(at: .infinity, clips: clips) == nil)
        #expect(EditorTimelineMapping.position(at: 0, clips: []) == nil)
        let layout = EditorTimelineGeometry(clips: clips, widths: [72, 72, 72], spacing: 2)
        #expect(layout.time(at: -100) == 0)
        #expect(layout.time(at: 10000) == 25)
        #expect(layout.time(at: .nan) == 0)
    }
}


@Suite("Montage timeline playback", .serialized)
@MainActor
struct MontageTimelinePlaybackTests {
    @Test("Latest seek wins and real playback advances through disjoint source scenes")
    func sourceClockAndCuts() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("timeline-source.mp4")
        let generated = try await ProcessRunner.shared.run(executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"),
            arguments: ["-v", "error", "-f", "lavfi", "-i", "testsrc2=size=160x90:rate=30",
                "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000", "-t", "3",
                "-c:v", "libx264", "-preset", "ultrafast", "-c:a", "aac", source.path])
        #expect(generated.isSuccess)
        let clips = [EditorTimelineClip(id: UUID(), start: 0.2, end: 0.7, isAdded: false),
                     .init(id: UUID(), start: 2, end: 2.5, isAdded: false)]
        let playback = MontageTimelinePlayback()
        playback.audio.setVolume(0)
        playback.open(url: source, clips: clips)
        defer { playback.close() }
        playback.scrub(to: 0.8, editing: true)
        playback.scrub(to: 0.2, editing: true)
        playback.scrub(to: 0.7, editing: false)
        for _ in 0..<150 {
            if abs((playback.player?.currentTime().seconds ?? 0) - 2.2) < 0.08 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(playback.activeClipID == clips[1].id)
        #expect(abs((playback.player?.currentTime().seconds ?? 0) - 2.2) < 0.08)
        #expect(abs(playback.currentTime - 0.7) < 0.08)

        playback.scrub(to: 0, editing: false)
        playback.toggle()
        for _ in 0..<200 {
            if !playback.isPlaying { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(playback.error == nil)
        #expect(!playback.isPlaying)
        #expect(playback.activeClipID == clips[1].id)
        #expect(playback.currentTime > 0.9 && playback.currentTime <= 1.01)

        playback.setClips([clips[1], clips[0]])
        #expect(playback.activeClipID == clips[1].id)
        #expect(playback.currentTime < 0.51)
    }
}


@Suite("Timeline editor live QA", .enabled(if: ProcessInfo.processInfo.environment["SHORTCAST_TIMELINE_UI"] == "1"))
@MainActor
struct TimelineEditorLiveQATests {
    @Test func opensBothEditorsWithDisposableMedia() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp/shortcast-timeline-ui")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let done = directory.appendingPathComponent("done")
        try? FileManager.default.removeItem(at: done)
        let source = directory.appendingPathComponent("source.mp4")
        let generated = try await ProcessRunner.shared.run(executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"),
            arguments: ["-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=30",
                "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000", "-t", "24", "-af", "volume=0.0001",
                "-c:v", "libx264", "-preset", "ultrafast", "-c:a", "aac", source.path])
        #expect(generated.isSuccess)
        let concept = ThematicConcept(word: "РИТМ", tagline: "Перевірка монтажу", philosophicalPremise: "Зв'язок сцен", suggestedTitle: "Ритм історії")
        let ranges: [TimeSegment] = [.init(start: 1, end: 9), .init(start: 15, end: 23)]
        let arc = LongformNarrativeArc(movieTitle: "Перевірка монтажної", concept: concept,
            acts: [.init(type: .hook, title: "Початок", dramaticBeat: "Вхід", segments: [ranges[0]]),
                   .init(type: .catharsis, title: "Фінал", dramaticBeat: "Відповідь", segments: [ranges[1]])], summary: "Тест")
        let transcript = Transcript(segments: [.init(start: 2, end: 5, text: "Перша сцена монтажу"),
                                             .init(start: 16, end: 19, text: "Друга сцена монтажу")], language: "uk")
        let result = LongformBuildResult(outputURL: source, arc: arc,
            metadata: LongformMetadataGenerator.generate(movieTitle: arc.movieTitle, concept: concept, arc: arc), duration: 19)
        let short = EssayShort(id: "short1", angle: "Ритм", hook: "Як працює монтаж?", title: "Перевірка", why: "Дві сцени",
            payoffQuote: "Друга сцена монтажу", question: "Який ритм?", segments: ranges)
        let workspace = WorkspaceModel()
        let settings = AppSettings()
        let view = TabView {
            LongformActEditorView(arc: arc, concept: concept, movieTitle: arc.movieTitle,
                transcriptSegments: transcript.segments, sourceURL: source, onApply: { _ in }, onCancel: {})
                .tabItem { Text("Эссе") }
            EssayShortEditorView(short: short, result: result, transcript: transcript, sourceURL: source, onSave: { _ in })
                .tabItem { Text("Шортс") }
        }.environment(workspace).environment(settings)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1340, height: 1000),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Проверка монтажной Shortcast"
        window.contentViewController = NSHostingController(rootView: view)
        window.setContentSize(NSSize(width: 1340, height: 900))
        window.center(); window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        defer { window.close() }
        print("TIMELINE_UI_READY")
        for _ in 0..<2400 {
            if FileManager.default.fileExists(atPath: done.path) { return }
            try await Task.sleep(for: .milliseconds(200))
        }
        Issue.record("The UI QA session timed out before completion")
    }
}

@Suite("Short visual evidence")
struct EssayShortVisualEvidenceTests {
    @Test("Vision prompt explicitly lists every row once in its JSON skeleton")
    func explicitRowCount() {
        let windows = ["S1", "S2"].map { EssayShortDirector.Window(id: $0, segments: [.init(start: 10, end: 50)], text: "Репліка") }
        let prompt = EssayShortVisualReviewer.reviewPrompt(batch: windows, movie: "Фільм")
        #expect(prompt.contains("exactly 2 candidate ROWS"))
        #expect(prompt.contains("Return exactly 2 assessments total"))
        #expect(prompt.components(separatedBy: "\"candidateID\":\"S1\"").count == 2)
        #expect(prompt.components(separatedBy: "\"candidateID\":\"S2\"").count == 2)
        #expect(prompt.contains("Timestamps label frames, not separate candidates"))
    }

    @Test("Frame probes stay inside disjoint source ranges")
    func boundedSamples() {
        let window = EssayShortDirector.Window(id: "S1", segments: [.init(start: 10, end: 20), .init(start: 90, end: 120)], text: "Репліка")
        let times = EssayShortVisualReviewer.sampleTimes(in: window)
        #expect(times.count == 3)
        for (actual, expected) in zip(times, [13.2, 100, 116.8]) { #expect(abs(actual - expected) < 0.0001) }
        #expect(times.allSatisfy { time in window.segments.contains { time >= $0.start && time <= $0.end } })
        #expect(EssayShortVisualReviewer.sampleTimes(in: .init(id: "bad", segments: [], text: "")).isEmpty)
    }

    @Test("Vision cannot omit, duplicate or invent candidate IDs or scores")
    func assessmentValidation() throws {
        let good = #"{"candidates":[{"candidateID":"S2","score":4,"confidence":0.8,"observation":"Видима напружена реакція"},{"candidateID":"S1","score":2,"confidence":0.4,"observation":"Обличчя дрібне"}]}"#
        let decoded = try EssayShortVisualReviewer.assessments(from: good, expectedIDs: ["S1", "S2"])
        #expect(decoded.count == 2)
        for bad in [good.replacingOccurrences(of: "S2", with: "S1"),
                    good.replacingOccurrences(of: "S2", with: "S99"),
                    good.replacingOccurrences(of: "\"score\":4", with: "\"score\":9"),
                    good.replacingOccurrences(of: "\"confidence\":0.8", with: "\"confidence\":1.2")] {
            #expect(throws: EssayReleaseError.self) {
                try EssayShortVisualReviewer.assessments(from: bad, expectedIDs: ["S1", "S2"])
            }
        }
        #expect(throws: EssayReleaseError.self) {
            try EssayShortVisualReviewer.assessments(from: good, expectedIDs: ["S1"])
        }
    }

    @Test("Visual provenance survives archive round-trip without changing source bounds")
    func provenanceRoundTrip() throws {
        var short = EssayShort(id: "short1", angle: "Вибір", hook: "Хто обирає?", title: "Вибір", why: "Діалог",
            payoffQuote: "Це твій вибір", question: "Яка ціна?", segments: [.init(start: 10, end: 50)])
        short.visualEvidence = .init(modelID: "test-vision", sampledTimes: [13.2, 30, 46.8], score: 4,
                                     confidence: 0.8, observation: "Видима реакція")
        let saved = try JSONDecoder().decode(EssayShort.self, from: JSONEncoder().encode(short))
        #expect(saved == short)
        #expect(saved.segments == short.segments)
    }

    @Test("Manual cuts expose missing historical probes without discarding provenance")
    func visualCoverageAfterManualCuts() throws {
        let evidence = EssayShortVisualEvidence(modelID: "vision", sampledTimes: [13, 30, 47],
            score: 4, confidence: 0.8, observation: "Реакція героя")
        #expect(evidence.retainedSampleCount(in: [.init(start: 10, end: 50)]) == 3)
        #expect(evidence.retainedSampleCount(in: [.init(start: 20, end: 40)]) == 1)
        #expect(evidence.retainedSampleCount(in: [.init(start: 90, end: 130)]) == 0)
        #expect(evidence.retainedSampleCount(in: [.init(start: 10, end: 20), .init(start: 40, end: 50)]) == 2)
        // Exact out points are excluded, as in AVFoundation's half-open ranges.
        #expect(evidence.retainedSampleCount(in: [.init(start: 13, end: 47)]) == 2)
        #expect(evidence.retainedSampleCount(in: [.init(start: .nan, end: 50)]) == 0)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let archived = try encoder.encode(evidence)
        _ = evidence.retainedSampleCount(in: [.init(start: 20, end: 40)])
        #expect(try encoder.encode(evidence) == archived)
    }

    @Test("Real saved shorts visual smoke", .enabled(if: ProcessInfo.processInfo.environment["SHORTCAST_PROBE_SHORT_VISUAL"] == "1"))
    @MainActor
    func savedShortsVisualSmoke() async throws {
        let env = ProcessInfo.processInfo.environment
        let projectID = env["SHORTCAST_SHORT_VISUAL_PROJECT_ID"] ?? "117F97CB-226B-490F-A16A-F4B42FFF9718"
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Shortcast/Projects/\(projectID).shortcastproj")
        let before = try Data(contentsOf: url)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let project = try decoder.decode(FilmProject.self, from: before)
        let shorts = try #require(project.essayRelease?.shorts)
        #expect(shorts.count == 2)
        let windows = shorts.map { EssayShortDirector.Window(id: $0.id, segments: $0.segments, text: $0.payoffQuote) }
        let session = CoverVisionSession(model: ModelManager.model)
        let gateway = ThumbnailVisionGateway(modelID: ModelManager.model.rawValue) { image, prompt in
            try await session.complete(image: image, prompt: prompt)
        }
        let reviewed: [EssayShortDirector.Window]
        do {
            reviewed = try await EssayShortVisualReviewer(model: gateway).review(windows, sourceURL: project.sourceMovieURL,
                movie: project.movieTitle, progress: { print("SHORT_VISUAL: " + $0) })
            await session.unload()
        } catch { await session.unload(); throw error }
        let evidence = Dictionary(uniqueKeysWithValues: reviewed.compactMap { window in
            window.visualEvidence.map { (window.id, $0) }
        })
        #expect(evidence.count == 2)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(evidence).write(to: URL(fileURLWithPath: "/private/tmp/shortcast-short-visual-review.json"), options: .atomic)
        #expect(try Data(contentsOf: url) == before)
    }
}

@Suite("Short copy editor")
struct EssayShortCopyEditorTests {
    private func fixture() -> EssayShort {
        var short = EssayShort(id: "short2", angle: "Свобода", hook: "Вибачте за цей виспівук", title: "Хто тут в'язень?",
            why: "Конфлікт", payoffQuote: "Він не актор, він в'язень.", question: "Яка ціна свободи?", segments: [.init(start: 10, end: 50)])
        short.selectedSourceSegments = short.segments
        short.visualEvidence = .init(modelID: "vision", sampledTimes: [13, 30, 47], score: 4, confidence: 0.9, observation: "Видима реакція")
        return short
    }
    private let valid = #"{"angle":"Свобода людини","hook":"Він не актор. Він — в'язень.","title":"Хто тут в'язень?","why":"Герої сперечаються про свободу Трумена.","question":"Чи може розвага виправдати полон?"}"#

    @Test("Copy repair preserves source, literal quotation and visual evidence")
    func immutableSource() throws {
        let original = fixture()
        let edited = try EssayShortCopyEditor.applying(valid, to: original)
        var expected = original
        expected.angle = edited.angle; expected.hook = edited.hook; expected.title = edited.title
        expected.why = edited.why; expected.question = edited.question
        #expect(edited == expected)
        #expect(edited.payoffQuote == original.payoffQuote)
        #expect(edited.visualEvidence == original.visualEvidence)
        #expect(edited.segments == original.segments)
        #expect(!edited.hook.contains("виспівук"))
    }

    @Test("Service chatter, extra source fields, oversized copy and Russian text are rejected")
    func invalidCopy() {
        let examples = [valid.replacingOccurrences(of: "Він не актор. Він — в'язень.", with: "Вибачте за цей виспівук, але це правда."),
            valid.replacingOccurrences(of: "Він не актор. Він — в'язень.", with: "Это чужая история."),
            valid.replacingOccurrences(of: "Хто тут в'язень?", with: String(repeating: "я", count: 71)),
            valid.replacingOccurrences(of: "{\"angle\"", with: "{\"payoffQuote\":\"Змінена цитата\",\"angle\"")]
        for text in examples {
            #expect(throws: EssayReleaseError.self) { try EssayShortCopyEditor.applying(text, to: fixture()) }
        }
    }

    @Test("Independent review must accept the exact short with no unresolved issues")
    func reviewerGate() {
        #expect(EssayShortCopyEditor.isApproved(#"{"id":"short2","approved":true,"issues":[]}"#, expectedID: "short2"))
        for raw in [#"{"id":"short2","approved":false,"issues":["Вигадане слово виспівук"]}"#,
                    #"{"id":"short2","approved":true,"issues":["Описка"]}"#,
                    #"{"id":"short1","approved":true,"issues":[]}"#,
                    #"{"approved":true}"#] {
            #expect(!EssayShortCopyEditor.isApproved(raw, expectedID: "short2"))
        }
    }

    @Test("Reviewer scopes language judgement to editable copy and rejects contradictory or multiple verdicts")
    func reviewScopeAndContradictions() {
        let prompt = EssayShortCopyEditor.reviewInstructions(id: "short2")
        #expect(prompt.contains("ТІЛЬКИ п'ять полів всередині COPY_TO_REVIEW"))
        #expect(prompt.contains("НЕ оцінюй мову SOURCE_REFERENCE"))
        #expect(prompt.contains("НЕ відхиляй COPY_TO_REVIEW через помилки ASR"))
        #expect(prompt.contains("approved=false з issues=[] заборонено"))
        let falseEmpty = #"{"id":"short2","approved":false,"issues":[]}"#
        let yes = #"{"id":"short2","approved":true,"issues":[]}"#
        #expect(EssayShortCopyEditor.verdict(falseEmpty, expectedID: "short2") == nil)
        #expect(EssayShortCopyEditor.verdict(yes + "\nПримітка: ще один текст.", expectedID: "short2") == nil)
        #expect(EssayShortCopyEditor.verdict(yes + "\n" + falseEmpty, expectedID: "short2") == nil)
        #expect(EssayShortCopyEditor.isApproved("```json\n" + yes + "\n```", expectedID: "short2"))
    }

    private actor Model: LongformActTitleModeling {
        let replies: [String]; var calls = 0
        init(_ replies: [String]) { self.replies = replies }
        var isReady: Bool { get async { true } }
        var modelID: String? { get async { "test-editor" } }
        func complete(instructions: String, prompt: String, maxTokens: Int) async -> String? {
            defer { calls += 1 }
            return calls < replies.count ? replies[calls] : nil
        }
    }

    @Test("An unapproved nonsense repair exhausts two attempts and never returns replacement shorts")
    func boundedFailure() async {
        let typo = valid.replacingOccurrences(of: "Він не актор. Він — в'язень.", with: "Він має виспівук.")
        let no = #"{"id":"short2","approved":false,"issues":["Вигадане слово виспівук"]}"#
        let model = Model([typo, no, typo, no])
        do {
            _ = try await EssayShortCopyEditor(model: model).edit([fixture()], movie: "Шоу Трумена",
                transcript: Transcript(segments: [], language: "uk"), progress: { _ in })
            Issue.record("Unapproved copy escaped the bounded editor")
        } catch {
            #expect(error is EssayReleaseError)
        }
        #expect(await model.calls == 4)
    }

    @Test("Approved repair returns the selected scene with only five copy fields updated")
    func approvedRepair() async throws {
        let model = Model([valid, #"{"id":"short2","approved":true,"issues":[]}"#])
        let original = fixture()
        let result = try await EssayShortCopyEditor(model: model).edit([original], movie: "Шоу Трумена",
            transcript: Transcript(segments: [], language: "uk"), progress: { _ in })
        #expect(result.count == 1)
        #expect(result[0] == (try EssayShortCopyEditor.applying(valid, to: original)))
        #expect(await model.calls == 2)
    }

    @Test("Real saved short copy repair without changing project", .enabled(if: ProcessInfo.processInfo.environment["SHORTCAST_PROBE_SHORT_COPY"] == "1"))
    @MainActor
    func savedShortsCopySmoke() async throws {
        let projectID = ProcessInfo.processInfo.environment["SHORTCAST_SHORT_COPY_PROJECT_ID"]
            ?? "117F97CB-226B-490F-A16A-F4B42FFF9718"
        let archive = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Shortcast/Projects/\(projectID).shortcastproj")
        let before = try Data(contentsOf: archive)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let project = try decoder.decode(FilmProject.self, from: before)
        var originals = try #require(project.essayRelease?.shorts)
        let transcript = try #require(project.transcript)
        try #require(originals.count == 2)
        // Reintroduce the real malformed output in memory so a UI repair does
        // not turn this live regression into an accidental clean-copy test.
        originals[1].hook = "Він не актор, він в’язень. Вибачте за цей виспівук, але це правда."
        let manager = ModelManager()
        try await manager.requireDirector(profile: .gemma12B)
        defer { manager.momentFinder.unload() }
        let finder = manager.momentFinder
        let gateway = DirectorChatGateway(readiness: { await finder.isReady },
            identifier: { ChatModelProfile.gemma12B.modelID },
            completion: { instructions, prompt, tokens in
                await finder.completeForActTitles(instructions: instructions, prompt: prompt, maxTokens: tokens)
            })
        let edited = try await EssayShortCopyEditor(model: gateway).edit(originals, movie: project.movieTitle,
            transcript: transcript, progress: { print("SHORT_COPY: " + $0) })
        #expect(edited.count == originals.count)
        for (original, result) in zip(originals, edited) {
            let copy = [result.angle, result.hook, result.title, result.why, result.question].joined(separator: " ").lowercased()
            #expect(!copy.contains("виспівук"))
            #expect(!copy.contains("вибачте за"))
            #expect(!copy.contains("перепрошую"))
            #expect(result.segments == original.segments)
            #expect(result.selectedSourceSegments == original.selectedSourceSegments)
            #expect(result.payoffQuote == original.payoffQuote)
            #expect(result.visualEvidence == original.visualEvidence)
            var expected = original
            expected.angle = result.angle; expected.hook = result.hook; expected.title = result.title
            expected.why = result.why; expected.question = result.question
            #expect(result == expected)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(edited).write(to: URL(fileURLWithPath: "/private/tmp/shortcast-copy-editor-live.json"), options: .atomic)
        #expect(try Data(contentsOf: archive) == before)
    }

}
