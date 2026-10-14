import SwiftUI
import AVKit
import AppKit

/// A compact card in the shorts grid: a phone-style preview of one cut clip with
/// quick actions (play with sound, download, approve) and a tap target to open
/// the full caption editor. Designed so the whole batch is scannable at a glance.
struct ShortClipTile: View {

    @Bindable var clip: ShortClip
    @Environment(AppSettings.self) private var settings

    @State private var showEditor = false
    @State private var showPlayer = false
    @State private var isHovered = false
    @State private var selectedPlatform: SocialPlatform = .tiktok
    @State private var copiedTitle = false
    @State private var copiedDescription = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            phoneArea
            detailsBlock
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.quaternary))
        .shadow(color: .black.opacity(0.04), radius: 6, x: 0, y: 2)
        .opacity(clip.isApproved ? 1.0 : 0.55)
        .onHover { isHovered = $0 }
        .sheet(isPresented: $showEditor) { ClipEditorSheet(clip: clip) }
        .sheet(isPresented: $showPlayer) {
            ClipPlayerSheet(clip: clip)
        }
        .onAppear {
            if let first = clip.variants.first?.platform {
                selectedPlatform = first
            }
        }
    }

    // MARK: - Phone preview + overlays

    @ViewBuilder
    private var phoneArea: some View {
        ZStack {
            switch clip.stage {
            case .ready:
                if let url = clip.clipJob?.url {
                    MiniPhone(url: url,
                              isPlaying: isHovered,
                              overlayHook: clip.overlayEnabled ? clip.overlayText : nil,
                              hookAppearance: clip.hookAppearance,
                              subtitleSegments: clip.subtitleSegments,
                              subtitleAppearance: clip.subtitleAppearance,
                              showSubtitles: clip.burnSubtitles,
                              watermarkText: clip.watermarkText,
                              watermarkAppearance: clip.watermarkAppearance,
                              showWatermark: clip.watermarkEnabled,
                              showPromoOverlay: clip.promoOverlayEnabled,
                              promoCode: clip.promoCode)
                        .contentShape(Rectangle())
                        .onTapGesture { showEditor = true }
                    overlays
                }
            case .failed(let message):
                placeholder {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange).multilineTextAlignment(.center)
                        .textSelection(.enabled)
                }
            default:
                placeholder {
                    VStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(clip.stage == .cutting ? "Cutting…" : "Writing captions…")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .aspectRatio(9.0 / 16.0, contentMode: .fit)
    }

    private func placeholder<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14).fill(.black.opacity(0.85))
            content().padding(10)
        }
    }

    private var overlays: some View {
        VStack {
            HStack(alignment: .top) {
                // Duration chip.
                Text("\(Int(clip.candidate.duration.rounded()))s")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(.black.opacity(0.65), in: Capsule())
                    .foregroundStyle(.white)

                if clip.isRendered {
                    Image(systemName: "aspectratio")
                        .font(.caption2.weight(.bold))
                        .padding(5)
                        .background(.black.opacity(0.65), in: Circle())
                        .foregroundStyle(.white)
                }
                if clip.backgroundMusicEnabled {
                    Image(systemName: "music.note")
                        .font(.caption2.weight(.bold))
                        .padding(5)
                        .background(.black.opacity(0.65), in: Circle())
                        .foregroundStyle(.white)
                        .help("Фоновая музыка включена")
                }
                Spacer()
                // Approve toggle.
                Button {
                    clip.isApproved.toggle()
                } label: {
                    Image(systemName: clip.isApproved ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, clip.isApproved ? Color.accentColor : .black.opacity(0.4))
                        .background(Circle().fill(.black.opacity(0.4)))
                }
                .buttonStyle(.plain)
                .help(clip.isApproved ? "Утверждён — входит в публикацию" : "Не утверждён")
            }
            Spacer()
        }
        .padding(10)
    }

    // MARK: - Details Block (Platform, Hook, Description, Actions)

    private var detailsBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            platformSelector
            titleSection
            descriptionSection
            if clip.scheduledDate != nil || clip.publishReport != nil || clip.exportError != nil {
                statusBadges
            }
            Divider()
            actionPanel
        }
        .padding(.horizontal, 2)
        .padding(.top, 2)
    }

    private var platformSelector: some View {
        HStack(spacing: 5) {
            ForEach(SocialPlatform.allCases) { platform in
                let isSelected = selectedPlatform == platform
                Button {
                    selectedPlatform = platform
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: platform.symbolName)
                            .font(.system(size: 10, weight: .semibold))
                        Text(platformLabel(platform))
                            .font(.system(size: 10, weight: .medium))
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(
                        isSelected ? platform.tint.opacity(0.18) : Color.primary.opacity(0.04),
                        in: Capsule()
                    )
                    .overlay(
                        Capsule().strokeBorder(
                            isSelected ? platform.tint.opacity(0.6) : Color.secondary.opacity(0.15),
                            lineWidth: 1
                        )
                    )
                    .foregroundStyle(isSelected ? platform.tint : .secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func platformLabel(_ platform: SocialPlatform) -> String {
        switch platform {
        case .tiktok: return "TikTok"
        case .instagram: return "Reels"
        case .youtube: return "Shorts"
        case .telegram: return "TG"
        }
    }

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("Название")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    ClipExportHelper.copyToPasteboard(currentHook)
                    copiedTitle = true
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        copiedTitle = false
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: copiedTitle ? "checkmark" : "doc.on.doc")
                        if copiedTitle {
                            Text("Скопировано")
                        }
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(copiedTitle ? .green : .secondary)
                }
                .buttonStyle(.plain)
                .help("Скопировать название в буфер обмена")
            }

            Text(currentHook.isEmpty ? "Без названия" : currentHook)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .foregroundStyle(currentHook.isEmpty ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var descriptionSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("Описание")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    let desc = currentFullDescription
                    guard !desc.isEmpty else { return }
                    ClipExportHelper.copyToPasteboard(desc)
                    copiedDescription = true
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        copiedDescription = false
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: copiedDescription ? "checkmark" : "doc.on.doc")
                        if copiedDescription {
                            Text("Скопировано")
                        }
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(copiedDescription ? .green : .secondary)
                }
                .buttonStyle(.plain)
                .help("Скопировать описание с тегами в буфер обмена")
                .disabled(currentFullDescription.isEmpty)
            }

            let desc = currentFullDescription
            Text(desc.isEmpty ? "Описание с тегами не сформировано" : desc)
                .font(.caption)
                .foregroundStyle(desc.isEmpty ? .tertiary : .secondary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var currentVariant: PostVariant? {
        clip.variants.first(where: { $0.platform == selectedPlatform }) ?? clip.variants.first
    }

    private var currentHook: String {
        if let hook = currentVariant?.hook.trimmingCharacters(in: .whitespacesAndNewlines), !hook.isEmpty {
            return hook
        }
        return clip.displayTitle
    }

    private var currentFullDescription: String {
        currentVariant?.fullDescriptionWithTags.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var statusBadges: some View {
        HStack(spacing: 6) {
            if let err = clip.exportError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
            if let date = clip.scheduledDate {
                Label(Self.shortDate(date), systemImage: "calendar")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.blue)
            } else if clip.publishReport != nil {
                Label("Опубликовано", systemImage: "checkmark.seal.fill")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.green)
            }
            Spacer()
        }
    }

    private var actionPanel: some View {
        HStack(spacing: 8) {
            Button {
                showPlayer = true
            } label: {
                Label("Смотреть", systemImage: "play.fill")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button {
                showEditor = true
            } label: {
                Label("Редактировать", systemImage: "square.and.pencil")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Spacer(minLength: 0)

            if clip.isExporting {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    downloadClip()
                } label: {
                    Label("Скачать MP4", systemImage: "arrow.down.circle")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
    }

    private func downloadClip() {
        ClipExportHelper.downloadClip(clip, settings: settings)
    }

    private static func shortDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "d MMM, HH:mm"
        return f.string(from: date)
    }

}

// MARK: - Mini phone

/// A small phone-framed, silent, looping preview of one clip.
struct MiniPhone: View {
    let url: URL
    var isPlaying: Bool = false
    var overlayHook: String?
    var hookAppearance: HookAppearance = .default
    var subtitleSegments: [SubtitleSegment] = []
    var subtitleAppearance: SubtitleAppearance = .tiktok
    var showSubtitles = false
    var watermarkText: String = ""
    var watermarkAppearance: WatermarkAppearance = .default
    var showWatermark = false
    var showPromoOverlay = false
    var promoCode: String = PromoOverlayConfig.default.promoCode

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let radius = w * 0.15
            ZStack {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: 0.16), Color(white: 0.03)],
                                         startPoint: .top, endPoint: .bottom))
                Color.black
                    .clipShape(RoundedRectangle(cornerRadius: radius - 3, style: .continuous))
                    .padding(3)

                if isPlaying {
                    PhoneVideoPlayer(url: url)
                        .clipShape(RoundedRectangle(cornerRadius: radius - 3, style: .continuous))
                        .padding(3)
                } else {
                    VideoThumbnailView(url: url)
                        .clipShape(RoundedRectangle(cornerRadius: radius - 3, style: .continuous))
                        .padding(3)
                }

                if showPromoOverlay {
                    PromoOverlayPreview(promoCode: promoCode, w: w)
                        .clipShape(RoundedRectangle(cornerRadius: radius - 3, style: .continuous))
                        .padding(3)
                }

                if showSubtitles, !subtitleSegments.isEmpty {
                    SubtitlePreviewOverlay(
                        segments: subtitleSegments,
                        appearance: subtitleAppearance,
                        w: w)
                        .clipShape(RoundedRectangle(cornerRadius: radius - 3, style: .continuous))
                        .padding(3)
                }

                if showWatermark, !watermarkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    WatermarkPreviewOverlay(
                        text: watermarkText,
                        appearance: watermarkAppearance,
                        w: w)
                        .clipShape(RoundedRectangle(cornerRadius: radius - 3, style: .continuous))
                        .padding(3)
                }

                if let overlayHook, !overlayHook.trimmingCharacters(in: .whitespaces).isEmpty {
                    VStack(spacing: 0) {
                        Spacer().frame(height: w * 0.30)
                        Text(overlayHook)
                            .font(.system(size: w * 0.042, weight: .heavy))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, w * 0.05).padding(.vertical, w * 0.03)
                            .background(.black.opacity(0.55),
                                        in: RoundedRectangle(cornerRadius: w * 0.04))
                            .padding(.horizontal, w * 0.07)
                        Spacer()
                    }
                    .allowsHitTesting(false)
                }
            }
        }
    }
}

// MARK: - Player sheet (with sound + native controls)

struct ClipPlayerSheet: View {
    @Bindable var clip: ShortClip
    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var settings
    @State private var player: AVPlayer?
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var temporaryURL: URL?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(clip.displayTitle).font(.headline).lineLimit(1)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()
            ZStack {
                Color.black
                if let player {
                    VideoPlayer(player: player)
                } else if loading {
                    ProgressView("Preparing preview…")
                        .controlSize(.large)
                        .tint(.white)
                        .foregroundStyle(.white)
                } else if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .padding()
                        .textSelection(.enabled)
                }
            }
            .frame(width: 372, height: 660)
        }
        .task { await load() }
        .onDisappear {
            player?.pause()
            player?.replaceCurrentItem(with: nil)
            player = nil
            if let temporaryURL {
                try? FileManager.default.removeItem(at: temporaryURL)
            }
        }
    }

    private func load() async {
        loading = true
        errorMessage = nil
        do {
            let enhance = VideoEnhancementOptions(
                preset: clip.videoEnhancementPreset,
                rifeFrameRate: clip.videoEnhancementRifeFPS,
                realesrganScale: clip.videoEnhancementScale,
                sharpness: clip.videoEnhancementSharpness,
                contrast: clip.videoEnhancementContrast,
                saturation: clip.videoEnhancementSaturation,
                bitrateMbps: clip.videoEnhancementBitrate)
            let preview = try await clip.makePreviewFile(
                workingDirectory: settings.workingDirectory,
                enhancementOptions: enhance)
            temporaryURL = preview.isTemporary ? preview.url : nil
            let p = AVPlayer(url: preview.url)
            p.play()
            player = p
        } catch {
            errorMessage = error.localizedDescription
            if let url = clip.clipJob?.url {
                let p = AVPlayer(url: url)
                p.play()
                player = p
            }
        }
        loading = false
    }
}

// MARK: - Editor sheet (the full per-clip caption editor)

struct ClipEditorSheet: View {
    @Bindable var clip: ShortClip
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Редактирование шортса")
                    .font(.headline)
                Spacer()
                Button("Готово") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)

            Divider()

            ShortClipCard(clip: clip)
                .padding(14)
        }
        .frame(minWidth: 1060, idealWidth: 1140, minHeight: 740, idealHeight: 820)
    }
}

// MARK: - Video Thumbnail View

struct VideoThumbnailView: View {
    let url: URL
    @State private var thumbnail: NSImage?

    var body: some View {
        ZStack {
            Color.black
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.black
            }
        }
        .task(id: url) {
            thumbnail = await Self.makeThumbnail(for: url)
        }
    }

    /// The clip file is often still being flushed to disk when the tile first
    /// appears, so a single `image(at:)` attempt fails silently and leaves the
    /// preview black forever. Retry with backoff and fall back to time zero
    /// (some codecs can't seek to 0.5s) before giving up.
    private static func makeThumbnail(for url: URL) async -> NSImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)

        let times: [CMTime] = [
            CMTime(seconds: 0.5, preferredTimescale: 600),
            CMTime(seconds: 0.0, preferredTimescale: 600)
        ]
        let delays: [UInt64] = [0, 250_000_000, 500_000_000, 1_000_000_000]

        for delay in delays {
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            if Task.isCancelled { return nil }
            for time in times {
                if let cgImage = try? await generator.image(at: time).image {
                    return NSImage(cgImage: cgImage,
                                   size: NSSize(width: cgImage.width, height: cgImage.height))
                }
            }
        }
        return nil
    }
}
