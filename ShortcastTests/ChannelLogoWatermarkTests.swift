import Testing
import AVFoundation
import CoreGraphics
import Foundation
import QuartzCore
@testable import Shortcast

/// Геометрия прожжённого знака канала. Тесты только численные: ни рендера, ни ассета, ни
/// `CALayer` — кроме одного, который проверяет ПОРЯДОК полос в собранном оверлее.
///
/// Все координаты — bottom-left origin (как у слоёв оверлея: `isGeometryFlipped == false`).
@Suite("Channel Logo Watermark Geometry")
struct ChannelLogoWatermarkTests {

    private let essay = CGSize(width: 1920, height: 1080)
    private let short916 = CGSize(width: 1080, height: 1920)
    private let style = ChannelLogoStyle.essay
    private let shortStyle = ChannelLogoStyle.shorts

    /// Слово темы из эталонного шрифта — та же нижняя граница, что кладёт оверлей.
    private func conceptY(_ word: String, renderSize: CGSize) -> CGFloat {
        let k = LongformSubtitleRenderer.scaleFactor(renderSize: renderSize)
        let attrs = LongformSubtitleRenderer.themeAttributes(
            pointSize: LongformSubtitleRenderer.resolvedThemePointSize(
                word: word, k: k, maxWidth: LongformSubtitleRenderer.themeMaxWidth(renderSizeWidth: Double(renderSize.width))
            ),
            k: k
        )
        let textSize = NSAttributedString(string: word.uppercased(), attributes: attrs).size()
        return LongformSubtitleRenderer.conceptBottomY(renderSize: renderSize, textSize: textSize, k: k)
    }

    private func band(_ lines: Int, renderSize: CGSize, y: CGFloat) -> CGRect {
        LongformSubtitleRenderer.essaySubtitleBand(renderSize: renderSize, conceptY: y, lines: lines)
    }

    // MARK: - Эссе: номинальный размер и центрирование

    @Test("номинальный знак — 11% высоты кадра, квадрат, по центру у нижнего края")
    func testNominalSizeIsElevenPercentAndCentered() throws {
        let rect = try #require(ChannelLogoPlacement.essay(
            renderSize: essay, subtitleBottom: 500, bottomBarHeight: 60, style: style
        ))
        let nominal = style.sizeFraction * essay.height // 118.8 px при 1080
        #expect(abs(rect.width - nominal) < 0.001)
        #expect(abs(rect.height - nominal) < 0.001)
        #expect(abs(rect.midX - essay.width / 2) < 0.001)
        // Опирается на верх леттбокса + edgeInset, а до субтитров оставляет запас gap.
        #expect(abs(rect.minY - (60 + style.edgeInset)) < 0.001)
        #expect(rect.maxY <= 500 - style.gapBelowSubtitles + 0.001)
    }

    @Test("полный размер знака остаётся при одной и при трёх строках субтитров")
    func testFullSizeAtOneAndThreeLineCaptions() throws {
        let y = conceptY("ТЕРПІННЯ", renderSize: essay)
        let nominal = style.sizeFraction * essay.height
        for lines in [1, 3] {
            let rect = try #require(LongformSubtitleRenderer.essayLogoBand(
                renderSize: essay, conceptY: y, lines: lines, bottomBarHeight: 60, style: style
            ))
            #expect(abs(rect.height - nominal) < 0.001, "строки \(lines): знак должен остаться номинальным")
            #expect(!rect.intersects(band(lines, renderSize: essay, y: y)), "строки \(lines): знак на субтитрах")
        }
    }

    @Test("четыре строки + летбокс: знак остаётся номинальным и не трогает субтитры")
    func testFourLinesKeepNominalLogoAboveLetterbox() throws {
        let y = conceptY("ТЕРПІННЯ", renderSize: essay)
        let bottomBar = 0.135 * essay.height // реальный летбокс 16:9-исходника в 9:16-монтаже
        let rect = try #require(LongformSubtitleRenderer.essayLogoBand(
            renderSize: essay, conceptY: y, lines: 4, bottomBarHeight: bottomBar, style: style
        ))
        let nominal = style.sizeFraction * essay.height
        #expect(abs(rect.height - nominal) < 0.001, "места у нижнего края хватает на полный знак")
        #expect(abs(rect.minY - (bottomBar + style.edgeInset)) < 0.001)
        #expect(!rect.intersects(band(4, renderSize: essay, y: y)))
    }

    @Test("пять строк + летбокс: знак ужимается, но не ниже пола 0.06·H")
    func testFiveLinesShrinkLogoToAvailableRoom() throws {
        let y = conceptY("ТЕРПІННЯ", renderSize: essay)
        let bottomBar = 0.135 * essay.height
        let rect = try #require(LongformSubtitleRenderer.essayLogoBand(
            renderSize: essay, conceptY: y, lines: 5, bottomBarHeight: bottomBar, style: style
        ))
        #expect(rect.height < style.sizeFraction * essay.height, "при нехватке места знак обязан ужаться")
        #expect(rect.height >= style.minSizeFraction * essay.height - 0.001)
        #expect(abs(rect.minY - (bottomBar + style.edgeInset)) < 0.001)
        #expect(!rect.intersects(band(5, renderSize: essay, y: y)))
        #expect(abs(rect.width - rect.height) < 0.001, "квадрат обязан остаться квадратом")
    }

    @Test("ниже пола 0.06·H знак не рисуется вообще")
    func testDropBelowMinimumSizeFraction() throws {
        // Субтитры почти легли на низ кадра: свободной полосы меньше minSizeFraction·H.
        #expect(ChannelLogoPlacement.essay(
            renderSize: essay, subtitleBottom: 95, bottomBarHeight: 0, style: style
        ) == nil)
        let floor = style.edgeInset + style.gapBelowSubtitles + style.minSizeFraction * essay.height
        #expect(ChannelLogoPlacement.essay(
            renderSize: essay, subtitleBottom: floor - 1, bottomBarHeight: 0, style: style
        ) == nil)
    }

    @Test("bottomBarHeight = 0 (16:9 без летбокса): отступ от края и ноль пересечений")
    func testBottomBarZeroKeepsEdgeInsetAndNoOverlap() throws {
        let y = conceptY("СТРАХ", renderSize: essay)
        for lines in [1, 3, 4, 5] {
            let rect = try #require(LongformSubtitleRenderer.essayLogoBand(
                renderSize: essay, conceptY: y, lines: lines, bottomBarHeight: 0, style: style
            ))
            #expect(abs(rect.minY - style.edgeInset) < 0.001, "строки \(lines): знак прижат к краю ровно на 12·k")
            #expect(!rect.intersects(band(lines, renderSize: essay, y: y)), "строки \(lines): пересечение с субтитрами")
        }
    }

    // MARK: - Шортсы

    @Test("шортс: пустые snapRects дают полосу по умолчанию 0.12·H")
    func testEmptySnapRectsUseDefaultBand() throws {
        #expect(SubtitleRenderer.shortSubtitleBottom(captionRects: [], renderSize: short916)
                    == 0.12 * short916.height)
        let rect = try #require(SubtitleRenderer.shortChannelLogoBand(renderSize: short916, captionRects: []))
        let inset = max(16, short916.width * 0.02)
        let gap = 0.012 * short916.height
        // Левый нижний угол, верх полосы — ровно под запасом от субтитров по умолчанию.
        #expect(abs(rect.minX - inset) < 0.001)
        #expect(abs(rect.minY - inset) < 0.001)
        #expect(abs(rect.maxY - (0.12 * short916.height - gap)) < 0.001)
        #expect(abs(rect.width - rect.height) < 0.001)
    }

    @Test("шортс: худший случай (капт прижат к полу, minY = 40) — знак не рисуем")
    func testShortsWorstCaseDrops() {
        // buildKineticSubtitleLayer зажимает snap Y снизу до 40 px — ниже уже некуда.
        // x = 100 внутри левой колонки, иначе капт не считается вообще.
        let floorCaption = CGRect(x: 100, y: 40, width: 600, height: 220)
        #expect(ChannelLogoPlacement.short(renderSize: short916, subtitleSnapRects: [floorCaption], style: shortStyle) == nil)
        #expect(SubtitleRenderer.shortChannelLogoBand(renderSize: short916, captionRects: [floorCaption]) == nil)
    }

    @Test("шортс: капт выше 0.12·H оставляет знак номинальным")
    func testShortsNominalAboveDefaultBand() throws {
        // Капт должен перекрывать левую колонку (x < 0.11·H + inset), иначе он не считается.
        let elevated = CGRect(x: 100, y: 0.25 * short916.height, width: 600, height: 200)
        let rect = try #require(SubtitleRenderer.shortChannelLogoBand(renderSize: short916, captionRects: [elevated]))
        let nominal = shortStyle.sizeFraction * short916.height // 211.2 px при 1920
        #expect(abs(rect.width - nominal) < 0.001)
        #expect(!rect.intersects(elevated))
        // Площадочный рельс actions (правый нижний угол) не задет: знак в левом.
        #expect(rect.maxX < short916.width * 0.84)
    }

    @Test("шортс: квадратный кадр остаётся в долях — без пиксельных констант")
    func testShortsSquareFrameUsesFractions() throws {
        let square = CGSize(width: 1080, height: 1080)
        let rect = try #require(SubtitleRenderer.shortChannelLogoBand(renderSize: square, captionRects: []))
        #expect(rect.width <= shortStyle.sizeFraction * square.height + 0.001)
        #expect(rect.minY >= max(16, square.width * 0.02) - 0.001)
        #expect(rect.maxX < square.width * 0.84, "вертикальный рельс actions занят не знаком")
    }

    // MARK: - Настройки и деградация

    @Test("настройка шортсов: без нового ключа — фолбэк на старый watermarkEnabled")
    func testShortsSettingFallsBackToLegacyFlag() {
        let defaults = UserDefaults(suiteName: "app.shortcast.tests.\(UUID().uuidString)")!
        // Ключей нет вовсе: бренд остаётся включённым (молча незабрендрованный клип — худший вариант).
        #expect(ChannelLogoWatermarkSettings.isEnabled(for: .shorts, defaults: defaults))
        defaults.set(false, forKey: ChannelLogoWatermarkSettings.legacyWatermarkKey)
        #expect(!ChannelLogoWatermarkSettings.isEnabled(for: .shorts, defaults: defaults))
        // Новый ключ важнее старого.
        defaults.set(true, forKey: ChannelLogoWatermarkSettings.shortsKey)
        #expect(ChannelLogoWatermarkSettings.isEnabled(for: .shorts, defaults: defaults))
        defaults.set(false, forKey: ChannelLogoWatermarkSettings.shortsKey)
        defaults.set(true, forKey: ChannelLogoWatermarkSettings.legacyWatermarkKey)
        #expect(!ChannelLogoWatermarkSettings.isEnabled(for: .shorts, defaults: defaults))
        // Явный флаг клипа имеет приоритет над настройкой (будущее поле ShortClip).
        #expect(ChannelLogoWatermarkSettings.isEnabled(for: .shorts, clipWants: true, defaults: defaults))
        defaults.set(true, forKey: ChannelLogoWatermarkSettings.shortsKey)
        #expect(!ChannelLogoWatermarkSettings.isEnabled(for: .shorts, clipWants: false, defaults: defaults))
    }

    @Test("шортс: чужая полоса в левом нижнем углу выключает знак, а не сдвигает его на неё")
    func testShortsHonorExcludedRects() throws {
        let elevated = CGRect(x: 100, y: 0.25 * short916.height, width: 600, height: 200)
        let nominal = try #require(SubtitleRenderer.shortChannelLogoBand(
            renderSize: short916, captionRects: [elevated]
        ))
        // Рельс actions, дотянувший до левого угла: пересечения быть не может — ничего не рисуем.
        let rail = CGRect(x: 0, y: 0, width: short916.width, height: nominal.maxY)
        #expect(SubtitleRenderer.shortChannelLogoBand(
            renderSize: short916, captionRects: [elevated], excludedRects: [rail]
        ) == nil)
        // Полоса выше знака не мешает.
        let above = CGRect(x: 0, y: nominal.maxY + 1, width: short916.width, height: 100)
        #expect(SubtitleRenderer.shortChannelLogoBand(
            renderSize: short916, captionRects: [elevated], excludedRects: [above]
        ) == nominal)
    }

    // MARK: - Порядок полос в собранном оверлее

    @Test("оверлей эссе: постоянный почти прозрачный знак — последним, по центру у низа")
    func testOverlayAppendsPersistentChannelLogoLast() async throws {
        guard ChannelLogo.isAvailable else {
            Issue.record("ассет ChannelLogo не долетел до тестового хоста: знак проверить нечем")
            return
        }
        let renderer = LongformSubtitleRenderer()
        let concept = ThematicConcept(
            word: "ТЕРПІННЯ",
            tagline: "Ты держишь руль, которого никогда не касался.",
            philosophicalPremise: "Свобода, которую ты не выбирал, всё равно тебя выбирает.",
            suggestedTitle: "Ты не у руля",
            accentColorHex: "#F5D020"
        )
        let phrases = [
            TimedSubtitlePhrase(start: 5.0, end: 8.0, text: "Ты держишь руль"),
            TimedSubtitlePhrase(start: 8.0, end: 11.0, text: "которого никогда не касался")
        ]
        let totalDuration = 600.0
        let root = await renderer.makeOverlayLayer(
            renderSize: essay, concept: concept, timedPhrases: phrases,
            totalDuration: totalDuration,
            layout: LongformOverlayLayout(bottomBarHeight: 0)
        )
        let layers = try #require(root.sublayers)
        // [0] тема, [1] субтитры, [2] слоган, [3] постоянный знак канала — последним.
        #expect(layers.count == 4)
        let logo = try #require(layers.last)
        #expect(logo.contents != nil, "знак — растр логотипа, а не пустая плашка")
        #expect(logo.opacity > 0.05 && logo.opacity < 0.2, "знак обязан быть почти прозрачным")
        #expect(logo.animation(forKey: "watermarkStingOpacity") == nil, "никаких стингов: знак постоянный")

        let style = ChannelLogoStyle.essay
        #expect(abs(logo.frame.width - style.sizeFraction * essay.height) < 0.001)
        #expect(abs(logo.frame.width - logo.frame.height) < 0.001)
        #expect(abs(logo.frame.midX - essay.width / 2) < 0.001, "знак по центру кадра")
        #expect(logo.frame.minY <= essay.height * 0.05, "знак у самого низа кадра")
        let captionFrame = try #require(layers[1].sublayers?.first?.frame)
        #expect(!logo.frame.intersects(captionFrame), "знак не залезает на субтитры")

        // Выключенный знак — ровно три полосы: тема, субтитры, слоган.
        let noLogo = await renderer.makeOverlayLayer(
            renderSize: essay, concept: concept, timedPhrases: phrases,
            totalDuration: totalDuration,
            layout: LongformOverlayLayout(bottomBarHeight: 0, channelLogo: nil)
        )
        #expect(noLogo.sublayers?.count == 3)
    }

    @Test("знак эссе почти прозрачный, шортсы сохраняют свою непрозрачность")
    func testEssayLogoIsNearlyTransparent() {
        #expect(ChannelLogoStyle.essay.opacity > 0.05)
        #expect(ChannelLogoStyle.essay.opacity <= 0.15)
        #expect(ChannelLogoStyle.shorts.opacity > ChannelLogoStyle.essay.opacity)
    }

    @Test("знак прижат к низу кадра на любом размере")
    func testLogoAnchorsToBottomEdgeOnEveryFrameSize() throws {
        for size in [essay, CGSize(width: 1280, height: 720), CGSize(width: 1080, height: 1920), CGSize(width: 3840, height: 2160)] {
            let style = ChannelLogoStyle.essay
            let k = size.height / 1080
            let rect = try #require(ChannelLogoPlacement.essay(
                renderSize: size, subtitleBottom: size.height * 0.55,
                bottomBarHeight: 0, style: style
            ))
            #expect(abs(rect.minY - style.edgeInset * k) < 0.001)
            #expect(abs(rect.midX - size.width / 2) < 0.001)
            #expect(abs(rect.height - style.sizeFraction * size.height) < 0.001)
        }
    }

    // MARK: - Хук и финальный CTA

    @Test("хук и CTA добавляют слои; без них состав прежний")
    func hookAndCTALayersAppearOnlyWhenProvided() async {
        let renderer = LongformSubtitleRenderer()
        let concept = ThematicConcept(
            word: "КОНТРОЛЬ",
            tagline: "т",
            philosophicalPremise: "п",
            suggestedTitle: "з",
            accentColorHex: "#FFFFFF"
        )
        let size = CGSize(width: 1920, height: 1080)
        let phrases = [TimedSubtitlePhrase(start: 1, end: 5, text: "Реплика под хуком")]

        let withTexts = await renderer.makeOverlayLayer(
            renderSize: size, concept: concept, timedPhrases: phrases,
            totalDuration: 120,
            layout: LongformOverlayLayout(channelLogo: nil),
            hookText: "Ти контролюєш усе, крім себе.",
            ctaText: "Напиши, від чого ти не відпустив."
        )
        #expect(withTexts.sublayers?.count == 4)

        let withoutTexts = await renderer.makeOverlayLayer(
            renderSize: size, concept: concept, timedPhrases: phrases,
            totalDuration: 120,
            layout: LongformOverlayLayout(channelLogo: nil)
        )
        #expect(withoutTexts.sublayers?.count == 3)
    }

    @Test("под хуком субтитры молчат до 6.2с")
    func subtitlesStayHiddenUnderHookUntilSixSeconds() async throws {
        let renderer = LongformSubtitleRenderer()
        let concept = ThematicConcept(
            word: "КОНТРОЛЬ",
            tagline: "т",
            philosophicalPremise: "п",
            suggestedTitle: "з",
            accentColorHex: "#FFFFFF"
        )
        let phrases = [TimedSubtitlePhrase(start: 1, end: 5, text: "Рання репліка")]
        let root = await renderer.makeOverlayLayer(
            renderSize: CGSize(width: 1920, height: 1080), concept: concept,
            timedPhrases: phrases, totalDuration: 120,
            layout: LongformOverlayLayout(channelLogo: nil),
            hookText: "Хук", ctaText: nil
        )
        let subtitleBand = try #require(root.sublayers?[1])
        #expect(subtitleBand.sublayers?.isEmpty ?? true)
    }
}
