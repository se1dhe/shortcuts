import Testing
import Foundation
@testable import Shortcast

/// Санитайзер сырых LLM-таймкодов. AVFoundation валидирует диапазоны композиции
/// ObjC-исключениями, которые Swift-`catch` не может перехватить, поэтому моменты
/// модели обязаны очищаться до построения арки: инвертированные и вырожденные
/// диапазоны выбрасываются, выход за фильм клампится, перекрытия склеиваются.
struct LongformMomentSanitationTests {

    private func moment(
        _ start: Double,
        _ end: Double,
        weight: Double = 0.8,
        reason: String = "Сцена розкриває тему"
    ) -> SelectedMoment {
        SelectedMoment(startTime: start, endTime: end, reason: reason, dramaticWeight: weight)
    }

    @Test func dropsInvertedAndDegenerateRanges() {
        let raw = [
            moment(120, 90),
            moment(200, 200),
            moment(300, 310),
            moment(500, 560),
        ]
        let clean = LongformNarrativeDirector.sanitizeSelectedMoments(raw, totalMovieDuration: 1000)
        #expect(clean.map(\.startTime) == [300, 500])
    }

    @Test func dropsRunsShorterThanMinRunDuration() {
        let raw = [
            moment(100, 103),
            moment(200, 207.99),
            moment(300, 308),
        ]
        let clean = LongformNarrativeDirector.sanitizeSelectedMoments(raw, totalMovieDuration: 1000)
        #expect(clean.map(\.startTime) == [300])
        #expect(abs(clean[0].endTime - clean[0].startTime - 8.0) < 0.0001)
    }

    @Test func clampsOvershootBeyondMovieDuration() {
        let raw = [moment(950, 1200)]
        let clean = LongformNarrativeDirector.sanitizeSelectedMoments(raw, totalMovieDuration: 1000)
        #expect(clean.count == 1)
        #expect(clean[0].startTime == 950)
        #expect(clean[0].endTime == 1000)
    }

    @Test func clampsNegativeStartToZero() {
        let raw = [moment(-40, 60)]
        let clean = LongformNarrativeDirector.sanitizeSelectedMoments(raw, totalMovieDuration: 1000)
        #expect(clean.count == 1)
        #expect(clean[0].startTime == 0)
        #expect(clean[0].endTime == 60)
    }

    @Test func mergesOverlappingMomentsIntoSingleSpan() {
        let raw = [
            moment(100, 150, weight: 0.6, reason: "Перший",),
            moment(130, 200, weight: 0.9, reason: "Другий"),
            moment(400, 450),
        ]
        let clean = LongformNarrativeDirector.sanitizeSelectedMoments(raw, totalMovieDuration: 1000)
        #expect(clean.count == 2)
        #expect(clean[0].startTime == 100)
        #expect(clean[0].endTime == 200)
        #expect(clean[0].dramaticWeight == 0.9)
        #expect(clean[0].reason == "Перший")
        #expect(clean[1].startTime == 400)
    }

    @Test func mergesTouchingSpans() {
        let raw = [
            moment(100, 150),
            moment(150, 200),
        ]
        let clean = LongformNarrativeDirector.sanitizeSelectedMoments(raw, totalMovieDuration: 1000)
        #expect(clean.count == 1)
        #expect(clean[0].startTime == 100)
        #expect(clean[0].endTime == 200)
    }

    @Test func returnsSortedOutputRegardlessOfInputOrder() {
        let raw = [
            moment(700, 760),
            moment(100, 160),
            moment(400, 460),
        ]
        let clean = LongformNarrativeDirector.sanitizeSelectedMoments(raw, totalMovieDuration: 1000)
        #expect(clean.map(\.startTime) == [100, 400, 700])
    }

    @Test func returnsEmptyForGarbageOnlyInput() {
        let raw = [
            moment(120, 90),
            moment(200, 201),
        ]
        let clean = LongformNarrativeDirector.sanitizeSelectedMoments(raw, totalMovieDuration: 1000)
        #expect(clean.isEmpty)
    }

    @Test func returnsEmptyForZeroMovieDuration() {
        let clean = LongformNarrativeDirector.sanitizeSelectedMoments(
            [moment(100, 150)],
            totalMovieDuration: 0
        )
        #expect(clean.isEmpty)
    }

    @Test func passesValidMomentsThroughUnchanged() {
        let raw = [
            moment(100, 160, weight: 0.5, reason: "Зачин"),
            moment(400, 460, weight: 0.7, reason: "Кульмінація"),
        ]
        let clean = LongformNarrativeDirector.sanitizeSelectedMoments(raw, totalMovieDuration: 1000)
        #expect(clean == raw)
    }
}
