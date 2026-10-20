import Testing
import Foundation
import CoreGraphics
import CoreText
import QuartzCore
import AppKit
import AVFoundation
@testable import Shortcast

@Suite("Longform Thumbnail Generator Tests")
struct LongformThumbnailGeneratorTests {

    /// Вспомогательное создание тестового CGImage заданного размера и цвета
    private func createTestCGImage(width: Int = 1920, height: Int = 1080) -> CGImage {
        let color = CGColor(gray: 0.3, alpha: 1.0)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        )!
        ctx.setFillColor(color)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    @Test("LongformThumbnailComposer generates 1920x1080 image with left layout when face is on right")
    func testComposerLeftTextRightFace() throws {
        let composer = LongformThumbnailComposer()
        let testImage = createTestCGImage()

        let candidate = ThumbnailCandidateFrame(
            time: 120.0,
            image: testImage,
            faceBox: CGRect(x: 0.60, y: 0.30, width: 0.25, height: 0.35), // Лицо справа
            score: 850.0,
            averageLuminance: 0.35
        )

        let concept = ThematicConcept(
            word: "ІЛЮЗІЯ",
            tagline: "Твой главный враг — это ложь, которую ты сам себе рассказываешь",
            philosophicalPremise: "Самообман",
            suggestedTitle: "Иллюзия выбора",
            accentColorHex: "#FFE45C"
        )

        let rendered = try composer.composeThumbnail(
            candidate: candidate,
            concept: concept,
            movieTitle: "Револьвер"
        )

        #expect(rendered.width == 1920)
        #expect(rendered.height == 1080)
    }

    @Test("LongformThumbnailComposer handles long words and multi-line taglines without crashing or truncation")
    func testComposerLongTaglineAndWordScaling() throws {
        let composer = LongformThumbnailComposer()
        let testImage = createTestCGImage()

        let candidate = ThumbnailCandidateFrame(
            time: 250.0,
            image: testImage,
            faceBox: CGRect(x: 0.20, y: 0.30, width: 0.20, height: 0.30), // Лицо слева
            score: 750.0,
            averageLuminance: 0.40
        )

        let concept = ThematicConcept(
            word: "ПЕРЕДВИЗНАЧЕНІСТЬ", // Очень длинное слово
            tagline: "Каждый шаг, который ты делаешь, пытаясь избежать своей судьбы, на самом деле лишь приближает тебя к неизбежному финалу", // Очень длинный тезис
            philosophicalPremise: "Рок и свобода воли",
            suggestedTitle: "Судьба",
            accentColorHex: "#E50914"
        )

        let rendered = try composer.composeThumbnail(
            candidate: candidate,
            concept: concept,
            movieTitle: "Бійцівський клуб"
        )

        #expect(rendered.width == 1920)
        #expect(rendered.height == 1080)
    }

    @Test("LongformThumbnailComposer falls back to center-bottom layout when no face is present")
    func testComposerFallbackWithoutFace() throws {
        let composer = LongformThumbnailComposer()
        let testImage = createTestCGImage()

        let candidate = ThumbnailCandidateFrame(
            time: 400.0,
            image: testImage,
            faceBox: nil, // Лицо отсутствует
            score: 100.0,
            averageLuminance: 0.30
        )

        let concept = ThematicConcept(
            word: "ЧАС",
            tagline: "Оно не лечит, оно лишь стирает воспоминания",
            philosophicalPremise: "Необратимость",
            suggestedTitle: "Время",
            accentColorHex: "#F5D020"
        )

        let rendered = try composer.composeThumbnail(
            candidate: candidate,
            concept: concept,
            movieTitle: "Интерстеллар"
        )

        #expect(rendered.width == 1920)
        #expect(rendered.height == 1080)
    }

    @Test("LongformThumbnailExporter exports valid JPEG file to target URL")
    func testExporterCreatesJPEG() throws {
        let exporter = LongformThumbnailExporter()
        let testImage = createTestCGImage(width: 640, height: 360)
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("thumb_test_\(UUID().uuidString).jpg")

        defer { try? FileManager.default.removeItem(at: tempURL) }

        let exportedURL = try exporter.export(image: testImage, to: tempURL, quality: 0.90)

        #expect(FileManager.default.fileExists(atPath: exportedURL.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: exportedURL.path)
        let fileSize = attributes[.size] as? Int64 ?? 0
        #expect(fileSize > 1000)
    }
}

/// Типографика кино-оверлея: кегли, авто-усадка якорного слова, порядок полос по вертикали
/// и общий источник констант для оверлея и превью. Тесты сознательно слепы к абсолютным
/// координатам — контракт это ПОРЯДОК полос, а не их позиция.
@Suite("Longform Overlay Typography Tests")
struct LongformOverlayTypographyTests {

    private let renderer = LongformSubtitleRenderer()
    private let productionSize = CGSize(width: 1920, height: 1080)

    private func concept(word: String, accent: String = "#F5D020") -> ThematicConcept {
        ThematicConcept(
            word: word,
            tagline: "Ты держишь руль, которого никогда не касался.",
            philosophicalPremise: "Свобода, которую ты не выбирал, всё равно тебя выбирает.",
            suggestedTitle: "Ты не у руля",
            accentColorHex: accent
        )
    }

    /// Инк-бокс реально отрисованных глифов (CoreText), а не layout-бокс строки
    private func inkBounds(of text: NSAttributedString) -> CGRect {
        let line = CTLineCreateWithAttributedString(text)
        return CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    }

    /// Границы нейтрально-светлых пикселей: офф-вайт #F5F5F7 слова темы на темном фоне превью.
    /// Золотые субтитры под этот фильтр не попадают (несбалансированные каналы).
    private func brightNeutralBounds(of image: CGImage) -> CGRect? {
        let width = image.width
        let height = image.height
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let buffer = context.data else { return nil }
        let pixels = buffer.bindMemory(to: UInt8.self, capacity: width * height * 4)

        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            let rowOffset = y * width * 4
            for x in 0..<width {
                let i = rowOffset + x * 4
                let red = Double(pixels[i]) / 255.0
                let green = Double(pixels[i + 1]) / 255.0
                let blue = Double(pixels[i + 2]) / 255.0
                let neutral = (max(red, green, blue) - min(red, green, blue)) < 0.10
                let bright = min(red, green, blue) > 0.40
                if neutral && bright {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    @Test("кегли масштабируются множителем k = высота кадра / 1080")
    func testPointSizesScaleWithResolution() {
        #expect(LongformSubtitleRenderer.scaleFactor(renderSize: CGSize(width: 1920, height: 1080)) == 1.0)
        #expect(LongformSubtitleRenderer.scaleFactor(renderSize: CGSize(width: 3840, height: 2160)) == 2.0)
        #expect(LongformSubtitleRenderer.themePointSize(k: 1.0) == 44.0)
        #expect(LongformSubtitleRenderer.themePointSize(k: 0.5) == 22.0)
        #expect(LongformSubtitleRenderer.captionPointSize(k: 1.0) == 32.0)
        #expect(LongformSubtitleRenderer.captionPointSize(k: 2.0) == 64.0)
        #expect(LongformSubtitleRenderer.taglinePointSize(k: 1.0) == 20.0)
        #expect(LongformSubtitleRenderer.actOverlinePointSize(k: 1.0) == 20.0)
        #expect(LongformSubtitleRenderer.actTitlePointSize(k: 1.0) == 34.0)

        // кегль из помощника и кегль real шрифта — одно и то же (иначе константы разъехались)
        #expect(LongformSubtitleRenderer.themeFont(k: 1.0).pointSize == CGFloat(LongformSubtitleRenderer.themePointSize(k: 1.0)))
        #expect(LongformSubtitleRenderer.captionFont(k: 2.0).pointSize == 64.0)
        #expect(LongformSubtitleRenderer.themeFont(k: 1.0).pointSize < LongformSubtitleRenderer.captionFont(k: 1.0).pointSize * 2.0)
    }

    @Test("надстрочник карточки акта получил обводку, которой раньше не было")
    func testActOverlineHasStrokeAndScales() {
        let attrs = LongformSubtitleRenderer.actOverlineAttributes(k: 1.0, accentHex: "#F5D020")
        #expect(attrs[.strokeColor] as? NSColor == NSColor.black)
        #expect(abs((attrs[.strokeWidth] as? CGFloat ?? 0.0) + 2.0) < 0.001)
        let scaled = LongformSubtitleRenderer.actOverlineAttributes(k: 2.0, accentHex: "#F5D020")
        #expect(abs((scaled[.strokeWidth] as? CGFloat ?? 0.0) + 4.0) < 0.001)
        #expect((scaled[.font] as? NSFont)?.pointSize == 40.0)

        let title = LongformSubtitleRenderer.actTitleAttributes(k: 1.0)
        #expect(abs((title[.strokeWidth] as? CGFloat ?? 0.0) + 2.4) < 0.001)
        #expect((title[.font] as? NSFont)?.pointSize == 34.0)
    }

    @Test("якорное слово усаживается, чтобы не занять больше 60% ширины кадра")
    func testThemeWordShrinksToFit() throws {
        let cap = 1000.0
        let longWord = String(repeating: "С", count: 40)
        let size = LongformSubtitleRenderer.resolvedThemePointSize(word: longWord, k: 1.0, maxWidth: cap)
        #expect(size < LongformSubtitleRenderer.themePointSize(k: 1.0))
        #expect(size >= LongformSubtitleRenderer.themeMinPointSize)
        let fitted = LongformSubtitleRenderer.measuredThemeWidth(word: longWord, pointSize: size, k: 1.0)
        #expect(fitted <= cap + 1.0)

        // недостижимая цель: пол 30pt·k, ниже не падаем
        let extreme = LongformSubtitleRenderer.resolvedThemePointSize(
            word: String(repeating: "Щ", count: 120), k: 1.0, maxWidth: 200.0)
        #expect(abs(extreme - LongformSubtitleRenderer.themeMinPointSize) < 0.001)

        // при k = 0.5 пол тоже масштабируется
        let small = LongformSubtitleRenderer.resolvedThemePointSize(word: longWord, k: 0.5, maxWidth: 240.0)
        #expect(small >= LongformSubtitleRenderer.themeMinPointSize * 0.5 - 0.001)
        #expect(small <= LongformSubtitleRenderer.themePointSize(k: 0.5) + 0.001)

        // короткое слово остаётся на эталонном кегле — усадка не «съедает» его
        let short = LongformSubtitleRenderer.resolvedThemePointSize(word: "ДОЛГ", k: 1.0, maxWidth: 1152.0)
        #expect(short == LongformSubtitleRenderer.themePointSize(k: 1.0))
    }

    @Test("в собранном оверлее слово темы не шире 60% кадра, а центр остаётся H/2")
    func testOverlayKeepsThemeWordWithinSixtyPercent() async throws {
        let root = await renderer.makeOverlayLayer(
            renderSize: productionSize,
            concept: concept(word: "ПредопределенностьСвободыВолиЧеловека"),
            timedPhrases: [],
            totalDuration: 60.0
        )
        let layer = try #require(root.sublayers?.first)
        let maxWidth = Double(productionSize.width) * LongformSubtitleRenderer.themeMaxWidthScale
        let padding = 40.0 * LongformSubtitleRenderer.scaleFactor(renderSize: productionSize)
        #expect(Double(layer.frame.width) <= maxWidth + padding + 1.0)
        #expect(abs(Double(layer.frame.midY) - Double(productionSize.height) / 2.0) < 0.01)
    }

    @Test("порядок полос неизменен: тема в центре, субтитры и слоган под ней, слоган до первой реплики")
    func testOverlayVerticalOrderIsPreserved() async throws {
        let phrases = [
            TimedSubtitlePhrase(start: 5.0, end: 8.0, text: "Ты держишь руль"),
            TimedSubtitlePhrase(start: 8.0, end: 11.0, text: "которого никогда не касался")
        ]
        let root = await renderer.makeOverlayLayer(
            renderSize: productionSize,
            concept: concept(word: "ТЕРПЕНИЕ"),
            timedPhrases: phrases,
            totalDuration: 30.0
        )
        let layers = try #require(root.sublayers)
        let conceptBand = try #require(layers.first)
        let subtitleBands = try #require(layers.count > 1 ? layers[1].sublayers : nil)
            .filter { $0.contents != nil }
        let taglineBands = try #require(layers.count > 2 ? layers[2].sublayers : nil)
            .filter { $0.contents != nil }

        #expect(subtitleBands.count == phrases.count)
        #expect(!taglineBands.isEmpty)

        // 1. Якорное слово — единственный источник истины по вертикали: центр кадра
        #expect(abs(conceptBand.frame.midY - productionSize.height / 2.0) < 0.01)

        // 2. Субтитры — целиком ПОД словом (y растет вверх: полоса субтитры ниже по minY)
        for band in subtitleBands {
            #expect(band.frame.maxY < conceptBand.frame.minY)
        }

        // 3. Слоган — строго ПОД словом. Он занимает то же вертикальное окно, что и субтитры,
        //    поэтому разделение держится по времени, а не по координатам (см. пункт 4).
        for band in taglineBands {
            #expect(band.frame.maxY < conceptBand.frame.minY)
        }

        // 4. Временная эксклюзивность: заставка гаснет до появления первой реплики.
        let taglineFade = try #require(layers[2].animation(forKey: "introTaglineFade") as? CAKeyframeAnimation)
        let taglineVisibleUntil = (taglineFade.keyTimes?[3] ?? NSDecimalNumber.zero).doubleValue * taglineFade.duration
        var firstCaptionAt = Double.infinity
        for band in subtitleBands {
            guard let fade = band.animation(forKey: "smoothPhraseFade") as? CAKeyframeAnimation,
                  let keyTimes = fade.keyTimes, keyTimes.count > 1 else { continue }
            firstCaptionAt = min(firstCaptionAt, keyTimes[1].doubleValue * fade.duration)
        }
        #expect(taglineVisibleUntil < firstCaptionAt)

        // 4. Плашки/рамки под текстом запрещены спецификацией
        for band in [conceptBand] + subtitleBands + taglineBands {
            #expect(band.backgroundColor == nil)
            #expect(band.borderWidth == 0.0)
        }
    }

    @Test("превью и оверлей разрешают один и тот же кегль темы через общий помощник")
    func testPreviewAndOverlayResolveIdenticalThemeSize() async throws {
        let thematicConcept = concept(word: "Субъективность")
        let k = LongformSubtitleRenderer.scaleFactor(renderSize: productionSize)
        let expectedSize = LongformSubtitleRenderer.resolvedThemePointSize(
            word: thematicConcept.word,
            k: k,
            maxWidth: Double(productionSize.width) * LongformSubtitleRenderer.themeMaxWidthScale
        )
        let attrs = LongformSubtitleRenderer.themeAttributes(pointSize: expectedSize, k: k)
        let upper = thematicConcept.word.uppercased()

        // Оверлей: высота слоя = высота текста из общего помощника + padding 20·k
        let root = await renderer.makeOverlayLayer(
            renderSize: productionSize, concept: thematicConcept, timedPhrases: [], totalDuration: 60.0
        )
        let conceptBand = try #require(root.sublayers?.first)
        let layoutHeight = Double(NSAttributedString(string: upper, attributes: attrs).size().height)
        #expect(abs(Double(conceptBand.frame.height) - (ceil(layoutHeight) + 20.0 * k)) < 0.75)

        // Превью: то же слово реально нарисовано тем же кеглем
        let image = try #require(renderer.renderPreviewImage(
            renderSize: productionSize, concept: thematicConcept, currentPhrase: nil
        ))
        let pixels = try #require(brightNeutralBounds(of: image))
        let expected = inkBounds(of: NSAttributedString(string: upper, attributes: attrs))
        #expect(abs(pixels.height - expected.height) <= 5.0)
        #expect(abs(pixels.width - expected.width) <= 6.0)

        // страховка от отката к прежним 56pt: старый кегль заметно крупнее нарисованного
        let legacy = inkBounds(of: NSAttributedString(
            string: upper,
            attributes: LongformSubtitleRenderer.themeAttributes(pointSize: 56.0 * k, k: k)
        ))
        #expect(pixels.height < legacy.height - 3.0)
        #expect(pixels.width < legacy.width - 10.0)
    }
}
