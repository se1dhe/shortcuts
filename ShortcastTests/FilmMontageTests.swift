import Foundation
import Testing
@testable import Shortcast

@Suite("Third short music montage")
struct FilmMontageTests {
    func shots() -> [FilmMontagePlan.Shot] {
        (0..<16).map { index in
            let start = Double(index * 300 + 30)
            let range = TimeSegment(start: start, end: start + 5.5)
            return FilmMontagePlan.Shot(id: "V\(index + 1)", source: range,
                sampledTimes: [start + 0.5, start + 3.5], observation: "Виразний кадр автомобіля", score: 4)
        }
    }
    func short(_ id: String, montage: Bool = false) -> EssayShort {
        var short = EssayShort(id: id, angle: "Ритм", hook: "Погляд героя", title: "Кадри фільму", why: "Ритм сцени", payoffQuote: "", question: "Що запам'яталося?",
            segments: [.init(start: 10, end: 30)], selectionVersion: EssayShortDirector.selectionVersion)
        if montage {
            short.format = .montage
            short.montagePlan = .init(shots: shots(), visionModelID: "vision", selectionModelID: "text", timingVersion: FilmMontagePlan.currentTimingVersion)
        }
        short.renderStyleVersion = EssayShort.currentRenderStyle
        return short
    }

    @Test("Legacy pairs remain valid and a new release requires all three artifacts")
    func releaseContract() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([1]).write(to: file); defer { try? FileManager.default.removeItem(at: file) }
        var first = short("short1"), second = short("short2"), third = short("short3", montage: true)
        first.outputURL = file; second.outputURL = file; third.outputURL = file
        var release = EssayRelease(essayKey: "test", shorts: [first, second])
        #expect(release.hasReadyShorts && release.usesWholeFilmSelection)
        release.includesMontage = true
        #expect(!release.hasReadyShorts && !release.usesWholeFilmSelection)
        #expect(release.hasWholeFilmStoryPlans)
        release.shorts.append(third)
        #expect(release.hasReadyShorts && release.hasCurrentShortStyle && release.usesWholeFilmSelection)
        let restored = try JSONDecoder().decode(EssayRelease.self, from: JSONEncoder().encode(release))
        #expect(restored.shorts[2].isMontage && restored.expectedShortCount == 3)
    }

    @Test("The visual catalogue spans the movie and every pick must be a shown ID")
    @MainActor func boundedVisualEvidence() throws {
        let ranges = FilmMontageDirector.ranges(duration: 6000)
        #expect(ranges.count == 72)
        #expect(ranges.last!.start > 5500)
        #expect(ranges.allSatisfy { $0.start >= 0 && $0.end <= 6000 && $0.duration > 5 })
        let pool = shots()
        let picks = try FilmMontageDirector.parseBatch(#"{"picks":[{"id":"V1","score":4,"observation":"Автомобіль у кадрі"}]}"#, candidates: Array(pool.prefix(3)))
        #expect(picks.first?.source == pool.first?.source)
        #expect(throws: (any Error).self) {
            try FilmMontageDirector.parseBatch(#"{"picks":[{"id":"V999","score":5,"observation":"Автомобіль"}]}"#, candidates: pool)
        }
        let order = String(decoding: try JSONSerialization.data(withJSONObject: ["shots": pool.prefix(12).map(\.id)]), as: UTF8.self)
        #expect(try FilmMontageDirector.parseOrder(order, pool: pool).count == 12)
        let loop = String(decoding: try JSONSerialization.data(withJSONObject: ["shots": pool.prefix(12).map(\.id) + [pool[0].id]]), as: UTF8.self)
        #expect(try FilmMontageDirector.parseOrder(loop, pool: pool).count == 13)
        let repeats = String(decoding: try JSONSerialization.data(withJSONObject: ["shots": [String](repeating: "V1", count: 12)]), as: UTF8.self)
        #expect(throws: (any Error).self) { try FilmMontageDirector.parseOrder(repeats, pool: pool) }
    }

    @Test("The music grid estimates its phase from actual transients")
    @MainActor func pulsePhase() {
        var energy = [Double](repeating: 0.001, count: 2000)
        for index in stride(from: 17, to: energy.count, by: 50) { energy[index] = 0.4 }
        let phase = FilmMontageDirector.musicalPhase(energy: energy, offset: 0, beat: 0.5)
        #expect(abs(phase - 0.17) < 0.015)
    }

    @Test("Retiming keeps the musical climax inside the shortened edit and preserves source bounds")
    @MainActor func retiming() throws {
        var original = short("short3", montage: true)
        original.segments = shots().map { .init(start: $0.source.start, end: $0.source.start + 2) }
        original.musicSettings = LongformAudioSettings()
        original.editPlan = .init(grade: .coolNight, transition: .cut, mood: "Intense", trackID: "track", trackTitle: "Track",
            musicOffset: 30.8, musicPeak: 51.8, payoffTime: 21, modelID: "local", bpm: 148)
        let edited = try FilmMontageDirector.align(original, energy: [Double](repeating: 0.01, count: 20000))
        #expect((20...30).contains(edited.duration))
        #expect(edited.montagePlan?.cutTimes?.count == edited.segments.count - 1)
        #expect(edited.renderStyleVersion == nil)
        #expect(edited.editPlan!.payoffTime < edited.duration)
        #expect(abs(edited.editPlan!.musicPeak - edited.editPlan!.musicOffset - edited.duration * 0.68) < 0.42)
        for (range, shot) in zip(edited.segments, shots()) {
            #expect(range.start >= shot.source.start && range.end <= shot.source.end + 0.001)
            let pulses = range.duration / edited.montagePlan!.beatSeconds!
            #expect(abs(pulses - pulses.rounded()) < 0.001)
        }
        #expect(throws: (any Error).self) { try FilmMontageDirector.align(original, energy: []) }
    }

    @Test("Short montage cuts are editable while dialogue scenes retain their minimum")
    func montageEditing() throws {
        let concept = ThematicConcept(word: "РИТМ", tagline: "Ритм", philosophicalPremise: "Кадри", suggestedTitle: "Кадри")
        let arc = LongformNarrativeArc(movieTitle: "Фільм", concept: concept, acts: [], summary: "")
        var montage = short("short3", montage: true)
        montage.segments = (0..<24).map { .init(start: Double($0 * 10), end: Double($0 * 10) + 0.75) }
        try EssayShortEditing.validate(montage, arc: arc, sourceDuration: 6000)
        montage.format = .scene
        #expect(throws: (any Error).self) { try EssayShortEditing.validate(montage, arc: arc, sourceDuration: 6000) }
    }
}
