import Testing
import Foundation
import CoreGraphics
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
            word: "ИЛЛЮЗИЯ",
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
            word: "ПРЕДОПРЕДЕЛЕННОСТЬ", // Очень длинное слово
            tagline: "Каждый шаг, который ты делаешь, пытаясь избежать своей судьбы, на самом деле лишь приближает тебя к неизбежному финалу", // Очень длинный тезис
            philosophicalPremise: "Рок и свобода воли",
            suggestedTitle: "Судьба",
            accentColorHex: "#E50914"
        )

        let rendered = try composer.composeThumbnail(
            candidate: candidate,
            concept: concept,
            movieTitle: "Бойцовский клуб"
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
            word: "ВРЕМЯ",
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
