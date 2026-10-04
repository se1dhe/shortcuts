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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            phoneArea
            footer
        }
        .padding(10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.quaternary))
        .opacity(clip.isApproved ? 1 : 0.5)
        .sheet(isPresented: $showEditor) { ClipEditorSheet(clip: clip) }
        .sheet(isPresented: $showPlayer) {
            ClipPlayerSheet(clip: clip)
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
                placeholder { Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).multilineTextAlignment(.center)
                    .textSelection(.enabled) }
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
                    .background(.black.opacity(0.55), in: Capsule())
                    .foregroundStyle(.white)
                if clip.isRendered {
                    Image(systemName: "aspectratio")
                        .font(.caption2.weight(.bold))
                        .padding(5)
                        .background(.black.opacity(0.55), in: Circle())
                        .foregroundStyle(.white)
                }
                if clip.backgroundMusicEnabled {
                    Image(systemName: "music.note")
                        .font(.caption2.weight(.bold))
                        .padding(5)
                        .background(.black.opacity(0.55), in: Circle())
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
                        .background(Circle().fill(.black.opacity(0.35)))
                }
                .buttonStyle(.plain)
                .help(clip.isApproved ? "Approved — included in Publish all" : "Not approved")
            }
            Spacer()
            // Action bar.
            HStack(spacing: 8) {
                tileButton("play.fill", "Смотреть со звуком") { showPlayer = true }
                tileButton("square.and.pencil", "Редактировать") { showEditor = true }
                if clip.isExporting {
                    ProgressView().controlSize(.small).frame(width: 30, height: 30)
                } else {
                    tileButton("arrow.down.circle", "Скачать MP4") { downloadClip() }
                }
            }
            .padding(6)
            .background(.black.opacity(0.4), in: Capsule())
        }
        .padding(10)
    }

    private func tileButton(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func downloadClip() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = clip.suggestedFileName
        panel.canCreateDirectories = true
        panel.title = String(localized: "Download short")
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            Task {
                let enhance = VideoEnhancementOptions(
                    preset: clip.videoEnhancementPreset,
                    rifeFrameRate: clip.videoEnhancementRifeFPS,
                    realesrganScale: clip.videoEnhancementScale,
                    sharpness: clip.videoEnhancementSharpness,
                    contrast: clip.videoEnhancementContrast,
                    saturation: clip.videoEnhancementSaturation,
                    bitrateMbps: clip.videoEnhancementBitrate)
                await clip.export(
                    to: destination,
                    workingDirectory: settings.workingDirectory,
                    customMusicDirectory: settings.customMusicDirectory,
                    enhancementOptions: enhance)
            }
        }
    }

    // MARK: - Footer (hook + platform dots)

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(clip.displayTitle)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                ForEach(clip.variants) { variant in
                    Image(systemName: variant.platform.symbolName)
                        .font(.caption2)
                        .foregroundStyle(variant.platform.tint)
                }
                Spacer()
                if let err = clip.exportError {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2).foregroundStyle(.orange).help(err)
                }
                if let date = clip.scheduledDate {
                    Label(Self.shortDate(date), systemImage: "calendar")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.blue)
                        .help("Scheduled")
                } else if clip.publishReport != nil {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.caption2).foregroundStyle(.green).help("Published")
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 2)
    }

    private static func shortDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "d MMM, HH:mm"
        return f.string(from: date)
    }

}

// MARK: - Mini phone

/// A small phone-framed, silent, looping preview of one clip.
private struct MiniPhone: View {
    let url: URL
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
                PhoneVideoPlayer(url: url)
                    .clipShape(RoundedRectangle(cornerRadius: radius - 3, style: .continuous))
                    .padding(3)

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
                Text("Edit short").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(14)
            Divider()
            ScrollView {
                ShortClipCard(clip: clip).padding(20)
            }
        }
        .frame(width: 920, height: 720)
    }
}
