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
