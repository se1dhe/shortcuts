import Testing
import Foundation
@testable import Shortcast

/// Гейт качества транскрипта: Whisper на тишине, музыке и титрах выдаёт
/// субтитровые «подписи», звуковые описания и текст на чужих языках. Все
/// строки ниже взяты из реального транскрипта «Той, хто біжить по лезу 2049»
/// (проект 61EE2B93), а не придуманы для теста.
struct TranscriptQualityGateTests {

    @Test func rejectsJunkLinesFromRealTranscript() {
        let junk = [
            "Tekstet av Nicolai Winther",
            "Undertexter av Nicolai Winther",
            "Sous-titrage FR?",
            "Субтитры создавал DimaTorzok",
            "© BF-WATCH TV 2021",
            "♪♪",
            "GONG",
            "*Screams*",
            "*Dramatic music*",
            "Gagaga, gagaga, gagagagaga...",
            "you",
            "ДОБРА ПІЧА",
            "ТРЕВОЖНАЯ МУЗЫКА",
            "ДИНАМИЧНАЯ МУЗЫКА",
            "DETERMINERING",
        ]
        for line in junk {
            #expect(TranscriptQualityGate.isJunkLine(line), "Должно быть отброшено: \(line)")
        }
    }

    @Test func keepsRealDialogueFromTheSameTranscript() {
        let dialogue = [
            "Коко мертвий.",
            "Так.",
            "Хочеш прогулятись?",
            "Дитя, виношене в утробі…",
            "Там дуже темно, мені страшно, але кінь – це все, що я маю, тому я йду туди",
            "Ты не любишь меня?",
            "Молодий хлопець you know",
            "ДНК-матеріал. Діти народжені 6-10-21.",
            "ТІКАЙ!",
        ]
        for line in dialogue {
            #expect(!TranscriptQualityGate.isJunkLine(line), "Живая реплика отброшена: \(line)")
        }
    }

    @Test func rejectsForeignScriptWhenTranscriptIsCyrillic() {
        let segments = [
            TranscriptSegment(start: 10, end: 13, text: "Коко мертвий."),
            TranscriptSegment(start: 20, end: 24, text: "Thank you."),
            TranscriptSegment(start: 30, end: 33, text: "Gå inn i fjellet."),
            TranscriptSegment(start: 40, end: 45, text: "I'm not sure if I can get through this."),
            TranscriptSegment(start: 50, end: 53, text: "Гаразд, я йду."),
            TranscriptSegment(start: 60, end: 63, text: "Молодий хлопець you know"),
            TranscriptSegment(start: 70, end: 74, text: "Там дуже темно, мені страшно, але я йду туди."),
            TranscriptSegment(start: 80, end: 82, text: "От і все."),
        ]
        let kept = TranscriptQualityGate(segments: segments).filtered(segments).map(\.text)

        #expect(kept == [
            "Коко мертвий.",
            "Гаразд, я йду.",
            "Молодий хлопець you know",
            "Там дуже темно, мені страшно, але я йду туди.",
            "От і все.",
        ])
    }

    @Test func keepsDialogueWhenTranscriptIsLatin() {
        let segments = [
            TranscriptSegment(start: 10, end: 13, text: "All right."),
            TranscriptSegment(start: 20, end: 24, text: "Thank you."),
            TranscriptSegment(start: 30, end: 33, text: "Субтитры создавал DimaTorzok"),
            TranscriptSegment(start: 40, end: 43, text: "Gagaga, gagaga, gagagagaga..."),
        ]
        let kept = TranscriptQualityGate(segments: segments).filtered(segments).map(\.text)

        #expect(kept == ["All right.", "Thank you."])
    }

    @Test func dominantScriptComesFromTheWholeTranscript() {
        let cyrillic = [
            TranscriptSegment(start: 0, end: 3, text: "Коко мертвий."),
            TranscriptSegment(start: 4, end: 7, text: "Так."),
            TranscriptSegment(start: 8, end: 11, text: "Thank you."),
        ]
        #expect(TranscriptQualityGate(segments: cyrillic).expectedScript == .cyrillic)

        let latin = [
            TranscriptSegment(start: 0, end: 3, text: "All right."),
            TranscriptSegment(start: 4, end: 7, text: "Thank you."),
        ]
        #expect(TranscriptQualityGate(segments: latin).expectedScript == .latin)
    }
}
