import SwiftUI

/// One result card: a phone-style preview of the post for a single platform,
/// with the live video playing behind the real platform UI. Every line of copy
/// is editable in place.
struct PostPreviewCard: View {

    @Binding var variant: PostVariant
    let videoURL: URL
    /// When set, a visual approximation of the burned-in text hook is shown near
    /// the top of the preview (the real overlay is rendered at publish time).
    var overlayHook: String? = nil
    var hookAppearance: HookAppearance = .default
    var subtitleSegments: [SubtitleSegment] = []
    var subtitleAppearance: SubtitleAppearance = .tiktok
    var showSubtitles = false
    var watermarkText: String = ""
    var watermarkAppearance: WatermarkAppearance = .default
    var showWatermark = false
    var showPromoOverlay = false
    var promoCode: String = PromoOverlayConfig.default.promoCode
    var trimStart: Double = 0
    var trimEnd: Double = 0

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: variant.platform.symbolName)
                Text(variant.platform.displayName)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(variant.platform.tint)

            PhoneMockup(
                variant: $variant,
                videoURL: videoURL,
                overlayHook: overlayHook,
                hookAppearance: hookAppearance,
                subtitleSegments: subtitleSegments,
                subtitleAppearance: subtitleAppearance,
                showSubtitles: showSubtitles,
                watermarkText: watermarkText,
                watermarkAppearance: watermarkAppearance,
                showWatermark: showWatermark,
                showPromoOverlay: showPromoOverlay,
                promoCode: promoCode,
                trimStart: trimStart,
                trimEnd: trimEnd)
        }
    }
}

// MARK: - Phone

private struct PhoneMockup: View {
    @Binding var variant: PostVariant
    let videoURL: URL
    var overlayHook: String? = nil
    var hookAppearance: HookAppearance = .default
    var subtitleSegments: [SubtitleSegment] = []
    var subtitleAppearance: SubtitleAppearance = .tiktok
    var showSubtitles = false
    var watermarkText: String = ""
    var watermarkAppearance: WatermarkAppearance = .default
    var showWatermark = false
    var showPromoOverlay = false
    var promoCode: String = PromoOverlayConfig.default.promoCode
    var trimStart: Double = 0
    var trimEnd: Double = 0

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let bezel = max(4, w * 0.024)
            let bodyRadius = w * 0.14

            ZStack {
                RoundedRectangle(cornerRadius: bodyRadius, style: .continuous)
                    .fill(LinearGradient(
                        colors: [Color(white: 0.17), Color(white: 0.04)],
                        startPoint: .top, endPoint: .bottom))
                    .overlay(
                        RoundedRectangle(cornerRadius: bodyRadius, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
                    .shadow(color: .black.opacity(0.35), radius: 20, y: 14)

                PhoneScreen(variant: $variant,
                            videoURL: videoURL,
                            overlayHook: overlayHook,
                            hookAppearance: hookAppearance,
                            subtitleSegments: subtitleSegments,
                            subtitleAppearance: subtitleAppearance,
                            showSubtitles: showSubtitles,
                            watermarkText: watermarkText,
                            watermarkAppearance: watermarkAppearance,
                            showWatermark: showWatermark,
                            showPromoOverlay: showPromoOverlay,
                            promoCode: promoCode,
                            trimStart: trimStart,
                            trimEnd: trimEnd,
                            w: w - bezel * 2)
                    .clipShape(RoundedRectangle(cornerRadius: bodyRadius - bezel * 0.7,
                                                style: .continuous))
                    .padding(bezel)
            }
        }
        .aspectRatio(0.485, contentMode: .fit)
    }
}

private struct PhoneScreen: View {
    @Binding var variant: PostVariant
    let videoURL: URL
    var overlayHook: String? = nil
    var hookAppearance: HookAppearance = .default
    var subtitleSegments: [SubtitleSegment] = []
    var subtitleAppearance: SubtitleAppearance = .tiktok
    var showSubtitles = false
    var watermarkText: String = ""
    var watermarkAppearance: WatermarkAppearance = .default
    var showWatermark = false
    var showPromoOverlay = false
    var promoCode: String = PromoOverlayConfig.default.promoCode
    var trimStart: Double = 0
    var trimEnd: Double = 0
    let w: CGFloat

    var body: some View {
        ZStack {
            Color.black
            PhoneVideoPlayer(url: videoURL, trimStart: trimStart, trimEnd: trimEnd)

            if showPromoOverlay {
                PromoOverlayPreview(promoCode: promoCode, w: w)
            }

            LinearGradient(colors: [.black.opacity(0.45), .clear],
                           startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.30))
            LinearGradient(colors: [.clear, .black.opacity(0.85)],
                           startPoint: UnitPoint(x: 0.5, y: 0.42), endPoint: .bottom)

            if showSubtitles, !subtitleSegments.isEmpty {
                SubtitlePreviewOverlay(
                    segments: subtitleSegments,
                    appearance: subtitleAppearance,
                    w: w)
            }

            if showWatermark, !watermarkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                WatermarkPreviewOverlay(
                    text: watermarkText,
                    appearance: watermarkAppearance,
                    w: w)
            }

            PlatformChrome(variant: $variant, w: w)

            // Burned-in text hook (visual approximation of the published render).
            if let overlayHook, !overlayHook.trimmingCharacters(in: .whitespaces).isEmpty {
                let style = hookAppearance.normalized.style
                let fontSize = w * hookAppearance.normalized.sizeScale * 1.8
                let cardHeight = w / 0.5625
                VStack(spacing: 0) {
                    Spacer().frame(height: cardHeight * 0.12 + (showPromoOverlay ? w * 0.35 : 0))
                    hookText(overlayHook, style: style)
                        .font(.system(size: fontSize, weight: .heavy))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, w * 0.045)
                        .padding(.vertical, w * 0.03)
                        .background(style.showsPill ? AnyShapeStyle(Color.black.opacity(0.55)) : AnyShapeStyle(Color.clear),
                                    in: RoundedRectangle(cornerRadius: w * 0.035))
                        .padding(.horizontal, w * 0.06)
                    Spacer()
                }
                .allowsHitTesting(false)
            }

            // Dynamic Island
            VStack {
                Capsule(style: .continuous)
                    .fill(.black)
                    .frame(width: w * 0.30, height: w * 0.085)
                    .padding(.top, w * 0.05)
                Spacer()
            }
        }
    }

    /// Approximates the burned hook look per style (glow for neon, outline-ish
    /// shadow for minimal). Animations aren't shown in the static preview.
    @ViewBuilder
    private func hookText(_ text: String, style: HookAppearance.HookStyle) -> some View {
        switch style {
        case .neon:
            Text(text)
                .foregroundStyle(.white)
                .shadow(color: Color(hex: "#48B7FF"), radius: w * 0.02)
                .shadow(color: Color(hex: "#48B7FF").opacity(0.7), radius: w * 0.045)
        case .minimal:
            Text(text)
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.9), radius: w * 0.006)
        default:
            Text(text)
                .foregroundStyle(.white)
        }
    }
}

struct SubtitlePreviewOverlay: View {
    let segments: [SubtitleSegment]
    let appearance: SubtitleAppearance
    let w: CGFloat

    private var normalized: SubtitleAppearance { appearance.normalized }
    private var chunks: [SubtitlePreviewChunk] {
        segments.flatMap { segment in
            let words = segment.text.split(whereSeparator: \.isWhitespace).map(String.init)
            guard words.count > normalized.maxWordsPerCaption else {
                return [SubtitlePreviewChunk(start: segment.start, end: segment.end, text: segment.text)]
            }
            let duration = max(segment.end - segment.start, 0.3)
            let count = Int(ceil(Double(words.count) / Double(normalized.maxWordsPerCaption)))
            let chunkDuration = duration / Double(count)
            return (0..<count).map { index in
                let wordStart = index * normalized.maxWordsPerCaption
                let wordEnd = min(wordStart + normalized.maxWordsPerCaption, words.count)
                let start = segment.start + Double(index) * chunkDuration
                let end = index == count - 1 ? segment.end : start + chunkDuration
                return SubtitlePreviewChunk(
                    start: start,
                    end: end,
                    text: words[wordStart..<wordEnd].joined(separator: " "))
            }
        }
    }
    private var totalDuration: Double {
        max(chunks.map(\.end).max() ?? 0, 1)
    }

    var body: some View {
        TimelineView(.animation) { context in
            let elapsed = context.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: totalDuration)
            if let segment = currentSegment(at: elapsed) {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                        .frame(maxHeight: .infinity)
                    highlightedText(segment.text, karaokeWord: karaokeWord(in: segment, at: elapsed))
                        .font(previewFont)
                        .shadow(color: isNeon ? Color(hex: normalized.accentColorHex) : .clear,
                                radius: isNeon ? w * normalized.fontSizeScale * 0.28 : 0)
                        .multilineTextAlignment(textAlignment(normalized.horizontalAlign))
                        .lineLimit(4)
                        .minimumScaleFactor(0.78)
                        .padding(w * normalized.paddingScale)
                        .frame(width: w * normalized.maxWidthScale,
                               alignment: frameAlignment(normalized.horizontalAlign))
                        .background(
                            Color(hex: normalized.bgColorHex).opacity(normalized.bgOpacity),
                            in: RoundedRectangle(cornerRadius: w * normalized.cornerRadiusScale,
                                                 style: .continuous))
                        .shadow(color: .black.opacity(0.95), radius: normalized.textBorderWidth, x: 0, y: 0)
                        .shadow(color: .black.opacity(0.85), radius: normalized.textBorderWidth * 0.45, x: 0, y: 1)
                        .padding(.horizontal, w * 0.04)
                        .frame(maxWidth: .infinity,
                               alignment: frameAlignment(normalized.horizontalAlign))
                    Spacer(minLength: 0)
                        .frame(height: previewBottomOffset)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(transition)
                .animation(.easeOut(duration: 0.16), value: segment.start)
                .allowsHitTesting(false)
            }
        }
    }

    private var previewBottomOffset: CGFloat {
        let screenHeight = w / 0.5625
        let safeBottom = screenHeight * 0.08
        return max(safeBottom, screenHeight * (1 - normalized.verticalPosition))
    }

    private var isNeon: Bool { normalized.animationRaw.lowercased() == "neon" }

    private var transition: AnyTransition {
        switch normalized.animationRaw.lowercased() {
        case "pop": .scale(scale: 0.92).combined(with: .opacity)
        case "bounce": .scale(scale: 0.7).combined(with: .opacity)
        case "slide": .move(edge: .bottom).combined(with: .opacity)
        default: .opacity
        }
    }

    private func currentSegment(at elapsed: Double) -> SubtitlePreviewChunk? {
        chunks.first { elapsed >= $0.start && elapsed <= $0.end }
            ?? chunks.first
    }

    /// For karaoke, the word that should be lit up at the current playback time.
    private func karaokeWord(in segment: SubtitlePreviewChunk, at elapsed: Double) -> String? {
        guard normalized.animationRaw.lowercased() == "karaoke" else { return nil }
        let words = segment.text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return nil }
        let dur = max(segment.end - segment.start, 0.3)
        let rawProgress = (elapsed - segment.start) / dur
        let progress = min(0.999, max(0, rawProgress))
        let index = min(words.count - 1, Int(progress * Double(words.count)))
        return words[index]
    }

    private var previewFont: Font {
        let size = w * normalized.fontSizeScale
        switch normalized.fontChoice {
        case .russoOne:
            return .custom("Russo One", size: size)
        case .oswald:
            return .custom("Oswald", size: size).weight(.bold)
        case .bebasNeue:
            return .custom("Bebas Neue", size: size)
        case .impact:
            return .custom("Impact", size: size)
        case .helvetica:
            return .custom("Helvetica Neue", size: size).weight(.bold)
        case .tiktokSans:
            return .custom("TikTok Sans", size: size).weight(.bold)
        case .montserrat:
            return .custom("Montserrat", size: size).weight(.bold)
        case .captureIt:
            return .custom("Capture It", size: size)
        case .dinCondensed:
            return .custom("DIN Condensed", size: size).weight(.bold)
        case .arialBlack:
            return .custom("Arial Black", size: size)
        @unknown default:
            return .system(size: size, weight: .bold)
        }
    }

    private func highlightedText(_ text: String, karaokeWord: String? = nil) -> Text {
        // Karaoke overrides the keyword heuristic with the current spoken word.
        let target = karaokeWord ?? (normalized.highlightModeRaw != "none" ? highlightTarget(in: text) : nil)
        guard let target, let range = text.range(of: target) else {
            return Text(text).foregroundStyle(Color(hex: normalized.textColorHex))
        }
        let before = String(text[..<range.lowerBound])
        let after = String(text[range.upperBound...])
        return Text(before).foregroundStyle(Color(hex: normalized.textColorHex))
            + Text(target).foregroundStyle(Color(hex: normalized.accentColorHex))
            + Text(after).foregroundStyle(Color(hex: normalized.textColorHex))
    }

    private func highlightTarget(in text: String) -> String? {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return nil }
        if normalized.highlightModeRaw.lowercased() == "firstword" {
            return words[0]
        }
        return words.max { $0.cleanedForHighlight.count < $1.cleanedForHighlight.count }
    }

    private func textAlignment(_ raw: String) -> TextAlignment {
        switch raw.lowercased() {
        case "left": .leading
        case "right": .trailing
        default: .center
        }
    }

    private func frameAlignment(_ raw: String) -> Alignment {
        switch raw.lowercased() {
        case "left": .leading
        case "right": .trailing
        default: .center
        }
    }
}

private struct SubtitlePreviewChunk {
    let start: Double
    let end: Double
    let text: String
}

struct WatermarkPreviewOverlay: View {
    let text: String
    let appearance: WatermarkAppearance
    let w: CGFloat

    private var cleanText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        TimelineView(.animation) { context in
            let progress = animationProgress(at: context.date)
            watermarkText(progress: progress)
                .font(.system(size: w * CGFloat(appearance.fontSizeScale),
                              weight: fontWeight,
                              design: .monospaced))
                .foregroundStyle(.white.opacity(appearance.opacity))
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .shadow(color: .black.opacity(0.9), radius: w * 0.008, y: 1)
                .modifier(WatermarkPreviewEffect(
                    progress: progress,
                    appearance: appearance,
                    w: w))
                .padding(.horizontal, w * 0.02)
                .padding(.vertical, w * 0.02)
                .frame(maxWidth: .infinity, maxHeight: .infinity,
                       alignment: alignment)
                .allowsHitTesting(false)
        }
    }

    private func animationProgress(at date: Date) -> Double {
        let total = max(1.0, min(12.0, appearance.typingDuration + appearance.holdDuration + appearance.typingDuration + 0.6))
        return date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: total) / total
    }

    @ViewBuilder
    private func watermarkText(progress: Double) -> some View {
        switch appearance.animation {
        case .typewriter:
            Text(typewriterText(progress: progress, cursor: "|"))
        case .cursorUnderscore:
            Text(typewriterText(progress: progress, cursor: "_"))
        case .scanLine:
            Text("│ " + scanText(progress: progress))
        case .subtitle:
            Text("[ \(cleanText.uppercased()) ]")
        case .hud:
            Text("ID // \(cleanText.uppercased().replacingOccurrences(of: "@", with: ""))")
        default:
            Text(cleanText)
        }
    }

    private func typewriterText(progress: Double, cursor: String) -> String {
        let typed = visibleCharacterCount(progress: progress)
        let prefix = String(cleanText.prefix(typed))
        let cursorVisible = Int(progress * 24).isMultiple(of: 2)
        return "\(prefix)\(cursorVisible ? cursor : " ")"
    }

    private func scanText(progress: Double) -> String {
        String(cleanText.uppercased().prefix(visibleCharacterCount(progress: progress)))
    }

    private func visibleCharacterCount(progress: Double) -> Int {
        let count = cleanText.count
        guard count > 0 else { return 0 }
        let intro = 0.18
        let outro = 0.72
        if progress < intro {
            return max(0, Int((progress / intro) * Double(count)))
        }
        if progress < outro {
            return count
        }
        let erase = max(0, min(1, (progress - outro) / (1 - outro)))
        return max(0, Int((1 - erase) * Double(count)))
    }

    private var alignment: Alignment {
        switch appearance.position {
        case .bottomLeft:   return .bottomLeading
        case .bottomCenter: return .bottom
        case .bottomRight:  return .bottomTrailing
        case .topLeft:      return .topLeading
        case .topCenter:    return .top
        case .topRight:     return .topTrailing
        }
    }

    private var fontWeight: Font.Weight {
        switch appearance.animation {
        case .subtitle, .cinematicFocus, .maskWipe: return .medium
        case .hud, .scanLine: return .semibold
        default: return .regular
        }
    }
}

struct WatermarkPreviewEffect: ViewModifier {
    let progress: Double
    let appearance: WatermarkAppearance
    let w: CGFloat

    func body(content: Content) -> some View {
        switch appearance.animation {
        case .cinematicFocus:
            content
                .blur(radius: focusBlur)
                .scaleEffect(focusScale)
                .opacity(effectOpacity)
        case .maskWipe:
            content
                .opacity(effectOpacity)
                .mask(alignment: .leading) {
                    Rectangle()
                        .frame(width: max(1, w * CGFloat(maskWidth)))
                }
        case .glitch:
            ZStack {
                content
                    .foregroundStyle(.cyan.opacity(glitchOpacity))
                    .offset(x: -glitchOffset)
                content
                    .foregroundStyle(.red.opacity(glitchOpacity))
                    .offset(x: glitchOffset)
                content.opacity(effectOpacity)
            }
        case .subtitle:
            content
                .padding(.horizontal, w * 0.024)
                .padding(.vertical, w * 0.010)
                .background(.black.opacity(0.18),
                            in: RoundedRectangle(cornerRadius: w * 0.010, style: .continuous))
                .opacity(effectOpacity)
        case .neon:
            content
                .shadow(color: Color(hex: "#48B7FF"), radius: w * 0.02)
                .shadow(color: Color(hex: "#48B7FF").opacity(0.7), radius: w * 0.04)
                .opacity(effectOpacity)
        case .bounce:
            content
                .scaleEffect(bounceScale)
                .opacity(effectOpacity)
        default:
            content.opacity(effectOpacity)
        }
    }

    private var bounceScale: CGFloat {
        // Springy overshoot during the intro, settles to 1.
        if progress < 0.06 { return 0.6 + CGFloat(progress / 0.06) * 0.58 }   // 0.6 → 1.18
        if progress < 0.12 { return 1.18 - CGFloat((progress - 0.06) / 0.06) * 0.18 } // 1.18 → 1.0
        return 1.0
    }

    private var effectOpacity: Double {
        switch appearance.animation {
        case .static:
            return 1
        default:
            if progress < 0.08 { return progress / 0.08 }
            if progress > 0.92 { return max(0, (1 - progress) / 0.08) }
            return 1
        }
    }

    private var focusBlur: CGFloat {
        let edge = min(progress, 1 - progress)
        return edge < 0.12 ? CGFloat((0.12 - edge) / 0.12) * w * 0.018 : 0
    }

    private var focusScale: CGFloat {
        let edge = min(progress, 1 - progress)
        return edge < 0.12 ? 1.03 : 1.0
    }

    private var maskWidth: Double {
        if progress < 0.18 { return progress / 0.18 }
        if progress > 0.82 { return max(0, (1 - progress) / 0.18) }
        return 1
    }

    private var glitchOpacity: Double {
        progress < 0.10 || progress > 0.90 ? 0.65 : 0
    }

    private var glitchOffset: CGFloat {
        (progress < 0.10 || progress > 0.90) ? w * 0.006 : 0
    }
}

// MARK: - Platform UI overlay

private struct PlatformChrome: View {
    @Binding var variant: PostVariant
    let w: CGFloat

    private var skin: PlatformSkin { .skin(for: variant.platform) }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Spacer(minLength: 0)
            HStack(alignment: .bottom, spacing: w * 0.03) {
                captionBlock
                Spacer(minLength: 0)
                ActionRail(skin: skin, w: w)
            }
            .padding(.horizontal, w * 0.045)
            .padding(.bottom, w * 0.07)
        }
    }

    private var topBar: some View {
        HStack {
            if let badge = skin.cornerBadge {
                Text(LocalizedStringKey(badge))
                    .font(.system(size: w * 0.058, weight: .heavy))
            }
            Spacer()
            Image(systemName: skin.topTrailingIcon)
                .font(.system(size: w * 0.052, weight: .semibold))
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.5), radius: 3)
        .padding(.horizontal, w * 0.05)
        .padding(.top, w * 0.165)
    }

    private var captionBlock: some View {
        VStack(alignment: .leading, spacing: w * 0.016) {
            HStack(spacing: w * 0.025) {
                Circle()
                    .fill(LinearGradient(
                        colors: [variant.platform.tint, variant.platform.tint.opacity(0.45)],
                        startPoint: .top, endPoint: .bottom))
                    .overlay(Image(systemName: "person.fill")
                        .font(.system(size: w * 0.038))
                        .foregroundStyle(.white))
                    .frame(width: w * 0.078, height: w * 0.078)
                Text(LocalizedStringKey(skin.username))
                    .font(.system(size: w * 0.042, weight: .semibold))
                if let label = skin.actionLabel {
                    Text(LocalizedStringKey(label))
                        .font(.system(size: w * 0.034, weight: .bold))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, w * 0.032)
                        .padding(.vertical, w * 0.014)
                        .background(skin.actionFilled
                                    ? AnyShapeStyle(skin.actionTint)
                                    : AnyShapeStyle(Color.clear))
                        .overlay(RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(.white.opacity(skin.actionFilled ? 0 : 0.85)))
                        .layoutPriority(1)
                }
            }
            .foregroundStyle(.white)
            .padding(.bottom, w * 0.012)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: w * 0.016) {
                    EditableLine(text: $variant.hook, w: w, size: 0.047, weight: .semibold)
                    EditableLine(text: $variant.summary, w: w, size: 0.041, weight: .regular)
                    EditableLine(text: hashtagsBinding, w: w, size: 0.041, weight: .medium,
                                 tint: Color(red: 0.64, green: 0.83, blue: 1.0))
                }
            }
            .frame(maxHeight: w * 0.96)

            HStack(spacing: w * 0.022) {
                Image(systemName: "music.note")
                Text(LocalizedStringKey(skin.audioLabel)).lineLimit(1)
            }
            .font(.system(size: w * 0.036, weight: .medium))
            .foregroundStyle(.white)
            .padding(.top, w * 0.014)
        }
        .frame(width: w * 0.64, alignment: .leading)
        .shadow(color: .black.opacity(0.6), radius: 3, y: 1)
    }

    private var hashtagsBinding: Binding<String> {
        Binding(
            get: { variant.hashtags.map { "#\($0)" }.joined(separator: " ") },
            set: { newValue in
                variant.hashtags = newValue
                    .split(whereSeparator: { " ,\n".contains($0) })
                    .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "# ")) }
                    .filter { !$0.isEmpty }
            })
    }
}

/// A single line of post copy, styled like the overlay text but editable.
private struct EditableLine: View {
    @Binding var text: String
    let w: CGFloat
    let size: CGFloat
    let weight: Font.Weight
    var tint: Color = .white

    var body: some View {
        TextField("", text: $text, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: w * size, weight: weight))
            .foregroundStyle(tint)
            .tint(.white)
    }
}

private struct ActionRail: View {
    let skin: PlatformSkin
    let w: CGFloat
    @State private var spin = false

    var body: some View {
        VStack(spacing: w * 0.052) {
            ForEach(skin.railItems.indices, id: \.self) { index in
                let item = skin.railItems[index]
                VStack(spacing: w * 0.012) {
                    Image(systemName: item.symbol)
                        .font(.system(size: w * 0.078, weight: .semibold))
                    if let caption = item.caption {
                        Text(caption).font(.system(size: w * 0.03, weight: .semibold))
                    }
                }
            }

            ZStack {
                Circle().fill(LinearGradient(
                    colors: [Color(white: 0.28), .black],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "music.note")
                    .font(.system(size: w * 0.048, weight: .bold))
            }
            .frame(width: w * 0.115, height: w * 0.115)
            .rotationEffect(.degrees(spin ? 360 : 0))
            .animation(.linear(duration: 6).repeatForever(autoreverses: false), value: spin)
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.55), radius: 3, y: 1)
        .onAppear { spin = true }
    }
}

// MARK: - Per-platform styling

private struct PlatformSkin {
    struct RailItem { let symbol: String; let caption: String? }

    let username: String
    let cornerBadge: String?
    let topTrailingIcon: String
    let railItems: [RailItem]
    let actionLabel: String?
    let actionFilled: Bool
    let actionTint: Color
    let audioLabel: String

    static func skin(for platform: SocialPlatform) -> PlatformSkin {
        switch platform {
        case .tiktok:
            PlatformSkin(
                username: "@creator",
                cornerBadge: nil,
                topTrailingIcon: "magnifyingglass",
                railItems: [
                    RailItem(symbol: "heart.fill", caption: "12.4K"),
                    RailItem(symbol: "ellipsis.bubble.fill", caption: "318"),
                    RailItem(symbol: "bookmark.fill", caption: "1.2K"),
                    RailItem(symbol: "arrowshape.turn.up.right.fill", caption: "504"),
                ],
                actionLabel: nil, actionFilled: false, actionTint: .clear,
                audioLabel: "original sound")
        case .instagram:
            PlatformSkin(
                username: "@creator",
                cornerBadge: "Reels",
                topTrailingIcon: "camera",
                railItems: [
                    RailItem(symbol: "heart", caption: "8.2K"),
                    RailItem(symbol: "bubble.right", caption: "204"),
                    RailItem(symbol: "paperplane", caption: "97"),
                    RailItem(symbol: "ellipsis", caption: nil),
                ],
                actionLabel: "Follow", actionFilled: false, actionTint: .clear,
                audioLabel: "original sound")
        case .youtube:
            PlatformSkin(
                username: "@channel",
                cornerBadge: "Shorts",
                topTrailingIcon: "magnifyingglass",
                railItems: [
                    RailItem(symbol: "hand.thumbsup.fill", caption: "5.7K"),
                    RailItem(symbol: "hand.thumbsdown.fill", caption: nil),
                    RailItem(symbol: "ellipsis.bubble.fill", caption: "146"),
                    RailItem(symbol: "arrowshape.turn.up.right.fill", caption: nil),
                ],
                actionLabel: "Subscribe", actionFilled: true,
                actionTint: Color(hex: "FF0000"),
                audioLabel: "original sound")
        case .telegram:
            PlatformSkin(
                username: "@your_channel",
                cornerBadge: "Channel",
                topTrailingIcon: "paperplane.fill",
                railItems: [
                    RailItem(symbol: "eye.fill", caption: "3.4K"),
                    RailItem(symbol: "heart.fill", caption: "420"),
                    RailItem(symbol: "bubble.right.fill", caption: "58"),
                    RailItem(symbol: "arrowshape.turn.up.right.fill", caption: "112"),
                ],
                actionLabel: "Join", actionFilled: true,
                actionTint: Color(hex: "2AABEE"),
                audioLabel: "telonyx cinema")
        }
    }
}
