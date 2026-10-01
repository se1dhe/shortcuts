import SwiftUI

/// Results for the long-video flow: a grid of generated shorts you can scan at a
/// glance. Each tile previews one clip in a phone frame with quick actions
/// (play with sound, download, approve) and opens the full caption editor on tap.
struct ShortsResultsView: View {

    @Environment(AppSettings.self) private var settings
    @Environment(WorkspaceModel.self) private var workspace
    @Environment(MovieShortsBrowserModel.self) private var browser
    @Environment(ModelManager.self) private var modelManager
    @State private var showingScheduler = false

    enum ViewMode: String, CaseIterable, Identifiable {
        case grid = "Сетка"
        case compare = "Сравнение"
        var id: String { rawValue }
    }

    @State private var viewMode: ViewMode = .grid
    private let columns = [GridItem(.adaptive(minimum: 190, maximum: 240), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            mainContent
            Divider()
            footer
        }
        .sheet(isPresented: $showingScheduler) { ScheduleSheet() }
        .onAppear {
            workspace.applyCurrentSubtitleSettings(settings)
            workspace.applyCurrentWatermarkSettings(settings)
            workspace.applyCurrentPromoSettings(settings)
            workspace.applyCurrentHookSettings(settings)
        }
        .onChange(of: settings.hookAppearance) { _, _ in
            workspace.applyCurrentHookSettings(settings)
        }
        .onChange(of: settings.burnSubtitles) { _, _ in
            workspace.applyCurrentSubtitleSettings(settings)
        }
        .onChange(of: settings.subtitleAppearance) { _, _ in
            workspace.applyCurrentSubtitleSettings(settings)
        }
        .onChange(of: settings.watermarkEnabled) { _, _ in
            workspace.applyCurrentWatermarkSettings(settings)
        }
        .onChange(of: settings.watermarkText) { _, _ in
            workspace.applyCurrentWatermarkSettings(settings)
        }
        .onChange(of: settings.watermarkAppearance) { _, _ in
            workspace.applyCurrentWatermarkSettings(settings)
        }
        .onChange(of: settings.promoOverlayEnabled) { _, _ in
            workspace.applyCurrentPromoSettings(settings)
        }
        .onChange(of: settings.promoCode) { _, _ in
            workspace.applyCurrentPromoSettings(settings)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(LinearGradient(colors: [.accentColor, .accentColor.opacity(0.55)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 42, height: 42)
                Image(systemName: "scissors")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(workspace.job?.fileName ?? "Your shorts")
                    .font(.title3.weight(.bold))
                    .lineLimit(1)
                HStack(spacing: 8) {
                    statChip("\(workspace.clips.count) shorts", "rectangle.stack")
                    if let lang = workspace.clips.compactMap(\.detectedLanguage).first {
                        statChip(lang.uppercased(), "globe")
                    }
                    statChip("\(workspace.approvedReadyCount) approved", "checkmark.circle")
                }
            }

            Picker("Режим", selection: $viewMode) {
                ForEach(ViewMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 170)

            Spacer()

            if browser.cameFromRecommendations {
                Button {
                    browser.cameFromRecommendations = false
                    browser.selectedTab = .shorts
                    workspace.startOver()
                } label: {
                    Label("Back to shorts", systemImage: "chevron.left")
                }
                .controlSize(.large)
            }

            Button {
                browser.cameFromRecommendations = false
                workspace.startOver()
            } label: {
                Label("Start over", systemImage: "arrow.counterclockwise")
            }
            .controlSize(.large)
            
            Button {
                workspace.regenerateShorts(modelManager: modelManager, settings: settings)
            } label: {
                Label("Regenerate", systemImage: "sparkles")
            }
            .controlSize(.large)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var mainContent: some View {
        switch viewMode {
        case .grid:
            gridView
        case .compare:
            batchCompareView
        }
    }

    private var gridView: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 18) {
                ForEach(workspace.clips) { clip in
                    ShortClipTile(clip: clip)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
        }
    }

    private var batchCompareView: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(spacing: 20) {
                ForEach(Array(workspace.clips.enumerated()), id: \.element.id) { index, clip in
                    BatchCompareCard(index: index, clip: clip)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
        }
    }

    private func statChip(_ text: String, _ symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(.quaternary, in: Capsule())
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        HStack {
            if settings.tiktokAsDraft {
                Label("TikTok uploads as a draft", systemImage: "tray.and.arrow.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()

            if settings.isConfigured {
                Button {
                    workspace.applyCurrentSubtitleSettings(settings)
                    workspace.applyCurrentWatermarkSettings(settings)
                    workspace.applyCurrentPromoSettings(settings)
                    showingScheduler = true
                } label: {
                    Label("Schedule…", systemImage: "calendar.badge.clock")
                        .frame(minWidth: 120)
                }
                .controlSize(.large)
                .disabled(workspace.approvedReadyCount == 0)

                Button {
                    Task {
                        workspace.applyCurrentSubtitleSettings(settings)
                        workspace.applyCurrentWatermarkSettings(settings)
                        workspace.applyCurrentPromoSettings(settings)
                        await workspace.publishAllApproved(settings: settings)
                    }
                } label: {
                    if workspace.isPublishingAll {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Publishing…")
                        }
                        .frame(minWidth: 200)
                    } else {
                        Label("Publish now (\(workspace.approvedReadyCount))",
                              systemImage: "paperplane.fill")
                            .frame(minWidth: 200)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(workspace.isPublishingAll || workspace.approvedReadyCount == 0)
            } else {
                HStack(spacing: 10) {
                    Text("Connect your Upload-Post account to publish.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    SettingsLink { Text("Open Settings") }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

private struct BatchCompareCard: View {
    let index: Int
    @Bindable var clip: ShortClip

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Вариант #\(index + 1)")
                    .font(.headline.weight(.bold))
                Spacer()
                Label("\(clip.candidate.viralScore)", systemImage: "flame.fill")
                    .font(.subheadline.weight(.heavy))
                    .foregroundStyle(.orange)
            }

            ShortClipTile(clip: clip)
                .frame(width: 250)

            VStack(alignment: .leading, spacing: 6) {
                Text(clip.candidate.hook)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Text(clip.candidate.why)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            .frame(width: 250)
        }
        .padding(14)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
    }
}
