import SwiftUI
import AppKit
import AVFoundation

/// One generated short: its hook + rationale, an Approve toggle, the three
/// editable platform previews of the cut clip, and a per-clip Publish action.
struct ShortClipCard: View {

    @Bindable var clip: ShortClip
    @Environment(AppSettings.self) private var settings
    @Environment(ModelManager.self) private var modelManager
    @Environment(LanguageManager.self) private var languageManager

    @State private var manualMovieTitle = ""
    @State private var manualMovieYear = ""
    @State private var manualMovieError: String?
    @State private var detectedMovie: TMDBMovie?
    @State private var movieCandidates: [TMDBMovie] = []
    @State private var isRegeneratingCinemaContent = false

    @State private var publishPlatforms: Set<SocialPlatform> = Set(SocialPlatform.allCases)
    @State private var showBrowserPublish = false
    @State private var showSubtitleEditor = false
    @State private var previewPlatform: SocialPlatform = .tiktok

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            switch clip.stage {
            case .pending, .cutting, .captioning:
                working
            case .failed(let message):
                failed(message)
            case .ready:
                mainContentEditor
                quickFinish
                advancedOptions
                footer
            }
        }
        .padding(18)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.quaternary))
        .opacity(clip.isApproved ? 1 : 0.55)
        .sheet(isPresented: publishResultPresented) {
            PublishResultView(report: clip.publishReport, error: clip.publishError)
        }
        .sheet(isPresented: $showBrowserPublish) {
            BrowserPublishSheet(clip: clip)
        }
        .sheet(isPresented: $showSubtitleEditor) {
            ShortSubtitleEditorView(clip: clip)
        }
        .onChange(of: clip.detectedMovieTitle) { _, newValue in
            if !newValue.trimmed.isEmpty { manualMovieTitle = newValue }
        }
        .onChange(of: clip.detectedMovieYear) { _, newValue in
            if !newValue.trimmed.isEmpty { manualMovieYear = newValue }
        }
        .onChange(of: clip.burnSubtitles) { _, newValue in
            settings.burnSubtitles = newValue
        }
        .onChange(of: clip.subtitleAppearance) { _, newValue in
            settings.subtitleAppearance = newValue
        }
        .onChange(of: clip.watermarkEnabled) { _, newValue in
            settings.watermarkEnabled = newValue
        }
        .onChange(of: clip.watermarkText) { _, newValue in
            settings.watermarkText = newValue
        }
        .onChange(of: clip.watermarkAppearance) { _, newValue in
            settings.watermarkAppearance = newValue
        }
        .onChange(of: clip.promoOverlayEnabled) { _, newValue in
            settings.promoOverlayEnabled = newValue
        }
        .onChange(of: clip.promoCode) { _, newValue in
            settings.promoCode = newValue
        }
        .onChange(of: clip.hookAppearance) { _, newValue in
            settings.hookAppearance = newValue
        }
    }


    private var hookSizeLabel: String {
        let scale = clip.hookAppearance.sizeScale
        if scale < 0.028 { return "Small" }
        if scale < 0.04 { return "Medium" }
        return "Large"
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(clip.displayTitle)
                    .font(.headline)
                HStack(spacing: 6) {
                    Label(clip.candidate.rangeLabel, systemImage: "scissors")
                    Text("·  \(Int(clip.candidate.duration.rounded()))s")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if !clip.candidate.why.isEmpty {
                    Text(clip.candidate.why)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            Toggle("Approve", isOn: $clip.isApproved)
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }

    // MARK: - States

    private var working: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(clip.stage == .cutting ? "Cutting the clip…" : "Writing captions…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 24)
    }

    private func failed(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.callout)
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12)
            .textSelection(.enabled)
    }

    @ViewBuilder
    private var trimEditor: some View {
        if let url = clip.clipJob?.url, let duration = clip.clipJob?.durationSeconds, duration > 0 {
            ClipTrimEditor(
                videoURL: url,
                duration: duration,
                trimStart: $clip.trimStartSeconds,
                trimEnd: $clip.trimEndSeconds)
        }
    }

    private var reframeEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $clip.reframeEnabled) {
                Label("Convert to vertical (9:16)", systemImage: "aspectratio")
                    .font(.callout)
            }
            .toggleStyle(.switch)

            if clip.reframeEnabled {
                Text("Tracks the speaker and reframes this horizontal clip for TikTok/Reels/Shorts when you publish.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 10))
    }

    /// Appearance-only tuning for the on-video hook. Its enable toggle and text live in
    /// the main editor (the hook field); this just styles it, shown when it's enabled.
    private var overlayEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            if clip.overlayEnabled {
                Text("Hook appearance")
                    .font(.callout.weight(.medium))

                Picker("Hook style", selection: $clip.hookAppearance.styleRaw) {
                    ForEach(HookAppearance.HookStyle.allCases) { style in
                        Text(LocalizedStringKey(style.displayName)).tag(style.rawValue)
                    }
                }
                .pickerStyle(.menu)

                HStack(spacing: 12) {
                    Text("Size")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .leading)
                    Slider(value: $clip.hookAppearance.sizeScale, in: 0.020...0.055, step: 0.002)
                        .controlSize(.small)
                    Text(hookSizeLabel)
                        .font(.caption.monospacedDigit())
                        .frame(width: 56, alignment: .trailing)
                }

                Text("Burned into the video when you publish (text follows the hook above).")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                Text("Enable “Показать хук на видео” above to style the on-video hook.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 10))
    }

    private var promoEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $clip.promoOverlayEnabled) {
                Label("RedQueen bot promo (top)", systemImage: "shield.lefthalf.filled")
                    .font(.callout)
            }
            .toggleStyle(.switch)

            if clip.promoOverlayEnabled {
                Text("Slim animated @RedQueenSecurity_Bot chip at the top of the video. Burned in when you publish or download.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 10))
    }

    private var subtitleEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $clip.burnSubtitles) {
                Label("Burn subtitles from transcript", systemImage: "captions.bubble")
                    .font(.callout)
            }
            .toggleStyle(.switch)

            if clip.burnSubtitles {
                SubtitleAppearanceEditor(appearance: $clip.subtitleAppearance)

                Button {
                    showSubtitleEditor = true
                } label: {
                    Label("Редактировать текст субтитров", systemImage: "square.and.pencil")
                        .font(.callout)
                }
                .buttonStyle(.bordered)
                .disabled(clip.subtitleSegments.isEmpty)
                .help(clip.subtitleSegments.isEmpty ? "Для этого клипа нет субтитров" : "Править текст, объединять и разбивать строки субтитров")

                Text("Uses the transcript to burn synced subtitles into the video when you publish.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 10))
    }

    private var watermarkEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $clip.watermarkEnabled) {
                Label("Watermark overlay", systemImage: "water.waves")
                    .font(.callout)
            }
            .toggleStyle(.switch)

            if clip.watermarkEnabled {
                TextField("Watermark text", text: $clip.watermarkText, prompt: Text("@yourhandle"))
                    .textFieldStyle(.roundedBorder)
                ClipWatermarkAppearanceEditor(appearance: $clip.watermarkAppearance)
            }
        }
        .padding(10)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 10))
    }

    private var musicEditor: some View {
        ShortClipAudioEditor(clip: clip)
    }

    private var enhancementEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Enhancement", selection: $clip.videoEnhancementPreset) {
                ForEach(VideoEnhancementPreset.allCases) { preset in
                    Text(preset.displayName).tag(preset)
                }
            }
            .pickerStyle(.segmented)

            if clip.videoEnhancementPreset != .off {
                sliderRow("Sharpness",
                          value: $clip.videoEnhancementSharpness,
                          range: 0.5...3.0, step: 0.1, format: "%.1f")
                sliderRow("Contrast",
                          value: $clip.videoEnhancementContrast,
                          range: 0.8...1.5, step: 0.05, format: "%.2f")
                sliderRow("Saturation",
                          value: $clip.videoEnhancementSaturation,
                          range: 0.8...1.5, step: 0.05, format: "%.2f")
                sliderRow("Bitrate",
                          value: Binding(get: { Double(clip.videoEnhancementBitrate) },
                                        set: { clip.videoEnhancementBitrate = Int($0) }),
                          range: 10.0...100.0,
                          step: 5, format: "%.0f Mbps")
            }

            if clip.videoEnhancementPreset.usesRIFE {
                sliderRow("RIFE FPS",
                          value: Binding(get: { Double(clip.videoEnhancementRifeFPS) },
                                        set: { clip.videoEnhancementRifeFPS = Int($0) }),
                          range: 60.0...120.0,
                          step: 60, format: "%.0f")
            }
        }
        .padding(10)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 10))
    }



    @ViewBuilder
    private var previews: some View {
        if let videoURL = clip.clipJob?.url {
            HStack(alignment: .top, spacing: 16) {
                ForEach($clip.variants) { $variant in
                    PostPreviewCard(
                        variant: $variant,
                        videoURL: videoURL,
                        overlayHook: clip.overlayEnabled ? clip.overlayText : nil,
                        hookAppearance: clip.hookAppearance,
                        subtitleSegments: clip.subtitleSegments,
                        subtitleAppearance: clip.subtitleAppearance,
                        showSubtitles: clip.burnSubtitles,
                        watermarkText: clip.watermarkText,
                        watermarkAppearance: clip.watermarkAppearance,
                        showWatermark: clip.watermarkEnabled,
                        showPromoOverlay: clip.promoOverlayEnabled,
                        promoCode: clip.promoCode,
                        trimStart: clip.trimStartSeconds,
                        trimEnd: clip.trimEndSeconds)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    // MARK: - Cinema quick editor (main section, YouTube clips only)

    /// Binding to the TikTok variant's hook (the text shown on social media,
    /// not the burned-in overlay). Falls back to a no-op when no variant exists.
    private var tiktokHookBinding: Binding<String> {
        Binding(
            get: {
                clip.variants.first(where: { $0.platform == .tiktok })?.hook ?? ""
            },
            set: { newValue in
                // Capture the old hook before writing the new one so we can
                // decide whether to sync overlayText (only when it was matching).
                let oldHook = clip.variants.first(where: { $0.platform == .tiktok })?.hook ?? ""
                if let idx = clip.variants.firstIndex(where: { $0.platform == .tiktok }) {
                    clip.variants[idx].hook = newValue
                }
                let overlayMatchedOldHook = clip.overlayText.trimmed == oldHook.trimmed
                    || clip.overlayText.trimmed.isEmpty
                if overlayMatchedOldHook {
                    clip.overlayText = newValue.truncatingToHook(limit: 60)
                }
            })
    }

    /// Binding to the TikTok variant's summary (description / caption body).
    private var tiktokSummaryBinding: Binding<String> {
        Binding(
            get: {
                clip.variants.first(where: { $0.platform == .tiktok })?.summary ?? ""
            },
            set: { newValue in
                if let idx = clip.variants.firstIndex(where: { $0.platform == .tiktok }) {
                    clip.variants[idx].summary = newValue
                }
            })
    }

    private var movieTitleBinding: Binding<String> {
        Binding(
            get: {
                if !manualMovieTitle.trimmed.isEmpty { return manualMovieTitle }
                return clip.detectedMovieTitle
            },
            set: { newValue in
                manualMovieTitle = newValue
                clip.detectedMovieTitle = newValue
            })
    }

    private var movieYearBinding: Binding<String> {
        Binding(
            get: {
                if !manualMovieYear.trimmed.isEmpty { return manualMovieYear }
                return clip.detectedMovieYear
            },
            set: { newValue in
                manualMovieYear = newValue
                clip.detectedMovieYear = newValue
            })
    }

    /// Combined binding for description + hashtags in one editor window with paragraph spacing.
    private var combinedDescriptionAndHashtagsBinding: Binding<String> {
        Binding(
            get: {
                let target = clip.variants.first(where: { $0.platform == previewPlatform }) ?? clip.variants.first
                let summary = target?.summary.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let tags = target?.hashtagLine.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return [summary, tags].filter { !$0.isEmpty }.joined(separator: "\n\n")
            },
            set: { newValue in
                let (summary, tags) = SocialCopyBox.splitCombined(newValue)
                if let idx = clip.variants.firstIndex(where: { $0.platform == previewPlatform }) {
                    clip.variants[idx].summary = summary
                    clip.variants[idx].hashtags = tags
                } else {
                    clip.variants.append(PostVariant(
                        platform: previewPlatform,
                        hook: clip.displayTitle,
                        summary: summary,
                        hashtags: tags,
                        pinnedComment: ""
                    ))
                }
            })
    }

    /// Master content editor section (Main Card).
    /// Displays film name, release year, TMDB search, hook, and combined description + hashtags in ONE beautiful window.
    @ViewBuilder
    private var mainContentEditor: some View {
        VStack(alignment: .leading, spacing: 12) {

            // ── Movie title & year ─────────────────────────────────────
            HStack(spacing: 8) {
                Label("Фильм / Сериал", systemImage: "film")
                    .font(.headline)
                Spacer()
                if isRegeneratingCinemaContent {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        regenerateCinemaContent()
                    } label: {
                        Label("Обновить из TMDB", systemImage: "arrow.clockwise")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .disabled(manualMovieTitle.trimmed.isEmpty)
                }
            }

            HStack(spacing: 6) {
                TextField("Название фильма", text: movieTitleBinding)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if !manualMovieTitle.trimmed.isEmpty { regenerateCinemaContent() } }
                TextField("Год", text: movieYearBinding)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .onSubmit { if !manualMovieTitle.trimmed.isEmpty { regenerateCinemaContent() } }
            }

            if movieCandidates.count > 1 {
                Picker("Выбрать вариант фильма", selection: selectedCandidateBinding) {
                    ForEach(movieCandidates) { candidate in
                        Text(candidate.pickerLabel).tag(candidate.id)
                    }
                }
                .pickerStyle(.menu)
                .disabled(isRegeneratingCinemaContent)
            }

            if let err = manualMovieError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            Divider()

            // ── Hook ───────────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 6) {
                Text("Хук (заголовок)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("🎬 Название фильма (2008)", text: tiktokHookBinding, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...2)
                Toggle(isOn: $clip.overlayEnabled) {
                    Label("Показать хук на видео (первые 3с)", systemImage: "textformat")
                        .font(.callout)
                }
                .toggleStyle(.switch)
            }

            // ── Description & Hashtags (Combined in one window) ────────
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Описание и хештеги:")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: $clip.descriptionMode) {
                        Text("Фильм").tag(CinemaContentGenerator.DescriptionMode.movie)
                        Text("Сцена").tag(CinemaContentGenerator.DescriptionMode.scene)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 140)
                    .disabled(settings.textAdEnabled)
                    .onChange(of: clip.descriptionMode) { _, _ in
                        regenerateCinemaContent()
                    }
                }

                Picker("Платформа", selection: $previewPlatform) {
                    ForEach(SocialPlatform.allCases) { platform in
                        Label(platform.rawValue.capitalized, systemImage: platform.symbolName)
                            .tag(platform)
                    }
                }
                .pickerStyle(.segmented)

                Toggle(isOn: Binding(
                    get: { settings.textAdEnabled },
                    set: { settings.textAdEnabled = $0; regenerateCinemaContent() }
                )) {
                    Label("Текстовая реклама бота — описание = промо @RedQueenSecurity_Bot",
                          systemImage: "megaphone.fill")
                        .font(.caption)
                }
                .toggleStyle(.switch)

                TextEditor(text: combinedDescriptionAndHashtagsBinding)
                    .font(.callout)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 140, maxHeight: 220)
                    .padding(8)
                    .background(.background, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
            }

            if let url = clip.sourceMetadata?.webpageURL {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.right.square").font(.caption2)
                    Text("Open on YouTube").font(.caption)
                }
                .foregroundStyle(.tint)
                .contentShape(Rectangle())
                .onTapGesture { NSWorkspace.shared.open(url) }
            }
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
        .onAppear { seedMovieFieldsFromSource() }
    }


    // MARK: - Footer (per-clip publish)

    /// The common path for a downloaded YouTube Short: optionally add subtitles
    /// and a watermark, inspect TikTok risks, then export or publish from the
    /// tile/footer.
    private var quickFinish: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Finish this Short")
                .font(.headline)
            subtitleEditor
            watermarkEditor
            musicEditor
            AntiCopyrightEditor(clip: clip)
            tiktokPreflight
        }
    }

    @ViewBuilder
    private var advancedOptions: some View {
        DisclosureGroup("Advanced editing") {
            VStack(alignment: .leading, spacing: 14) {
                trimEditor
                if clip.isLandscape { reframeEditor }
                overlayEditor
                promoEditor
                enhancementEditor
                previews
            }
            .padding(.top, 12)
        }
        .font(.callout.weight(.medium))
        .padding(12)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 10))
    }


    @ViewBuilder
    private var tiktokPreflight: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("TikTok preflight", systemImage: "checkmark.shield")
                    .font(.headline)
                Spacer()
                Button("Check") {
                    Task { await clip.runTikTokPreflight() }
                }
                .disabled(clip.clipJob == nil)
            }
            Text("Checks basic file readiness and highlights content, originality and music-rights risks. It cannot guarantee moderation, copyright clearance or reach.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let report = clip.tiktokPreflightReport {
                ForEach(report.findings) { finding in
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(finding.title).font(.subheadline.weight(.medium))
                            Text(finding.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: preflightSymbol(for: finding.severity))
                            .foregroundStyle(preflightColor(for: finding.severity))
                    }
                }
            }
        }
        .padding(12)
        .background(.background.tertiary, in: RoundedRectangle(cornerRadius: 10))
    }

    private func preflightSymbol(for severity: TikTokPreflightService.Severity) -> String {
        switch severity {
        case .info: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    private func preflightColor(for severity: TikTokPreflightService.Severity) -> Color {
        switch severity {
        case .info: .green
        case .warning: .orange
        case .error: .red
        }
    }

    @ViewBuilder
    private var footer: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Button {
                    showBrowserPublish = true
                } label: {
                    Label("Автопубликация (Google Chrome)", systemImage: "globe.badge.chevron.backward")
                        .font(.callout.weight(.medium))
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .disabled(clip.clipJob == nil || clip.variants.isEmpty)

                Button {
                    Task { await clip.publishToTelegram(settings: settings) }
                } label: {
                    if clip.isPublishingToTelegram {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Отправка в TG…")
                        }
                    } else {
                        Label("Пост в Telegram", systemImage: "paperplane.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(hex: "2AABEE"))
                .disabled(clip.isPublishingToTelegram || settings.telegramBotToken.trimmed.isEmpty)
                .help(settings.telegramBotToken.trimmed.isEmpty ? "Укажите токен бота в Настройках (⌘,)" : "Опубликовать карточку фильма в \(settings.telegramChannelId.trimmed.isEmpty ? "Telegram-канал" : settings.telegramChannelId.trimmed)")

                Spacer()

                if settings.isConfigured {
                    HStack(spacing: 8) {
                        ForEach([SocialPlatform.tiktok, .instagram, .youtube]) { platform in
                            let active = publishPlatforms.contains(platform)
                            Button {
                                if active {
                                    if publishPlatforms.count > 1 { publishPlatforms.remove(platform) }
                                } else {
                                    publishPlatforms.insert(platform)
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: platform.symbolName)
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(active ? Color(hex: platform.tintHex) : .secondary)
                                    Text(platform.rawValue.capitalized)
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(active ? .primary : .secondary)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(active ? Color.secondary.opacity(0.14) : Color.secondary.opacity(0.04), in: Capsule())
                                .overlay(Capsule().strokeBorder(active ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Button {
                        Task { await clip.publish(settings: settings, selectedPlatforms: publishPlatforms) }
                    } label: {
                        if clip.isPublishing {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Выгрузка…")
                            }
                            .frame(minWidth: 140)
                        } else {
                            Label("Через API (\(publishPlatforms.filter { $0 != .telegram }.count))", systemImage: "paperplane.fill")
                                .frame(minWidth: 140)
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(clip.isPublishing || clip.variants.isEmpty)
                } else {
                    Text("API Upload-Post не настроен")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            if let tgURL = clip.telegramPostURL {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Опубликовано в Telegram:")
                        .font(.caption)
                    Link(tgURL, destination: URL(string: tgURL)!)
                        .font(.caption.weight(.semibold))
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            } else if let tgErr = clip.telegramPublishError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Ошибка отправки в Telegram: \(tgErr)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var publishResultPresented: Binding<Bool> {
        Binding(
            get: { clip.publishReport != nil || clip.publishError != nil },
            set: { if !$0 { clip.dismissPublishResult() } })
    }

    // MARK: - Cinema regeneration

    /// Binding that drives the disambiguation menu: reading returns the current
    /// movie's id; picking a different one re-applies content for that movie
    /// without another TMDB search.
    private var selectedCandidateBinding: Binding<String> {
        Binding(
            get: { detectedMovie?.id ?? movieCandidates.first?.id ?? "" },
            set: { newID in
                guard let picked = movieCandidates.first(where: { $0.id == newID }) else { return }
                applyCinemaContent(for: picked)
            })
    }

    /// Language for the scene description. Falls back through: manual caption
    /// override → the clip's detected language → the app UI language. Without
    /// this, an empty override made the scene describer default to English even
    /// with the app in Russian.
    private var effectiveDescriptionLanguage: String {
        let override = settings.languageOverride.trimmed
        if !override.isEmpty { return override }
        if let detected = clip.detectedLanguage?.trimmed, !detected.isEmpty { return detected }
        return languageManager.selectedLanguage.rawValue
    }

    private func regenerateCinemaContent(preselected: TMDBMovie? = nil) {
        let title = manualMovieTitle.trimmed
        let year = sanitizedMovieYear(manualMovieYear)
        guard !title.isEmpty else {
            manualMovieError = "Enter movie title."
            return
        }

        manualMovieYear = year
        manualMovieError = nil
        isRegeneratingCinemaContent = true

        Task {
            let query = CinemaContentGenerator.MovieSearchQuery(
                title: title,
                year: year.isEmpty ? nil : year)
            let sourceText = [
                clip.sourceMetadata?.title,
                clip.sourceMetadata?.description,
                clip.displayTitle
            ]
                .compactMap { $0?.trimmed }
                .joined(separator: " ")

            await modelManager.prepareDirectorIfNeeded()
            let mode = clip.descriptionMode
            let result = await CinemaContentGenerator.generate(
                query: query,
                sourceText: sourceText,
                tmdbAPIKey: settings.tmdbAPIKey,
                descriptionMode: mode,
                textAd: settings.textAdEnabled,
                preselectedMovie: preselected,
                channelHandle: settings.telegramChannelId,
                sceneDescriptionProvider: {
                    await modelManager.momentFinder.describeScene(
                        transcriptSlice: clip.transcriptSlice,
                        movieTitle: title,
                        language: effectiveDescriptionLanguage)
                },
                hookProvider: {
                    await modelManager.momentFinder.generateSocialHooks(
                        transcriptSlice: clip.transcriptSlice,
                        movieTitle: title,
                        language: effectiveDescriptionLanguage) ?? [:]
                },
                fallbackMovieProvider: {
                    await modelManager.momentFinder.inferMovie(query: query, sourceText: sourceText)
                })

            movieCandidates = result.candidates
            detectedMovie = result.movie
            manualMovieTitle = result.query.title
            manualMovieYear = result.query.year ?? ""
            clip.detectedMovieTitle = result.query.title
            clip.detectedMovieYear = result.query.year ?? ""
            manualMovieError = result.error

            CinemaContentGenerator.apply(
                content: result.content,
                to: clip,
                replaceHook: true,
                saveToHistory: true,
                settings: settings)

            isRegeneratingCinemaContent = false
        }
    }

    /// Re-applies cinema content for a specific movie the user picked in the
    /// disambiguation menu — no new TMDB search, keeps the current description mode.
    private func applyCinemaContent(for movie: TMDBMovie) {
        manualMovieError = nil
        isRegeneratingCinemaContent = true

        Task {
            let query = CinemaContentGenerator.MovieSearchQuery(title: movie.title, year: movie.year)
            await modelManager.prepareDirectorIfNeeded()
            let mode = clip.descriptionMode
            let result = await CinemaContentGenerator.generate(
                query: query,
                sourceText: "",
                tmdbAPIKey: settings.tmdbAPIKey,
                descriptionMode: mode,
                textAd: settings.textAdEnabled,
                preselectedMovie: movie,
                channelHandle: settings.telegramChannelId,
                sceneDescriptionProvider: {
                    await modelManager.momentFinder.describeScene(
                        transcriptSlice: clip.transcriptSlice,
                        movieTitle: movie.title,
                        language: effectiveDescriptionLanguage)
                },
                hookProvider: {
                    await modelManager.momentFinder.generateSocialHooks(
                        transcriptSlice: clip.transcriptSlice,
                        movieTitle: movie.title,
                        language: effectiveDescriptionLanguage) ?? [:]
                })

            detectedMovie = result.movie
            manualMovieTitle = result.query.title
            manualMovieYear = result.query.year ?? ""
            clip.detectedMovieTitle = result.query.title
            clip.detectedMovieYear = result.query.year ?? ""

            CinemaContentGenerator.apply(
                content: result.content,
                to: clip,
                replaceHook: true,
                saveToHistory: true,
                settings: settings)

            isRegeneratingCinemaContent = false
        }
    }

    private func seedMovieFieldsFromSource() {
        var seeded = false
        if !clip.detectedMovieTitle.trimmed.isEmpty {
            manualMovieTitle = clip.detectedMovieTitle
            manualMovieYear = clip.detectedMovieYear
            seeded = true
        } else {
            let candidateSources = [
                clip.sourceMetadata?.description,
                clip.sourceMetadata?.title,
            ]
            for source in candidateSources.compactMap({ $0?.trimmed }).filter({ !$0.isEmpty }) {
                if let query = CinemaContentGenerator.movieTitleGuess(from: source) {
                    manualMovieTitle = query.title
                    manualMovieYear = query.year ?? ""
                    clip.detectedMovieTitle = query.title
                    clip.detectedMovieYear = query.year ?? ""
                    seeded = true
                    break
                }
            }
        }

        if seeded && !manualMovieTitle.trimmed.isEmpty {
            let tiktokHook = clip.variants.first(where: { $0.platform == .tiktok })?.hook ?? ""
            let needsRegenerate = tiktokHook.isEmpty || tiktokHook == "Short clip" || !tiktokHook.contains("🎬")
            if needsRegenerate && !isRegeneratingCinemaContent {
                regenerateCinemaContent()
            }
        }
    }

    private func sanitizedMovieYear(_ raw: String) -> String {
        String(raw.filter(\.isNumber).prefix(4))
    }
}

private struct ClipWatermarkAppearanceEditor: View {

    @Binding var appearance: WatermarkAppearance

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            row("Position") {
                Picker("", selection: $appearance.positionRaw) {
                    ForEach(WatermarkAppearance.WatermarkPosition.allCases) { pos in
                        Text(LocalizedStringKey(pos.displayName)).tag(pos.rawValue)
                    }
                }
                .labelsHidden()
                .frame(width: 180)
            }

            row("Animation") {
                Picker("", selection: $appearance.animationRaw) {
                    ForEach(WatermarkAppearance.WatermarkAnimation.allCases) { anim in
                        Text(LocalizedStringKey(anim.displayName)).tag(anim.rawValue)
                    }
                }
                .labelsHidden()
                .frame(width: 180)
            }

            if appearance.animationRaw == "typewriter" {
                row("Speed") {
                    Slider(value: $appearance.typingDuration, in: 0.5...3.0, step: 0.25)
                        .controlSize(.small)
                    Text("\(appearance.typingDuration, specifier: "%.1f")s")
                        .font(.caption.monospacedDigit())
                        .frame(width: 36, alignment: .trailing)
                }
            }

            if appearance.animationRaw != "static" {
                row("Duration") {
                    Slider(value: $appearance.holdDuration, in: 0.5...8.0, step: 0.25)
                        .controlSize(.small)
                    Text("\(appearance.holdDuration, specifier: "%.1f")s")
                        .font(.caption.monospacedDigit())
                        .frame(width: 36, alignment: .trailing)
                }
            }

            row("Opacity") {
                Slider(value: $appearance.opacity, in: 0.3...1.0, step: 0.05)
                    .controlSize(.small)
                Text("\(Int(appearance.opacity * 100))%")
                    .font(.caption.monospacedDigit())
                    .frame(width: 36, alignment: .trailing)
            }

            row("Size") {
                Slider(value: $appearance.fontSizeScale, in: 0.015...0.045, step: 0.002)
                    .controlSize(.small)
                Text(LocalizedStringKey(sizeLabel))
                    .font(.caption.monospacedDigit())
                    .frame(width: 56, alignment: .trailing)
            }
        }
    }

    @ViewBuilder
    private func row(_ label: String, @ViewBuilder control: () -> some View) -> some View {
        HStack(spacing: 12) {
            Text(LocalizedStringKey(label))
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            control()
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sizeLabel: String {
        if appearance.fontSizeScale < 0.025 { return "Small" }
        if appearance.fontSizeScale < 0.035 { return "Medium" }
        return "Large"
    }
}

// MARK: - Helpers

private func sliderRow(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, format: String) -> some View {
    HStack(spacing: 12) {
        Text(LocalizedStringKey(label))
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(width: 72, alignment: .leading)
        Slider(value: value, in: range, step: step)
            .controlSize(.small)
        Text(String(format: format, value.wrappedValue))
            .font(.caption.monospacedDigit())
            .frame(width: 64, alignment: .trailing)
    }
}

// MARK: - Social copy box

private struct SocialCopyBox: View {

    @Binding var variant: PostVariant
    var promoCode: String = PromoOverlayConfig.default.promoCode
    var promoEnabled = false

    @State private var isRegeneratingPinnedComment = false
    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label {
                    Text(variant.platform.displayName)
                        .font(.caption.weight(.semibold))
                } icon: {
                    Image(systemName: variant.platform.symbolName)
                }
                .foregroundStyle(variant.platform.tint)

                Spacer()

                Button {
                    copyAll()
                } label: {
                    Label(didCopy ? "Copied" : "Copy",
                          systemImage: didCopy ? "checkmark" : "doc.on.doc")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.tint)
            }

            // One combined field — description and hashtags together, ready to
            // paste straight into TikTok/Reels/Shorts. Trailing '#' tokens are
            // parsed back into the hashtag list so the preview stays in sync.
            VStack(alignment: .leading, spacing: 5) {
                Text("Description and hashtags")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                TextEditor(text: combinedBinding)
                    .font(.callout)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 150)
                    .padding(6)
                    .background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
            }

            if promoEnabled {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("Pinned comment (1win promo)")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            regenerate()
                        } label: {
                            if isRegeneratingPinnedComment {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Regenerate")
                                    .font(.caption2)
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                        .disabled(isRegeneratingPinnedComment)
                    }
                    TextEditor(text: $variant.pinnedComment)
                        .font(.callout)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 72)
                        .padding(6)
                        .background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private func regenerate() {
        isRegeneratingPinnedComment = true
        variant.pinnedComment = PinnedCommentGenerator.generate(promoCode: promoCode)
        isRegeneratingPinnedComment = false
    }

    /// The full text a user would paste into a platform: description, a blank
    /// line, then the hashtags.
    private var combinedText: String {
        let summary = variant.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let tags = variant.hashtagLine.trimmingCharacters(in: .whitespacesAndNewlines)
        return [summary, tags].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    private func copyAll() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(combinedText, forType: .string)
        didCopy = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            didCopy = false
        }
    }

    /// Single editable field backing both `summary` and `hashtags`. On edit, the
    /// trailing run of `#`-prefixed tokens becomes the hashtag list and the rest
    /// becomes the description, so the phone preview keeps rendering them apart.
    private var combinedBinding: Binding<String> {
        Binding(
            get: { combinedText },
            set: { newValue in
                let (summary, tags) = Self.splitCombined(newValue)
                variant.summary = summary
                variant.hashtags = tags
            })
    }

    /// Splits combined text into (description, hashtags). The trailing block of
    /// `#`-prefixed tokens becomes the hashtag list; everything before it is the
    /// description. If there are no trailing hashtags, it's all description.
    static func splitCombined(_ text: String) -> (summary: String, hashtags: [String]) {
        // Match a trailing run of "#tag" tokens (and the whitespace before them).
        let pattern = "(\\s*#[^\\s#]\\S*)+\\s*$"
        guard let range = text.range(of: pattern, options: .regularExpression) else {
            return (text.trimmingCharacters(in: .whitespacesAndNewlines), [])
        }
        let summary = String(text[..<range.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let tags = text[range.lowerBound...]
            .split(whereSeparator: { " \n\t,".contains($0) })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "# ")) }
            .filter { !$0.isEmpty }
        return (summary, tags)
    }
}
