import AVFoundation
import AppKit
import CoreGraphics
import UniformTypeIdentifiers
import Vision

/// Протокол генератора обложек YouTube в стиле канала @prrodan и Shortcast Cinema (SOLID: DIP)
protocol LongformThumbnailGeneratingProtocol: Sendable {
    func generateThumbnail(
        sourceAsset: AVURLAsset,
        segments: [TimeSegment],
        concept: ThematicConcept,
        movieTitle: String,
        outputURL: URL
    ) async throws -> URL
}

/// Модель оцененного кандидата кадра для обложки
struct ThumbnailCandidateFrame: Sendable {
    let time: Double
    let image: CGImage
    let faceBox: CGRect?
    let score: Double
    let averageLuminance: Double
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

/// Сервис умного подбора и скоринга кадров через Apple Vision (SOLID: Single Responsibility)
final class LongformThumbnailCandidateSelector: Sendable {

    /// Подбирает наиболее выразительный кадр фильма (портретный крупный план героя с высоким контрастом)
    func selectBestCandidate(
        sourceAsset: AVURLAsset,
        segments: [TimeSegment],
        renderSize: CGSize = CGSize(width: 1920, height: 1080)
    ) async throws -> ThumbnailCandidateFrame {
        let candidateTimes = generateCandidateTimestamps(segments: segments, sourceAsset: sourceAsset)
        
        let generator = AVAssetImageGenerator(asset: sourceAsset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = renderSize
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)

        var scoredCandidates: [ThumbnailCandidateFrame] = []

        for timeSec in candidateTimes {
            let cmTime = CMTime(seconds: timeSec, preferredTimescale: 600)
            guard let (cgImage, _) = try? await generator.image(at: cmTime) else {
                continue
            }

            let luminance = calculateAverageLuminance(of: cgImage)
            
            // Если кадр полностью черный (склейка в темноту) или выбелен - отсекаем
            if luminance < 0.05 {
                continue
            }

            let (bestFaceBox, faceCount) = detectFaces(in: cgImage)
            let score = scoreCandidate(
                time: timeSec,
                luminance: luminance,
                bestFaceBox: bestFaceBox,
                faceCount: faceCount,
                candidateTimes: candidateTimes
            )

            scoredCandidates.append(
                ThumbnailCandidateFrame(
                    time: timeSec,
                    image: cgImage,
                    faceBox: bestFaceBox,
                    score: score,
                    averageLuminance: luminance
                )
            )
        }

        // Сортируем по очкам выразительности
        scoredCandidates.sort(by: { $0.score > $1.score })

        if let best = scoredCandidates.first {
            return best
        }

        // Если не удалось извлечь ни одного кадра из кандидатов, берем аварийный кадр
        let fallbackTime = segments.first?.start ?? 60.0
        let (fallbackImage, _) = try await generator.image(at: CMTime(seconds: fallbackTime, preferredTimescale: 600))
        return ThumbnailCandidateFrame(
            time: fallbackTime,
            image: fallbackImage,
            faceBox: nil,
            score: 0.0,
            averageLuminance: calculateAverageLuminance(of: fallbackImage)
        )
    }

    /// Генерирует 12-16 контрольных точек по всему хронометражу фильма
    private func generateCandidateTimestamps(segments: [TimeSegment], sourceAsset: AVURLAsset) -> [Double] {
        guard !segments.isEmpty else {
            // Если сегменты не переданы, распределяем точки равномерно по видео
            let dur = CMTimeGetSeconds(sourceAsset.duration)
            let safeDur = dur.isFinite && dur > 10.0 ? dur : 300.0
            return [0.15, 0.30, 0.45, 0.55, 0.65, 0.75, 0.85].map { $0 * safeDur }
        }

        var times: [Double] = []
        for seg in segments {
            // Середина сегмента
            times.append(seg.start + seg.duration * 0.5)
            // Дополнительные точки для длинных эмоциональных сцен
            if seg.duration >= 7.0 {
                times.append(seg.start + seg.duration * 0.25)
                times.append(seg.start + seg.duration * 0.75)
            }
        }

        // Если точек слишком много, берем до 16 равномерно распределенных
        if times.count > 16 {
            let step = Double(times.count) / 16.0
            var sampled: [Double] = []
            for i in 0..<16 {
                let idx = min(Int(Double(i) * step), times.count - 1)
                sampled.append(times[idx])
            }
            return sampled
        }

        return times
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

    func composeThumbnail(
        candidate: ThumbnailCandidateFrame,
        concept: ThematicConcept,
        movieTitle: String,
        renderSize: CGSize = CGSize(width: 1920, height: 1080)
    ) throws -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue

        guard let context = CGContext(
            data: nil,
            width: Int(renderSize.width),
            height: Int(renderSize.height),
            bitsPerComponent: 8,
            bytesPerRow: Int(renderSize.width) * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw NSError(domain: "ThumbnailComposer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Не удалось создать графический контекст."])
        }

        // 1. Черная кинематографическая база
        context.setFillColor(CGColor(gray: 0.0, alpha: 1.0))
        context.fill(CGRect(origin: .zero, size: renderSize))

        // 2. Отрисовка кадра с Aspect-Fill (устранение черных полос исходника)
        let srcW = CGFloat(candidate.image.width)
        let srcH = CGFloat(candidate.image.height)
        let scale = max(renderSize.width / srcW, renderSize.height / srcH)
        let drawW = srcW * scale
        let drawH = srcH * scale
        let drawX = (renderSize.width - drawW) / 2.0
        let drawY = (renderSize.height - drawH) / 2.0
        context.draw(candidate.image, in: CGRect(x: drawX, y: drawY, width: drawW, height: drawH))

        // 3. Определение ориентации композиции
        let layoutMode: ThumbnailLayoutMode
        if let box = candidate.faceBox {
            if box.midX >= 0.42 {
                layoutMode = .leftTextRightFace
            } else {
                layoutMode = .rightTextLeftFace
            }
        } else {
            layoutMode = .centerBottomFallback
        }

        // 4. Наложение кино-градиентов
        drawCinematicGradients(context: context, colorSpace: colorSpace, layoutMode: layoutMode, renderSize: renderSize)

        // 5. Отрисовка монументальной типографики
        drawTypography(
            context: context,
            layoutMode: layoutMode,
            concept: concept,
            movieTitle: movieTitle,
            renderSize: renderSize
        )

        guard let finalImage = context.makeImage() else {
            throw NSError(domain: "ThumbnailComposer", code: -2, userInfo: [NSLocalizedDescriptionKey: "Не удалось сформировать изображение."])
        }

        return finalImage
    }

    /// Кинематографический градиент: глубокое затемнение на стороне текста + мягкая верхняя/нижняя виньетка
    private func drawCinematicGradients(
        context: CGContext,
        colorSpace: CGColorSpace,
        layoutMode: ThumbnailLayoutMode,
        renderSize: CGSize
    ) {
        let gradColors = [
            CGColor(gray: 0.0, alpha: 0.96),
            CGColor(gray: 0.0, alpha: 0.88),
            CGColor(gray: 0.0, alpha: 0.50),
            CGColor(gray: 0.0, alpha: 0.0)
        ] as CFArray
        let gradLocations: [CGFloat] = [0.0, 0.40, 0.70, 1.0]

        if let sideGrad = CGGradient(colorsSpace: colorSpace, colors: gradColors, locations: gradLocations) {
            switch layoutMode {
            case .leftTextRightFace:
                // Затемнение слева направо (текст слева)
                context.drawLinearGradient(
                    sideGrad,
                    start: CGPoint(x: 0, y: renderSize.height / 2.0),
                    end: CGPoint(x: 1250, y: renderSize.height / 2.0),
                    options: []
                )
            case .rightTextLeftFace:
                // Затемнение справа налево (текст справа)
                context.drawLinearGradient(
                    sideGrad,
                    start: CGPoint(x: renderSize.width, y: renderSize.height / 2.0),
                    end: CGPoint(x: 670, y: renderSize.height / 2.0),
                    options: []
                )
            case .centerBottomFallback:
                // Нижнее затемнение для центрированного текста
                let bottomColors = [
                    CGColor(gray: 0.0, alpha: 0.94),
                    CGColor(gray: 0.0, alpha: 0.65),
                    CGColor(gray: 0.0, alpha: 0.0)
                ] as CFArray
                if let bGrad = CGGradient(colorsSpace: colorSpace, colors: bottomColors, locations: [0.0, 0.50, 1.0]) {
                    context.drawLinearGradient(
                        bGrad,
                        start: CGPoint(x: renderSize.width / 2.0, y: 0),
                        end: CGPoint(x: renderSize.width / 2.0, y: 680),
                        options: []
                    )
                }
            }
        }

        // Мягкая виньетка сверху и снизу
        let edgeColors = [CGColor(gray: 0.0, alpha: 0.60), CGColor(gray: 0.0, alpha: 0.0)] as CFArray
        if let edgeGrad = CGGradient(colorsSpace: colorSpace, colors: edgeColors, locations: [0.0, 1.0]) {
            // Верх
            context.drawLinearGradient(
                edgeGrad,
                start: CGPoint(x: renderSize.width / 2.0, y: renderSize.height),
                end: CGPoint(x: renderSize.width / 2.0, y: renderSize.height - 200.0),
                options: []
            )
            // Низ
            context.drawLinearGradient(
                edgeGrad,
                start: CGPoint(x: renderSize.width / 2.0, y: 0),
                end: CGPoint(x: renderSize.width / 2.0, y: 220.0),
                options: []
            )
        }
    }

    /// Отрисовка монументальной типографики в стиле @prrodan (SOLID: Single Responsibility)
    private func drawTypography(
        context: CGContext,
        layoutMode: ThumbnailLayoutMode,
        concept: ThematicConcept,
        movieTitle: String,
        renderSize: CGSize
    ) {
        let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsContext

        // Координаты размещения текстового блока
        let textX: CGFloat
        let textMaxW: CGFloat
        let baseY: CGFloat
        let isCentered: Bool

        switch layoutMode {
        case .leftTextRightFace:
            textX = 110.0
            textMaxW = 820.0
            baseY = 340.0
            isCentered = false
        case .rightTextLeftFace:
            textX = 990.0
            textMaxW = 820.0
            baseY = 340.0
            isCentered = false
        case .centerBottomFallback:
            textX = 140.0
            textMaxW = 1640.0
            baseY = 160.0
            isCentered = true
        }

        // Кинематографическая глубокая тень
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.98)
        shadow.shadowBlurRadius = 18.0
        shadow.shadowOffset = NSSize(width: 0, height: -4.0)

        let accentColor = NSColor(hex: concept.accentColorHex) ?? NSColor(calibratedRed: 1.0, green: 0.89, blue: 0.36, alpha: 1.0)

        // 1. Бейдж-надстрочник: ФИЛОСОФИЯ ФИЛЬМА «НАЗВАНИЕ»
        let badgeFont = SubtitleRenderer.resolveFont(name: "RussoOne-Regular", size: 22.0, fallback: .bold)
        let badgeParagraph = NSMutableParagraphStyle()
        if isCentered { badgeParagraph.alignment = .center }

        let badgeAttrs: [NSAttributedString.Key: Any] = [
            .font: badgeFont,
            .foregroundColor: accentColor,
            .shadow: shadow,
            .paragraphStyle: badgeParagraph,
            .kern: 3.0
        ]
        let badgeText = "ФИЛОСОФИЯ ФИЛЬМА «\(movieTitle.uppercased())»"
        let badgeStr = NSAttributedString(string: badgeText, attributes: badgeAttrs)
        let badgeY = baseY + 360.0
        if isCentered {
            badgeStr.draw(in: CGRect(x: textX, y: badgeY, width: textMaxW, height: 40.0))
        } else {
            badgeStr.draw(at: NSPoint(x: textX, y: badgeY))
        }

        // 2. Главное якорное слово темы (монументально 125-130pt с авто-масштабированием)
        var anchorFontSize: CGFloat = isCentered ? 110.0 : 125.0
        let rawAnchor = concept.word.uppercased()

        // Проверяем ширину и уменьшаем шрифт при необходимости, чтобы слово никогда не вылезало за границу
        let testFont = SubtitleRenderer.resolveFont(name: "RussoOne-Regular", size: anchorFontSize, fallback: .heavy)
        let testSize = (rawAnchor as NSString).size(withAttributes: [.font: testFont, .kern: 4.0])
        if testSize.width > textMaxW {
            anchorFontSize = max(65.0, floor(anchorFontSize * (textMaxW / testSize.width)))
        }

        let titleFont = SubtitleRenderer.resolveFont(name: "RussoOne-Regular", size: anchorFontSize, fallback: .heavy)
        let titleParagraph = NSMutableParagraphStyle()
        if isCentered { titleParagraph.alignment = .center }

        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: titleFont,
            .foregroundColor: NSColor.white,
            .strokeColor: NSColor.black,
            .strokeWidth: -3.2,
            .shadow: shadow,
            .paragraphStyle: titleParagraph,
            .kern: 4.0
        ]
        let titleStr = NSAttributedString(string: rawAnchor, attributes: titleAttrs)
        let titleY = baseY + 190.0
        if isCentered {
            titleStr.draw(in: CGRect(x: textX, y: titleY, width: textMaxW, height: 160.0))
        } else {
            titleStr.draw(at: NSPoint(x: textX, y: titleY))
        }

        // 3. Золотая акцентная разделительная черта
        let lineW: CGFloat = isCentered ? 160.0 : min(140.0, textMaxW)
        let lineX: CGFloat = isCentered ? (renderSize.width - lineW) / 2.0 : textX
        let lineRect = CGRect(x: lineX, y: baseY + 160.0, width: lineW, height: 4.5)
        context.setFillColor(accentColor.cgColor)
        context.fill(lineRect)

        // 4. Смысловой тезис / хук (жесткий перенос слов по строкам, защита от обрезания)
        var hookFontSize: CGFloat = 34.0
        let hookParagraph = NSMutableParagraphStyle()
        hookParagraph.lineBreakMode = .byWordWrapping
        hookParagraph.lineSpacing = 8.0
        if isCentered { hookParagraph.alignment = .center }

        var hookAttrs: [NSAttributedString.Key: Any] = [
            .font: SubtitleRenderer.resolveFont(name: "RussoOne-Regular", size: hookFontSize, fallback: .heavy),
            .foregroundColor: NSColor(calibratedWhite: 0.94, alpha: 1.0),
            .strokeColor: NSColor.black,
            .strokeWidth: -2.0,
            .shadow: shadow,
            .paragraphStyle: hookParagraph,
            .kern: 1.5
        ]

        let cleanTagline = concept.tagline.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        var hookStr = NSAttributedString(string: cleanTagline, attributes: hookAttrs)

        // Измеряем высоту с переносом строк
        var measuredRect = hookStr.boundingRect(
            with: CGSize(width: textMaxW, height: 300.0),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )

        // Если текст слишком длинный для 3 строк, масштабируем размер шрифта вниз
        if measuredRect.height > 165.0 {
            hookFontSize = 28.0
            hookAttrs[.font] = SubtitleRenderer.resolveFont(name: "RussoOne-Regular", size: hookFontSize, fallback: .heavy)
            hookStr = NSAttributedString(string: cleanTagline, attributes: hookAttrs)
            measuredRect = hookStr.boundingRect(
                with: CGSize(width: textMaxW, height: 300.0),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
        }

        let hookRect = CGRect(x: textX, y: baseY - 15.0, width: textMaxW, height: max(measuredRect.height + 20.0, 160.0))
        hookStr.draw(in: hookRect)

        NSGraphicsContext.restoreGraphicsState()
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

/// Главный генератор кинематографических обложек YouTube 1080p (SOLID: Facade & DIP)
final class LongformThumbnailGenerator: LongformThumbnailGeneratingProtocol, Sendable {

    private let candidateSelector: LongformThumbnailCandidateSelector
    private let composer: LongformThumbnailComposer
    private let exporter: LongformThumbnailExporter

    init(
        candidateSelector: LongformThumbnailCandidateSelector = LongformThumbnailCandidateSelector(),
        composer: LongformThumbnailComposer = LongformThumbnailComposer(),
        exporter: LongformThumbnailExporter = LongformThumbnailExporter()
    ) {
        self.candidateSelector = candidateSelector
        self.composer = composer
        self.exporter = exporter
    }

    func generateThumbnail(
        sourceAsset: AVURLAsset,
        segments: [TimeSegment],
        concept: ThematicConcept,
        movieTitle: String,
        outputURL: URL
    ) async throws -> URL {
        let renderSize = CGSize(width: 1920, height: 1080)

        // 1. Умный поиск лучшего драматического кадра через Vision и скоринг
        let bestCandidate = try await candidateSelector.selectBestCandidate(
            sourceAsset: sourceAsset,
            segments: segments,
            renderSize: renderSize
        )

        // 2. Кинематографическая компоновка кадра, градиентов и монументальной типографики
        let composedImage = try composer.composeThumbnail(
            candidate: bestCandidate,
            concept: concept,
            movieTitle: movieTitle,
            renderSize: renderSize
        )

        // 3. Экспорт в финальный JPEG 1920x1080
        return try exporter.export(image: composedImage, to: outputURL, quality: 0.94)
    }
}
