import Testing
import Foundation
import AppKit
@testable import Shortcast

@Suite("ShortsTable & ShortClipTile View Mode & Model Tests")
struct ShortsTableAndTileTests {

    @Test("ShortsResultsView.ViewMode cases and localization keys")
    func testViewModes() {
        let cases = ShortsResultsView.ViewMode.allCases
        #expect(cases.count == 3)
        #expect(cases.contains(.grid))
        #expect(cases.contains(.table))
        #expect(cases.contains(.compare))

        #expect(ShortsResultsView.ViewMode.grid.rawValue == "Сетка")
        #expect(ShortsResultsView.ViewMode.table.rawValue == "Таблица")
        #expect(ShortsResultsView.ViewMode.compare.rawValue == "Сравнение")
    }

    @Test("ClipExportHelper copies text to pasteboard accurately")
    @MainActor
    func testPasteboardCopy() {
        let testString = "Культовый момент из фильма #кино #shorts"
        ClipExportHelper.copyToPasteboard(testString)

        let pasted = NSPasteboard.general.string(forType: .string)
        #expect(pasted == testString)
    }

    @Test("ShortClip variant hook and fullDescriptionWithTags update correctly")
    @MainActor
    func testVariantDescriptionAndHookUpdate() {
        let candidate = ClipCandidate(
            start: 10,
            end: 45,
            why: "Динамичная сцена",
            hook: "Начальный хук",
            viralScore: 92
        )
        let clip = ShortClip(
            candidate: candidate,
            transcriptSlice: "Текст диалога",
            subtitleSegments: [],
            overlayEnabled: false,
            reframeEnabled: false,
            burnSubtitles: false,
            subtitleAppearance: .tiktok
        )

        #expect(clip.displayTitle == "Начальный хук")

        var variant = PostVariant(
            platform: .tiktok,
            hook: "ТТ Хук",
            summary: "Описание фильма",
            hashtags: ["фильм", "топ"],
            pinnedComment: ""
        )
        clip.variants.append(variant)

        #expect(variant.fullDescriptionWithTags == "Описание фильма\n\n#фильм #топ")

        // Update via combined description
        variant.updateFromCombinedDescription("Новое описание сцены\n\n#триллер #кино")
        #expect(variant.summary == "Новое описание сцены")
        #expect(variant.hashtags == ["триллер", "кино"])
        #expect(variant.fullDescriptionWithTags == "Новое описание сцены\n\n#триллер #кино")
    }
}
