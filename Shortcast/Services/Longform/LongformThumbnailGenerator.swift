import AVFoundation
import AppKit
import CoreGraphics
import UniformTypeIdentifiers
import Vision

/// Генератор обложек «Кадр & Сенс» с подтверждением главного героя.
protocol LongformThumbnailGeneratingProtocol: Sendable {
    func generateThumbnail(
        sourceAsset: AVURLAsset,
        segments: [TimeSegment],
        concept: ThematicConcept,
        movieTitle: String,
        outputURL: URL
    ) async throws -> URL
    func generateReviewedThumbnail(sourceAsset: AVURLAsset, segments: [TimeSegment],
        concept: ThematicConcept, movieTitle: String, outputURL: URL) async throws -> ReviewedThumbnail
    func generateAlternativeReviewedThumbnail(sourceAsset: AVURLAsset, segments: [TimeSegment],
        concept: ThematicConcept, movieTitle: String, outputURL: URL,
        avoidingTimes: [Double]) async throws -> ReviewedThumbnail
}

extension LongformThumbnailGeneratingProtocol {
    func generateReviewedThumbnail(sourceAsset: AVURLAsset, segments: [TimeSegment],
        concept: ThematicConcept, movieTitle: String, outputURL: URL) async throws -> ReviewedThumbnail {
        let url = try await generateThumbnail(sourceAsset: sourceAsset, segments: segments,
            concept: concept, movieTitle: movieTitle, outputURL: outputURL)
        return ReviewedThumbnail(url: url, subject: nil)
    }

    func generateAlternativeReviewedThumbnail(sourceAsset: AVURLAsset, segments: [TimeSegment],
        concept: ThematicConcept, movieTitle: String, outputURL: URL,
        avoidingTimes: [Double]) async throws -> ReviewedThumbnail {
        try await generateReviewedThumbnail(sourceAsset: sourceAsset, segments: segments,
            concept: concept, movieTitle: movieTitle, outputURL: outputURL)
    }
}

/// Модель оцененного кандидата кадра для обложки
struct ThumbnailCandidateFrame: Sendable {
    let time: Double
    let image: CGImage
    let faceBox: CGRect?
    let score: Double
    let averageLuminance: Double
    var faceCount: Int = 1
}

/// Компоновка обложки в зависимости от положения ключевого объекта
enum ThumbnailLayoutMode: Sendable {
    /// Главный герой справа (правило третей), текст слева с горизонтальным кино-градиентом
    case leftTextRightFace
    /// Главный герой слева, текст справа с градиентом справа
    case rightTextLeftFace
    /// Лицо не найдено или по центру: текст снизу с глубоким нижним градиентом
    case centerBottomFallback
}

/// Геометрия текстовых полос обложки эссе и полос кино-виньетки.
///
/// Все координаты — доли канваса (эталон 1920×1080), а не пиксели формата: обложка
/// остаётся самой собой при любом размере рендера. Это единственный источник истины:
/// его рисует `LongformThumbnailComposer` и его же проверяет тест на коллизию с
/// логотипом канала, поэтому тест не может разойтись с отрисовкой.
struct LongformCoverTextSlots: Sendable, Equatable {
    /// Название бренда.
    let badge: CGRect
    /// Смысловой заголовок эссе.
    let themeWord: CGRect
    /// Золотая разделительная черта
    let rule: CGRect
    /// Название фильма.
    let hook: CGRect

    /// Верхняя виньетка: эталон 200 pt при 1080 строках.
    static let topVignetteScale: CGFloat = 200.0 / 1080.0
    /// Нижняя виньетка: эталон 220 pt при 1080 строках.
    static let bottomVignetteScale: CGFloat = 220.0 / 1080.0
    /// Худший случай высоты блока хука: измерение ограничено 300 pt + 20 pt запаса.
    static let hookMaxHeightScale: CGFloat = 320.0 / 1080.0

    var all: [CGRect] { [badge, themeWord, rule, hook] }
    var highestTextY: CGFloat { all.map(\.maxY).max() ?? 0 }

    static func topVignette(canvas: CGSize) -> CGRect {
        let height = canvas.height * topVignetteScale
        return CGRect(x: 0, y: canvas.height - height, width: canvas.width, height: height)
    }

    static func bottomVignette(canvas: CGSize) -> CGRect {
        CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height * bottomVignetteScale)
    }

    static func make(layoutMode: ThumbnailLayoutMode, canvas: CGSize, hookHeight: CGFloat) -> LongformCoverTextSlots {
        let k = canvas.height / 1080
        let x = canvas.width * 0.05, width = canvas.width * 0.43
        return LongformCoverTextSlots(
            badge: CGRect(x: x, y: 930 * k, width: width, height: 44 * k),
            themeWord: CGRect(x: x, y: 440 * k, width: width, height: 440 * k),
            rule: CGRect(x: x, y: 390 * k, width: 140 * k, height: 3 * k),
            hook: CGRect(x: x, y: 150 * k, width: width, height: min(hookHeight, 190 * k)))
    }

    /// Полосы при максимально допустимом блоке хука — то, чем оперирует тест на коллизию.
    static func worstCase(layoutMode: ThumbnailLayoutMode, canvas: CGSize) -> LongformCoverTextSlots {
        make(layoutMode: layoutMode, canvas: canvas, hookHeight: hookMaxHeightScale * canvas.height)
    }
}

/// Сервис умного подбора и скоринга кадров через Apple Vision (SOLID: Single Responsibility)
final class LongformThumbnailCandidateSelector: Sendable {

    func selectBestCandidate(sourceAsset: AVURLAsset, segments: [TimeSegment],
                             renderSize: CGSize = CGSize(width: 1920, height: 1080)) async throws -> ThumbnailCandidateFrame {
        guard let first = try await rankedCandidates(sourceAsset: sourceAsset, segments: segments).first else {
            throw ThumbnailSelectionError.noVerifiedLead
        }
        return first
    }

    func rankedCandidates(sourceAsset: AVURLAsset, segments: [TimeSegment]) async throws -> [ThumbnailCandidateFrame] {
        let duration = CMTimeGetSeconds(try await sourceAsset.load(.duration))
        let times = Self.candidateTimestamps(segments: segments, duration: duration)
        let generator = AVAssetImageGenerator(asset: sourceAsset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 960, height: 540)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.3, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.3, preferredTimescale: 600)
        var candidates: [ThumbnailCandidateFrame] = []
        for time in times {
            try Task.checkCancellation()
            guard let (image, actualTime) = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)) else { continue }
            let luminance = calculateAverageLuminance(of: image)
            guard (0.08...0.88).contains(luminance) else { continue }
            let (face, count) = detectFaces(in: image)
            guard count == 1, let face, face.width * face.height >= 0.015 else { continue }
            let score = scoreCandidate(time: time, luminance: luminance, bestFaceBox: face,
                                       faceCount: count, candidateTimes: times)
            candidates.append(ThumbnailCandidateFrame(time: CMTimeGetSeconds(actualTime), image: image,
                faceBox: face, score: score, averageLuminance: luminance, faceCount: count))
        }
        var diverse: [ThumbnailCandidateFrame] = []
        for candidate in candidates.sorted(by: { $0.score > $1.score }) {
            if diverse.allSatisfy({ abs($0.time - candidate.time) >= 8 }) { diverse.append(candidate) }
            if diverse.count == 24 { break }
        }
        DirectorRunLog.write("cover candidates: sampled=\(times.count) clearPortraits=\(candidates.count) diverse=\(diverse.count)")
        return diverse
    }

    static func candidateTimestamps(segments: [TimeSegment], duration: Double) -> [Double] {
        guard duration.isFinite, duration > 1 else { return [] }
        var times = segments.filter { $0.start.isFinite && $0.end.isFinite && $0.end > $0.start }.flatMap { scene in
            [0.25, 0.5, 0.75].map { scene.start + scene.duration * $0 }
        }
        // Герой может не попасть в 16 кадров монтажа: проверяем также весь фильм.
        times += (0..<40).map { duration * (0.03 + Double($0) / 40 * 0.89) }
        let valid = Array(Set(times.filter { $0 >= 0 && $0 < duration })).sorted()
        guard valid.count > 96 else { return valid }
        return (0..<96).map { valid[min(valid.count - 1, Int(Double($0) * Double(valid.count - 1) / 95))] }
    }

    /// Детекция лиц через Apple Vision Framework
    private func detectFaces(in cgImage: CGImage) -> (bestFaceBox: CGRect?, faceCount: Int) {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])

        let faces = request.results ?? []
        guard !faces.isEmpty else { return (nil, 0) }

        var bestFace: VNFaceObservation? = nil
        var maxArea: CGFloat = 0.0

        for f in faces {
            let area = f.boundingBox.width * f.boundingBox.height
            if area > maxArea {
                maxArea = area
                bestFace = f
            }
        }

        return (bestFace?.boundingBox, faces.count)
    }

    /// Оценка кадра для кинематографической обложки YouTube
    private func scoreCandidate(
        time: Double,
        luminance: Double,
        bestFaceBox: CGRect?,
        faceCount: Int,
        candidateTimes: [Double]
    ) -> Double {
        var score: Double = 0.0

        // 1. Оценка лица
        if let box = bestFaceBox {
            let area = box.width * box.height
            // Идеальный портретный план для обложки (крупный или поясной план героя)
            if area >= 0.035 && area <= 0.40 {
                score += 550.0
            } else if area > 0.40 && area <= 0.65 {
                score += 400.0 // Сверхкрупный драматический план
            } else if area > 0.015 {
                score += 200.0 // Средний общий план
            }

            // Композиция по правилу третей (лицо сбоку идеально оставляет место для гигантского текста)
            let midX = box.midX
            if midX >= 0.42 && midX <= 0.85 {
                score += 350.0 // Идеально: лицо справа, текст слева (стандарт чтения слева направо)
            } else if midX >= 0.15 && midX < 0.42 {
                score += 250.0 // Лицо слева, текст справа
            } else {
                score += 150.0 // Лицо по центру
            }

            // Одиночный портрет главного героя предпочтительнее массовки
            if faceCount == 1 {
                score += 120.0
            } else if faceCount == 2 {
                score += 50.0
            }
        }

        // 2. Оценка яркости и контраста (избегаем слишком темных или пересвеченных кадров)
        if luminance >= 0.15 && luminance <= 0.65 {
            score += 100.0 // Оптимальный кинематографический контраст
        } else if luminance < 0.08 {
            score -= 600.0 // Слишком темный кадр
        } else if luminance > 0.85 {
            score -= 300.0 // Пересвеченный кадр
        }

        // 3. Бонус кульминации (кадры из эмоциональной середины и финала обычно выразительнее экспозиции)
        if let minTime = candidateTimes.min(), let maxTime = candidateTimes.max(), maxTime > minTime {
            let relativePos = (time - minTime) / (maxTime - minTime)
            if relativePos >= 0.35 && relativePos <= 0.85 {
                score += 80.0
            }
        }

        return score
    }

    /// Быстрый расчет средней яркости кадра через дискретный 16x16 сэмпл
    private func calculateAverageLuminance(of image: CGImage) -> Double {
        let sampleSize = 16
        var pixelData = [UInt8](repeating: 0, count: sampleSize * sampleSize * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        
        guard let ctx = CGContext(
            data: &pixelData,
            width: sampleSize,
            height: sampleSize,
            bitsPerComponent: 8,
            bytesPerRow: sampleSize * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return 0.3
        }

        ctx.draw(image, in: CGRect(x: 0, y: 0, width: sampleSize, height: sampleSize))

        var totalLum: Double = 0.0
        let totalCount = Double(sampleSize * sampleSize)
        for i in stride(from: 0, to: pixelData.count, by: 4) {
            let r = Double(pixelData[i]) / 255.0
            let g = Double(pixelData[i + 1]) / 255.0
            let b = Double(pixelData[i + 2]) / 255.0
            // Формула яркости Rec. 709
            let lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
            totalLum += lum
        }

        return totalLum / totalCount
    }
}

/// Сервис компоновки, кино-грейдинга и монументальной типографики обложки (SOLID: Single Responsibility)
final class LongformThumbnailComposer: Sendable {
    private static let obsidian = NSColor(srgbRed: 8/255, green: 9/255, blue: 12/255, alpha: 1)
    private static let gold = NSColor(srgbRed: 212/255, green: 175/255, blue: 55/255, alpha: 1)
    private static let ivory = NSColor(srgbRed: 250/255, green: 247/255, blue: 242/255, alpha: 1)

    /// Фокус изображения задаёт подтверждённое лицо; текст всегда остаётся на чистом тёмном поле.
    static func imageRect(imageSize: CGSize, faceBox: CGRect?, canvas: CGSize) -> CGRect {
        let pane = CGRect(x: canvas.width * 0.38, y: 0, width: canvas.width * 0.62, height: canvas.height)
        let scale = max(pane.width / imageSize.width, pane.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let face = faceBox ?? CGRect(x: 0.4, y: 0.25, width: 0.2, height: 0.4)
        let desiredX = canvas.width * 0.74 - face.midX * size.width
        let desiredY = canvas.height * 0.53 - face.midY * size.height
        return CGRect(x: min(pane.minX, max(pane.maxX - size.width, desiredX)),
                      y: min(pane.minY, max(pane.maxY - size.height, desiredY)), width: size.width, height: size.height)
    }

    func composeThumbnail(candidate: ThumbnailCandidateFrame, concept: ThematicConcept, movieTitle: String,
                          renderSize: CGSize = CGSize(width: 1920, height: 1080)) throws -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: Int(renderSize.width), height: Int(renderSize.height),
            bitsPerComponent: 8, bytesPerRow: Int(renderSize.width) * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ThumbnailSelectionError.noVerifiedLead
        }
        let bounds = CGRect(origin: .zero, size: renderSize), k = renderSize.height / 1080
        context.setFillColor(Self.obsidian.cgColor); context.fill(bounds)
        context.saveGState()
        context.clip(to: CGRect(x: renderSize.width * 0.38, y: 0, width: renderSize.width * 0.62, height: renderSize.height))
        let imageRect = Self.imageRect(imageSize: CGSize(width: candidate.image.width, height: candidate.image.height),
                                      faceBox: candidate.faceBox, canvas: renderSize)
        context.interpolationQuality = .high
        context.draw(candidate.image, in: imageRect)
        context.restoreGState()
        if let gradient = CGGradient(colorsSpace: space, colors: [Self.obsidian.cgColor,
            Self.obsidian.withAlphaComponent(0.96).cgColor, Self.obsidian.withAlphaComponent(0).cgColor] as CFArray,
            locations: [0, 0.38, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: renderSize.width * 0.27, y: 0),
                end: CGPoint(x: renderSize.width * 0.65, y: 0), options: [.drawsBeforeStartLocation])
        }
        if let shade = CGGradient(colorsSpace: space,
            colors: [Self.obsidian.withAlphaComponent(0.72).cgColor, Self.obsidian.withAlphaComponent(0).cgColor] as CFArray,
            locations: [0, 1]) {
            context.drawLinearGradient(shade, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: renderSize.height * 0.26), options: [])
            context.drawLinearGradient(shade, start: CGPoint(x: 0, y: renderSize.height),
                end: CGPoint(x: 0, y: renderSize.height * 0.83), options: [])
        }
        drawViewfinder(in: context, canvas: renderSize)
        let layout = LongformCoverTextSlots.make(layoutMode: .leftTextRightFace, canvas: renderSize, hookHeight: 190 * k)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        defer { NSGraphicsContext.current = previous }
        let brand = NSMutableAttributedString(string: "КАДР & СЕНС", attributes: [
            .font: serif(30 * k), .foregroundColor: Self.ivory, .kern: 4 * k])
        brand.addAttribute(.foregroundColor, value: Self.gold, range: NSRange(location: 5, length: 1))
        brand.draw(in: layout.badge)
        let heading = concept.suggestedTitle.trimmed.isEmpty ? concept.word : concept.suggestedTitle
        drawFitted(heading.uppercased(), in: layout.themeWord, maxSize: 108 * k, minSize: 54 * k,
                   color: Self.ivory, serif: true, tracking: 0)
        context.setFillColor(Self.gold.cgColor); context.fill(layout.rule)
        drawFitted(movieTitle.uppercased(), in: layout.hook, maxSize: 48 * k, minSize: 28 * k,
                   color: Self.gold, serif: false, tracking: 2 * k)
        ("УКРАЇНСЬКЕ КІНОЕСЕ" as NSString).draw(at: CGPoint(x: layout.badge.minX, y: 82 * k),
            withAttributes: [.font: NSFont.systemFont(ofSize: 22 * k, weight: .medium),
                             .foregroundColor: Self.ivory.withAlphaComponent(0.7), .kern: 3 * k])
        if let image = NSImage(named: "EssayCoverBrandMark") {
            var rect = NSRect(origin: .zero, size: image.size)
            if let mark = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
                context.draw(mark, in: ChannelLogoPlacement.essayCover(canvas: renderSize, inset: 48 * k))
            }
        }
        guard let image = context.makeImage() else { throw ThumbnailSelectionError.noVerifiedLead }
        return image
    }

    private func serif(_ size: CGFloat) -> NSFont {
        NSFont(name: "Georgia-Bold", size: size) ?? NSFont.systemFont(ofSize: size, weight: .bold)
    }
    private func drawFitted(_ text: String, in rect: CGRect, maxSize: CGFloat, minSize: CGFloat,
                            color: NSColor, serif useSerif: Bool, tracking: CGFloat) {
        var size = maxSize
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = maxSize * 0.04
        var attributed = NSAttributedString()
        var measured = CGRect.zero
        repeat {
            let font = useSerif ? serif(size) : (NSFont(name: "AvenirNext-DemiBold", size: size) ?? NSFont.boldSystemFont(ofSize: size))
            attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color,
                .paragraphStyle: paragraph, .kern: tracking])
            measured = attributed.boundingRect(with: CGSize(width: rect.width, height: 4000),
                options: [.usesLineFragmentOrigin, .usesFontLeading])
            if measured.height <= rect.height && measured.width <= rect.width + 1 { break }
            size -= 2
        } while size >= minSize
        // Верхний край фиксирован: разные длины названия не сдвигают название фильма.
        attributed.draw(with: CGRect(x: rect.minX, y: rect.maxY - min(rect.height, ceil(measured.height)),
            width: rect.width, height: min(rect.height, ceil(measured.height) + 2)),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
    }
    private func drawViewfinder(in context: CGContext, canvas: CGSize) {
        let k = canvas.height / 1080, inset = 34 * k, length = 34 * k
        context.setStrokeColor(Self.gold.withAlphaComponent(0.65).cgColor); context.setLineWidth(2 * k)
        for point in [CGPoint(x: inset, y: inset), CGPoint(x: canvas.width - inset, y: inset),
                      CGPoint(x: inset, y: canvas.height - inset), CGPoint(x: canvas.width - inset, y: canvas.height - inset)] {
            let dx: CGFloat = point.x < canvas.width / 2 ? 1 : -1
            let dy: CGFloat = point.y < canvas.height / 2 ? 1 : -1
            context.strokeLineSegments(between: [CGPoint(x: point.x, y: point.y + dy * length), point,
                                                point, CGPoint(x: point.x + dx * length, y: point.y)])
        }
    }
}

/// Сервис экспорта изображения в высококачественный JPEG (SOLID: Single Responsibility)
final class LongformThumbnailExporter: Sendable {

    func export(image: CGImage, to outputURL: URL, quality: CGFloat = 0.94) throws -> URL {
        try? FileManager.default.removeItem(at: outputURL)

        guard let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw NSError(domain: "ThumbnailExporter", code: -3, userInfo: [NSLocalizedDescriptionKey: "Не удалось создать целевой файл JPEG."])
        }

        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "ThumbnailExporter", code: -4, userInfo: [NSLocalizedDescriptionKey: "Не удалось записать обложку на диск."])
        }

        return outputURL
    }
}

/// Проверка героя, композиция по бренду и экспорт обложки 1080p.
final class LongformThumbnailGenerator: LongformThumbnailGeneratingProtocol, Sendable {

    private let candidateSelector: LongformThumbnailCandidateSelector
    private let composer: LongformThumbnailComposer
    private let exporter: LongformThumbnailExporter
    private let verifier: ThumbnailSubjectVerifier?

    init(candidateSelector: LongformThumbnailCandidateSelector = LongformThumbnailCandidateSelector(),
         composer: LongformThumbnailComposer = LongformThumbnailComposer(),
         exporter: LongformThumbnailExporter = LongformThumbnailExporter(),
         verifier: ThumbnailSubjectVerifier? = nil) {
        self.candidateSelector = candidateSelector; self.composer = composer
        self.exporter = exporter; self.verifier = verifier
    }

    func generateThumbnail(sourceAsset: AVURLAsset, segments: [TimeSegment], concept: ThematicConcept,
                           movieTitle: String, outputURL: URL) async throws -> URL {
        try await generateReviewedThumbnail(sourceAsset: sourceAsset, segments: segments, concept: concept,
                                             movieTitle: movieTitle, outputURL: outputURL).url
    }

    func generateReviewedThumbnail(sourceAsset: AVURLAsset, segments: [TimeSegment], concept: ThematicConcept,
                                   movieTitle: String, outputURL: URL) async throws -> ReviewedThumbnail {
        try await generateReviewedThumbnail(sourceAsset: sourceAsset, segments: segments,
            concept: concept, movieTitle: movieTitle, outputURL: outputURL, avoidingTimes: [])
    }

    func generateAlternativeReviewedThumbnail(sourceAsset: AVURLAsset, segments: [TimeSegment], concept: ThematicConcept,
        movieTitle: String, outputURL: URL, avoidingTimes: [Double]) async throws -> ReviewedThumbnail {
        try await generateReviewedThumbnail(sourceAsset: sourceAsset, segments: segments,
            concept: concept, movieTitle: movieTitle, outputURL: outputURL, avoidingTimes: avoidingTimes)
    }

    private func generateReviewedThumbnail(sourceAsset: AVURLAsset, segments: [TimeSegment], concept: ThematicConcept,
        movieTitle: String, outputURL: URL, avoidingTimes: [Double]) async throws -> ReviewedThumbnail {
        guard let verifier else { throw ThumbnailSelectionError.visionUnavailable }
        let candidates = try await candidateSelector.rankedCandidates(sourceAsset: sourceAsset, segments: segments)
        var (candidate, evidence) = try await verifier.select(
            from: candidates, movieTitle: movieTitle, avoidingTimes: avoidingTimes)
        let full = AVAssetImageGenerator(asset: sourceAsset)
        full.appliesPreferredTrackTransform = true
        full.maximumSize = CGSize(width: 1920, height: 1080)
        full.requestedTimeToleranceBefore = .zero; full.requestedTimeToleranceAfter = .zero
        let (image, _) = try await full.image(at: CMTime(seconds: candidate.time, preferredTimescale: 600))
        candidate = ThumbnailCandidateFrame(time: candidate.time, image: image, faceBox: candidate.faceBox,
            score: candidate.score, averageLuminance: candidate.averageLuminance, faceCount: candidate.faceCount)
        let composed = try composer.composeThumbnail(candidate: candidate, concept: concept, movieTitle: movieTitle)
        let url = try exporter.export(image: composed, to: outputURL)
        DirectorRunLog.write("cover confirmed: leadingCast=\(evidence.leadingCast.joined(separator: ", ")) time=\(evidence.sourceTime) model=\(evidence.modelID)")
        return ReviewedThumbnail(url: url, subject: evidence)
    }
}
