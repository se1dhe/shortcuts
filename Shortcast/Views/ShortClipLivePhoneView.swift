import SwiftUI
import AVKit

/// Монитор предпросмотра 9:16 шортса в реальном времени.
/// Single Responsibility Principle (SRP): отвечает за рендеринг видеопотока,
/// наложения субтитров, хуков, водяных знаков и промокода в формате смартфона.
struct ShortClipLivePhoneView: View {
    @Bindable var clip: ShortClip
    var seekTime: Double? = nil
    var showPlatformChrome: Bool = false
    var activePlatform: SocialPlatform = .tiktok

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let bezel = max(4, w * 0.024)
            let bodyRadius = w * 0.12

            ZStack {
                // Корпус смартфона
                RoundedRectangle(cornerRadius: bodyRadius, style: .continuous)
                    .fill(LinearGradient(
                        colors: [Color(white: 0.18), Color(white: 0.06)],
                        startPoint: .top, endPoint: .bottom))
                    .overlay(
                        RoundedRectangle(cornerRadius: bodyRadius, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.15), lineWidth: 1))
                    .shadow(color: .black.opacity(0.4), radius: 18, y: 10)

                // Экран смартфона
                screenContent(w: w - bezel * 2)
                    .clipShape(RoundedRectangle(cornerRadius: bodyRadius - bezel * 0.7, style: .continuous))
                    .padding(bezel)
            }
        }
        .aspectRatio(0.485, contentMode: .fit)
    }

    @ViewBuilder
    private func screenContent(w: CGFloat) -> some View {
        ZStack {
            Color.black

            if let videoURL = clip.clipJob?.url {
                PhoneVideoPlayer(
                    url: videoURL,
                    gravity: .resizeAspect,
                    trimStart: clip.trimStartSeconds,
                    trimEnd: clip.trimEndSeconds,
                    seekTime: seekTime
                )
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "video.slash")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("Видео готовится…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Градиенты для читаемости текста
            LinearGradient(colors: [.black.opacity(0.45), .clear],
                           startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.25))
            LinearGradient(colors: [.clear, .black.opacity(0.75)],
                           startPoint: UnitPoint(x: 0.5, y: 0.5), endPoint: .bottom)

            // Промо-баннер вверху
            if clip.promoOverlayEnabled {
                PromoOverlayPreview(promoCode: clip.promoCode, w: w)
            }

            // Субтитры (живой предпросмотр)
            if !clip.subtitleSegments.isEmpty {
                SubtitlePreviewOverlay(
                    segments: clip.subtitleSegments,
                    appearance: clip.subtitleAppearance,
                    w: w
                )
            }

            // Водяной знак
            if clip.watermarkEnabled && !clip.watermarkText.trimmed.isEmpty {
                WatermarkPreviewOverlay(
                    text: clip.watermarkText,
                    appearance: clip.watermarkAppearance,
                    w: w
                )
            }

            // Наэкранный хук
            if clip.overlayEnabled && !clip.overlayText.trimmed.isEmpty {
                hookOverlay(w: w)
            }

            // Опциональный интерфейс соцсети
            if showPlatformChrome, let variant = clip.variants.first(where: { $0.platform == activePlatform }) ?? clip.variants.first {
                platformChromeOverlay(variant: variant, w: w)
            }

            // Dynamic Island
            VStack {
                Capsule(style: .continuous)
                    .fill(.black)
                    .frame(width: w * 0.28, height: w * 0.075)
                    .padding(.top, w * 0.04)
                Spacer()
            }
        }
    }

    @ViewBuilder
    private func hookOverlay(w: CGFloat) -> some View {
        let style = clip.hookAppearance.normalized.style
        let fontSize = w * clip.hookAppearance.normalized.sizeScale * 1.8
        let cardHeight = w / 0.5625

        VStack(spacing: 0) {
            Spacer().frame(height: cardHeight * 0.12 + (clip.promoOverlayEnabled ? w * 0.35 : 0))
            Text(clip.overlayText)
                .font(.system(size: fontSize, weight: .heavy))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .padding(.horizontal, w * 0.045)
                .padding(.vertical, w * 0.03)
                .background(
                    style.showsPill ? Color.black.opacity(0.55) : Color.clear,
                    in: RoundedRectangle(cornerRadius: w * 0.035)
                )
                .padding(.horizontal, w * 0.06)
            Spacer()
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func platformChromeOverlay(variant: PostVariant, w: CGFloat) -> some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Image(systemName: "magnifyingglass")
                    .font(.system(size: w * 0.05, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, w * 0.05)
            .padding(.top, w * 0.16)

            Spacer()

            VStack(alignment: .leading, spacing: 4) {
                Text("@creator")
                    .font(.system(size: w * 0.042, weight: .bold))
                    .foregroundStyle(.white)
                Text(variant.hook)
                    .font(.system(size: w * 0.038, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, w * 0.05)
            .padding(.bottom, w * 0.08)
        }
        .allowsHitTesting(false)
    }
}
