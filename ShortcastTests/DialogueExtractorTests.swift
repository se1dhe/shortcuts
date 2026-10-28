import XCTest
@testable import Shortcast

final class DialogueExtractorTests: XCTestCase {

    func testExtractDialogueFindsOverlappingSegments() {
        let segments = [
            TranscriptSegment(start: 0.0, end: 2.0, text: "First line", words: []),
            TranscriptSegment(start: 2.5, end: 5.0, text: "Second line", words: []),
            TranscriptSegment(start: 6.0, end: 8.0, text: "Third line", words: []),
            TranscriptSegment(start: 10.0, end: 12.0, text: "Fourth line", words: [])
        ]
        let transcript = Transcript(segments: segments, language: "uk", provenance: .whisper)

        let dialogue = DialogueExtractor.extractDialogue(
            from: transcript,
            startTime: 2.0,
            endTime: 7.0
        )

        XCTAssertEqual(dialogue, ["Second line", "Third line"])
    }

    func testExtractDialogueFiltersMicroFragments() {
        let segments = [
            TranscriptSegment(start: 0.0, end: 0.2, text: "Micro", words: []),
            TranscriptSegment(start: 1.0, end: 3.0, text: "Normal line", words: []),
            TranscriptSegment(start: 4.0, end: 4.3, text: "Another micro", words: [])
        ]
        let transcript = Transcript(segments: segments, language: "uk", provenance: .whisper)

        let dialogue = DialogueExtractor.extractDialogue(
            from: transcript,
            startTime: 0.0,
            endTime: 5.0,
            minSegmentDuration: 0.35
        )

        XCTAssertEqual(dialogue, ["Normal line"])
    }

    func testExtractDialogueTrimsWhitespace() {
        let segments = [
            TranscriptSegment(start: 0.0, end: 2.0, text: "  Line with spaces  ", words: []),
            TranscriptSegment(start: 3.0, end: 5.0, text: "\nLine with newlines\n", words: [])
        ]
        let transcript = Transcript(segments: segments, language: "uk", provenance: .whisper)

        let dialogue = DialogueExtractor.extractDialogue(
            from: transcript,
            startTime: 0.0,
            endTime: 6.0
        )

        XCTAssertEqual(dialogue, ["Line with spaces", "Line with newlines"])
    }

    func testExtractDialogueReturnsEmptyForNoOverlap() {
        let segments = [
            TranscriptSegment(start: 0.0, end: 2.0, text: "First", words: []),
            TranscriptSegment(start: 10.0, end: 12.0, text: "Second", words: [])
        ]
        let transcript = Transcript(segments: segments, language: "uk", provenance: .whisper)

        let dialogue = DialogueExtractor.extractDialogue(
            from: transcript,
            startTime: 5.0,
            endTime: 7.0
        )

        XCTAssertTrue(dialogue.isEmpty)
    }

    func testExtractDialogueHandlesPartialOverlap() {
        let segments = [
            TranscriptSegment(start: 0.0, end: 3.0, text: "Starts before range", words: []),
            TranscriptSegment(start: 4.0, end: 8.0, text: "Ends after range", words: [])
        ]
        let transcript = Transcript(segments: segments, language: "uk", provenance: .whisper)

        let dialogue = DialogueExtractor.extractDialogue(
            from: transcript,
            startTime: 2.0,
            endTime: 6.0
        )

        XCTAssertEqual(dialogue.count, 2)
        XCTAssertEqual(dialogue[0], "Starts before range")
        XCTAssertEqual(dialogue[1], "Ends after range")
    }

    func testExtractDialogueForAllUpdatesAllClips() {
        let segments = [
            TranscriptSegment(start: 0.0, end: 2.0, text: "Line 1", words: []),
            TranscriptSegment(start: 5.0, end: 7.0, text: "Line 2", words: []),
            TranscriptSegment(start: 10.0, end: 12.0, text: "Line 3", words: [])
        ]
        let transcript = Transcript(segments: segments, language: "uk", provenance: .whisper)

        let clips = [
            ClipCandidate(start: 0.0, end: 3.0, why: "Test 1", hook: "Hook 1"),
            ClipCandidate(start: 5.0, end: 8.0, why: "Test 2", hook: "Hook 2"),
            ClipCandidate(start: 15.0, end: 18.0, why: "Test 3", hook: "Hook 3")
        ]

        let updatedClips = DialogueExtractor.extractDialogueForAll(clips: clips, transcript: transcript)

        XCTAssertEqual(updatedClips.count, 3)
        XCTAssertEqual(updatedClips[0].dialogue, ["Line 1"])
        XCTAssertEqual(updatedClips[1].dialogue, ["Line 2"])
        XCTAssertTrue(updatedClips[2].dialogue.isEmpty)
    }
}
