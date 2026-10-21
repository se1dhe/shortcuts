import Testing
import Foundation
@testable import Shortcast

/// `avgLogprob` и `noSpeechProb` нужны для ворот подозрения на галлюцинацию.
/// Эти поля терялись при сохранении/загрузке проекта `.shortcastproj` (JSON),
/// потому что изначально отсутствовали в `TranscriptSegment`. Тесты фиксируют,
/// что теперь они переживают полный цикл Codable.
@Suite("Transcript confidence persistence")
struct TranscriptConfidencePersistenceTests {

    // MARK: - Test 1: TranscriptSegment round-trip

    @Test("TranscriptSegment preserves avgLogprob and noSpeechProb through JSON round-trip")
    func segmentRoundTrip() throws {
        let segment = TranscriptSegment(
            start: 1.5,
            end: 4.2,
            text: "hello world",
            words: [],
            avgLogprob: -0.3,
            noSpeechProb: 0.05
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(segment)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(TranscriptSegment.self, from: data)

        #expect(restored.start == 1.5)
        #expect(restored.end == 4.2)
        #expect(restored.text == "hello world")
        #expect(restored.avgLogprob == -0.3)
        #expect(restored.noSpeechProb == 0.05)
    }

    // MARK: - Test 2: Full Transcript round-trip

    @Test("Full Transcript preserves confidence fields across all segments after JSON round-trip")
    func transcriptRoundTrip() throws {
        let segments = [
            TranscriptSegment(
                start: 0.0, end: 3.0, text: "first segment",
                words: [], avgLogprob: -0.2, noSpeechProb: 0.01
            ),
            TranscriptSegment(
                start: 3.5, end: 7.0, text: "second segment",
                words: [], avgLogprob: -0.5, noSpeechProb: 0.15
            ),
            TranscriptSegment(
                start: 8.0, end: 10.0, text: "third segment",
                words: [], avgLogprob: -1.2, noSpeechProb: 0.85
            ),
        ]
        let transcript = Transcript(segments: segments, language: "en", provenance: .whisper)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(transcript)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(Transcript.self, from: data)

        #expect(restored.segments.count == 3)
        #expect(restored.language == "en")
        #expect(restored.provenance == .whisper)

        // Все сегменты сохраняют метрики уверенности
        #expect(restored.segments[0].avgLogprob == -0.2)
        #expect(restored.segments[0].noSpeechProb == 0.01)
        #expect(restored.segments[1].avgLogprob == -0.5)
        #expect(restored.segments[1].noSpeechProb == 0.15)
        #expect(restored.segments[2].avgLogprob == -1.2)
        #expect(restored.segments[2].noSpeechProb == 0.85)
    }

    // MARK: - Test 3: Backward compatibility — old JSON without confidence fields

    @Test("TranscriptSegment decodes from JSON that lacks avgLogprob and noSpeechProb (backward compatibility)")
    func backwardCompatibility() throws {
        // JSON в формате, который мог быть сохранён до добавления полей уверенности
        let legacyJSON = """
        {
            "start": 0.0,
            "end": 5.0,
            "text": "legacy text",
            "words": []
        }
        """
        let data = Data(legacyJSON.utf8)
        let decoder = JSONDecoder()
        let restored = try decoder.decode(TranscriptSegment.self, from: data)

        #expect(restored.start == 0.0)
        #expect(restored.end == 5.0)
        #expect(restored.text == "legacy text")
        // Поля отсутствуют в JSON — должны быть nil, а не крашиться
        #expect(restored.avgLogprob == nil)
        #expect(restored.noSpeechProb == nil)
    }

    // MARK: - Test 4: FilmProject round-trip with confidence fields

    @Test("FilmProject preserves transcript confidence fields through JSON round-trip")
    func filmProjectRoundTrip() throws {
        let segments = [
            TranscriptSegment(
                start: 0.0, end: 3.0, text: "suspicious hallucination",
                words: [], avgLogprob: -1.5, noSpeechProb: 0.9
            ),
        ]
        let transcript = Transcript(segments: segments, language: "en", provenance: .whisper)
        let project = FilmProject(
            sourceMovieURL: URL(fileURLWithPath: "/tmp/test.mp4"),
            movieFileName: "test.mp4",
            movieTitle: "Test Film",
            durationSeconds: 100.0,
            transcript: transcript
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(project)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(FilmProject.self, from: data)

        let restoredSegment = try #require(restored.transcript?.segments.first)
        #expect(restoredSegment.avgLogprob == -1.5)
        #expect(restoredSegment.noSpeechProb == 0.9)
    }
}
