import AVFoundation
import AppKit
import CoreGraphics
import CoreImage
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
        DirectorRunLog.write("cover composition: " + diverse.prefix(6).map { candidate in
            let face = candidate.faceBox ?? .zero
            return String(format: "t=%.1f face=(%.2f,%.2f) size=%.2f top=%.2f score=%.0f", candidate.time,
                          face.midX, face.midY, face.width * face.height, face.maxY, candidate.score)
        }.joined(separator: "; "))
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
            // Средний план оставляет место и для лица, и для выразительного текста.
            if area >= 0.025 && area <= 0.14 { score += 520 }
            else if area > 0.14 && area <= 0.22 { score += 120 }
            else if area > 0.22 { score -= 320 }
            else if area > 0.015 { score += 120 }

            // Над головой должен оставаться воздух, чтобы слой героя не съедал заголовок.
            score += max(-500, min(500, (0.78 - box.maxY) * 1_800))

            // Композиция по правилу третей (лицо сбоку идеально оставляет место для гигантского текста)
            let midX = box.midX
            if midX >= 0.42 && midX <= 0.85 {
                score += 350.0 // Идеально: лицо справа, текст слева (стандарт чтения слева направо)
            } else if midX >= 0.15 && midX < 0.42 {
                score += 250.0 // Лицо слева, текст справа
            } else {
                score += 150.0 // Лицо по центру
            }

            // Для обложки нужен воздух над персонажем: целимся в лицо чуть
            // ниже середины кадра, чтобы слоган жил в свободной верхней зоне.
            let lowerFaceCenter = box.midY
            score += 900 - abs(lowerFaceCenter - 0.40) * 2_200

            // Предпочитаем героя ближе к центру/правой трети: слева остаётся
            // пространство для заголовка, а маска героя может дать глубину.
            score += 520 - abs(box.midX - 0.62) * 2_000

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

    /// Full-bleed frame used for the cover. Keep this exact rect for both the
    /// background and the Vision cutout so the foreground cannot ghost.
    static func fullFrameRect(imageSize: CGSize, faceBox: CGRect?, canvas: CGSize) -> CGRect {
        let scale = max(canvas.width / imageSize.width, canvas.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let face = faceBox ?? CGRect(x: 0.58, y: 0.25, width: 0.2, height: 0.4)
        let desiredX = canvas.width * 0.68 - face.midX * size.width
        let desiredY = canvas.height * 0.5 - face.midY * size.height
        return CGRect(x: min(0, max(canvas.width - size.width, desiredX)),
                      y: min(0, max(canvas.height - size.height, desiredY)), width: size.width, height: size.height)
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
        let imageRect = Self.fullFrameRect(imageSize: CGSize(width: candidate.image.width, height: candidate.image.height),
                                           faceBox: candidate.faceBox, canvas: renderSize)
        context.setFillColor(Self.obsidian.cgColor); context.fill(bounds)
        context.interpolationQuality = .high
        context.draw(candidate.image, in: imageRect)
        let textOnLeft = (candidate.faceBox?.midX ?? 0.68) >= 0.5
        if let gradient = CGGradient(colorsSpace: space, colors: [Self.obsidian.cgColor,
            Self.obsidian.withAlphaComponent(0.9).cgColor, Self.obsidian.withAlphaComponent(0).cgColor] as CFArray,
            locations: [0, 0.48, 1]) {
            let startX = textOnLeft ? 0 : renderSize.width
            let endX = textOnLeft ? renderSize.width * 0.76 : renderSize.width * 0.24
            context.drawLinearGradient(gradient, start: CGPoint(x: startX, y: 0),
                end: CGPoint(x: endX, y: 0), options: [.drawsBeforeStartLocation])
        }
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        defer { NSGraphicsContext.current = previous }
        let cleanedTitle = ThematicConcept.cleanTitle(concept.coverText ?? concept.displayWord)
        let heading = cleanedTitle.isEmpty ? concept.displayWord : cleanedTitle
        let words = heading.uppercased().split(whereSeparator: \.isWhitespace).map(String.init)
        if words.count == 2 {
            let firstWidth = renderSize.width * 0.42
            let firstX = textOnLeft ? renderSize.width * 0.055 : renderSize.width * 0.525
            let firstWordRect = CGRect(x: firstX, y: renderSize.height * 0.68,
                width: firstWidth, height: renderSize.height * 0.22)
            drawFitted(words[0], in: firstWordRect, maxSize: 176 * k, minSize: 112 * k,
                       color: Self.ivory, serif: false, tracking: 0)

            // The second word deliberately runs behind the lead's head. Its
            // final letters remain on the far side of the silhouette, while
            // the person mask creates the depth break through the middle.
            let secondWidth = renderSize.width * 0.97
            let secondX = renderSize.width * 0.015
            let secondWordRect = CGRect(x: secondX, y: renderSize.height * 0.50,
                width: secondWidth, height: renderSize.height * 0.27)
            drawFitted(words[1], in: secondWordRect, maxSize: 360 * k, minSize: 220 * k,
                       color: Self.ivory, serif: false, tracking: 0, wide: true, horizontalScale: 2.1)
        } else {
            let textWidth = renderSize.width * 0.70
            let headingRect = CGRect(x: textOnLeft ? renderSize.width * 0.055 : renderSize.width * 0.945 - textWidth,
                y: renderSize.height * 0.39, width: textWidth, height: renderSize.height * 0.54)
            drawFitted(heading.uppercased(), in: headingRect, maxSize: 176 * k, minSize: 112 * k,
                       color: Self.ivory, serif: false, tracking: 0)
        }
        // Draw the aligned foreground last: a selected lower-centered portrait
        // lets the subject overlap only the edge of the slogan for real depth.
        if let foreground = Self.foregroundSubject(from: candidate.image) {
            context.interpolationQuality = .high
            context.draw(foreground, in: imageRect)
        }
        guard let image = context.makeImage() else { throw ThumbnailSelectionError.noVerifiedLead }
        return image
    }

    private static func foregroundSubject(from image: CGImage) -> CGImage? {
        let handler = VNImageRequestHandler(cgImage: image)
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .accurate
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        do {
            try handler.perform([request])
            guard let observation = request.results?.first else { return nil }
            let source = CIImage(cgImage: image)
            let rawMask = CIImage(cvPixelBuffer: observation.pixelBuffer)
            let scaleX = source.extent.width / rawMask.extent.width
            let scaleY = source.extent.height / rawMask.extent.height
            let mask = rawMask.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
                .cropped(to: source.extent)
            let clear = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: source.extent)
            let foreground = source.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: clear,
                kCIInputMaskImageKey: mask
            ])
            return CIContext().createCGImage(foreground, from: source.extent)
        } catch {
            DirectorRunLog.write("cover person depth unavailable: \(error.localizedDescription)")
            return nil
        }
    }

    private func serif(_ size: CGFloat) -> NSFont {
        NSFont(name: "Georgia-Bold", size: size) ?? NSFont.systemFont(ofSize: size, weight: .bold)
    }
    /// AppKit's word wrapping still falls back to splitting an oversized word.
    /// Build explicit lines and fit their actual glyph widths before drawing.
    static func fittedText(_ text: String, in rect: CGRect, maxSize: CGFloat,
                           minSize: CGFloat, serif useSerif: Bool, tracking: CGFloat = 0,
                           wide: Bool = false) -> NSAttributedString {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        var size = maxSize
        while true {
            let font = useSerif
                ? (NSFont(name: "Georgia-Bold", size: size) ?? NSFont.boldSystemFont(ofSize: size))
                : wide
                    ? (NSFont(name: "AvenirNext-Heavy", size: size) ?? NSFont.systemFont(ofSize: size, weight: .heavy))
                    : (NSFont(name: "AvenirNextCondensed-Heavy", size: size)
                    ?? NSFont(name: "HelveticaNeue-CondensedBlack", size: size)
                    ?? NSFont.boldSystemFont(ofSize: size))
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byClipping
            paragraph.hyphenationFactor = 0
            paragraph.lineSpacing = size * 0.04
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font, .paragraphStyle: paragraph, .kern: tracking * size / maxSize]
            func width(_ line: String) -> CGFloat {
                (line as NSString).size(withAttributes: attributes).width
            }
            var lines: [String] = []
            for word in words {
                if let last = lines.last, width(last + " " + word) <= rect.width - 2 {
                    lines[lines.count - 1] = last + " " + word
                } else { lines.append(word) }
            }
            let value = NSAttributedString(string: lines.joined(separator: "\n"), attributes: attributes)
            let bounds = value.boundingRect(with: CGSize(width: rect.width, height: 100_000),
                                             options: [.usesLineFragmentOrigin, .usesFontLeading])
            let fitsWidth = lines.allSatisfy { width($0) <= rect.width - 2 }
            if (fitsWidth && ceil(bounds.height) + 2 <= rect.height) || size <= 1 { return value }
            // minSize is the preferred lower bound; unusually long words must
            // fit even below it rather than break in the middle or be clipped.
            size = max(1, size - (size > minSize ? 2 : 1))
        }
    }

    private func drawFitted(_ text: String, in rect: CGRect, maxSize: CGFloat, minSize: CGFloat,
                            color: NSColor, serif useSerif: Bool, tracking: CGFloat, wide: Bool = false,
                            horizontalScale: CGFloat = 1) {
        let fitted = Self.fittedText(text, in: rect, maxSize: maxSize, minSize: minSize,
                                    serif: useSerif, tracking: tracking, wide: wide)
        let attributed = NSMutableAttributedString(attributedString: fitted)
        attributed.addAttribute(.foregroundColor, value: color, range: NSRange(location: 0, length: attributed.length))
        let measured = attributed.boundingRect(with: CGSize(width: rect.width, height: 100_000),
                                               options: [.usesLineFragmentOrigin, .usesFontLeading])
        let scale = Self.safeHorizontalScale(for: attributed, availableWidth: rect.width, preferred: horizontalScale)
        let context = NSGraphicsContext.current!.cgContext
        context.saveGState()
        context.translateBy(x: rect.minX, y: 0)
        context.scaleBy(x: scale, y: 1)
        context.translateBy(x: -rect.minX, y: 0)
        attributed.draw(with: CGRect(x: rect.minX, y: rect.maxY - ceil(measured.height) - 2,
                                     width: rect.width, height: ceil(measured.height) + 2),
                        options: [.usesLineFragmentOrigin, .usesFontLeading])
        context.restoreGState()
    }

    /// Stretch the depth headline only as far as the actual glyph widths permit.
    /// A fixed factor clips longer slogans even when the unscaled text fits.
    static func safeHorizontalScale(for text: NSAttributedString, availableWidth: CGFloat,
                                    preferred: CGFloat) -> CGFloat {
        guard text.length > 0, availableWidth > 0 else { return 1 }
        let attributes = text.attributes(at: 0, effectiveRange: nil)
        let width = text.string.components(separatedBy: "\n")
            .map { ($0 as NSString).size(withAttributes: attributes).width }.max() ?? 0
        guard width.isFinite, width > 0 else { return 1 }
        return min(max(0.01, preferred), max(0.01, (availableWidth - 2) / width))
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
