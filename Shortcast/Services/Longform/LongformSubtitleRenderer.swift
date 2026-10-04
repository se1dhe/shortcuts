import AppKit
import AVFoundation
import CoreGraphics
import QuartzCore

/// Кинематографический отрисовщик титров и оверлеев в стиле канала @prrodan,
/// но с фирменной типографикой, шрифтами и стилем Shortcast Cinema (SOLID):
/// 1. Центральное якорное слово концепта (например, "ТЕРПЕНИЕ"):
///    - Постоянно отображается по центру экрана на протяжении всего фильма (opacity 1.0)
///    - Фирменная типографика Shortcast: шрифт Russo One / Bebas Neue, крупный кегль,
///      широкий кинематографический трекинг (kern: 5.0), офф-вайт (#F5F5F7),
///      тонкая контрастная окантовка (-2.8) и глубокая кино-тень (blur 14.0)
/// 2. Плавные синхронные субтитры реплик под концептом:
///    - Располагаются строго под якорным словом по центру
///    - Плавное появление (fade-in 0.10с) и мягкое затухание (fade-out 0.10с) по таймкодам реплик
///    - Фирменный акцент Shortcast: золото (#FFE45C / #F5D020), шрифт Russo One 26pt,
///      четкая обводка (-3.2) и кино-тень
/// 3. Вступительный подзаголовок темы (Intro Hook, 0.0с – 4.5с):
///    - Золотая линия и философский слоган под центральным словом, плавно затухающие к 4.5с
/// 4. Маркеры драматургических актов (Act Chapter Cards):
///    - Стильные бейджи смены актов («АКТ II • БОРЬБА», «АКТ III • КУЛЬМИНАЦИЯ») в верхнем углу
final class LongformSubtitleRenderer: LongformSubtitleRenderingProtocol, Sendable {

    private let appearance: SubtitleAppearance

    init(appearance: SubtitleAppearance = .cinemaLongform) {
        self.appearance = appearance
    }

    func makeOverlayLayer(
        renderSize: CGSize,
        concept: ThematicConcept,
        timedPhrases: [TimedSubtitlePhrase],
        acts: [LongformAct] = [],
        totalDuration: Double = 0.0
    ) async -> CALayer {
        let rootLayer = CALayer()
        rootLayer.frame = CGRect(origin: .zero, size: renderSize)
        rootLayer.isGeometryFlipped = false

        let calculatedTotalDuration = max(totalDuration, timedPhrases.last?.end ?? 300.0)
        let W = renderSize.width
        let H = renderSize.height

        // 1. Центральное якорное слово концепта (висит весь фильм, плавно растворяется в финале)
        let (conceptLayer, conceptY, _) = buildCentralConceptLayer(
            renderSize: renderSize,
            concept: concept,
            totalDuration: calculatedTotalDuration
        )
        rootLayer.addSublayer(conceptLayer)

        // 2. Плавные синхронные субтитры реплик персонажей прямо под концептом
        let subtitlePhrasesLayer = buildSynchronizedSubtitlesLayer(
            renderSize: renderSize,
            concept: concept,
            conceptY: conceptY,
            timedPhrases: timedPhrases,
            totalDuration: calculatedTotalDuration
        )
        rootLayer.addSublayer(subtitlePhrasesLayer)

        // 3. Вступительная золотая линия и философский слоган (0.0с – 4.5с)
        let introTaglineLayer = buildIntroTaglineLayer(
            renderSize: renderSize,
            concept: concept,
            conceptY: conceptY,
            totalDuration: calculatedTotalDuration
        )
        rootLayer.addSublayer(introTaglineLayer)

        // 4. Маркеры перехода между драматургическими актами (Act Chapter Cards)
        if !acts.isEmpty {
            let actLayers = buildActChapterLayers(
                renderSize: renderSize,
                acts: acts,
                concept: concept,
                totalDuration: calculatedTotalDuration
            )
            rootLayer.addSublayer(actLayers)
        }

        return rootLayer
    }

    // MARK: - 1. Центральное якорное слово концепта (Shortcast Cinema Typography)

    private func buildCentralConceptLayer(
        renderSize: CGSize,
        concept: ThematicConcept,
        totalDuration: Double
    ) -> (layer: CALayer, conceptY: CGFloat, conceptH: CGFloat) {
        let W = renderSize.width
        let H = renderSize.height
        let t = max(totalDuration, 5.0)

        let font = SubtitleRenderer.resolveFont(name: "RussoOne-Regular", size: 56.0, fallback: .heavy)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.96)
        shadow.shadowBlurRadius = 14.0
        shadow.shadowOffset = CGSize(width: 0, height: -3.0)

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(hex: "#F5F5F7") ?? .white,
            .strokeColor: NSColor.black,
            .strokeWidth: -2.8,
            .paragraphStyle: paragraph,
            .shadow: shadow,
            .kern: 5.0
        ]

        let conceptStr = NSAttributedString(string: concept.word.uppercased(), attributes: attrs)
        let textSize = conceptStr.size()
        let layerW = textSize.width + 48.0
        let layerH = textSize.height + 24.0

        // Строго по центру экрана
        let conceptX = (W - layerW) / 2.0
        let conceptY = (H - layerH) / 2.0

        let layer = CALayer()
        layer.frame = CGRect(x: conceptX, y: conceptY, width: layerW, height: layerH)
        layer.contentsScale = 2.0
        layer.contents = renderAttributedText(conceptStr, size: layer.frame.size)

        // Плавное затухание в последние 2.0 секунды фильма
        let outroStartTime = max(0.0, totalDuration - 2.0)
        let kOutroStart = outroStartTime / t

        let anim = CAKeyframeAnimation(keyPath: "opacity")
        anim.values = [1.0, 1.0, 0.0]
        anim.keyTimes = [
            NSNumber(value: 0.0),
            NSNumber(value: kOutroStart),
            NSNumber(value: 1.0)
        ]
        anim.duration = t
        anim.beginTime = AVCoreAnimationBeginTimeAtZero
        anim.fillMode = .both
        anim.isRemovedOnCompletion = false
        layer.add(anim, forKey: "centralConceptOutroFade")

        return (layer, conceptY, layerH)
    }

    // MARK: - 2. Плавные синхронные субтитры реплик под концептом

    private func buildSynchronizedSubtitlesLayer(
        renderSize: CGSize,
        concept: ThematicConcept,
        conceptY: CGFloat,
        timedPhrases: [TimedSubtitlePhrase],
        totalDuration: Double
    ) -> CALayer {
        let container = CALayer()
        container.frame = CGRect(origin: .zero, size: renderSize)

        let W = renderSize.width
        let t = max(totalDuration, 1.0)

        let subFont = SubtitleRenderer.resolveFont(name: "RussoOne-Regular", size: 26.0, fallback: .heavy)
        let accentColor = NSColor(hex: concept.accentColorHex) ?? NSColor(hex: "#FFE45C") ?? .yellow

        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.95)
        shadow.shadowBlurRadius = 10.0
        shadow.shadowOffset = CGSize(width: 0, height: -2.0)

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center

        let subAttrs: [NSAttributedString.Key: Any] = [
            .font: subFont,
            .foregroundColor: accentColor,
            .strokeColor: NSColor.black,
            .strokeWidth: -3.2,
            .paragraphStyle: paragraph,
            .shadow: shadow,
            .kern: 1.5
        ]

        for phrase in timedPhrases {
            let cleanText = phrase.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanText.isEmpty, phrase.end > phrase.start else { continue }
            // Не показываем субтитры во время вступительной заставки (0.0-4.5с), чтобы не перекрывать тезис
            guard phrase.end > 4.5 else { continue }

            let subStr = NSAttributedString(string: cleanText.uppercased(), attributes: subAttrs)
            let textSize = subStr.size()
            let subW = min(W * 0.85, textSize.width + 40.0)
            let subH = textSize.height + 18.0

            // Размещаем прямо под концептом (вниз от conceptY с безопасным отступом)
            let subX = (W - subW) / 2.0
            let subY = conceptY - subH - 18.0

            let phraseLayer = CALayer()
            phraseLayer.frame = CGRect(x: subX, y: subY, width: subW, height: subH)
            phraseLayer.contentsScale = 2.0
            phraseLayer.contents = renderAttributedText(subStr, size: phraseLayer.frame.size)
            phraseLayer.opacity = 0.0

            // Если фраза началась до окончания заставки, плавно включаем ее сразу после исчезновения заставки (4.55с)
            let pStart = max(phrase.start, 4.55)
            // И ограничиваем конец фразы началом финального затухания (totalDuration - 2.0)
            let maxEndTime = max(pStart + 0.35, totalDuration - 2.0)
            let pEnd = min(max(phrase.end, pStart + 0.35), maxEndTime)
            guard pEnd > pStart else { continue }
            let phraseDuration = pEnd - pStart
            let fadeDuration = min(0.12, phraseDuration * 0.25)

            let kStart = pStart / t
            let kFadeIn = (pStart + fadeDuration) / t
            let kFadeOutStart = max(pStart + fadeDuration, pEnd - fadeDuration) / t
            let kEnd = pEnd / t

            let anim = CAKeyframeAnimation(keyPath: "opacity")
            anim.values = [0.0, 0.0, 1.0, 1.0, 0.0, 0.0]
            anim.keyTimes = [
                NSNumber(value: 0.0),
                NSNumber(value: max(0.0, kStart)),
                NSNumber(value: min(1.0, kFadeIn)),
                NSNumber(value: min(1.0, kFadeOutStart)),
                NSNumber(value: min(1.0, kEnd)),
                NSNumber(value: 1.0)
            ]
            anim.duration = t
            anim.beginTime = AVCoreAnimationBeginTimeAtZero
            anim.fillMode = .both
            anim.isRemovedOnCompletion = false

            phraseLayer.add(anim, forKey: "smoothPhraseFade")
            container.addSublayer(phraseLayer)
        }

        return container
    }

    // MARK: - 3. Вступительный подзаголовок темы (Intro Hook, 0.0с – 4.5с)

    private func buildIntroTaglineLayer(
        renderSize: CGSize,
        concept: ThematicConcept,
        conceptY: CGFloat,
        totalDuration: Double
    ) -> CALayer {
        let container = CALayer()
        container.frame = CGRect(origin: .zero, size: renderSize)
        container.opacity = 0.0

        let W = renderSize.width
        let t = max(totalDuration, 5.0)

        // Золотая акцентная черта
        let accentColor = NSColor(hex: concept.accentColorHex)?.cgColor ?? CGColor(srgbRed: 0.96, green: 0.82, blue: 0.13, alpha: 1.0)
        let lineW: CGFloat = 140.0
        let lineLayer = CALayer()
        lineLayer.frame = CGRect(x: (W - lineW) / 2.0, y: conceptY - 10.0, width: lineW, height: 2.5)
        lineLayer.backgroundColor = accentColor
        lineLayer.cornerRadius = 1.25
        lineLayer.shadowColor = CGColor(gray: 0, alpha: 0.8)
        lineLayer.shadowRadius = 4.0
        lineLayer.shadowOffset = CGSize(width: 0, height: -1.0)
        container.addSublayer(lineLayer)

        // Подзаголовок / тезис
        let taglineText = concept.tagline.isEmpty ? concept.philosophicalPremise : concept.tagline
        if !taglineText.isEmpty {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center

            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.9)
            shadow.shadowBlurRadius = 10.0
            shadow.shadowOffset = CGSize(width: 0, height: -2.0)

            let subFont = NSFont.systemFont(ofSize: 18.0, weight: .medium)
            let subAttrs: [NSAttributedString.Key: Any] = [
                .font: subFont,
                .foregroundColor: NSColor(hex: "#E0E0E0") ?? .lightGray,
                .paragraphStyle: paragraph,
                .shadow: shadow,
                .kern: 1.8
            ]

            let subStr = NSAttributedString(string: taglineText, attributes: subAttrs)
            let textSize = subStr.size()
            let subW = textSize.width + 40.0
            let subH = textSize.height + 16.0

            let subLayer = CALayer()
            subLayer.frame = CGRect(x: (W - subW) / 2.0, y: conceptY - 40.0, width: subW, height: subH)
            subLayer.contentsScale = 2.0
            subLayer.contents = renderAttributedText(subStr, size: subLayer.frame.size)
            container.addSublayer(subLayer)
        }

        // Анимация: плавно появляется (0.0-0.8с), держится до 3.2с, плавно затухает к 4.2с
        let tFadeIn = 0.8 / t
        let tHold = 3.2 / t
        let tFadeOut = 4.2 / t

        let anim = CAKeyframeAnimation(keyPath: "opacity")
        anim.values = [0.0, 1.0, 1.0, 0.0, 0.0]
        anim.keyTimes = [
            NSNumber(value: 0.0),
            NSNumber(value: tFadeIn),
            NSNumber(value: tHold),
            NSNumber(value: tFadeOut),
            NSNumber(value: 1.0)
        ]
        anim.duration = t
        anim.beginTime = AVCoreAnimationBeginTimeAtZero
        anim.fillMode = .both
        anim.isRemovedOnCompletion = false
        container.add(anim, forKey: "introTaglineFade")

        return container
    }

    // MARK: - 4. Маркеры драматургических актов (Act Chapter Cards)

    private func buildActChapterLayers(
        renderSize: CGSize,
        acts: [LongformAct],
        concept: ThematicConcept,
        totalDuration: Double
    ) -> CALayer {
        let container = CALayer()
        container.frame = CGRect(origin: .zero, size: renderSize)

        let t = max(totalDuration, 5.0)
        let romanNumerals = ["I", "II", "III", "IV", "V"]
        var accumulatedTime = 0.0

        for (idx, act) in acts.enumerated() {
            let actStart = accumulatedTime
            accumulatedTime += act.duration

            // Первый акт пропускаем, так как в начале уже играет интро
            guard actStart >= 4.5 && actStart < t else { continue }

            let roman = idx < romanNumerals.count ? romanNumerals[idx] : "\(idx + 1)"
            let badgeText = "АКТ \(roman) • \(act.type.rawValue.uppercased())"

            let font = NSFont.systemFont(ofSize: 18.0, weight: .bold)
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .left

            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.9)
            shadow.shadowBlurRadius = 8.0
            shadow.shadowOffset = CGSize(width: 0, height: -2.0)

            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor(hex: concept.accentColorHex) ?? NSColor(hex: "#FFE45C") ?? .yellow,
                .paragraphStyle: paragraph,
                .shadow: shadow,
                .kern: 3.0
            ]

            let str = NSAttributedString(string: badgeText, attributes: attrs)
            let textSize = str.size()
            let badgeW = textSize.width + 36.0
            let badgeH = textSize.height + 16.0

            let badgeLayer = CALayer()
            badgeLayer.frame = CGRect(
                x: 70.0,
                y: renderSize.height - badgeH - 60.0,
                width: badgeW,
                height: badgeH
            )
            badgeLayer.backgroundColor = CGColor(gray: 0.05, alpha: 0.65)
            badgeLayer.cornerRadius = 8.0
            badgeLayer.borderWidth = 1.0
            badgeLayer.borderColor = CGColor(gray: 1.0, alpha: 0.15)
            badgeLayer.opacity = 0.0

            let textSubLayer = CALayer()
            textSubLayer.frame = CGRect(x: 18.0, y: 8.0, width: textSize.width + 10.0, height: textSize.height + 4.0)
            textSubLayer.contentsScale = 2.0
            textSubLayer.contents = renderAttributedText(str, size: textSubLayer.frame.size)
            badgeLayer.addSublayer(textSubLayer)

            // Анимация показа акта на 3 секунды
            let fadeInEnd = actStart + 0.4
            let holdEnd = actStart + 2.6
            let fadeOutEnd = actStart + 3.2

            let kStart = actStart / t
            let kFadeIn = fadeInEnd / t
            let kHold = holdEnd / t
            let kFadeOut = fadeOutEnd / t

            let anim = CAKeyframeAnimation(keyPath: "opacity")
            anim.values = [0.0, 0.0, 1.0, 1.0, 0.0, 0.0]
            anim.keyTimes = [
                NSNumber(value: 0.0),
                NSNumber(value: max(0.0, kStart)),
                NSNumber(value: min(1.0, kFadeIn)),
                NSNumber(value: min(1.0, kHold)),
                NSNumber(value: min(1.0, kFadeOut)),
                NSNumber(value: 1.0)
            ]
            anim.duration = t
            anim.beginTime = AVCoreAnimationBeginTimeAtZero
            anim.fillMode = .both
            anim.isRemovedOnCompletion = false
            badgeLayer.add(anim, forKey: "actBadgeOpacity")

            container.addSublayer(badgeLayer)
        }

        return container
    }

    // MARK: - 5. Генерация превью в стиле Shortcast Cinema

    func renderPreviewImage(
        renderSize: CGSize,
        concept: ThematicConcept,
        currentPhrase: String?
    ) -> CGImage? {
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
        ) else { return nil }

        // Темный кинематографичный фон для превью
        context.setFillColor(CGColor(gray: 0.08, alpha: 1.0))
        context.fill(CGRect(origin: .zero, size: renderSize))

        let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsContext

        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.96)
        shadow.shadowBlurRadius = 14.0
        shadow.shadowOffset = NSSize(width: 0, height: -3.0)

        // 1. Центральное якорное слово темы (Russo One, kern 5.0, офф-вайт, обводка)
        let conceptFont = SubtitleRenderer.resolveFont(name: "RussoOne-Regular", size: 56.0, fallback: .heavy)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center

        let conceptAttrs: [NSAttributedString.Key: Any] = [
            .font: conceptFont,
            .foregroundColor: NSColor(hex: "#F5F5F7") ?? .white,
            .strokeColor: NSColor.black,
            .strokeWidth: -2.8,
            .paragraphStyle: paragraph,
            .shadow: shadow,
            .kern: 5.0
        ]

        let conceptStr = NSAttributedString(string: concept.word.uppercased(), attributes: conceptAttrs)
        let conceptSize = conceptStr.size()
        let conceptOrigin = NSPoint(
            x: (renderSize.width - conceptSize.width) / 2.0,
            y: (renderSize.height - conceptSize.height) / 2.0
        )
        conceptStr.draw(at: conceptOrigin)

        // 2. Плавный субтитр диалога прямо под концептом (золото Shortcast, Russo One 26pt, обводка)
        let phraseText = currentPhrase?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "ПОТЕРЯЕШЬ ВСЁ"
        if !phraseText.isEmpty {
            let accentColor = NSColor(hex: concept.accentColorHex) ?? NSColor(hex: "#FFE45C") ?? .yellow
            let subFont = SubtitleRenderer.resolveFont(name: "RussoOne-Regular", size: 26.0, fallback: .heavy)
            let subAttrs: [NSAttributedString.Key: Any] = [
                .font: subFont,
                .foregroundColor: accentColor,
                .strokeColor: NSColor.black,
                .strokeWidth: -3.2,
                .paragraphStyle: paragraph,
                .shadow: shadow,
                .kern: 1.5
            ]
            let subStr = NSAttributedString(string: phraseText.uppercased(), attributes: subAttrs)
            let subSize = subStr.size()
            let subOrigin = NSPoint(
                x: (renderSize.width - subSize.width) / 2.0,
                y: conceptOrigin.y - subSize.height - 12.0
            )
            subStr.draw(at: subOrigin)
        }

        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    // MARK: - Helpers

    private func renderAttributedText(_ text: NSAttributedString, size: CGSize) -> CGImage? {
        let scale: CGFloat = 2.0
        let pxW = max(1, Int(ceil(size.width * scale)))
        let pxH = max(1, Int(ceil(size.height * scale)))

        guard let ctx = CGContext(
            data: nil,
            width: pxW,
            height: pxH,
            bitsPerComponent: 8,
            bytesPerRow: pxW * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx
        ctx.scaleBy(x: scale, y: scale)

        text.draw(with: CGRect(origin: .zero, size: size), options: [.usesLineFragmentOrigin, .usesFontLeading])

        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }
}
