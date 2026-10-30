import XCTest
@testable import Shortcast

final class AudioTrackSelectionTests: XCTestCase {

    // MARK: - pickRecommendedAudioTrack

    func testUkrainianTrackPriorityOverRussianDub() {
        let tracks = [
            AudioTrackInfo(id: 0, audioIndex: 0, title: "Дубляж", language: "ukr", codec: "ac3", channels: 2, isDefault: false, isForced: false),
            AudioTrackInfo(id: 1, audioIndex: 1, title: "DUB", language: "rus", codec: "ac3", channels: 2, isDefault: false, isForced: false),
            AudioTrackInfo(id: 2, audioIndex: 2, title: nil, language: "eng", codec: "ac3", channels: 2, isDefault: false, isForced: false),
        ]
        let chosen = MediaExtractor.pickRecommendedAudioTrack(from: tracks)
        XCTAssertEqual(chosen?.id, 0, "Should prioritize Ukrainian track by language code")
        XCTAssertEqual(chosen?.language, "ukr")
    }

    func testUkrainianTitleMatchWhenNoLanguageCode() {
        let tracks = [
            AudioTrackInfo(id: 0, audioIndex: 0, title: "Українська озвучка", language: nil, codec: "ac3", channels: 2, isDefault: false, isForced: false),
            AudioTrackInfo(id: 1, audioIndex: 1, title: "DUB", language: "rus", codec: "ac3", channels: 2, isDefault: false, isForced: false),
        ]
        let chosen = MediaExtractor.pickRecommendedAudioTrack(from: tracks)
        XCTAssertEqual(chosen?.id, 0, "Should match Ukrainian by title when language code is missing")
    }

    func testBladeRunner2049UkrainianTrackSelection() {
        // Real audio tracks from Blade Runner 2049 (2017) WEB-DL 4K MKV
        let tracks = [
            AudioTrackInfo(
                id: 1,
                audioIndex: 0,
                title: "Ukrainian | DTS | 5.1 | 768 kbps | DUB | LeDoyen",
                language: "ukr",
                codec: "dts",
                channels: 6,
                isDefault: false,
                isForced: false
            ),
            AudioTrackInfo(
                id: 2,
                audioIndex: 1,
                title: "English | E-AC-3 JOC | 5.1 | 640 kbps",
                language: "eng",
                codec: "eac3",
                channels: 6,
                isDefault: true,
                isForced: false
            )
        ]
        let chosen = MediaExtractor.pickRecommendedAudioTrack(from: tracks)
        XCTAssertEqual(chosen?.id, 1, "Should select Ukrainian track over English default")
        XCTAssertEqual(chosen?.language, "ukr")
        XCTAssertTrue(chosen?.isUkrainianVoiceover == true, "Track should be recognized as Ukrainian voiceover")
    }

    func testFallbackToRussianWhenNoUkrainian() {
        let tracks = [
            AudioTrackInfo(id: 0, audioIndex: 0, title: "DUB", language: "rus", codec: "ac3", channels: 2, isDefault: false, isForced: false),
            AudioTrackInfo(id: 1, audioIndex: 1, title: nil, language: "eng", codec: "ac3", channels: 2, isDefault: false, isForced: false),
        ]
        let chosen = MediaExtractor.pickRecommendedAudioTrack(from: tracks)
        XCTAssertEqual(chosen?.id, 0, "Should fall back to Russian dub when no Ukrainian track")
        XCTAssertEqual(chosen?.language, "rus")
    }

    func testFallbackToContainerDefaultWhenNoDub() {
        let tracks = [
            AudioTrackInfo(id: 0, audioIndex: 0, title: nil, language: "eng", codec: "ac3", channels: 2, isDefault: false, isForced: false),
            AudioTrackInfo(id: 1, audioIndex: 1, title: nil, language: "eng", codec: "ac3", channels: 2, isDefault: true, isForced: false),
        ]
        let chosen = MediaExtractor.pickRecommendedAudioTrack(from: tracks)
        XCTAssertEqual(chosen?.id, 1, "Should fall back to container default track")
        XCTAssertTrue(chosen?.isDefault ?? false)
    }

    func testFallbackToFirstTrackWhenNothingMatches() {
        let tracks = [
            AudioTrackInfo(id: 0, audioIndex: 0, title: nil, language: "eng", codec: "ac3", channels: 2, isDefault: false, isForced: false),
            AudioTrackInfo(id: 1, audioIndex: 1, title: nil, language: "fra", codec: "ac3", channels: 2, isDefault: false, isForced: false),
        ]
        let chosen = MediaExtractor.pickRecommendedAudioTrack(from: tracks)
        XCTAssertEqual(chosen?.id, 0, "Should fall back to first track when nothing matches")
    }

    func testEmptyTrackListReturnsNil() {
        let chosen = MediaExtractor.pickRecommendedAudioTrack(from: [])
        XCTAssertNil(chosen, "Empty track list should return nil")
    }

    // MARK: - languageCode(from:)

    @MainActor
    func testLanguageCodeMappingUkrainian() async {
        XCTAssertEqual(TranscriptionService.languageCode(from: "uk"), "uk")
        XCTAssertEqual(TranscriptionService.languageCode(from: "ukr"), "uk")
        XCTAssertEqual(TranscriptionService.languageCode(from: "українська"), "uk")
        XCTAssertEqual(TranscriptionService.languageCode(from: "український"), "uk")
        XCTAssertEqual(TranscriptionService.languageCode(from: "Ukrainian"), "uk")
    }

    @MainActor
    func testLanguageCodeMappingRussian() async {
        XCTAssertEqual(TranscriptionService.languageCode(from: "ru"), "ru")
        XCTAssertEqual(TranscriptionService.languageCode(from: "rus"), "ru")
        XCTAssertEqual(TranscriptionService.languageCode(from: "російська"), "ru")
        XCTAssertEqual(TranscriptionService.languageCode(from: "російський"), "ru")
        XCTAssertEqual(TranscriptionService.languageCode(from: "Russian"), "ru")
    }

    @MainActor
    func testLanguageCodeMappingOtherLanguages() async {
        XCTAssertEqual(TranscriptionService.languageCode(from: "es"), "es")
        XCTAssertEqual(TranscriptionService.languageCode(from: "Spanish"), "es")
        XCTAssertEqual(TranscriptionService.languageCode(from: "en"), "en")
        XCTAssertEqual(TranscriptionService.languageCode(from: "English"), "en")
    }

    @MainActor
    func testLanguageCodeEmptyReturnsNil() async {
        XCTAssertNil(TranscriptionService.languageCode(from: ""))
        XCTAssertNil(TranscriptionService.languageCode(from: "   "))
    }

    @MainActor
    func testLanguageCodeUnknownReturnsNil() async {
        XCTAssertNil(TranscriptionService.languageCode(from: "klingon"))
        XCTAssertEqual(TranscriptionService.languageCode(from: "xx"), "xx", "2-letter codes are passed through as-is")
    }

    // MARK: - AudioTrackInfo.isUkrainianVoiceover

    func testIsUkrainianVoiceoverByLanguageCode() {
        XCTAssertTrue(AudioTrackInfo(id: 0, audioIndex: 0, title: nil, language: "ukr", codec: "ac3", channels: 2, isDefault: false, isForced: false).isUkrainianVoiceover)
        XCTAssertTrue(AudioTrackInfo(id: 0, audioIndex: 0, title: nil, language: "uk", codec: "ac3", channels: 2, isDefault: false, isForced: false).isUkrainianVoiceover)
        XCTAssertTrue(AudioTrackInfo(id: 0, audioIndex: 0, title: nil, language: "українська", codec: "ac3", channels: 2, isDefault: false, isForced: false).isUkrainianVoiceover)
    }

    func testIsUkrainianVoiceoverByTitle() {
        XCTAssertTrue(AudioTrackInfo(id: 0, audioIndex: 0, title: "Українська озвучка", language: nil, codec: "ac3", channels: 2, isDefault: false, isForced: false).isUkrainianVoiceover)
        XCTAssertTrue(AudioTrackInfo(id: 0, audioIndex: 0, title: "Ukrainian dub", language: nil, codec: "ac3", channels: 2, isDefault: false, isForced: false).isUkrainianVoiceover)
    }

    func testIsUkrainianVoiceoverFalseForRussian() {
        XCTAssertFalse(AudioTrackInfo(id: 0, audioIndex: 0, title: "DUB", language: "rus", codec: "ac3", channels: 2, isDefault: false, isForced: false).isUkrainianVoiceover)
        XCTAssertFalse(AudioTrackInfo(id: 0, audioIndex: 0, title: nil, language: "ru", codec: "ac3", channels: 2, isDefault: false, isForced: false).isUkrainianVoiceover)
    }

}
