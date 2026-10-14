import XCTest
@testable import Shortcast

@MainActor
final class ShortClipEditorTests: XCTestCase {

    func testEditorTabsCoverage() {
        let tabs = ShortClipEditorTab.allCases
        XCTAssertEqual(tabs.count, 5)
        XCTAssertEqual(ShortClipEditorTab.content.title, "Контент")
        XCTAssertEqual(ShortClipEditorTab.scene.title, "Монтаж сцены")
        XCTAssertEqual(ShortClipEditorTab.subtitles.title, "Субтитры")
        XCTAssertEqual(ShortClipEditorTab.styleAudio.title, "Стиль и звук")
        XCTAssertEqual(ShortClipEditorTab.publish.title, "Публикация")

        for tab in tabs {
            XCTAssertFalse(tab.icon.isEmpty, "Tab \(tab) should have a valid SF symbol icon")
        }
    }

    func testSubtitleSegmentMutationsAndFormatting() {
        var segment = SubtitleSegment(
            start: 12.5,
            end: 18.2,
            text: "Это культовый момент фильма",
            words: [
                WordTimestamp(word: "Это", start: 12.5, end: 13.0),
                WordTimestamp(word: "культовый", start: 13.1, end: 14.5),
                WordTimestamp(word: "момент", start: 14.6, end: 16.0),
                WordTimestamp(word: "фильма", start: 16.1, end: 18.2)
            ]
        )

        XCTAssertEqual(segment.duration, 5.7, accuracy: 0.001)
        XCTAssertTrue(segment.timecodeDisplay.contains("00:12.5 — 00:18.2"))

        // Direct text edit
        segment.text = "Это исправленный текст фразы"
        XCTAssertEqual(segment.text, "Это исправленный текст фразы")

        // Scaled copy
        let scaled = segment.scaled(by: 0.5)
        XCTAssertEqual(scaled.start, 6.25, accuracy: 0.001)
        XCTAssertEqual(scaled.end, 9.1, accuracy: 0.001)
        XCTAssertEqual(scaled.words.first?.start ?? 0, 6.25, accuracy: 0.001)
    }

    func testShortClipSubtitleEditingDirectly() {
        let candidate = ClipCandidate(
            start: 100.0,
            end: 130.0,
            why: "Культовый финал с небоскребами",
            hook: "Мы встретились в странный период моей жизни",
            viralScore: 99
        )

        let initialSegments = [
            SubtitleSegment(start: 0.5, end: 4.0, text: "Мы встретились в странный период"),
            SubtitleSegment(start: 4.2, end: 7.0, text: "моей жизни")
        ]

        let clip = ShortClip(
            candidate: candidate,
            transcriptSlice: "Мы встретились в странный период моей жизни",
            subtitleSegments: initialSegments,
            sourceMetadata: nil,
            overlayEnabled: true,
            reframeEnabled: false,
            burnSubtitles: true,
            subtitleAppearance: .tiktok
        )

        XCTAssertEqual(clip.subtitleSegments.count, 2)
        XCTAssertEqual(clip.subtitleSegments[0].text, "Мы встретились в странный период")

        // Редактирование текста пользователем в редакторе субтитров
        clip.subtitleSegments[0].text = "Мы встретились в очень странный период"
        XCTAssertEqual(clip.subtitleSegments[0].text, "Мы встретились в очень странный период")

        // Добавление новой реплики
        let newSeg = SubtitleSegment(start: 7.5, end: 10.0, text: "Звучит песня Where Is My Mind")
        clip.subtitleSegments.append(newSeg)
        XCTAssertEqual(clip.subtitleSegments.count, 3)

        // Удаление реплики
        clip.subtitleSegments.remove(at: 1)
        XCTAssertEqual(clip.subtitleSegments.count, 2)
        XCTAssertEqual(clip.subtitleSegments[1].text, "Звучит песня Where Is My Mind")
    }

    func testShortClipSceneTrimmingBounds() {
        let candidate = ClipCandidate(
            start: 200.0,
            end: 240.0,
            why: "Разговор дона Корлеоне",
            hook: "Предложение, от которого нельзя отказаться",
            viralScore: 95
        )

        let clip = ShortClip(
            candidate: candidate,
            transcriptSlice: "Я сделаю ему предложение...",
            subtitleSegments: [],
            sourceMetadata: nil,
            overlayEnabled: true,
            reframeEnabled: false,
            burnSubtitles: false,
            subtitleAppearance: .tiktok
        )

        XCTAssertFalse(clip.hasCustomTrim)

        // Настройка In/Out тримминга
        clip.trimStartSeconds = 2.5
        clip.trimEndSeconds = 35.0
        XCTAssertTrue(clip.hasCustomTrim)

        // Сброс тримминга
        clip.trimStartSeconds = 0.0
        clip.trimEndSeconds = 0.0
        XCTAssertFalse(clip.hasCustomTrim)
    }

    func testCombinedDescriptionBindingUpdatesVariants() {
        let variant = PostVariant(
            platform: .tiktok,
            hook: "Культовая сцена",
            summary: "Этот момент навсегда изменил кинематограф.",
            hashtags: ["cinema", "fightclub", "classic"],
            pinnedComment: "Пиши в комментарии"
        )

        var mutableVariant = variant
        let fullText = mutableVariant.fullDescriptionWithTags
        XCTAssertTrue(fullText.contains("Этот момент навсегда изменил кинематограф."))
        XCTAssertTrue(fullText.contains("#cinema #fightclub #classic"))

        // Обновление из объединенного текста
        let newCombined = "Полностью новое описание сцены.\n\n#epic #masterpiece"
        mutableVariant.updateFromCombinedDescription(newCombined)

        XCTAssertEqual(mutableVariant.summary, "Полностью новое описание сцены.")
        XCTAssertEqual(mutableVariant.hashtags, ["epic", "masterpiece"])
    }
}
