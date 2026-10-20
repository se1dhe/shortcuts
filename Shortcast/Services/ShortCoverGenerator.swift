import AVFoundation
import AppKit
import CoreGraphics
import Foundation
import os
import QuartzCore
import UniformTypeIdentifiers
import Vision

// MARK: - Request

/// Всё, что нужно для обложки одного шортса: сам файл клипа, его границы и текст.
///
/// Отдельное значение, а не `ShortClip`: генератор остаётся `Sendable` и вызывается
/// из фонового рендера, а карточка клипа — `@MainActor`-observable.
struct ShortCoverRequest: Sendable, Equatable {
    /// Файл готового шортса — из него берётся кадр, поэтому обложка = сам клип, а не фильм.
    let clipURL: URL
    /// Начало интересующего участка внутри клипа (секунды, как ручной тримминг).
    var trimStart: Double = 0
    /// Конец участка; `<= 0` — до конца клипа.
    var trimEnd: Double = 0
    /// Ударная реплика в нижней трети. Пустая — строка просто не рисуется.
    var hook: String
    /// Название фильма для строки под логотипом.
    var movieTitle: String
    /// Рабочий каталог пользователя: обложка лежит в `Exports/<ФИЛЬМ>/shorts/`.
    var workingDirectory: URL? = nil

    init(clipURL: URL,
         trimStart: Double = 0,
         trimEnd: Double = 0,
         hook: String,
         movieTitle: String,
         workingDirectory: URL? = nil) {
        self.clipURL = clipURL
        self.trimStart = trimStart
        self.trimEnd = trimEnd
        self.hook = hook
        self.movieTitle = movieTitle
        self.workingDirectory = workingDirectory
    }
}

// MARK: - Protocol

/// Протокол генератора вертикальных обложек шортсов 9:16 (SOLID: ISP & DIP).
protocol ShortCoverGeneratingProtocol: Sendable {
    /// Собирает обложку 1080×1920 и пишет её рядом с клипом.
    /// НЕ бросает: обложка — отделка, шортс обязан выйти и без неё.
    /// `nil` = обложки нет, в логе ровно одно notice-сообщение.
    func generateCover(for request: ShortCoverRequest) async -> URL?

    /// Композиция кадра: face-центрированный кроп, кино-вуали, типографика, логотип поверх всего.
    func composeCover(
        baseImage: CGImage,
        hook: String,
        movieTitle: String,
        faceBox: CGRect?,
        canvas: CGSize
    ) throws -> CGImage

    /// Путь обложки по запросу и запись JPEG в него (тот же экспортёр, что у обложки эссе).
    func save(image: CGImage, for request: ShortCoverRequest) throws -> URL
}

// MARK: - Layout

/// Геометрия обложки шортса 9:16. Каждый слот — доля канваса, пиксельных констант
/// формата здесь нет: при 1080×1920 значения совпадают с эталоном, при любом другом
/// размере пропорции сохраняются.
///
/// Верх занят логотипом канала и строкой фильма, низ — хуком: середина остаётся
/// пустой, чтобы лицо из кропа не утонуло в тексте.
enum ShortCoverLayout {
    static let canvas = CGSize(width: 1080, height: 1920)

    /// Кино-вуаль сверху: 520 pt при эталонных 1920.
    static let topVeilScale: CGFloat = 520.0 / 1920.0
    /// Кино-вуаль снизу: 720 pt при эталонных 1920 — за ней живёт хук.
    static let bottomVeilScale: CGFloat = 720.0 / 1920.0
    /// Зазор между логотипом и строкой фильма: 23 pt.
    static let logoGapScale: CGFloat = 23.0 / 1920.0
    /// Боковые поля строки фильма: 40 pt при ширине 1080.
    static let sideInsetScale: CGFloat = 40.0 / 1080.0
    /// Боковые поля хука: 60 pt при ширине 1080.
    static let hookInsetScale: CGFloat = 60.0 / 1080.0
    /// Нижняя граница блока хука: 260 pt — нижняя треть кадра.
    static let hookBaseScale: CGFloat = 260.0 / 1920.0
    /// Потолок высоты хука: 355 pt. Выше он не поднимается никогда.
    static let hookMaxHeightScale: CGFloat = 355.0 / 1920.0
    /// Высота строки фильма: 40 pt.
    static let movieLineHeightScale: CGFloat = 40.0 / 1920.0
    /// Кегль строки фильма: 26 pt.
    static let moviePointScale: CGFloat = 26.0 / 1920.0
    /// Кегль хука: 58 pt, пол усадки — 44 pt.
    static let hookPointScale: CGFloat = 58.0 / 1920.0
    static let hookMinPointScale: CGFloat = 44.0 / 1920.0

    /// Лицо после кропа обязано остаться в этом вертикальном коридоре:
    /// ниже лезет интерфейс платформы, выше — логотип и название фильма.
    static let faceBand: ClosedRange<CGFloat> = 0.35...0.85
    /// Куда ставим центр лица при свободном вертикальном ходе кропа.
    static let faceTargetScale: CGFloat = 0.58

    static func logoRect(canvas: CGSize = ShortCoverLayout.canvas) -> CGRect {
        ChannelLogoPlacement.shortCover(canvas: canvas)
    }

    static func topVeil(canvas: CGSize) -> CGRect {
        let height = canvas.height * topVeilScale
        return CGRect(x: 0, y: canvas.height - height, width: canvas.width, height: height)
    }

    static func bottomVeil(canvas: CGSize) -> CGRect {
        CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height * bottomVeilScale)
    }

    /// Строка фильма — сразу под логотипом, с гарантированным зазором.
    static func movieLine(canvas: CGSize) -> CGRect {
        let height = canvas.height * movieLineHeightScale
        let logo = logoRect(canvas: canvas)
        return CGRect(
            x: canvas.width * sideInsetScale,
            y: logo.minY - canvas.height * logoGapScale - height,
            width: canvas.width - 2 * canvas.width * sideInsetScale,
            height: height
        )
    }

    static func hookRect(canvas: CGSize, height: CGFloat) -> CGRect {
        CGRect(
            x: canvas.width * hookInsetScale,
            y: canvas.height * hookBaseScale,
            width: canvas.width - 2 * canvas.width * hookInsetScale,
            height: height
        )
    }

    /// Все текстовые полосы сразу — и для отрисовки, и для теста на коллизию с логотипом.
    static func textSlots(canvas: CGSize, hookHeight: CGFloat) -> [CGRect] {
        [movieLine(canvas: canvas), hookRect(canvas: canvas, height: hookHeight)]
    }

    /// Худший случай: хук на весь разрешённый потолок. Им оперирует тест.
    static func worstCaseTextSlots(canvas: CGSize) -> [CGRect] {
        textSlots(canvas: canvas, hookHeight: hookMaxHeightScale * canvas.height)
    }
}

// MARK: - Framing

/// Результат face-центрированного кропа под 9:16: куда ложится кадр и куда после
/// трансформации уезжает прямоугольник лица (в координатах канваса, bottom-left origin).
struct ShortCoverCrop: Sendable, Equatable {
    let imageRect: CGRect
    let faceRect: CGRect?
}

/// Геометрия заполняющего кропа. Чистая функция без CoreGraphics-вызовов — чтобы
/// вертикальный коридор лица проверялся тестом, а не глазами.
enum ShortCoverFraming {
    /// Шаг перебора приблизительного зума: 1.0 … 1.6 с шагом 0.1.
    static let maxZoom: CGFloat = 1.6
    static let zoomStep: CGFloat = 0.1
    /// Насколько строго требуем запас от границ коридора при выборе зума.
    static let bandSafetyMargin: CGFloat = 0.015

    static func crop(
        sourceSize: CGSize,
        faceBox: CGRect?,
        canvas: CGSize = ShortCoverLayout.canvas,
        band: ClosedRange<CGFloat> = ShortCoverLayout.faceBand
    ) -> ShortCoverCrop {
        guard sourceSize.width > 0, sourceSize.height > 0 else {
            return ShortCoverCrop(imageRect: CGRect(origin: .zero, size: canvas), faceRect: nil)
        }

        let baseScale = max(canvas.width / sourceSize.width, canvas.height / sourceSize.height)

        // Без лица — классический aspect-fill по центру.
        guard let faceBox else {
            let drawW = sourceSize.width * baseScale
            let drawH = sourceSize.height * baseScale
            return ShortCoverCrop(
                imageRect: CGRect(x: (canvas.width - drawW) / 2.0, y: (canvas.height - drawH) / 2.0,
                                  width: drawW, height: drawH),
                faceRect: nil
            )
        }

        var best: (crop: ShortCoverCrop, penalty: CGFloat)?
        var zoom: CGFloat = 1.0
        while zoom <= maxZoom + 0.0001 {
            let candidate = place(sourceSize: sourceSize, faceBox: faceBox, canvas: canvas,
                                  scale: baseScale * zoom, band: band)
            if candidate.penalty == 0 { return candidate.crop }
            if best == nil || candidate.penalty < best!.penalty { best = candidate }
            zoom += zoomStep
        }
        // Лицо слишком крупное, чтобы влезть в коридор вообще: берём наименьшее нарушение.
        return best?.crop ?? ShortCoverCrop(
            imageRect: CGRect(origin: .zero, size: canvas),
            faceRect: nil
        )
    }

    private static func place(sourceSize: CGSize, faceBox: CGRect, canvas: CGSize,
                              scale: CGFloat, band: ClosedRange<CGFloat>) -> (crop: ShortCoverCrop, penalty: CGFloat) {
        let drawW = sourceSize.width * scale
        let drawH = sourceSize.height * scale

        let rawX = canvas.width / 2.0 - faceBox.midX * drawW
        let drawX = clamp(rawX, lower: min(0, canvas.width - drawW), upper: max(0, canvas.width - drawW))
        let rawY = canvas.height * ShortCoverLayout.faceTargetScale - faceBox.midY * drawH
        let drawY = clamp(rawY, lower: min(0, canvas.height - drawH), upper: max(0, canvas.height - drawH))

        let faceRect = CGRect(
            x: drawX + faceBox.minX * drawW,
            y: drawY + faceBox.minY * drawH,
            width: faceBox.width * drawW,
            height: faceBox.height * drawH
        )
        let penalty = violation(of: faceRect, canvas: canvas, band: band)
        return (ShortCoverCrop(
            imageRect: CGRect(x: drawX, y: drawY, width: drawW, height: drawH),
            faceRect: faceRect
        ), penalty)
    }

    /// 0, когда лицо целиком внутри коридора с запасом; иначе сумма выходов за границы.
    private static func violation(of rect: CGRect, canvas: CGSize, band: ClosedRange<CGFloat>) -> CGFloat {
        let lower = (band.lowerBound + bandSafetyMargin) * canvas.height
        let upper = (band.upperBound - bandSafetyMargin) * canvas.height
        let below = max(0, lower - rect.minY)
        let above = max(0, rect.maxY - upper)
        return below + above
    }

    private static func clamp(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        min(max(value, lower), upper)
    }

    /// Крупнейшее лицо в кадре через штатный `VNDetectFaceRectanglesRequest`.
    /// Тот же идиом, что у `LongformThumbnailCandidateSelector` и `VerticalReframer`:
    /// нормализованный `boundingBox` с началом координат внизу слева.
    nonisolated static func detectBestFace(in image: CGImage) -> CGRect? {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil,
              let faces = request.results, !faces.isEmpty else { return nil }
        return faces.max { a, b in
            (a.boundingBox.width * a.boundingBox.height) < (b.boundingBox.width * b.boundingBox.height)
        }?.boundingBox
    }
}

// MARK: - Store

/// Где живёт обложка шортса: `Exports/<ФИЛЬМ>/shorts/cover_<основа клипа>.jpg`.
///
/// Имя детерминировано по файлу клипа и пишется всегда в одно и то же место, поэтому
/// публикация и плитка находят обложку по `clipURL`, без поля в модели.
/// `ExportLayout.artifact(unique: false)` для этого не годится: при существующем файле
/// он выдает имя с суффиксом `-2`, и поиск по клипу молча промахивается.
enum ShortCoverStore {
    static func coverFileName(clipURL: URL) -> String {
        let stem = clipURL.deletingPathExtension().lastPathComponent
        return "\(ExportLayout.Kind.shortCover.rawValue)_\(ExportLayout.fileNameBase(from: stem)).jpg"
    }

    /// Каталог под обложку БЕЗ создания на диске — читатель (вьюха) не должен плодить папки.
    static func directory(movieTitle: String, workingDirectory: URL?) -> URL {
        let root = workingDirectory
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("ShortcastExports", isDirectory: true)
        return root
            .appendingPathComponent(ExportLayout.rootDirName, isDirectory: true)
            .appendingPathComponent(ExportLayout.directoryName(for: movieTitle), isDirectory: true)
            .appendingPathComponent(ExportLayout.shortsDirName, isDirectory: true)
    }

    /// То же место, но с созданием каталога — для пишущей стороны.
    static func makeDirectory(movieTitle: String, workingDirectory: URL?) throws -> URL {
        let film = try ExportLayout.filmDirectory(workingDirectory: workingDirectory, movieTitle: movieTitle)
        return try ExportLayout.shortsDirectory(in: film)
    }

    static func coverURL(clipURL: URL, movieTitle: String, workingDirectory: URL?) -> URL {
        directory(movieTitle: movieTitle, workingDirectory: workingDirectory)
            .appendingPathComponent(coverFileName(clipURL: clipURL))
    }

    static func existingCoverURL(clipURL: URL, movieTitle: String, workingDirectory: URL?) -> URL? {
        let url = coverURL(clipURL: clipURL, movieTitle: movieTitle, workingDirectory: workingDirectory)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

// MARK: - Generator

/// Генератор обложек шортсов 9:16 (SOLID: Facade & DIP).
///
/// Кадр берётся из самого клипа через `LongformThumbnailCandidateSelector` (Vision-скоринг
/// лиц и яркости), композиция — своя, вертикальная, запись — тем же JPEG-экспортёром,
/// что и у обложки эссе. Никаких констант формата: вся геометрия в `ShortCoverLayout`.
final class ShortCoverGenerator: ShortCoverGeneratingProtocol, Sendable {

    private static let logger = Logger(subsystem: "app.shortcast", category: "ShortCoverGenerator")

    private let candidateSelector: LongformThumbnailCandidateSelector
    private let exporter: LongformThumbnailExporter

    init(
        candidateSelector: LongformThumbnailCandidateSelector = LongformThumbnailCandidateSelector(),
        exporter: LongformThumbnailExporter = LongformThumbnailExporter()
    ) {
        self.candidateSelector = candidateSelector
        self.exporter = exporter
    }

    /// Точка входа для пайплайна. Ошибки не бросает: нет обложки — пусть платформа
    /// возьмёт первый кадр, но шортс обязан уйти на экспорт.
    func generateCover(for request: ShortCoverRequest) async -> URL? {
        do {
            let asset = AVURLAsset(url: request.clipURL)
            let duration = CMTimeGetSeconds(asset.duration)
            let segment = try trimSegment(of: request, duration: duration)

            let candidate = try await candidateSelector.selectBestCandidate(
                sourceAsset: asset,
                segments: [segment],
                renderSize: ShortCoverLayout.canvas
            )
            let image = try composeCover(
                baseImage: candidate.image,
                hook: request.hook,
                movieTitle: request.movieTitle,
                faceBox: candidate.faceBox,
                canvas: ShortCoverLayout.canvas
            )
            return try save(image: image, for: request)
        } catch {
            Self.logger.notice(
                "short cover skipped for '\(request.clipURL.lastPathComponent, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    func composeCover(
        baseImage: CGImage,
        hook: String,
        movieTitle: String,
        faceBox: CGRect? = nil,
        canvas: CGSize = ShortCoverLayout.canvas
    ) throws -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let context = CGContext(
            data: nil,
            width: Int(canvas.width),
            height: Int(canvas.height),
            bitsPerComponent: 8,
            bytesPerRow: Int(canvas.width) * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw MediaExtractorError.clipExportFailed("Failed to create CGContext for 9:16 cover")
        }

        // 1. Чёрная база: до кропа кадр может не докрывать канвас.
        context.setFillColor(CGColor(gray: 0.0, alpha: 1.0))
        context.fill(CGRect(origin: .zero, size: canvas))

        // 2. Face-центрированный aspect-fill.
        let resolvedFace = faceBox ?? ShortCoverFraming.detectBestFace(in: baseImage)
        let crop = ShortCoverFraming.crop(
            sourceSize: CGSize(width: baseImage.width, height: baseImage.height),
            faceBox: resolvedFace,
            canvas: canvas
        )
        context.interpolationQuality = .high
        context.draw(baseImage, in: crop.imageRect)

        // 3. Кино-вуали сверху и снизу: на них ложится и логотип, и текст.
        drawVeils(in: context, colorSpace: colorSpace, canvas: canvas)

        // 4. Типографика: строка фильма под логотипом и хук в нижней трети.
        drawTypography(in: context, canvas: canvas, hook: hook, movieTitle: movieTitle)

        // 5. Логотип канала — последним слоем.
        ChannelLogo.composite(in: context, rect: ShortCoverLayout.logoRect(canvas: canvas))

        guard let image = context.makeImage() else {
            throw MediaExtractorError.clipExportFailed("Failed to render 9:16 cover CGImage")
        }
        return image
    }

    func save(image: CGImage, for request: ShortCoverRequest) throws -> URL {
        // Каталог через ExportLayout, имя — через ShortCoverStore: один источник истины
        // и для записи, и для поиска обложки по файлу клипа.
        _ = try ShortCoverStore.makeDirectory(
            movieTitle: request.movieTitle,
            workingDirectory: request.workingDirectory
        )
        let outputURL = ShortCoverStore.coverURL(
            clipURL: request.clipURL,
            movieTitle: request.movieTitle,
            workingDirectory: request.workingDirectory
        )
        return try exporter.export(image: image, to: outputURL, quality: 0.92)
    }

    // MARK: - Private

    /// Участок клипа, из которого берётся кадр. `trimEnd <= 0` — до конца файла.
    private func trimSegment(of request: ShortCoverRequest, duration: Double) throws -> TimeSegment {
        let usable = duration.isFinite && duration > 0 ? duration : 0
        guard usable > 0 else {
            throw MediaExtractorError.clipExportFailed("Clip '\(request.clipURL.lastPathComponent)' has no readable duration")
        }
        let end = request.trimEnd > 0 ? min(request.trimEnd, usable) : usable
        let start = min(max(0, request.trimStart), max(0, end - 0.1))
        guard end > start else {
            throw MediaExtractorError.clipExportFailed("Trim range \(start)…\(end) is empty")
        }
        return TimeSegment(start: start, end: end)
    }

    private func drawVeils(in context: CGContext, colorSpace: CGColorSpace, canvas: CGSize) {
        let colors = [
            CGColor(gray: 0.0, alpha: 0.88),
            CGColor(gray: 0.0, alpha: 0.40),
            CGColor(gray: 0.0, alpha: 0.0)
        ] as CFArray
        guard let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0.0, 0.5, 1.0]) else {
            return
        }
        let top = ShortCoverLayout.topVeil(canvas: canvas)
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: canvas.width / 2.0, y: top.maxY),
            end: CGPoint(x: canvas.width / 2.0, y: top.minY),
            options: []
        )
        let bottom = ShortCoverLayout.bottomVeil(canvas: canvas)
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: canvas.width / 2.0, y: bottom.minY),
            end: CGPoint(x: canvas.width / 2.0, y: bottom.maxY),
            options: []
        )
    }

    private func drawTypography(in context: CGContext, canvas: CGSize, hook: String, movieTitle: String) {
        let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsContext

        let accentColor = NSColor(calibratedRed: 1.0, green: 0.89, blue: 0.36, alpha: 1.0)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.96)
        shadow.shadowBlurRadius = 16.0
        shadow.shadowOffset = NSSize(width: 0, height: -3.0)

        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        centered.lineBreakMode = .byWordWrapping
        centered.lineSpacing = 8.0

        // 1. Название фильма под логотипом.
        let cleanTitle = ShortCoverText.clean(movieTitle).uppercased()
        if !cleanTitle.isEmpty {
            let movieAttrs: [NSAttributedString.Key: Any] = [
                .font: SubtitleRenderer.resolveFont(name: "RussoOne-Regular",
                                                    size: canvas.height * ShortCoverLayout.moviePointScale,
                                                    fallback: .bold),
                .foregroundColor: accentColor,
                .shadow: shadow,
                .paragraphStyle: centered,
                .kern: 3.5
            ]
            NSAttributedString(string: "«\(cleanTitle)»", attributes: movieAttrs)
                .draw(in: ShortCoverLayout.movieLine(canvas: canvas))
        }

        // 2. Хук в нижней трети: усаживаем кегль, при необходимости режем по словам.
        let cleanHook = ShortCoverText.clean(hook).uppercased()
        if !cleanHook.isEmpty {
            let boxWidth = ShortCoverLayout.hookRect(canvas: canvas, height: 1).width
            if let laidOut = ShortCoverText.laidOutHook(
                cleanHook,
                canvas: canvas,
                boxWidth: boxWidth,
                paragraphStyle: centered,
                shadow: shadow
            ) {
                NSAttributedString(string: laidOut.text, attributes: laidOut.attributes)
                    .draw(in: ShortCoverLayout.hookRect(canvas: canvas, height: laidOut.height))
            }
        }

        NSGraphicsContext.restoreGraphicsState()
    }
}

/// Текстовая часть обложки шортса: очистка от разметки и подбор кегля под потолок блока.
enum ShortCoverText {
    /// Хук приходит из генератора копипасты — иногда с тегами и переносами.
    static func clean(_ raw: String) -> String {
        raw.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func hookAttributes(_ text: String, pointSize: CGFloat, paragraphStyle: NSParagraphStyle,
                              shadow: NSShadow) -> [NSAttributedString.Key: Any] {
        [
            .font: SubtitleRenderer.resolveFont(name: "RussoOne-Regular", size: pointSize, fallback: .heavy),
            .foregroundColor: NSColor.white,
            .strokeColor: NSColor.black,
            .strokeWidth: -3.5,
            .shadow: shadow,
            .paragraphStyle: paragraphStyle,
            .kern: 2.0
        ]
    }

    /// Раскладка хука: кегль усаживается от эталонного к полу, а если и на полу текст
    /// не влезает в потолок блока — отсекаем целые слова с хвоста и ставим многоточие.
    /// Так нижняя треть гарантированно остаётся нижней третью и никогда не дорастает до логотипа.
    /// `nil` — текст не влезает даже порезанным: строку не рисуем вовсе, а не превращаем
    /// обложку в кашу и не толкаем её в сторону знака.
    static func laidOutHook(_ rawText: String, canvas: CGSize, boxWidth: CGFloat,
                            paragraphStyle: NSParagraphStyle, shadow: NSShadow)
        -> (text: String, attributes: [NSAttributedString.Key: Any], height: CGFloat)? {
        let maxHeight = canvas.height * ShortCoverLayout.hookMaxHeightScale
        let minSize = canvas.height * ShortCoverLayout.hookMinPointScale
        var pointSize = canvas.height * ShortCoverLayout.hookPointScale
        var text = rawText
        var attributes = hookAttributes(text, pointSize: pointSize, paragraphStyle: paragraphStyle, shadow: shadow)
        var measured = measure(text, attributes: attributes, boxWidth: boxWidth)

        // 1. Пробуем вписаться кеглем.
        var shrinkSteps = 0
        while measured.height > maxHeight, pointSize > minSize, shrinkSteps < 4 {
            let next = max(minSize, floor(pointSize * (maxHeight / measured.height) * 0.98))
            if next >= pointSize { break }
            pointSize = next
            attributes = hookAttributes(text, pointSize: pointSize, paragraphStyle: paragraphStyle, shadow: shadow)
            measured = measure(text, attributes: attributes, boxWidth: boxWidth)
            shrinkSteps += 1
        }

        // 2. Пол кегля достигнут, а текста всё больше, чем влезает: режем по словам.
        var words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        var trimmed = 0
        while measured.height > maxHeight, words.count > 2, trimmed < 60 {
            words.removeLast()
            text = words.joined(separator: " ") + "…"
            attributes = hookAttributes(text, pointSize: pointSize, paragraphStyle: paragraphStyle, shadow: shadow)
            measured = measure(text, attributes: attributes, boxWidth: boxWidth)
            trimmed += 1
        }

        guard measured.height <= maxHeight else { return nil }
        let floorHeight = canvas.height * ShortCoverLayout.movieLineHeightScale
        return (text, attributes, min(max(measured.height + 20.0, floorHeight), maxHeight))
    }

    private static func measure(_ text: String, attributes: [NSAttributedString.Key: Any], boxWidth: CGFloat) -> CGRect {
        NSAttributedString(string: text, attributes: attributes).boundingRect(
            with: CGSize(width: boxWidth, height: 10_000),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
    }
}
