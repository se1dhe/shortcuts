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

        // 3. Вступительная золотая линия и философский слоган (0.0с – 3.2с)
        let introTaglineLayer = buildIntroTaglineLayer(
            renderSize: renderSize,
            concept: concept,
            conceptY: conceptY,
            totalDuration: calculatedTotalDuration
        )
        rootLayer.addSublayer(introTaglineLayer)

        // 4. Элегантные экранные карточки смены акта (Act Transition Cards)
        let actCardsLayer = buildActTransitionCardsLayer(
            renderSize: renderSize,
            concept: concept,
            acts: acts,
            totalDuration: calculatedTotalDuration
        )
        rootLayer.addSublayer(actCardsLayer)

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

        // Плавный Cold Open Fade-In (0.0 -> 0.8с) и затухание в последние 2.5 секунды
        let outroStartTime = max(0.0, totalDuration - 2.5)
        let kFadeIn = min(0.8 / t, 0.08)
        let kOutroStart = max(kFadeIn + 0.01, outroStartTime / t)

        let anim = CAKeyframeAnimation(keyPath: "opacity")
        anim.values = [0.0, 1.0, 1.0, 0.0]
        anim.keyTimes = [
            NSNumber(value: 0.0),
            NSNumber(value: kFadeIn),
            NSNumber(value: kOutroStart),
            NSNumber(value: 1.0)
        ]
        anim.duration = t
        anim.beginTime = AVCoreAnimationBeginTimeAtZero
        anim.fillMode = .both
        anim.isRemovedOnCompletion = false
        layer.add(anim, forKey: "centralConceptFade")

        return (layer, conceptY, layerH)
    }

    // MARK: - 2. Плавные синхронные субтитры реплик под концептом

    // MARK: - 2. Плавные синхронные субтитры реплик под концептом

    private func chunkTimedPhrases(_ phrases: [TimedSubtitlePhrase]) -> [TimedSubtitlePhrase] {
        var result: [TimedSubtitlePhrase] = []
        for phrase in phrases {
            let clean = phrase.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, phrase.end > phrase.start else { continue }
            let words = clean.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            if words.count <= 5 && clean.count <= 38 {
                result.append(phrase)
                continue
            }

            // Разбиваем длинную фразу на ритмичные порции по 3-5 слов (кино-ритм)
            var chunks: [[String]] = []
            var currentChunk: [String] = []
            var currentLen = 0

            for word in words {
                if !currentChunk.isEmpty && (currentChunk.count >= 4 || currentLen + word.count + 1 > 34) {
                    chunks.append(currentChunk)
                    currentChunk = [word]
                    currentLen = word.count
                } else {
                    currentChunk.append(word)
                    currentLen += word.count + 1
                }
            }
            if !currentChunk.isEmpty {
                chunks.append(currentChunk)
            }

            let totalChars = max(1, clean.count)
            let totalDur = phrase.end - phrase.start
            var runningTime = phrase.start

            for chunk in chunks {
                let chunkText = chunk.joined(separator: " ")
                let chunkFraction = Double(chunkText.count) / Double(totalChars)
                let chunkDur = max(0.45, totalDur * chunkFraction)
                let chunkEnd = min(phrase.end, runningTime + chunkDur)
                if chunkEnd > runningTime {
                    result.append(TimedSubtitlePhrase(start: runningTime, end: chunkEnd, text: chunkText))
                }
                runningTime = chunkEnd
            }
        }
        return result
    }

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

        let maxTextWidth = min(W * 0.75, 960.0)
        let chunked = chunkTimedPhrases(timedPhrases)

        for phrase in chunked {
            let cleanText = phrase.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanText.isEmpty, phrase.end > phrase.start else { continue }
            // Не показываем субтитры во время вступительной заставки (0.0-4.5с), чтобы не перекрывать тезис
            guard phrase.end > 4.5 else { continue }

            let subStr = NSAttributedString(string: cleanText.uppercased(), attributes: subAttrs)
            let boundingRect = subStr.boundingRect(
                with: CGSize(width: maxTextWidth, height: 200.0),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
            let subW = min(W * 0.85, max(120.0, ceil(boundingRect.width) + 36.0))
            let subH = max(36.0, ceil(boundingRect.height) + 16.0)

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
            let maxEndTime = max(pStart + 0.35, totalDuration - 2.0)
            let pEnd = min(max(phrase.end, pStart + 0.35), maxEndTime)
            guard pEnd > pStart else { continue }
            let phraseDuration = pEnd - pStart
            let fadeDuration = min(0.10, phraseDuration * 0.20)

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

        // Золотая акцентная черта строго под словом концепта
        let accentColor = NSColor(hex: concept.accentColorHex)?.cgColor ?? CGColor(srgbRed: 0.96, green: 0.82, blue: 0.13, alpha: 1.0)
        let lineW: CGFloat = 140.0
        let lineY = conceptY - 14.0
        let lineLayer = CALayer()
        lineLayer.frame = CGRect(x: (W - lineW) / 2.0, y: lineY, width: lineW, height: 2.5)
        lineLayer.backgroundColor = accentColor
        lineLayer.cornerRadius = 1.25
        lineLayer.shadowColor = CGColor(gray: 0, alpha: 0.8)
        lineLayer.shadowRadius = 4.0
        lineLayer.shadowOffset = CGSize(width: 0, height: -1.0)
        container.addSublayer(lineLayer)

        // Подзаголовок / тезис размещается строго ПОД золотой чертой с зазором
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
            let maxTaglineW = min(W * 0.75, 960.0)
            let boundingRect = subStr.boundingRect(
                with: CGSize(width: maxTaglineW, height: 160.0),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
            let subW = min(W * 0.85, ceil(boundingRect.width) + 40.0)
            let subH = ceil(boundingRect.height) + 16.0

            // Размещаем под линией с отступом 14.0px
            let subY = lineY - subH - 14.0
            let subLayer = CALayer()
            subLayer.frame = CGRect(x: (W - subW) / 2.0, y: subY, width: subW, height: subH)
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

    // MARK: - 4. Карточки смены драматургических актов (Act Transition Cards)

    private func buildActTransitionCardsLayer(
        renderSize: CGSize,
        concept: ThematicConcept,
        acts: [LongformAct],
        totalDuration: Double
    ) -> CALayer {
        let root = CALayer()
        root.frame = CGRect(origin: .zero, size: renderSize)
        let t = max(totalDuration, 5.0)
        let W = renderSize.width
        let H = renderSize.height

        let accentColor = NSColor(hex: concept.accentColorHex) ?? NSColor(hex: "#FFE45C") ?? .yellow
        let romanNumerals = ["I", "II", "III", "IV", "V", "VI"]

        var currentTimelineOffset: Double = 2.5 // Синхронизировано с introPadding (Cold Open)

        for (index, act) in acts.enumerated() {
            let actDuration = act.duration
            let actStartTimeline = currentTimelineOffset
            currentTimelineOffset += actDuration

            // Титры для последующих актов (начиная со второго: Акт II, III, IV), чтобы не перекрывать вступительный интро-слоган
            guard index > 0, actStartTimeline < totalDuration else { continue }

            let roman = (index < romanNumerals.count) ? romanNumerals[index] : "\(index + 1)"
            let actPartText = "— ЧАСТЬ \(roman) —"
            let cleanedTitle = act.title.trimmingCharacters(in: CharacterSet(charactersIn: "«»\" ")).uppercased()
            let actTitleText = "«\(cleanedTitle)»"

            // 1. Надстрочник части (золотой акцентный, разрядка 5.0, Russo One 18pt)
            let partFont = SubtitleRenderer.resolveFont(name: "RussoOne-Regular", size: 18.0, fallback: .heavy)
            let paragraphCenter = NSMutableParagraphStyle()
            paragraphCenter.alignment = .center

            let partShadow = NSShadow()
            partShadow.shadowColor = NSColor.black.withAlphaComponent(0.92)
            partShadow.shadowBlurRadius = 8.0
            partShadow.shadowOffset = CGSize(width: 0, height: -2.0)

            let partAttrs: [NSAttributedString.Key: Any] = [
                .font: partFont,
                .foregroundColor: accentColor,
                .paragraphStyle: paragraphCenter,
                .shadow: partShadow,
                .kern: 5.0
            ]
            let partAttributed = NSAttributedString(string: actPartText, attributes: partAttrs)
            let partSize = partAttributed.size()

            // 2. Название главы (монументальный белый Russo One 34pt, разрядка 3.5, глубокая кино-тень)
            let titleFont = SubtitleRenderer.resolveFont(name: "RussoOne-Regular", size: 34.0, fallback: .heavy)
            let titleShadow = NSShadow()
            titleShadow.shadowColor = NSColor.black.withAlphaComponent(0.98)
            titleShadow.shadowBlurRadius = 16.0
            titleShadow.shadowOffset = CGSize(width: 0, height: -3.0)

            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: titleFont,
                .foregroundColor: NSColor.white,
                .strokeColor: NSColor.black,
                .strokeWidth: -2.0,
                .paragraphStyle: paragraphCenter,
                .shadow: titleShadow,
                .kern: 3.5
            ]
            let titleAttributed = NSAttributedString(string: actTitleText, attributes: titleAttrs)
            let titleBounding = titleAttributed.boundingRect(
                with: CGSize(width: W * 0.85, height: 200.0),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
            let titleSize = CGSize(width: ceil(titleBounding.width) + 16.0, height: ceil(titleBounding.height) + 8.0)

            // Контейнер без рамок и без плашек (чистая кино-типографика)
            let containerW = max(partSize.width, titleSize.width) + 40.0
            let lineWidth: CGFloat = 120.0
            let lineHeight: CGFloat = 2.5
            let spacingPartToTitle: CGFloat = 6.0
            let spacingTitleToLine: CGFloat = 12.0
            let totalContentH = partSize.height + spacingPartToTitle + titleSize.height + spacingTitleToLine + lineHeight

            let containerX = (W - containerW) / 2.0
            let containerY = H * 0.77 // В верхней трети экрана

            let containerLayer = CALayer()
            containerLayer.frame = CGRect(x: containerX, y: containerY, width: containerW, height: totalContentH)
            containerLayer.opacity = 0.0

            // Слой надстрочника
            let partLayer = CALayer()
            partLayer.frame = CGRect(
                x: (containerW - partSize.width) / 2.0,
                y: totalContentH - partSize.height,
                width: partSize.width,
                height: partSize.height
            )
            partLayer.contentsScale = 2.0
            partLayer.contents = renderAttributedText(partAttributed, size: partSize)
            containerLayer.addSublayer(partLayer)

            // Слой названия главы
            let titleLayerY = partLayer.frame.minY - spacingPartToTitle - titleSize.height
            let titleLayer = CALayer()
            titleLayer.frame = CGRect(
                x: (containerW - titleSize.width) / 2.0,
                y: titleLayerY,
                width: titleSize.width,
                height: titleSize.height
            )
            titleLayer.contentsScale = 2.0
            titleLayer.contents = renderAttributedText(titleAttributed, size: titleSize)
            containerLayer.addSublayer(titleLayer)

            // Золотая акцентная линия под названием главы
            let lineLayerY = titleLayer.frame.minY - spacingTitleToLine - lineHeight
            let lineLayer = CALayer()
            lineLayer.frame = CGRect(
                x: (containerW - lineWidth) / 2.0,
                y: lineLayerY,
                width: lineWidth,
                height: lineHeight
            )
            lineLayer.backgroundColor = accentColor.cgColor
            lineLayer.cornerRadius = lineHeight / 2.0
            lineLayer.shadowColor = CGColor(gray: 0, alpha: 0.9)
            lineLayer.shadowRadius = 6.0
            lineLayer.shadowOffset = CGSize(width: 0, height: -1.0)
            containerLayer.addSublayer(lineLayer)

            // Анимация показа: 3.0 секунды (0.4с fade-in, 2.2с hold, 0.4с fade-out)
            let tStart = actStartTimeline
            let cardDuration = 3.0
            let tEnd = min(totalDuration, tStart + cardDuration)
            guard tEnd > tStart else { continue }

            let k0 = max(0.0, (tStart - 0.01) / t)
            let k1 = min(1.0, (tStart + 0.40) / t)
            let k2 = max(k1, (tEnd - 0.40) / t)
            let k3 = min(1.0, tEnd / t)

            let anim = CAKeyframeAnimation(keyPath: "opacity")
            anim.values = [0.0, 0.0, 1.0, 1.0, 0.0, 0.0]
            anim.keyTimes = [
                NSNumber(value: 0.0),
                NSNumber(value: k0),
                NSNumber(value: k1),
                NSNumber(value: k2),
                NSNumber(value: k3),
                NSNumber(value: 1.0)
            ]
            anim.duration = t
            anim.beginTime = AVCoreAnimationBeginTimeAtZero
            anim.fillMode = .both
            anim.isRemovedOnCompletion = false
            containerLayer.add(anim, forKey: "actTypography_\(index)")

            root.addSublayer(containerLayer)
        }

        return root
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
