import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import Shortcast

@Suite("SinglePassClipCompositor Audio & Ramps Tests")
@MainActor
struct SinglePassClipCompositorTests {

    private func createTracks() -> (composition: AVMutableComposition, speechTrack: AVCompositionTrack?, musicTrack: AVCompositionTrack?) {
        let composition = AVMutableComposition()
        let speechTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: 1)
        let musicTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: 2)
        return (composition, speechTrack, musicTrack)
    }

    @Test("Audio mix builds successfully without AVFoundation exception when subtitle segments are closely spaced")
    func testAudioMixWithOverlappingAndRapidSubtitlesWithoutException() {
        let (_, speechTrack, musicTrack) = createTracks()

        // Субтитры с паузами меньше 0.45с, которые в старой реализации пересекали attack и release
        let subtitles = [
            SubtitleSegment(start: 1.0, end: 2.0, text: "Реплика 1"),
            SubtitleSegment(start: 2.2, end: 3.1, text: "Реплика 2 (пауза 0.2с)"),
            SubtitleSegment(start: 3.3, end: 4.5, text: "Реплика 3 (пауза 0.2с)"),
            SubtitleSegment(start: 8.0, end: 10.0, text: "Реплика 4 через большую паузу")
        ]

        let mix = SinglePassClipCompositor.shared.buildAudioMix(
            speechTrack: speechTrack,
            musicTrack: musicTrack,
            clipDurationSec: 15.0,
            startSec: 0.0,
            subtitleSegments: subtitles,
            isOriginalAudioMuted: false,
            originalAudioVolume: 1.0,
            musicVolume: 0.70,
            musicDuckingEnabled: true
        )

        #expect(mix.inputParameters.count == 2)
    }

    @Test("Audio mix safely handles speech near the clip end without colliding with final fade-out")
    func testAudioMixTailSpeechAndFinalFadeOutWithoutCollision() {
        let (_, speechTrack, musicTrack) = createTracks()

        // Реплика в самом хвосте клипа, где release пересекался бы с финальным фейд-аутом clipDurationSec - 0.8
        let subtitles = [
            SubtitleSegment(start: 28.5, end: 29.8, text: "Финальная реплика перед титрами")
        ]

        let mix = SinglePassClipCompositor.shared.buildAudioMix(
            speechTrack: speechTrack,
            musicTrack: musicTrack,
            clipDurationSec: 30.0,
            startSec: 0.0,
            subtitleSegments: subtitles,
            isOriginalAudioMuted: false,
            originalAudioVolume: 1.0,
            musicVolume: 0.70,
            musicDuckingEnabled: true
        )

        #expect(mix.inputParameters.count == 2)
    }

    @Test("Audio mix handles unsorted, overlapping and out-of-bounds subtitles gracefully")
    func testAudioMixWithUnsortedAndOverlappingSubtitles() {
        let (_, speechTrack, musicTrack) = createTracks()

        // Неотсортированные сегменты, сегменты до начала клипа и сегменты с перекрытиями
        let subtitles = [
            SubtitleSegment(start: 5.0, end: 7.0, text: "Середина"),
            SubtitleSegment(start: -2.0, end: 0.5, text: "Отрезанное начало"),
            SubtitleSegment(start: 1.0, end: 3.0, text: "Первая фраза"),
            SubtitleSegment(start: 2.5, end: 4.0, text: "Пересекающаяся фраза"),
            SubtitleSegment(start: 40.0, end: 45.0, text: "Далеко за пределами клипа")
        ]

        let mix = SinglePassClipCompositor.shared.buildAudioMix(
            speechTrack: speechTrack,
            musicTrack: musicTrack,
            clipDurationSec: 12.0,
            startSec: 0.0,
            subtitleSegments: subtitles,
            isOriginalAudioMuted: false,
            originalAudioVolume: 1.0,
            musicVolume: 0.60,
            musicDuckingEnabled: true
        )

        #expect(mix.inputParameters.count == 2)
    }

    @Test("Audio mix creates parameters when music ducking is disabled")
    func testAudioMixDuckingDisabled() {
        let (_, speechTrack, musicTrack) = createTracks()

        let subtitles = [
            SubtitleSegment(start: 1.0, end: 5.0, text: "Фраза без дакинга")
        ]

        let mix = SinglePassClipCompositor.shared.buildAudioMix(
            speechTrack: speechTrack,
            musicTrack: musicTrack,
            clipDurationSec: 10.0,
            startSec: 0.0,
            subtitleSegments: subtitles,
            isOriginalAudioMuted: false,
            originalAudioVolume: 1.0,
            musicVolume: 0.50,
            musicDuckingEnabled: false
        )

        #expect(mix.inputParameters.count == 2)
    }

    @Test("Audio mix handles absence of speech track or music track")
    func testAudioMixSingleTrackOnly() {
        let composition = AVMutableComposition()
        let musicTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: 1)

        let mixMusicOnly = SinglePassClipCompositor.shared.buildAudioMix(
            speechTrack: nil,
            musicTrack: musicTrack,
            clipDurationSec: 10.0,
            startSec: 0.0,
            subtitleSegments: [],
            isOriginalAudioMuted: false,
            originalAudioVolume: 1.0,
            musicVolume: 0.50,
            musicDuckingEnabled: true
        )

        #expect(mixMusicOnly.inputParameters.count == 1)

        let speechTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: 2)
        let mixSpeechOnly = SinglePassClipCompositor.shared.buildAudioMix(
            speechTrack: speechTrack,
            musicTrack: nil,
            clipDurationSec: 10.0,
            startSec: 0.0,
            subtitleSegments: [],
            isOriginalAudioMuted: false,
            originalAudioVolume: 1.0,
            musicVolume: 0.50,
            musicDuckingEnabled: true
        )

        #expect(mixSpeechOnly.inputParameters.count == 1)
    }
}

@Suite("Clip Subtitle Projection & Memory Optimization Tests")
struct SubtitleProjectionTests {

    @Test("projectSubtitles correctly shifts single range segments and word timings")
    func testProjectSubtitlesSingleRange() {
        let transcriptSegments = [
            TranscriptSegment(
                start: 10.0,
                end: 15.0,
                text: "Привет мир",
                words: [
                    WordTimestamp(word: "Привет", start: 10.0, end: 12.0),
                    WordTimestamp(word: "мир", start: 12.5, end: 15.0)
                ]
            ),
            TranscriptSegment(
                start: 20.0,
                end: 25.0,
                text: "Вне диапазона",
                words: []
            )
        ]

        let ranges = [
            CMTimeRange(
                start: CMTime(seconds: 10.0, preferredTimescale: 600),
                duration: CMTime(seconds: 5.0, preferredTimescale: 600)
            )
        ]

        let projected = ClipRenderingService.projectSubtitles(segments: transcriptSegments, onto: ranges)
        #expect(projected.count == 1)
        #expect(projected[0].text == "Привет мир")
        #expect(projected[0].start == 0.0)
        #expect(projected[0].end == 5.0)
        #expect(projected[0].words.count == 2)
        #expect(projected[0].words[0].word == "Привет")
        #expect(projected[0].words[0].start == 0.0)
        #expect(projected[0].words[0].end == 2.0)
        #expect(projected[0].words[1].word == "мир")
        #expect(projected[0].words[1].start == 2.5)
        #expect(projected[0].words[1].end == 5.0)
    }

    @Test("projectSubtitles correctly projects multiple stitched ranges across jump cuts")
    func testProjectSubtitlesMultipleStitchedRanges() {
        let transcriptSegments = [
            TranscriptSegment(
                start: 10.0,
                end: 14.0,
                text: "Первая фраза",
                words: [
                    WordTimestamp(word: "Первая", start: 10.0, end: 11.5),
                    WordTimestamp(word: "фраза", start: 12.0, end: 14.0)
                ]
            ),
            TranscriptSegment(
                start: 15.0,
                end: 25.0,
                text: "Вырезанная тишина и пауза",
                words: []
            ),
            TranscriptSegment(
                start: 30.0,
                end: 35.0,
                text: "Вторая фраза",
                words: [
                    WordTimestamp(word: "Вторая", start: 30.5, end: 32.0),
                    WordTimestamp(word: "фраза", start: 32.5, end: 35.0)
                ]
            )
        ]

        // Range 1: 10.0s to 14.0s (duration 4.0s)
        // Range 2: 30.0s to 35.0s (duration 5.0s)
        let ranges = [
            CMTimeRange(
                start: CMTime(seconds: 10.0, preferredTimescale: 600),
                duration: CMTime(seconds: 4.0, preferredTimescale: 600)
            ),
            CMTimeRange(
                start: CMTime(seconds: 30.0, preferredTimescale: 600),
                duration: CMTime(seconds: 5.0, preferredTimescale: 600)
            )
        ]

        let projected = ClipRenderingService.projectSubtitles(segments: transcriptSegments, onto: ranges)
        #expect(projected.count == 2)

        // Первая фраза в первой склейке: timelineOffset = 0
        #expect(projected[0].text == "Первая фраза")
        #expect(projected[0].start == 0.0)
        #expect(projected[0].end == 4.0)
        #expect(projected[0].words[0].start == 0.0)
        #expect(projected[0].words[0].end == 1.5)
        #expect(projected[0].words[1].start == 2.0)
        #expect(projected[0].words[1].end == 4.0)

        // Вторая фраза во второй склейке: timelineOffset = 4.0 (длительность первой)
        #expect(projected[1].text == "Вторая фраза")
        #expect(projected[1].start == 4.0) // 30.0 - 30.0 + 4.0
        #expect(projected[1].end == 9.0)   // 35.0 - 30.0 + 4.0
        #expect(projected[1].words[0].start == 4.5) // (30.5 - 30.0) + 4.0
        #expect(projected[1].words[0].end == 6.0)   // (32.0 - 30.0) + 4.0
        #expect(projected[1].words[1].start == 6.5) // (32.5 - 30.0) + 4.0
        #expect(projected[1].words[1].end == 9.0)   // (35.0 - 30.0) + 4.0
    }

    @Test("TranscriptionService unload clears state and phase")
    @MainActor
    func testTranscriptionServiceUnload() {
        let service = TranscriptionService()
        service.unload()
        #expect(service.phase == .idle)
    }
}
