import Testing
import Foundation
@testable import Shortcast

@Suite("SentenceBoundary & Narrative Continuity Tests")
struct SentenceBoundaryTests {

    @Test("SentenceBoundaryDetector does not cut off speech mid-sentence")
    func testBoundaryRefinement() {
        let segments = [
            Transcript.Segment(
                id: 1,
                start: 10.0,
                end: 13.5,
                text: "Я думал, что мы успеем,",
                words: []
            ),
            Transcript.Segment(
                id: 2,
                start: 13.6,
                end: 18.0,
                text: "но поезд уже ушел.",
                words: []
            ),
            Transcript.Segment(
                id: 3,
                start: 18.2,
                end: 22.0,
                text: "И теперь нам некуда идти...",
                words: []
            )
        ]

        // Initial cut cuts off at 16.0s (in the middle of segment 2: "но поезд уже [cut]")
        let initialRange = 10.0..<16.0
        let refined = LongformNarrativeDirector.refineSceneBoundary(
            in: segments,
            around: initialRange,
            maxAllowedDuration: 30.0
        )

        // Must expand to at least 18.0 + 0.45 = 18.45s so segment 2 finishes on punctuation "."
        #expect(refined.upperBound >= 18.4)
        // Must maintain leading safety margin before 10.0s (max 0, 10.0 - 0.20 = 9.8)
        #expect(refined.lowerBound <= 9.85)
    }

    @Test("Outro scene includes sufficient tail padding for fade to black strictly after speech")
    func testFinalSceneFadeOutPadding() {
        let lastSegment = Transcript.Segment(
            id: 10,
            start: 120.0,
            end: 125.0,
            text: "Это был наш единственный шанс.",
            words: []
        )

        let initialRange = 115.0..<125.0
        let refined = LongformNarrativeDirector.refineSceneBoundary(
            in: [lastSegment],
            around: initialRange,
            maxAllowedDuration: 40.0
        )

        // Tail boundary must extend beyond the end of speech by tailPadding (0.45s)
        #expect(refined.upperBound >= 125.4)
    }
}
