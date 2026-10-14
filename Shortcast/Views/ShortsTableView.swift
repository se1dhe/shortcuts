import SwiftUI
import AVKit

/// Table mode for reviewing, editing, and publishing generated shorts.
/// Provides a clear tabular view with dedicated columns for preview, platform switching,
/// headline/hook, full description with hashtags, and batch actions.
struct ShortsTableView: View {

    let clips: [ShortClip]
    @Environment(WorkspaceModel.self) private var workspace
    @Environment(ModelManager.self) private var modelManager
    @Environment(AppSettings.self) private var settings

    var displayClips: [ShortClip] {
        clips.isEmpty ? workspace.clips : clips
    }

    var body: some View {
        Group {
            if displayClips.isEmpty {
                emptyState
            } else {
                VStack(spacing: 0) {
                    tableHeader
                    Divider()
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(displayClips) { clip in
                                ShortsTableRowView(clip: clip)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 16)
                    }
                }
            }
        }
    }

    // MARK: - Header & Empty State

    private var tableHeader: some View {
        HStack(spacing: 16) {
            Text("Превью")
                .frame(width: 120, alignment: .leading)
            Text("Платформа")
                .frame(width: 140, alignment: .leading)
            Text("Название (Хук)")
                .frame(width: 260, alignment: .leading)
            Text("Описание (с тегами)")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Действия")
                .frame(width: 140, alignment: .trailing)
        }
        .font(.caption.weight(.bold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 32)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Шортсы не найдены", systemImage: "scissors")
        } description: {
            Text("Модель не смогла выделить подходящие сцены из этого фильма. Попробуйте сгенерировать ещё раз.")
                .multilineTextAlignment(.center)
        } actions: {
            Button {
                workspace.regenerateShorts(modelManager: modelManager, settings: settings)
            } label: {
                Label("Попробовать снова", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Table Row View

struct ShortsTableRowView: View {

    @Bindable var clip: ShortClip
    @Environment(AppSettings.self) private var settings

    @State private var selectedPlatform: SocialPlatform = .tiktok
    @State private var showPlayer = false
    @State private var showEditor = false
    @State private var isHovered = false
    @State private var copiedTitle = false
    @State private var copiedDescription = false

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            previewColumn
            platformColumn
            titleColumn
            descriptionColumn
            actionsColumn
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.quaternary))
        .shadow(color: .black.opacity(0.03), radius: 4, x: 0, y: 1)
        .opacity(clip.isApproved ? 1.0 : 0.55)
        .onHover { isHovered = $0 }
        .sheet(isPresented: $showEditor) { ClipEditorSheet(clip: clip) }
        .sheet(isPresented: $showPlayer) { ClipPlayerSheet(clip: clip) }
        .onAppear {
            if let first = clip.variants.first?.platform {
                selectedPlatform = first
            }
        }
    }

    // MARK: - Columns

    // 1. Column: Preview (120px)
    private var previewColumn: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topTrailing) {
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
                        .frame(width: 80, height: 142)
                        .contentShape(Rectangle())
                        .onTapGesture { showEditor = true }
                } else {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.black.opacity(0.85))
                        .frame(width: 80, height: 142)
                        .overlay {
                            ProgressView().controlSize(.small)
                        }
                }

                Text("\(Int(clip.candidate.duration.rounded()))s")
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(.black.opacity(0.65), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(4)
            }

            Button {
                showPlayer = true
            } label: {
                Label("Смотреть", systemImage: "play.fill")
                    .font(.system(size: 10, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
        .frame(width: 120)
    }

    // 2. Column: Platform (140px)
    private var platformColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Платформа", selection: $selectedPlatform) {
                ForEach(SocialPlatform.allCases) { platform in
                    Label(platform.displayName, systemImage: platform.symbolName)
                        .tag(platform)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()

            HStack(spacing: 5) {
                ForEach(SocialPlatform.allCases) { platform in
                    let isSelected = selectedPlatform == platform
                    Button {
                        selectedPlatform = platform
                    } label: {
                        Image(systemName: platform.symbolName)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(isSelected ? platform.tint : .secondary)
                            .frame(width: 26, height: 26)
                            .background(
                                isSelected ? platform.tint.opacity(0.18) : Color.primary.opacity(0.04),
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(isSelected ? platform.tint.opacity(0.5) : Color.clear, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(platform.displayName)
                }
            }

            Spacer(minLength: 4)

            if let date = clip.scheduledDate {
                Label(Self.shortDate(date), systemImage: "calendar")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.blue)
            } else if clip.publishReport != nil {
                Label("Опубликовано", systemImage: "checkmark.seal.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.green)
            } else if let err = clip.exportError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
        }
        .frame(width: 140, alignment: .leading)
    }

    // 3. Column: Name / Hook (260px)
    private var titleColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Название (Хук)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    ClipExportHelper.copyToPasteboard(hookBinding.wrappedValue)
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

            TextField("Название шортса", text: hookBinding, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)
                .font(.callout.weight(.medium))

            Toggle(isOn: $clip.overlayEnabled) {
                Text("Хук на видео (первые 3с)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .toggleStyle(.checkbox)
        }
        .frame(width: 260, alignment: .leading)
    }

    // 4. Column: Description with tags (flexible)
    private var descriptionColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Описание (с тегами внутри)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    let text = combinedDescriptionBinding.wrappedValue
                    guard !text.isEmpty else { return }
                    ClipExportHelper.copyToPasteboard(text)
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
                .disabled(combinedDescriptionBinding.wrappedValue.isEmpty)
            }

            TextEditor(text: combinedDescriptionBinding)
                .font(.callout)
                .lineSpacing(2)
                .frame(minHeight: 110, maxHeight: 140)
                .padding(4)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.2)))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // 5. Column: Actions (140px)
    private var actionsColumn: some View {
        VStack(alignment: .trailing, spacing: 10) {
            Toggle(isOn: $clip.isApproved) {
                Text(clip.isApproved ? "Утверждён" : "Пропущен")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(clip.isApproved ? .primary : .secondary)
            }
            .toggleStyle(.checkbox)

            Button {
                showEditor = true
            } label: {
                Label("Редактировать", systemImage: "slider.horizontal.3")
                    .font(.caption)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)

            if clip.isExporting {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Экспорт…").font(.caption)
                }
                .frame(maxWidth: .infinity)
            } else {
                Button {
                    ClipExportHelper.downloadClip(clip, settings: settings)
                } label: {
                    Label("Скачать MP4", systemImage: "arrow.down.circle")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
        }
        .frame(width: 140, alignment: .trailing)
    }

    // MARK: - Bindings & Helpers

    private var hookBinding: Binding<String> {
        Binding(
            get: {
                if let variant = clip.variants.first(where: { $0.platform == selectedPlatform }) {
                    return variant.hook
                }
                return clip.displayTitle
            },
            set: { newValue in
                if let idx = clip.variants.firstIndex(where: { $0.platform == selectedPlatform }) {
                    clip.variants[idx].hook = newValue
                } else {
                    var newVariant = PostVariant(
                        platform: selectedPlatform,
                        hook: newValue,
                        summary: "",
                        hashtags: [],
                        pinnedComment: ""
                    )
                    clip.variants.append(newVariant)
                }
            }
        )
    }

    private var combinedDescriptionBinding: Binding<String> {
        Binding(
            get: {
                let target = clip.variants.first(where: { $0.platform == selectedPlatform }) ?? clip.variants.first
                return target?.fullDescriptionWithTags ?? ""
            },
            set: { newValue in
                if let idx = clip.variants.firstIndex(where: { $0.platform == selectedPlatform }) {
                    clip.variants[idx].updateFromCombinedDescription(newValue)
                } else {
                    var newVariant = PostVariant(
                        platform: selectedPlatform,
                        hook: clip.displayTitle,
                        summary: "",
                        hashtags: [],
                        pinnedComment: ""
                    )
                    newVariant.updateFromCombinedDescription(newValue)
                    clip.variants.append(newVariant)
                }
            }
        )
    }

    private static func shortDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "d MMM, HH:mm"
        return f.string(from: date)
    }
}
