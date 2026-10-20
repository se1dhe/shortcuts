import Testing
import Foundation
import AVFoundation
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import Shortcast

/// Обложка шортса 9:16: геометрия слотов, кроп по лицу и запись JPEG.
/// Тесты сознательно не смотрят на пиксели логотипа — контракт это КООРДИНАТЫ
/// полос (они считаются от `ChannelLogoPlacement`), а не их содержимое.
@Suite("Short Cover Generator Tests")
struct ShortCoverGeneratorTests {

    private let canvas = ShortCoverLayout.canvas

    /// Синтетический «киношный» кадр: ландшафт 16:9, чтобы проверить заполняющий кроп в 9:16.
    private func makeLandscapeFrame(width: Int = 1920, height: Int = 1080) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        ))
        context.setFillColor(CGColor(red: 0.35, green: 0.32, blue: 0.28, alpha: 1.0))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.85, green: 0.80, blue: 0.70, alpha: 1.0))
        let w = CGFloat(width)
        let h = CGFloat(height)
        let rectX = w * 0.45
        let rectY = h * 0.35
        let rectW = w * 0.2
        let rectH = h * 0.35
        context.fill(CGRect(x: rectX, y: rectY, width: rectW, height: rectH))
        return try #require(context.makeImage())
    }

    private func makeTempWorkingDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("shortcast-cover-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Геометрия слотов

    @Test("полосы текста обложки 9:16 не пересекают прямоугольник логотипа")
    func testTextSlotsNeverCollideWithLogo() throws {
        let logo = ShortCoverLayout.logoRect(canvas: canvas)
        let slots = ShortCoverLayout.worstCaseTextSlots(canvas: canvas)
        #expect(slots.count == 2)

        for slot in slots {
            #expect(slot.intersection(logo).isEmpty, "слот \(slot) залез в логотип \(logo)")
        }

        // Логотип целиком в верхней вуали (тёмный фон под знаком) и внутри канваса.
        let topVeil = ShortCoverLayout.topVeil(canvas: canvas)
        #expect(topVeil.contains(logo))
        #expect(CGRect(origin: .zero, size: canvas).contains(logo))
        #expect(logo.minX > 0)
        #expect(logo.minY > 0)
    }

    @Test("строка фильма прижата к логотипу снизу, хук живёт в нижней трети")
    func testSlotOrderIsPreserved() throws {
        let logo = ShortCoverLayout.logoRect(canvas: canvas)
        let movieLine = ShortCoverLayout.movieLine(canvas: canvas)
        let hook = ShortCoverLayout.hookRect(
            canvas: canvas,
            height: ShortCoverLayout.hookMaxHeightScale * canvas.height
        )

        // Порядок по вертикали (bottom-left origin): хук < строка фильма < знак.
        #expect(hook.maxY < movieLine.minY)
        #expect(movieLine.maxY < logo.minY)
        // Зазор между знаком и названием не тоньше эталонного.
        #expect(logo.minY - movieLine.maxY >= canvas.height * (ShortCoverLayout.logoGapScale - 0.001))
        // Верхняя строка остаётся под верхним краем, хук — внутри нижней вуали.
        #expect(movieLine.maxY <= canvas.height)
        #expect(ShortCoverLayout.bottomVeil(canvas: canvas).contains(hook))
    }

    @Test("геометрия масштабируется долями, а не пикселями формата")
    func testSlotsScaleWithCanvas() throws {
        let scaled = CGSize(width: canvas.width * 2, height: canvas.height * 2)
        let small = ShortCoverLayout.worstCaseTextSlots(canvas: canvas)
        let large = ShortCoverLayout.worstCaseTextSlots(canvas: scaled)
        let logoSmall = ShortCoverLayout.logoRect(canvas: canvas)
        let logoLarge = ShortCoverLayout.logoRect(canvas: scaled)

        #expect(abs(logoLarge.width - logoSmall.width * 2) < 0.001)
        #expect(abs(logoLarge.minY - logoSmall.minY * 2) < 0.001)
        #expect(abs(logoLarge.minX - logoSmall.minX * 2) < 0.001)
        for (lhs, rhs) in zip(small, large) {
            #expect(abs(rhs.width - lhs.width * 2) < 0.001)
            #expect(abs(rhs.minY - lhs.minY * 2) < 0.001)
            #expect(abs(rhs.height - lhs.height * 2) < 0.001)
            // ...и на удвоенном канвасе в логотип тоже никто не лезет.
            #expect(rhs.intersection(logoLarge).isEmpty)
        }
    }

    // MARK: - Обложка эссе: правый верх свободен от типографики

    @Test("ни одна текстовая полоса обложки эссе не мешает знаку в правом верху")
    func testEssayCoverSlotsClearTheLogo() throws {
        let essayCanvas = CGSize(width: 1920, height: 1080)
        let logo = ChannelLogoPlacement.essayCover(canvas: essayCanvas)
        let vignette = LongformCoverTextSlots.topVignette(canvas: essayCanvas)

        for mode in [ThumbnailLayoutMode.leftTextRightFace, .rightTextLeftFace, .centerBottomFallback] {
            let slots = LongformCoverTextSlots.worstCase(layoutMode: mode, canvas: essayCanvas)
            for slot in slots.all {
                #expect(slot.intersection(logo).isEmpty, "\(mode): слот \(slot) пересекает знак \(logo)")
            }
            // Запас между самой высокой полосой и знаком — не меньше 15% высоты кадра.
            #expect(slots.highestTextY <= logo.minY)
            #expect(logo.minY - slots.highestTextY >= essayCanvas.height * 0.15)
            // Знак лежит на виньетке, а не на светлом участке кадра.
            #expect(vignette.contains(logo))
        }
    }

    @Test("полосы обложки эссе = те же доли на 4K, что и на 1080p")
    func testEssayCoverSlotsAreFormatIndependent() throws {
        let hd = CGSize(width: 1920, height: 1080)
        let uhd = CGSize(width: 3840, height: 2160)
        let modes: [ThumbnailLayoutMode] = [.leftTextRightFace, .rightTextLeftFace, .centerBottomFallback]

        for mode in modes {
            let small = LongformCoverTextSlots.worstCase(layoutMode: mode, canvas: hd)
            let large = LongformCoverTextSlots.worstCase(layoutMode: mode, canvas: uhd)
            #expect(abs(large.badge.minY - small.badge.minY * 2) < 0.01)
            #expect(abs(large.hook.height - small.hook.height * 2) < 0.01)
            let logo = ChannelLogoPlacement.essayCover(canvas: uhd)
            #expect(large.highestTextY <= logo.minY)
            #expect(abs(logo.width - uhd.height * 0.11) < 0.01)
            #expect(logo.maxX <= uhd.width && logo.maxY <= uhd.height)
        }
    }

    // MARK: - Кроп по лицу

    @Test("ландшафтный кадр, залитый в 9:16, держит лицо в коридоре 0.35…0.85 высоты")
    func testLandscapeFaceStaysInBand() throws {
        let source = CGSize(width: 1920, height: 1080)
        // Типовые позиции лица: нижняя, средняя и верхняя части кадра (Vision — низ слева).
        let faces = [
            CGRect(x: 0.62, y: 0.25, width: 0.15, height: 0.20),
            CGRect(x: 0.60, y: 0.40, width: 0.16, height: 0.20),
            CGRect(x: 0.30, y: 0.55, width: 0.14, height: 0.20),
            CGRect(x: 0.20, y: 0.45, width: 0.18, height: 0.30)
        ]

        for face in faces {
            let crop = ShortCoverFraming.crop(sourceSize: source, faceBox: face, canvas: canvas)
            let rect = try #require(crop.faceRect)

            #expect(rect.minY >= canvas.height * ShortCoverLayout.faceBand.lowerBound - 0.001)
            #expect(rect.maxY <= canvas.height * ShortCoverLayout.faceBand.upperBound + 0.001)
            // Кадр обязан покрывать канвас: чёрных полей по бокам обложка не имеет.
            #expect(crop.imageRect.width >= canvas.width - 0.001)
            #expect(crop.imageRect.height >= canvas.height - 0.001)
            // Лицо осталось внутри кадра и по горизонтали.
            #expect(rect.midX >= 0 && rect.midX <= canvas.width)
        }
    }

    @Test("без лица кроп остаётся классическим aspect-fill по центру")
    func testFacelessCropIsCentred() throws {
        let crop = ShortCoverFraming.crop(
            sourceSize: CGSize(width: 1920, height: 1080),
            faceBox: nil,
            canvas: canvas
        )
        #expect(crop.faceRect == nil)
        #expect(abs(crop.imageRect.midX - canvas.width / 2) < 0.001)
        #expect(abs(crop.imageRect.midY - canvas.height / 2) < 0.001)
        #expect(crop.imageRect.height >= canvas.height)
    }

    // MARK: - Композиция и запись

    @Test("обложка шортса выходит ровно 1080×1920")
    func testComposeProducesNineBySixteen() throws {
        let generator = ShortCoverGenerator()
        let image = try generator.composeCover(
            baseImage: makeLandscapeFrame(),
            hook: "Он понял это только спустя двадцать лет",
            movieTitle: "Бегущий по лезвию 2049",
            faceBox: CGRect(x: 0.55, y: 0.4, width: 0.16, height: 0.22),
            canvas: ShortCoverLayout.canvas
        )
        #expect(image.width == 1080)
        #expect(image.height == 1920)
    }

    @Test("записанный JPEG читается и лежит рядом с клипом в Exports/<ФИЛЬМ>/shorts")
    func testSaveWritesDecodableJPEG() throws {
        let working = try makeTempWorkingDirectory()
        defer { try? FileManager.default.removeItem(at: working) }

        let clipURL = working
            .appendingPathComponent("Exports", isDirectory: true)
            .appendingPathComponent("Бегущий по лезвию 2049 (2017)", isDirectory: true)
            .appendingPathComponent("shorts", isDirectory: true)
            .appendingPathComponent("short_kulminatsiya_A1B2C3.mp4")
        let request = ShortCoverRequest(
            clipURL: clipURL,
            hook: "Он понял это только спустя двадцать лет",
            movieTitle: "Бегущий по лезвию 2049 (2017)",
            workingDirectory: working
        )

        // До записи обложку найти нельзя — читатель не должен создавать файлы.
        #expect(ShortCoverStore.existingCoverURL(
            clipURL: clipURL, movieTitle: request.movieTitle, workingDirectory: working) == nil)

        let generator = ShortCoverGenerator()
        let composed = try generator.composeCover(
            baseImage: makeLandscapeFrame(),
            hook: request.hook,
            movieTitle: request.movieTitle,
            faceBox: CGRect(x: 0.5, y: 0.45, width: 0.15, height: 0.2),
            canvas: ShortCoverLayout.canvas
        )
        let written = try generator.save(image: composed, for: request)

        #expect(written == ShortCoverStore.coverURL(
            clipURL: clipURL, movieTitle: request.movieTitle, workingDirectory: working))
        #expect(written.pathExtension.lowercased() == "jpg")
        #expect(written.lastPathComponent.hasPrefix("\(ExportLayout.Kind.shortCover.rawValue)_"))
        #expect(written.deletingLastPathComponent().lastPathComponent == ExportLayout.shortsDirName)
        #expect(FileManager.default.fileExists(atPath: written.path))
        // Обложка рядом с видео: тот же каталог, что и файл клипа в финальной раскладке.
        #expect(written.deletingLastPathComponent().path == clipURL.deletingLastPathComponent().path)

        let source = try #require(
            CGImageSourceCreateWithURL(written as CFURL, nil),
            "JPEG не читается как изображение"
        )
        #expect(CGImageSourceGetCount(source) == 1)
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.width == 1080)
        #expect(decoded.height == 1920)
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        #expect(properties?[kCGImagePropertyPixelWidth] as? Int == 1080)
        #expect(properties?[kCGImagePropertyPixelHeight] as? Int == 1920)
        let type = try #require(CGImageSourceGetType(source)) as String
        #expect(type == UTType.jpeg.identifier)
        let size = try #require(FileManager.default.attributesOfItem(atPath: written.path)[.size] as? Int)
        #expect(size > 1000)

        // После записи путь снова находится по одному только файлу клипа.
        #expect(ShortCoverStore.existingCoverURL(
            clipURL: clipURL, movieTitle: request.movieTitle, workingDirectory: working) == written)
    }

    @Test("имя обложки детерминировано по файлу клипа")
    func testCoverFileNameIsStable() throws {
        let clip = URL(fileURLWithPath: "/tmp/short_kulminatsiya_A1B2C3.mp4")
        let first = ShortCoverStore.coverFileName(clipURL: clip)
        let second = ShortCoverStore.coverFileName(clipURL: clip)
        #expect(first == second)
        #expect(first == "cover_short_kulminatsiya_a1b2c3.jpg")
    }

    @Test("пустой хук не ломает обложку: строка просто не рисуется")
    func testEmptyHookStillRendersCover() throws {
        let generator = ShortCoverGenerator()
        let image = try generator.composeCover(
            baseImage: makeLandscapeFrame(),
            hook: "   ",
            movieTitle: "Интерстеллар",
            faceBox: nil,
            canvas: ShortCoverLayout.canvas
        )
        #expect(image.width == 1080)
        #expect(image.height == 1920)
        let laidOut = ShortCoverText.laidOutHook(
            "С",
            canvas: ShortCoverLayout.canvas,
            boxWidth: ShortCoverLayout.hookRect(canvas: ShortCoverLayout.canvas, height: 1).width,
            paragraphStyle: NSParagraphStyle.default,
            shadow: NSShadow()
        )
        #expect(laidOut != nil)
    }

    @Test("разметка из хука вырезается до отрисовки")
    func testHookStripsMarkup() throws {
        #expect(ShortCoverText.clean("<b>Ты </b>разбил<em> молчание </em>") == "Ты разбил молчание")
    }

    // MARK: - Не фатальность

    @Test("от недоступного клипа обложки нет, но генератор не бросает")
    func testMissingClipReturnsNilCover() async throws {
        let generator = ShortCoverGenerator()
        let missing = URL(fileURLWithPath: "/tmp/shortcast-no-such-clip-\(UUID().uuidString).mp4")
        let cover = await generator.generateCover(for: ShortCoverRequest(
            clipURL: missing,
            hook: "Хук",
            movieTitle: "Фильм",
            workingDirectory: FileManager.default.temporaryDirectory
        ))
        #expect(cover == nil)
    }

    @Test("кривой тримминг не роняет генерацию обложки")
    func testInvalidTrimIsNonFatal() async throws {
        let working = try makeTempWorkingDirectory()
        defer { try? FileManager.default.removeItem(at: working) }
        let clip = working.appendingPathComponent("short_clip.mp4")
        // Файл существует, но это не видео: duration == 0 → обложки нет, исключения нет.
        try Data([0x00, 0x00]).write(to: clip)

        let cover = await ShortCoverGenerator().generateCover(for: ShortCoverRequest(
            clipURL: clip,
            trimStart: 10,
            trimEnd: 0,
            hook: "Хук",
            movieTitle: "Фильм",
            workingDirectory: working
        ))
        #expect(cover == nil)
        #expect(ShortCoverStore.existingCoverURL(
            clipURL: clip, movieTitle: "Фильм", workingDirectory: working) == nil)
    }
}
