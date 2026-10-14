import SwiftUI
import AppKit
import AVFoundation

/// Главное меню редактирования шортса с понятной навигацией по 5 вкладкам (SOLID):
/// 1. 🎬 Контент — метаданные фильма, хук, описание с тегами, промо-комментарий
/// 2. ✂️ Монтаж сцены — 9:16 видеоплеер, In/Out триммер, подстройка границ, таймкоды
/// 3. 💬 Субтитры — текстовый редактор реплик Whisper, таймкоды, поиск и живой видеомонитор
/// 4. 🎨 Стиль и звук — наэкранный хук, стиль субтитров, водяной знак, музыка, дакинг, AI-улучшения
/// 5. 🚀 Публикация — выбор платформ, экспорт MP4 и публикация
struct ShortClipCard: View {

    @Bindable var clip: ShortClip
    @Environment(AppSettings.self) private var settings
    @State private var selectedTab: ShortClipEditorTab = .content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            tabBar

            Divider()

            switch clip.stage {
            case .pending, .cutting, .captioning:
                working
            case .failed(let message):
                failed(message)
            case .ready:
                tabContent
            }
        }
        .padding(18)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.quaternary))
        .opacity(clip.isApproved ? 1 : 0.55)
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

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(clip.displayTitle)
                    .font(.title3.weight(.bold))

                HStack(spacing: 8) {
                    Label(clip.candidate.rangeLabel, systemImage: "scissors")
                    Text("·  \(Int(clip.candidate.duration.rounded()))с")
                    if clip.isRendered {
                        Text("·  Обработан")
                            .foregroundStyle(.green)
                    }
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

            Toggle("Утвердить", isOn: $clip.isApproved)
                .toggleStyle(.switch)
        }
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        HStack(spacing: 8) {
            ForEach(ShortClipEditorTab.allCases) { tab in
                let isSelected = selectedTab == tab
                Button {
                    selectedTab = tab
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: tab.icon)
                            .font(.callout)
                        Text(tab.title)
                            .font(.body.weight(isSelected ? .bold : .medium))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(isSelected ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 1)
                    )
                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    // MARK: - Tab Content

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .content:
            ShortClipContentEditorView(clip: clip)
        case .scene:
            ShortClipSceneEditorView(clip: clip)
        case .subtitles:
            ShortClipSubtitleTextEditorView(clip: clip)
        case .styleAudio:
            ShortClipStyleAudioEditorView(clip: clip)
        case .publish:
            ShortClipPublishEditorView(clip: clip)
        }
    }

    // MARK: - States

    private var working: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(clip.stage == .cutting ? "Нарезка клипа…" : "Генерация субтитров и контента…")
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
}
