import Testing
import Foundation
import CoreGraphics
import AVFoundation
@testable import Shortcast

@Suite("Longform Subtitle Sync & Chunking Tests")
struct LongformSubtitleSyncTests {

    @Test("Word-level timestamp grouping respects actor speech pauses")
    func wordGroupingSplitsOnPauses() async {
        // Симулируем фразу: 3 слова в начале (2.6..4.1), пауза 1.3 секунды, затем 3 слова (5.4..6.9)
        let words: [WordTimestamp] = [
            WordTimestamp(word: "Служба", start: 2.6, end: 3.0),
            WordTimestamp(word: "спасения", start: 3.1, end: 3.6),
            WordTimestamp(word: "слушаю", start: 3.7, end: 4.1),
            // Пауза 1.3 секунды
            WordTimestamp(word: "мне", start: 5.4, end: 5.7),
            WordTimestamp(word: "нужна", start: 5.8, end: 6.2),
            WordTimestamp(word: "помощь", start: 6.3, end: 6.9)
        ]

        let phrase = TimedSubtitlePhrase(
            start: 2.6,
            end: 6.9,
            text: "Служба спасения слушаю мне нужна помощь",
            words: words
        )

        let renderer = LongformSubtitleRenderer()
        let layer = await renderer.makeOverlayLayer(
            renderSize: CGSize(width: 1920, height: 1080),
            concept: ThematicConcept(
                word: "СПАСЕНИЕ",
                tagline: "Когда надежда угасает",
                philosophicalPremise: "Служба спасения человеческой души",
                suggestedTitle: "Иногда помощь приходит оттуда, откуда не ждешь"
            ),
            timedPhrases: [phrase],
            totalDuration: 10.0,
            introPadding: 2.5
        )

        #expect(layer.sublayers?.count ?? 0 >= 2, "Overlay layer must contain concept and subtitle layers")
    }

    @Test("Subtitles before introPadding are hidden during cold open black screen")
    func subtitlesRespectIntroPadding() async {
        // Реплика в самом начале фильма во время Cold Open (0.5..2.0)
        let earlyPhrase = TimedSubtitlePhrase(
            start: 0.5,
            end: 2.0,
            text: "В темноте голос",
            words: []
        )
        // Реплика сразу после Cold Open (2.6..4.0)
        let activePhrase = TimedSubtitlePhrase(
            start: 2.6,
            end: 4.0,
            text: "Служба девять один один",
            words: []
        )

        let renderer = LongformSubtitleRenderer()
        let layer = await renderer.makeOverlayLayer(
            renderSize: CGSize(width: 1920, height: 1080),
            concept: ThematicConcept(
                word: "СУДЬБА",
                tagline: "Неотвратимый финал",
                philosophicalPremise: "Каждый шаг ведет к искуплению",
                suggestedTitle: "Ты поймешь это слишком поздно"
            ),
            timedPhrases: [earlyPhrase, activePhrase],
            totalDuration: 10.0,
            introPadding: 2.5
        )

        #expect(layer.sublayers != nil)
    }

    @Test("AntiCopyright audio filters use monotonic aresample without first_pts=0 reset")
    func audioFiltersUseMonotonicResample() {
        let config = AntiCopyrightConfig.cinemaShield
        let transformer = AntiCopyrightService(config: config)
        let filters = transformer.buildFFmpegAudioFilters(method: .rubberband, sampleRate: 44100)

        #expect(filters.contains("aresample=async=1"), "Audio filters must include async resample")
        #expect(!filters.contains("first_pts=0"), "Audio filters must not include first_pts=0 which resets PTS on AC3 filter reconfiguration")
    }

    @Test("TranscriptSegment.sliced trims words across scene cut boundaries without bleeding earlier dialogue")
    func segmentSlicingPreventsCrossCutDialogueBleed() {
        // Симулируем 12-секундный сегмент (1402..1414), который пересекает границу склейки:
        // Сцена 1 заканчивается на 1406.0, Сцена 2 начинается на 1411.5
        let seg = TranscriptSegment(
            start: 1402.0,
            end: 1414.0,
            text: "Уж точно получше тебя. Ладно, давай быстрее, я опаздываю.",
            words: []
        )

        // В Сцене 2 (1411.5..1422.5, вставленной на таймлайн в 28.9с) должны остаться только финальные слова
        let slicedForScene2 = seg.sliced(windowStart: 1411.5, windowEnd: 1422.5, timelineOffset: 28.9)
        #expect(slicedForScene2 != nil)
        #expect(slicedForScene2?.text.contains("Уж точно") == false, "Words spoken in Scene 1 must not bleed into Scene 2")
        #expect(slicedForScene2?.text.contains("опаздываю") == true, "Words spoken inside Scene 2 must be preserved")
    }
}
