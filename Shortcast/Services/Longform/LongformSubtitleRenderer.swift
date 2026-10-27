import AppKit
import AVFoundation
import CoreGraphics
import os
import QuartzCore

// MARK: - WCAG 2.1 контраст (чистая арифметика: без CALayer и без графического контекста)

extension Double {
    /// Относительная светлота sRGB по WCAG 2.1 (каналы в 0...1)
    static func wcagRelativeLuminance(red: Double, green: Double, blue: Double) -> Double {
        func linearize(_ channel: Double) -> Double {
            channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linearize(red) + 0.7152 * linearize(green) + 0.0722 * linearize(blue)
    }

    /// Контраст foreground/background по WCAG 2.1: (L_max + 0.05) / (L_min + 0.05)
    static func wcagContrast(foregroundL: Double, backgroundL: Double) -> Double {
        let high = Swift.max(foregroundL, backgroundL)
        let low = Swift.min(foregroundL, backgroundL)
        return (high + 0.05) / (low + 0.05)
    }

    /// Какая светлота нужна тексту, чтобы добить контраст target против фона backgroundL
    static func minimumLuminance(forContrast target: Double, against backgroundL: Double) -> Double {
        Swift.min(Swift.max(target * (backgroundL + 0.05) - 0.05, 0.0), 1.0)
    }
}

extension String {
    /// Светлота тёмного кинокадра под наложенными титрами (запас на тёмные сцены фильма)
    static let cinemaFrameLuminance: Double = 0.02
    /// Планка WCAG AA для акцентного текста поверх произвольного кадра
    static let accentMinContrast: Double = 4.5

    /// hex → sRGB 0...1 напрямую, без конвертаций NSColorSpace (иначе тесты не точны)
    static func srgbComponents(hex: String) -> (red: Double, green: Double, blue: Double)? {
        let clean = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard clean.count == 6, let value = UInt64(clean, radix: 16) else { return nil }
        return (
            red: Double((value >> 16) & 0xFF) / 255.0,
            green: Double((value >> 8) & 0xFF) / 255.0,
            blue: Double(value & 0xFF) / 255.0
        )
    }

    /// Светлота цвета из hex по WCAG 2.1
    static func wcagLuminance(hex: String) -> Double? {
        guard let rgb = srgbComponents(hex: hex) else { return nil }
        return Double.wcagRelativeLuminance(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    /// Акцентный цвет, поднятый до WCAG AA 4.5:1 против тёмного кадра.
    /// Тон (hue) сохраняется, растёт яркость HSB, насыщенность приглушается на (B_new - B_old) * 0.35.
    /// Если контраст уже в норме — цвет возвращается БЕЗ изменений; если планка недостижима —
    /// возвращается ближайший достижимый вариант при B = 1.0.
    static func legibleAccent(
        hex: String,
        backgroundL: Double = String.cinemaFrameLuminance,
        minContrast: Double = String.accentMinContrast
    ) -> NSColor {
        let fallback = NSColor(hex: "#FFE45C") ?? .yellow
        guard let start = srgbComponents(hex: hex) else { return fallback }

        let targetL = Double.minimumLuminance(forContrast: minContrast, against: backgroundL)
        let startL = Double.wcagRelativeLuminance(red: start.red, green: start.green, blue: start.blue)
        if startL >= targetL {
            // Комплаентный акцент не трогаем вообще — он обязан вернуться байт-в-байт
            return NSColor(hex: hex) ?? fallback
        }

        let hsb = longformHSB(red: start.red, green: start.green, blue: start.blue)
        var closest = start
        let steps = 100
        for step in 0...steps {
            let brightness = hsb.brightness + (1.0 - hsb.brightness) * Double(step) / Double(steps)
            let saturation = Swift.max(0.0, hsb.saturation - (brightness - hsb.brightness) * 0.35)
            let candidate = longformRGB(hue: hsb.hue, saturation: saturation, brightness: brightness)
            closest = candidate
            let luminance = Double.wcagRelativeLuminance(red: candidate.red, green: candidate.green, blue: candidate.blue)
            if luminance >= targetL {
                return NSColor(
                    red: CGFloat(candidate.red),
                    green: CGFloat(candidate.green),
                    blue: CGFloat(candidate.blue),
                    alpha: 1.0
                )
            }
        }
        // Цель недостижима (B уже 1.0) — отдаём самый светлый достигнутый оттенок
        return NSColor(red: CGFloat(closest.red), green: CGFloat(closest.green), blue: CGFloat(closest.blue), alpha: 1.0)
    }
}

/// HSB в нормированном sRGB-пространстве (0...1), вручную — чтобы не зависеть от NSColorSpace
fileprivate func longformHSB(red: Double, green: Double, blue: Double) -> (hue: Double, saturation: Double, brightness: Double) {
    let maxC = max(red, green, blue)
    let minC = min(red, green, blue)
    let delta = maxC - minC
    var hue = 0.0
    if delta > 0 {
        if maxC == red {
            hue = ((green - blue) / delta).truncatingRemainder(dividingBy: 6.0)
        } else if maxC == green {
            hue = (blue - red) / delta + 2.0
        } else {
            hue = (red - green) / delta + 4.0
        }
        hue /= 6.0
        if hue < 0 { hue += 1.0 }
    }
    return (hue, maxC > 0 ? delta / maxC : 0.0, maxC)
}

/// Обратная конверсия HSB (0...1) → sRGB (0...1)
fileprivate func longformRGB(hue: Double, saturation: Double, brightness: Double) -> (red: Double, green: Double, blue: Double) {
    let h = (hue - floor(hue)) * 6.0
    let sector = Int(floor(h)) % 6
    let f = h - floor(h)
    let p = brightness * (1.0 - saturation)
    let q = brightness * (1.0 - saturation * f)
    let t = brightness * (1.0 - saturation * (1.0 - f))
    switch sector {
    case 0: return (red: brightness, green: t, blue: p)
    case 1: return (red: q, green: brightness, blue: p)
    case 2: return (red: p, green: brightness, blue: t)
    case 3: return (red: p, green: q, blue: brightness)
    case 4: return (red: t, green: p, blue: brightness)
    default: return (red: brightness, green: p, blue: q)
    }
}

/// Кинематографический отрисовщик титров и оверлеев в стиле канала @prrodan,
/// но с фирменной типографикой, шрифтами и стилем Shortcast Cinema (SOLID):
/// 1. Центральное якорное слово концепта (например, "ТЕРПЕНИЕ"):
///    - Постоянно отображается по центру экрана на протяжении всего фильма (opacity 1.0)
///    - Фирменная типографика Shortcast: шрифт Russo One, кегль 44pt на эталонных 1080 строках
///      с авто-усадкой (пол не ниже 30pt), чтобы слово никогда не занимало больше 60% ширины кадра;
///      широкий кинематографический трекинг (kern 3.0), офф-вайт (#F5F5F7),
///      тонкая контрастная окантовка (-2.2) и глубокая кино-тень (blur 10.0)
/// 2. Плавные синхронные субтитры реплик под концептом:
///    - Располагаются строго под якорным словом по центру
///    - Плавное появление (fade-in 0.10с) и мягкое затухание (fade-out 0.10с) по таймкодам реплик
///    - Фирменный акцент Shortcast: Russo One 32pt, четкая обводка (-3.6) и кино-тень;
///      акцентный цвет принудительно поднимается до WCAG AA 4.5:1 против кадра (плашки запрещены)
/// 3. Вступительный подзаголовок темы (Intro Hook, 0.0с – 4.5с):
///    - Золотая линия и философский слоган (20pt) под центральным словом, плавно затухающие к 4.5с
/// 4. Маркеры драматургических актов (Act Chapter Cards):
///    - Карточки смены актов («— ЧАСТЬ II —» 20pt с обводкой + название 34pt), чистый текст без рамок
///
/// Все кегли, обводки, трекинги, тени и отступы объявлены один раз в разделе
/// «Единый источник типографики» и масштабируются множителем k = renderSize.height / 1080.0,
/// поэтому оверлей и превью (`renderPreviewImage`) не могут разъехаться по шрифтам.
final class LongformSubtitleRenderer: LongformSubtitleRenderingProtocol, Sendable {

    private static let logger = Logger(subsystem: "app.shortcast", category: "LongformLogoWatermark")

    // MARK: - Единый источник типографики (его зовут ОБА пути: оверлей и превью)

    /// Эталонный кегль якорного слова темы при 1080 строках (исторически 56pt — визуально гигант)
    static let themeBasePointSize: Double = 44.0
    /// Пол авто-усадки якорного слова: ниже не опускаемся даже для очень длинного слова
    static let themeMinPointSize: Double = 30.0
    /// Якорное слово никогда не занимает больше этой доли ширины кадра
    static let themeMaxWidthScale: Double = 0.60
    /// Эталонный кегль субтитров при 1080 строках
    static let captionBasePointSize: Double = 32.0
    /// Эталонный кегль вступительного слогана
    static let taglineBasePointSize: Double = 20.0
    /// Эталонный кегль надстрочника карточки акта («— ЧАСТЬ II —»)
    static let actOverlineBasePointSize: Double = 20.0
    /// Эталонный кегль названия главы в карточке акта
    static let actTitleBasePointSize: Double = 34.0
    /// Эталонный кегль финального CTA
    static let ctaBasePointSize: Double = 30.0

    /// Запас под самой нижней строкой субтитров (в единицах `k`): там живёт слоган интро
    /// (20·k кегль + отступы) и нижняя золотая черта. Знак канала отступает на эту величину,
    /// чтобы не сесть на слоган. Единый источник для оверлея, превью и теста.
    static let subtitleLogoClearance: CGFloat = 64.0

    /// Масштаб всей типографики: k = высота кадра / 1080 (1920x1080 -> k == 1.0)
    static func scaleFactor(renderSize: CGSize) -> Double {
        Double(renderSize.height) / 1080.0
    }

    static func themePointSize(k: Double) -> Double { themeBasePointSize * k }
    static func captionPointSize(k: Double) -> Double { captionBasePointSize * k }
    static func taglinePointSize(k: Double) -> Double { taglineBasePointSize * k }
    static func actOverlinePointSize(k: Double) -> Double { actOverlineBasePointSize * k }
    static func actTitlePointSize(k: Double) -> Double { actTitleBasePointSize * k }
    static func ctaPointSize(k: Double) -> Double { ctaBasePointSize * k }

    /// Шрифт якорного слова для уже разрешённого (после авто-усадки) кегля
    static func themeFont(pointSize: Double) -> NSFont {
        SubtitleRenderer.resolveFont(name: "RussoOne-Regular", size: CGFloat(pointSize), fallback: .heavy)
    }

    static func themeFont(k: Double) -> NSFont { themeFont(pointSize: themePointSize(k: k)) }

    static func captionFont(k: Double) -> NSFont {
        SubtitleRenderer.resolveFont(name: "RussoOne-Regular", size: CGFloat(captionPointSize(k: k)), fallback: .heavy)
    }

    static func taglineFont(k: Double) -> NSFont {
        NSFont.systemFont(ofSize: CGFloat(taglinePointSize(k: k)), weight: .medium)
    }

    static func actOverlineFont(k: Double) -> NSFont {
        SubtitleRenderer.resolveFont(name: "RussoOne-Regular", size: CGFloat(actOverlinePointSize(k: k)), fallback: .heavy)
    }

    static func actTitleFont(k: Double) -> NSFont {
        SubtitleRenderer.resolveFont(name: "RussoOne-Regular", size: CGFloat(actTitlePointSize(k: k)), fallback: .heavy)
    }

    static func ctaFont(k: Double) -> NSFont {
        SubtitleRenderer.resolveFont(name: "RussoOne-Regular", size: CGFloat(ctaPointSize(k: k)), fallback: .heavy)
    }

    private static func centerParagraph() -> NSMutableParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        return paragraph
    }

    static func cinematicShadow(blur: Double, offsetY: Double, alpha: CGFloat) -> NSShadow {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(alpha)
        shadow.shadowBlurRadius = CGFloat(blur)
        shadow.shadowOffset = CGSize(width: 0, height: offsetY)
        return shadow
    }

    /// Атрибуты якорного слова темы (офф-вайт #F5F5F7: 13,8:1 против тёмного кадра с L = 0,02 — WCAG AA проходит сам, клампинг не нужен)
    static func themeAttributes(pointSize: Double, k: Double) -> [NSAttributedString.Key: Any] {
        [
            .font: themeFont(pointSize: pointSize),
            .foregroundColor: NSColor(hex: "#F5F5F7") ?? .white,
            .strokeColor: NSColor.black,
            .strokeWidth: CGFloat(-2.2 * k),
            .paragraphStyle: centerParagraph(),
            .shadow: cinematicShadow(blur: 10.0 * k, offsetY: -2.0 * k, alpha: 0.92),
            .kern: CGFloat(3.0 * k)
        ]
    }

    /// Атрибуты субтитра: акцент обязательно проходит WCAG-клампинг против тёмного кадра
    static func captionAttributes(k: Double, accentHex: String) -> [NSAttributedString.Key: Any] {
        [
            .font: captionFont(k: k),
            .foregroundColor: String.legibleAccent(hex: accentHex),
            .strokeColor: NSColor.black,
            .strokeWidth: CGFloat(-3.6 * k),
            .paragraphStyle: centerParagraph(),
            .shadow: cinematicShadow(blur: 10.0 * k, offsetY: -2.0 * k, alpha: 0.95),
            .kern: CGFloat(1.0 * k)
        ]
    }

    /// Атрибуты вступительного слогана (офф-вайт #DCDCDE с тонкой обводкой)
    static func taglineAttributes(k: Double) -> [NSAttributedString.Key: Any] {
        [
            .font: taglineFont(k: k),
            .foregroundColor: NSColor(hex: "#DCDCDE") ?? .lightGray,
            .strokeColor: NSColor.black,
            .strokeWidth: CGFloat(-1.4 * k),
            .paragraphStyle: centerParagraph(),
            .shadow: cinematicShadow(blur: 10.0 * k, offsetY: -2.0 * k, alpha: 0.90),
            .kern: CGFloat(1.8 * k)
        ]
    }

    /// Атрибуты надстрочника акта: раньше был единственный текст в app вообще без обводки
    static func actOverlineAttributes(k: Double, accentHex: String) -> [NSAttributedString.Key: Any] {
        [
            .font: actOverlineFont(k: k),
            .foregroundColor: String.legibleAccent(hex: accentHex),
            .strokeColor: NSColor.black,
            .strokeWidth: CGFloat(-2.0 * k),
            .paragraphStyle: centerParagraph(),
            .shadow: cinematicShadow(blur: 8.0 * k, offsetY: -2.0 * k, alpha: 0.92),
            .kern: CGFloat(5.0 * k)
        ]
    }

    static func actTitleAttributes(k: Double) -> [NSAttributedString.Key: Any] {
        [
            .font: actTitleFont(k: k),
            .foregroundColor: NSColor.white,
            .strokeColor: NSColor.black,
            .strokeWidth: CGFloat(-2.4 * k),
            .paragraphStyle: centerParagraph(),
            .shadow: cinematicShadow(blur: 16.0 * k, offsetY: -3.0 * k, alpha: 0.98),
            .kern: CGFloat(3.0 * k)
        ]
    }

    /// Атрибуты финального CTA: белый Russo One с той же обводкой/тенью, что и карточка акта
    static func ctaAttributes(k: Double) -> [NSAttributedString.Key: Any] {
        [
            .font: ctaFont(k: k),
            .foregroundColor: NSColor.white,
            .strokeColor: NSColor.black,
            .strokeWidth: CGFloat(-2.2 * k),
            .paragraphStyle: centerParagraph(),
            .shadow: cinematicShadow(blur: 14.0 * k, offsetY: -3.0 * k, alpha: 0.96),
            .kern: CGFloat(1.5 * k)
        ]
    }

    /// Фактическая ширина якорного слова при данном кегле (со штатным трекингом и обводкой)
    static func measuredThemeWidth(word: String, pointSize: Double, k: Double) -> Double {
        let str = NSAttributedString(string: word.uppercased(), attributes: themeAttributes(pointSize: pointSize, k: k))
        return Double(str.size().width)
    }

    /// Авто-усадка якорного слова: стартовый кегль themePointSize(k), пока ширина слова
    /// не влезет в maxWidth; пол — themeMinPointSize·k (подход тот же, что в LongformThumbnailGenerator).
    static func resolvedThemePointSize(word: String, k: Double, maxWidth: Double) -> Double {
        let minSize = themeMinPointSize * k
        let cap = max(1.0, maxWidth)
        var pointSize = themePointSize(k: k)
        for _ in 0..<6 {
            let width = measuredThemeWidth(word: word, pointSize: pointSize, k: k)
            if width <= cap || pointSize <= minSize { break }
            pointSize = max(minSize, pointSize * (cap / width))
        }
        return pointSize
    }

    /// Максимальная ширина якорного слова в данном кадре (60% ширины кадра)
    static func themeMaxWidth(renderSizeWidth: Double) -> Double {
        renderSizeWidth * themeMaxWidthScale
    }

    /// Нижняя граница слоя слова темы (тот же расчёт, что в `buildCentralConceptLayer`):
    /// слой = высота текста + 20·k запаса, строго по центру кадра. Нужна знаку канала и тестам.
    static func conceptBottomY(renderSize: CGSize, textSize: CGSize, k: Double) -> CGFloat {
        (renderSize.height - (textSize.height + CGFloat(20.0 * k))) / 2.0
    }

    /// Авто-усадка названия акта: старт `actTitlePointSize(k)` (34·k), пол 24·k, текст обязан
    /// влезть в `maxWidth` НЕ БОЛЕЕ ЧЕМ В ДВЕ СТРОКИ — при 34pt вторая строка названия
    /// залезает в верхнюю литербокс-полосу карточки. Измерение — теми же атрибутами, что
    /// рисует карточка (Russo One, трекинг 3.0·k, обводка −2.4·k); передавать ровно тот
    /// текст, что рисуется, вместе с кавычками-«ёлочками». Идеал усадки общий с
    /// `resolvedThemePointSize`, чтобы в repo оставался ОДИН приём «усаживаем, чтобы влезло».
    static func resolvedActTitlePointSize(text: String, k: Double, maxWidth: Double) -> Double {
        let minSize = 24.0 * k
        let cap = max(1.0, maxWidth)
        let title = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return actTitlePointSize(k: k) }

        var pointSize = actTitlePointSize(k: k)
        for _ in 0..<8 {
            let font = SubtitleRenderer.resolveFont(
                name: "RussoOne-Regular",
                size: CGFloat(pointSize),
                fallback: .heavy
            )
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.white,
                .strokeColor: NSColor.black,
                .strokeWidth: CGFloat(-2.4 * k),
                .paragraphStyle: paragraph,
                .kern: CGFloat(3.0 * k)
            ]
            let bounding = NSAttributedString(string: title, attributes: attributes).boundingRect(
                with: CGSize(width: cap, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
            // NSFont не отдаёт lineHeight (это UIFont-API): высота строки берём из
            // boundingRectForFont, ровно столько занимает одна строка этим шрифтом
            let lineHeight = ceil(font.boundingRectForFont.height)
            if bounding.height <= lineHeight * 2.0 + 1.0 || pointSize <= minSize { break }
            pointSize = max(minSize, pointSize - 2.0 * k)
        }
        return pointSize
    }

    func makeOverlayLayer(
        renderSize: CGSize,
        concept: ThematicConcept,
        timedPhrases: [TimedSubtitlePhrase],
        acts: [LongformAct] = [],
        actStartTimes: [Double] = [],
        totalDuration: Double = 0.0,
        layout: LongformOverlayLayout = LongformOverlayLayout(),
        hookText: String? = nil,
        ctaText: String? = nil
    ) async -> CALayer {
        let rootLayer = CALayer()
        rootLayer.frame = CGRect(origin: .zero, size: renderSize)
        rootLayer.isGeometryFlipped = false

        let calculatedTotalDuration = max(totalDuration, timedPhrases.last?.end ?? 300.0)
        // Единый множитель типографики для всего оверлея (1920x1080 -> k = 1.0)
        let k = Self.scaleFactor(renderSize: renderSize)

        let hook = hookText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasHook = !(hook ?? "").isEmpty
        let introEnd = hasHook ? 6.2 : 4.5

        // 1. Центральное якорное слово концепта (висит весь фильм, плавно растворяется в финале)
        let (conceptLayer, conceptY, _) = buildCentralConceptLayer(
            renderSize: renderSize,
            k: k,
            concept: concept,
            totalDuration: calculatedTotalDuration
        )
        rootLayer.addSublayer(conceptLayer)

        // 2. Плавные синхронные субтитры реплик персонажей прямо под концептом
        let (subtitlePhrasesLayer, subtitleBottom) = buildSynchronizedSubtitlesLayer(
            renderSize: renderSize,
            k: k,
            concept: concept,
            conceptY: conceptY,
            timedPhrases: timedPhrases,
            totalDuration: calculatedTotalDuration,
            introEnd: introEnd
        )
        rootLayer.addSublayer(subtitlePhrasesLayer)

        // 3. Вступительная золотая линия и хук/философский слоган (с хуком — до 6.0с)
        let introTaglineLayer = buildIntroTaglineLayer(
            renderSize: renderSize,
            k: k,
            concept: concept,
            conceptY: conceptY,
            totalDuration: calculatedTotalDuration,
            hookText: hasHook ? hook : nil
        )
        rootLayer.addSublayer(introTaglineLayer)

        // 4. Элегантные экранные карточки смены акта (Act Transition Cards)
        let actCardsLayer = buildActTransitionCardsLayer(
            renderSize: renderSize,
            k: k,
            concept: concept,
            acts: acts,
            actStartTimes: actStartTimes,
            totalDuration: calculatedTotalDuration
        )
        rootLayer.addSublayer(actCardsLayer)

        // 5. Финальный CTA — только когда задан; иначе слой-состав остаётся прежним (4 подслоя)
        if let cta = ctaText?.trimmingCharacters(in: .whitespacesAndNewlines), !cta.isEmpty {
            let ctaLayer = buildFinalCTALayer(
                renderSize: renderSize,
                k: k,
                concept: concept,
                ctaText: cta,
                totalDuration: calculatedTotalDuration
            )
            rootLayer.addSublayer(ctaLayer)
        }

        // 6. Знак канала — ВСЕГДА добавляется последней и только если
        // для неё реально есть место. Раньше вставать в середину нельзя: тесты читают
        // sublayers по позициям, а у слоя-картинки ненулевой `contents`.
        appendChannelLogoBand(to: rootLayer, renderSize: renderSize,
                              subtitleBottom: subtitleBottom, layout: layout)

        return rootLayer
    }

    /// Единственная точка, решающая «рисовать ли знак в эссе».
    /// Места нет — не рисуем ничего (никаких самодельных эмблем) и пишем ОДНО notice на рендер.
    private func appendChannelLogoBand(
        to rootLayer: CALayer,
        renderSize: CGSize,
        subtitleBottom: CGFloat,
        layout: LongformOverlayLayout
    ) {
        guard let style = layout.channelLogo else { return }
        let rect = ChannelLogoPlacement.essay(
            renderSize: renderSize,
            subtitleBottom: subtitleBottom,
            bottomBarHeight: layout.bottomBarHeight,
            style: style
        )
        guard let rect else {
            Self.reportMissingLogoRoom(renderSize: renderSize, subtitleBottom: subtitleBottom,
                                       bottomBarHeight: layout.bottomBarHeight, style: style)
            return
        }
        guard let logoLayer = ChannelLogo.makeLayer(frame: rect, renderSize: renderSize,
                                                   opacity: style.opacity) else { return }
        rootLayer.addSublayer(logoLayer)
    }

    /// Одна строка на рендер: молча обесбренденное видео — худший из вариантов,
    /// но и писать по строке на каждый из сотен кадров — шум.
    static func reportMissingLogoRoom(renderSize: CGSize, subtitleBottom: CGFloat,
                                      bottomBarHeight: CGFloat, style: ChannelLogoStyle) {
        let height = renderSize.height
        let k = height / 1080.0
        let gap = style.gapBelowSubtitles * k
        let floorY = bottomBarHeight + style.edgeInset * k
        let available = subtitleBottom - gap - floorY
        logger.notice("ChannelLogo skipped in essay: needs \(Int(style.sizeFraction * height))px, free \(Int(available))px (subtitleBottom \(Int(subtitleBottom))px, bottomBar \(Int(bottomBarHeight))px, gap \(Int(gap))px, floor \(Int(floorY))px, min \(Int(style.minSizeFraction * height))px)")
    }

    // MARK: - 1. Центральное якорное слово концепта (Shortcast Cinema Typography)

    private func buildCentralConceptLayer(
        renderSize: CGSize,
        k: Double,
        concept: ThematicConcept,
        totalDuration: Double
    ) -> (layer: CALayer, conceptY: CGFloat, conceptH: CGFloat) {
        let W = renderSize.width
        let t = max(totalDuration, 5.0)

        // Кегль 44pt на эталонных 1080 строках + авто-усадка, чтобы слово не лезло за 60% ширины кадра
        let upperWord = concept.word.uppercased()
        let maxWordWidth = Self.themeMaxWidth(renderSizeWidth: Double(W))
        let themeSize = Self.resolvedThemePointSize(word: upperWord, k: k, maxWidth: maxWordWidth)
        let attrs = Self.themeAttributes(pointSize: themeSize, k: k)

        let conceptStr = NSAttributedString(string: upperWord, attributes: attrs)
        let textSize = conceptStr.size()
        let layerW = textSize.width + CGFloat(40.0 * k)
        let layerH = textSize.height + CGFloat(20.0 * k)

        // Строго по центру экрана
        let conceptX = (W - layerW) / 2.0
        let conceptY = Self.conceptBottomY(renderSize: renderSize, textSize: textSize, k: k)

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

    /// Разбивает текст на экранные строки в соответствии с кино-ритмом Shortcast Cinema
    public static func formatScreenLines(text: String, maxChars: Int = 34, maxWords: Int = 4) -> [String] {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return [] }

        let rawLines = clean.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var resultLines: [String] = []

        for rawLine in rawLines {
            let words = rawLine.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            if words.count <= maxWords && rawLine.count <= maxChars {
                resultLines.append(rawLine.uppercased())
                continue
            }

            var currentChunk: [String] = []
            var currentLen = 0

            for word in words {
                if !currentChunk.isEmpty && (currentChunk.count >= maxWords || (currentLen + word.count + 1) > maxChars) {
                    resultLines.append(currentChunk.joined(separator: " ").uppercased())
                    currentChunk = [word]
                    currentLen = word.count
                } else {
                    currentChunk.append(word)
                    currentLen += (currentChunk.count == 1 ? word.count : (word.count + 1))
                }
            }
            if !currentChunk.isEmpty {
                resultLines.append(currentChunk.joined(separator: " ").uppercased())
            }
        }

        return resultLines
    }

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

    // MARK: - Геометрия полосы субтитров (один расчёт для раскладки, знака канала и теста)

    /// Рамка слоя реплики: та же формула, что в цикле раскладки. Вынесена, чтобы полоса,
    /// из которой считается место под знак, и реальная раскладка не могли разъехаться.
    static func captionRect(textWidth: CGFloat, textHeight: CGFloat, renderSize: CGSize,
                            conceptY: CGFloat, k: Double) -> CGRect {
        let W = renderSize.width
        let subW = min(W * 0.85, max(CGFloat(120.0 * k), ceil(textWidth) + CGFloat(36.0 * k)))
        let subH = max(CGFloat(44.0 * k), ceil(textHeight) + CGFloat(16.0 * k))
        return CGRect(x: (W - subW) / 2.0, y: conceptY - subH - 18.0, width: subW, height: subH)
    }

    /// Полоса субтитров при заданном числе строк — тот же путь, что и в рендере.
    /// Чистая функция (без Layers и анимаций), чтобы тест проверял реальную раскладку, а не догадку.
    static func essaySubtitleBand(renderSize: CGSize, conceptY: CGFloat, lines: Int,
                                  accentHex: String = "#FFE45C") -> CGRect {
        let k = scaleFactor(renderSize: renderSize)
        let attrs = captionAttributes(k: k, accentHex: accentHex)
        let text = Array(repeating: "—", count: max(1, lines)).joined(separator: "\n")
        let measured = NSAttributedString(string: text, attributes: attrs)
            .boundingRect(with: CGSize(width: 10_000, height: 10_000),
                          options: [.usesLineFragmentOrigin, .usesFontLeading])
        return captionRect(textWidth: measured.width, textHeight: measured.height,
                           renderSize: renderSize, conceptY: conceptY, k: k)
    }

    /// Место под знак канала, которое оставляет раскладка субтитров при `lines` строках.
    /// Ровно та цепочка, что проходит `makeOverlayLayer`: полоса → запас на слоган → placement.
    static func essayLogoBand(renderSize: CGSize, conceptY: CGFloat, lines: Int,
                              bottomBarHeight: CGFloat = 0,
                              style: ChannelLogoStyle = .essay) -> CGRect? {
        let k = scaleFactor(renderSize: renderSize)
        let subtitleBottom = max(0, essaySubtitleBand(renderSize: renderSize, conceptY: conceptY, lines: lines).minY
                                    - subtitleLogoClearance * CGFloat(k))
        return ChannelLogoPlacement.essay(renderSize: renderSize, subtitleBottom: subtitleBottom,
                                          bottomBarHeight: bottomBarHeight, style: style)
    }

    /// Рамка карточки акта в той же системе координат (низ слева): знак канала обязан
    /// оставлять её свободной — это и проверяет тест коллизии.
    static func actCardY(renderSize: CGSize) -> CGFloat { renderSize.height * 0.77 }

    static func actCardRect(renderSize: CGSize, contentHeight: CGFloat = 120.0) -> CGRect {
        CGRect(x: 0, y: actCardY(renderSize: renderSize), width: renderSize.width, height: contentHeight)
    }

    private func buildSynchronizedSubtitlesLayer(
        renderSize: CGSize,
        k: Double,
        concept: ThematicConcept,
        conceptY: CGFloat,
        timedPhrases: [TimedSubtitlePhrase],
        totalDuration: Double,
        introEnd: Double = 4.5
    ) -> (layer: CALayer, subtitleBottom: CGFloat) {
        let container = CALayer()
        container.frame = CGRect(origin: .zero, size: renderSize)

        let W = renderSize.width
        let H = renderSize.height
        let t = max(totalDuration, 1.0)

        // Единый источник атрибутов: кегль 32pt·k + акцент, пропущенный через WCAG-клампинг
        let subAttrs = Self.captionAttributes(k: k, accentHex: concept.accentColorHex)

        let maxTextWidth = min(W * 0.78, CGFloat(1240.0 * k))
        let chunked = chunkTimedPhrases(timedPhrases)
        // Фактическая нижняя граница самой нижней реплики — знак канала отступает от неё,
        // а не от выдуманного запаса.
        var lowestCaptionY = CGFloat.greatestFiniteMagnitude

        for phrase in chunked {
            let cleanText = phrase.text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Фильтруем галлюцинации Whisper large-v3 до рендера:
            // «Sous-titres par LaVacheSquid», «Tekstet av Nicolai Winther»,
            // одиночные «♪» / «you» и прочие артефакты декодера не выжигаются на экран.
            guard !Self.isHallucinationLine(cleanText) else { continue }
            guard !cleanText.isEmpty, phrase.end > phrase.start else { continue }
            // Не показываем субтитры во время вступительной заставки (4.5с без хука, 6.2с с хуком),
            // чтобы не перекрывать тезис
            guard phrase.end > introEnd else { continue }

            let subStr = NSAttributedString(string: cleanText.uppercased(), attributes: subAttrs)
            let boundingRect = subStr.boundingRect(
                with: CGSize(width: maxTextWidth, height: 200.0),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )

            // Размещаем прямо под концептом (вниз от conceptY с безопасным отступом)
            let captionFrame = Self.captionRect(textWidth: boundingRect.width, textHeight: boundingRect.height,
                                                 renderSize: renderSize, conceptY: conceptY, k: k)

            let phraseLayer = CALayer()
            phraseLayer.frame = captionFrame
            lowestCaptionY = min(lowestCaptionY, captionFrame.minY)
            phraseLayer.contentsScale = 2.0
            phraseLayer.contents = renderAttributedText(subStr, size: phraseLayer.frame.size)
            phraseLayer.opacity = 0.0

            // Если фраза началась до окончания заставки, плавно включаем ее сразу после исчезновения заставки
            let pStart = max(phrase.start, introEnd + 0.05)
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

        // Реплик не было (например, всё вступление) — считаем полосу от одной строки по умолчанию.
        let referenceBottom: CGFloat
        if lowestCaptionY == .greatestFiniteMagnitude {
            referenceBottom = Self.essaySubtitleBand(renderSize: renderSize, conceptY: conceptY, lines: 1).minY
        } else {
            referenceBottom = lowestCaptionY
        }
        // Под полосой субтитров живёт слоган интро (шрифт 20·k + отступы): запас 64·k.
        return (container, max(0, referenceBottom - Self.subtitleLogoClearance * CGFloat(k)))
    }

    // MARK: - 3. Вступительный подзаголовок темы / хук (0.0с – 4.5с / 6.0с)

    private func buildIntroTaglineLayer(
        renderSize: CGSize,
        k: Double,
        concept: ThematicConcept,
        conceptY: CGFloat,
        totalDuration: Double,
        hookText: String? = nil
    ) -> CALayer {
        let container = CALayer()
        container.frame = CGRect(origin: .zero, size: renderSize)
        container.opacity = 0.0

        let W = renderSize.width
        let t = max(totalDuration, 5.0)
        let hook = hookText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasHook = !(hook ?? "").isEmpty

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

        // Подзаголовок / тезис / хук размещается строго ПОД золотой чертой с зазором
        let taglineText = hasHook ? hook! : (concept.tagline.isEmpty ? concept.philosophicalPremise : concept.tagline)
        if !taglineText.isEmpty {
            let subAttrs = Self.taglineAttributes(k: k)

            let subStr = NSAttributedString(string: taglineText, attributes: subAttrs)
            // Хук — 1–2 предложения: держим в пределах трёх строк, как и задумано карточкой
            let maxTaglineW = min(W * 0.75, CGFloat(960.0 * k))
            let maxTaglineH = hasHook ? CGFloat(3.0 * Self.taglinePointSize(k: k) * 1.6 + 16.0 * k) : CGFloat(160.0)
            let boundingRect = subStr.boundingRect(
                with: CGSize(width: maxTaglineW, height: maxTaglineH),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
            let subW = min(W * 0.85, ceil(boundingRect.width) + CGFloat(40.0 * k))
            let subH = ceil(boundingRect.height) + CGFloat(16.0 * k)

            // Размещаем под линией с отступом 14.0px
            let subY = lineY - subH - 14.0
            let subLayer = CALayer()
            subLayer.frame = CGRect(x: (W - subW) / 2.0, y: subY, width: subW, height: subH)
            subLayer.contentsScale = 2.0
            subLayer.contents = renderAttributedText(subStr, size: subLayer.frame.size)
            container.addSublayer(subLayer)
        }

        // Анимация: хук держится до 6.0с, прежний слоган — до 4.2с
        let tFadeIn = 0.8 / t
        let tHold = (hasHook ? 5.2 : 3.2) / t
        let tFadeOut = (hasHook ? 6.0 : 4.2) / t

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

    // MARK: - 5. Финальный CTA (последние ~4 секунды)

    private func buildFinalCTALayer(
        renderSize: CGSize,
        k: Double,
        concept: ThematicConcept,
        ctaText: String,
        totalDuration: Double
    ) -> CALayer {
        let container = CALayer()
        container.frame = CGRect(origin: .zero, size: renderSize)
        container.opacity = 0.0

        let W = renderSize.width
        let H = renderSize.height
        let t = max(totalDuration, 5.0)

        let accentColor = NSColor(hex: concept.accentColorHex)?.cgColor ?? CGColor(srgbRed: 0.96, green: 0.82, blue: 0.13, alpha: 1.0)
        let lineW = CGFloat(120.0 * k)
        let lineH: CGFloat = 2.5
        let textAttrs = Self.ctaAttributes(k: k)
        let textStr = NSAttributedString(string: ctaText.uppercased(), attributes: textAttrs)
        let maxTextW = min(W * 0.78, CGFloat(1100.0 * k))
        let bounding = textStr.boundingRect(
            with: CGSize(width: maxTextW, height: CGFloat(4.0 * Self.ctaPointSize(k: k) * 1.6)),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let textW = min(W * 0.88, ceil(bounding.width) + CGFloat(24.0 * k))
        let textH = ceil(bounding.height) + CGFloat(12.0 * k)

        // Нижняя треть кадра: не спорит с якорным словом по центру
        let blockY = H * 0.30
        let textY = blockY
        let lineY = textY + textH + CGFloat(14.0 * k)

        let lineLayer = CALayer()
        lineLayer.frame = CGRect(x: (W - lineW) / 2.0, y: lineY, width: lineW, height: lineH)
        lineLayer.backgroundColor = accentColor
        lineLayer.cornerRadius = lineH / 2.0
        lineLayer.shadowColor = CGColor(gray: 0, alpha: 0.9)
        lineLayer.shadowRadius = 6.0
        lineLayer.shadowOffset = CGSize(width: 0, height: -1.0)
        container.addSublayer(lineLayer)

        let textLayer = CALayer()
        textLayer.frame = CGRect(x: (W - textW) / 2.0, y: textY, width: textW, height: textH)
        textLayer.contentsScale = 2.0
        textLayer.contents = renderAttributedText(textStr, size: textLayer.frame.size)
        container.addSublayer(textLayer)

        // Появляется за 4.2с до конца, держится до -0.7с, гаснет ровно к концу
        let ctaStart = max(0.0, totalDuration - 4.2)
        let ctaHold = max(ctaStart, totalDuration - 0.7)
        let k0 = max(0.0, (ctaStart - 0.01) / t)
        let k1 = min(1.0, (ctaStart + 0.40) / t)
        let k2 = min(1.0, ctaHold / t)
        let k3 = min(1.0, max(k2, (totalDuration - 0.1) / t))

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
        container.add(anim, forKey: "finalCTAFade")

        return container
    }

    // MARK: - 4. Карточки смены драматургических актов (Act Transition Cards)

    private func buildActTransitionCardsLayer(
        renderSize: CGSize,
        k: Double,
        concept: ThematicConcept,
        acts: [LongformAct],
        actStartTimes: [Double] = [],
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
            let actStartTimeline = (index < actStartTimes.count && actStartTimes[index] > 0)
                ? actStartTimes[index]
                : currentTimelineOffset
            currentTimelineOffset += actDuration

            // Титры для последующих актов (начиная со второго: Акт II, III, IV), чтобы не перекрывать вступительный интро-слоган.
            // Пустой акт не получает карточку: объявлять «ЧАСТЬ» над кадром, где играть нечему, — обман зрителя.
            guard index > 0, !act.segments.isEmpty, actStartTimeline < totalDuration else { continue }

            let roman = (index < romanNumerals.count) ? romanNumerals[index] : "\(index + 1)"
            let actPartText = "— ЧАСТИНА \(roman) —"
            let cleanedTitle = act.title.trimmingCharacters(in: CharacterSet(charactersIn: "«»\" ")).uppercased()
            let actTitleText = "«\(cleanedTitle)»"

            // 1. Надстрочник части (акцентный WCAG-легible, разрядка 5.0·k, Russo One 20pt·k, обводка -2.0·k)
            let partAttrs = Self.actOverlineAttributes(k: k, accentHex: concept.accentColorHex)
            let partAttributed = NSAttributedString(string: actPartText, attributes: partAttrs)
            let partSize = partAttributed.size()

            // 2. Название главы (монументальный белый Russo One 34pt·k, разрядка 3.0·k, глубокая кино-тень)
            let titleAttrs = Self.actTitleAttributes(k: k)
            let titleAttributed = NSAttributedString(string: actTitleText, attributes: titleAttrs)
            let titleBounding = titleAttributed.boundingRect(
                with: CGSize(width: W * 0.85, height: 200.0),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
            let titleSize = CGSize(
                width: ceil(titleBounding.width) + CGFloat(16.0 * k),
                height: ceil(titleBounding.height) + CGFloat(8.0 * k)
            )

            // Контейнер без рамок и без плашек (чистая кино-типографика)
            let containerW = max(partSize.width, titleSize.width) + CGFloat(40.0 * k)
            let lineWidth: CGFloat = 120.0
            let lineHeight: CGFloat = 2.5
            let spacingPartToTitle: CGFloat = 6.0 * CGFloat(k)
            let spacingTitleToLine: CGFloat = 12.0 * CGFloat(k)
            let totalContentH = partSize.height + spacingPartToTitle + titleSize.height + spacingTitleToLine + lineHeight

            let containerX = (W - containerW) / 2.0
            let containerY = Self.actCardY(renderSize: renderSize) // В верхней трети экрана

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
        currentPhrase: String?,
        layout: LongformOverlayLayout = LongformOverlayLayout()
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

        // Тот же множитель и те же помощники типографики, что и в оверлее: пути не могут разъехаться
        let k = Self.scaleFactor(renderSize: renderSize)

        // 1. Центральное якорное слово темы (Russo One 44pt·k с авто-усадкой до 60% ширины, офф-вайт, обводка)
        let upperWord = concept.word.uppercased()
        let themeSize = Self.resolvedThemePointSize(
            word: upperWord,
            k: k,
            maxWidth: Self.themeMaxWidth(renderSizeWidth: Double(renderSize.width))
        )
        let conceptAttrs = Self.themeAttributes(pointSize: themeSize, k: k)

        let conceptStr = NSAttributedString(string: upperWord, attributes: conceptAttrs)
        let conceptSize = conceptStr.size()
        let conceptOrigin = NSPoint(
            x: (renderSize.width - conceptSize.width) / 2.0,
            y: (renderSize.height - conceptSize.height) / 2.0
        )
        conceptStr.draw(at: conceptOrigin)

        // 2. Плавный субтитр диалога прямо под концептом (акцент WCAG-легible, Russo One 32pt·k, обводка)
        let phraseText = currentPhrase?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "ВСЕ ВТРАТИШ"
        if !phraseText.isEmpty {
            let subAttrs = Self.captionAttributes(k: k, accentHex: concept.accentColorHex)
            let subStr = NSAttributedString(string: phraseText.uppercased(), attributes: subAttrs)
            let subSize = subStr.size()
            let subOrigin = NSPoint(
                x: (renderSize.width - subSize.width) / 2.0,
                y: conceptOrigin.y - subSize.height - 12.0
            )
            subStr.draw(at: subOrigin)
        }

        // 3. Знак канала — ровно та же цепочка раскладки, что в видео, иначе превью разойдётся с рендером.
        if let style = layout.channelLogo {
            let conceptY = Self.conceptBottomY(renderSize: renderSize, textSize: conceptSize, k: k)
            let logoRect = Self.essayLogoBand(renderSize: renderSize, conceptY: conceptY, lines: 1,
                                              bottomBarHeight: layout.bottomBarHeight, style: style)
            if let logoRect {
                ChannelLogo.composite(in: context, rect: logoRect, opacity: CGFloat(style.opacity))
            } else {
                let subtitleBottom = Self.essaySubtitleBand(renderSize: renderSize, conceptY: conceptY, lines: 1).minY
                    - Self.subtitleLogoClearance * CGFloat(k)
                Self.reportMissingLogoRoom(renderSize: renderSize, subtitleBottom: max(0, subtitleBottom),
                                           bottomBarHeight: layout.bottomBarHeight, style: style)
            }
        }

        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    // MARK: - Фильтр галлюцинаций Whisper large-v3

    ///canonical-галлюцинации Whisper large-v3, которые модель генерирует на тишине
    ///и которые нельзя выжигать на экран как субтитры. Проверка до рендера:
    ///если фраза совпадает с известным артефактом декодера, она пропускается.
    static func isHallucinationLine(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }

        // Канонические галлюцинации подписчиков (французский, норвежский, шведский)
        let knownHallucinations = [
            "sous-titres par lavachesquid",
            "tekstet av nicolai winther",
            "undertexter av nicolai winther",
        ]
        if knownHallucinations.contains(trimmed.lowercased()) {
            return true
        }

        // Строки, состоящие только из музыкальных символов (♪) и пробелов
        let musicOnly = trimmed.unicodeScalars.allSatisfy { scalar in
            let v: UInt32 = scalar.value
            return v == 0x266A || v == 0x266B || CharacterSet.whitespaces.contains(scalar)
        }
        if musicOnly { return true }

        // Одиночное "you" / "You" — артефакт декодера Whisper на тишине
        if trimmed.lowercased() == "you" { return true }

        return false
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
