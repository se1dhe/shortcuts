import SwiftUI
import AppKit

/// Вкладка «Стиль и звук»: визуальное оформление шортса (хук, субтитры, водяной знак, промокод),
/// кадрирование 9:16, фоновая музыка с дакингом и AI-улучшения видео (RIFE 60fps / RealESRGAN).
/// Single Responsibility Principle (SRP): отвечает за эстетику, аудиотрек и эффекты клипа.
struct ShortClipStyleAudioEditorView: View {

    @Bindable var clip: ShortClip
    @Environment(AppSettings.self) private var settings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // 1. Оформление хука на видео
                hookStyleSection

                // 2. Стиль и пресеты субтитров
                subtitlesStyleSection

                // 3. Водяной знак
                watermarkSection

                // 4. Промо-бейдж RedQueen
                promoSection

                // 5. Вертикальное кадрирование 9:16
                reframeSection

                // 6. Фоновая музыка и дакинг
                musicSection

                // 7. AI-улучшение качества (RIFE 60fps / RealESRGAN)
                enhancementSection

                // 8. Защита от алгоритмов правообладателей
                AntiCopyrightEditor(clip: clip)

                // 9. Предварительная проверка TikTok
                tiktokPreflightSection
            }
            .padding(16)
        }
    }

    // MARK: - 1. Hook Style Section

    private var hookStyleSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Наэкранный хук", systemImage: "sparkles")
                    .font(.headline)
                Spacer()
                Toggle("Показывать хук на видео", isOn: $clip.overlayEnabled)
                    .toggleStyle(.switch)
            }

            if clip.overlayEnabled {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Стиль хука", selection: $clip.hookAppearance.styleRaw) {
                        ForEach(HookAppearance.HookStyle.allCases) { style in
                            Text(LocalizedStringKey(style.displayName)).tag(style.rawValue)
                        }
                    }
                    .pickerStyle(.menu)

                    HStack(spacing: 12) {
                        Text("Размер:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 55, alignment: .leading)

                        Slider(value: $clip.hookAppearance.sizeScale, in: 0.020...0.055, step: 0.002)
                            .controlSize(.small)

                        Text(hookSizeLabel)
                            .font(.caption.monospacedDigit())
                            .frame(width: 56, alignment: .trailing)
                    }

                    Text("Хук впечатывается в верхнюю треть видеокадра (текст задается во вкладке «Контент»).")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(10)
                .background(.quinary, in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
    }

    private var hookSizeLabel: String {
        let scale = clip.hookAppearance.sizeScale
        if scale < 0.028 { return "Компактный" }
        if scale < 0.04 { return "Средний" }
        return "Крупный"
    }

    // MARK: - 2. Subtitles Style Section

    private var subtitlesStyleSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Стиль субтитров", systemImage: "captions.bubble.fill")
                    .font(.headline)
                Spacer()
                Toggle("Вжигать субтитры", isOn: $clip.burnSubtitles)
                    .toggleStyle(.switch)
            }

            if clip.burnSubtitles {
                SubtitleAppearanceEditor(appearance: $clip.subtitleAppearance)
                Text("Субтитры автоматически позиционируются и синхронизируются со звуком.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
    }

    // MARK: - 3. Watermark Section

    private var watermarkSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Водяной знак", systemImage: "water.waves")
                    .font(.headline)
                Spacer()
                Toggle("Водяной знак", isOn: $clip.watermarkEnabled)
                    .toggleStyle(.switch)
            }

            if clip.watermarkEnabled {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Текст водяного знака (@канал)", text: $clip.watermarkText)
                        .textFieldStyle(.roundedBorder)

                    WatermarkAppearanceEditor(appearance: $clip.watermarkAppearance)
                }
                .padding(10)
                .background(.quinary, in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
    }

    // MARK: - 4. Promo Section

    private var promoSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Промо-бейдж RedQueen", systemImage: "shield.lefthalf.filled")
                    .font(.headline)
                Spacer()
                Toggle("Показывать промо", isOn: $clip.promoOverlayEnabled)
                    .toggleStyle(.switch)
            }

            if clip.promoOverlayEnabled {
                HStack(spacing: 8) {
                    Text("Промокод:")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    TextField("Промокод", text: $clip.promoCode)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 200)
                }
                Text("Анимированная плашка @RedQueenSecurity_Bot в верхней части экрана для монетизации трафика.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
    }

    // MARK: - 5. Reframe Section

    private var reframeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Кадрирование в 9:16", systemImage: "aspectratio")
                    .font(.headline)
                Spacer()
                Toggle("Умный трекинг лиц (9:16)", isOn: $clip.reframeEnabled)
                    .toggleStyle(.switch)
            }

            Text("Автоматически отслеживает говорящих персонажей в кадре и центрирует вертикальное видео.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
    }

    // MARK: - 6. Music Section

    private var musicSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Фоновая музыка", systemImage: "music.note")
                    .font(.headline)
                Spacer()
                Toggle("Включить фоновую музыку", isOn: $clip.backgroundMusicEnabled)
                    .toggleStyle(.switch)
            }

            if clip.backgroundMusicEnabled {
                VStack(alignment: .leading, spacing: 10) {
                    ShortClipAudioEditor(clip: clip)

                    Toggle(isOn: $clip.musicDuckingEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Сайдчейн-дакинг музыки под голос")
                                .font(.callout.weight(.medium))
                            Text("Фоновая музыка автоматически приглушается в момент речи персонажей.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                }
                .padding(10)
                .background(.quinary, in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
    }

    // MARK: - 7. Enhancement Section

    private var enhancementSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("AI-улучшение видео", systemImage: "sparkles.tv")
                .font(.headline)

            Picker("Пресет улучшения", selection: $clip.videoEnhancementPreset) {
                ForEach(VideoEnhancementPreset.allCases) { preset in
                    Text(preset.displayName).tag(preset)
                }
            }
            .pickerStyle(.segmented)

            if clip.videoEnhancementPreset != .off {
                VStack(spacing: 8) {
                    sliderRow("Резкость",
                              value: $clip.videoEnhancementSharpness,
                              range: 0.5...3.0, step: 0.1, format: "%.1f")
                    sliderRow("Контраст",
                              value: $clip.videoEnhancementContrast,
                              range: 0.8...1.5, step: 0.05, format: "%.2f")
                    sliderRow("Насыщенность",
                              value: $clip.videoEnhancementSaturation,
                              range: 0.8...1.5, step: 0.05, format: "%.2f")
                    sliderRow("Битрейт",
                              value: Binding(get: { Double(clip.videoEnhancementBitrate) },
                                            set: { clip.videoEnhancementBitrate = Int($0) }),
                              range: 10.0...100.0,
                              step: 5, format: "%.0f Mbps")

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
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
    }

    // MARK: - 8. TikTok Preflight

    private var tiktokPreflightSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Проверка готовности к TikTok", systemImage: "checkmark.shield")
                    .font(.headline)
                Spacer()
                Button("Проверить") {
                    Task { await clip.runTikTokPreflight() }
                }
                .buttonStyle(.bordered)
                .disabled(clip.clipJob == nil)
            }

            Text("Анализирует параметры ролика и предупреждает о возможных рисках модерации и авторских прав.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let report = clip.tiktokPreflightReport {
                VStack(alignment: .leading, spacing: 6) {
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
                .padding(10)
                .background(.background.tertiary, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
    }

    private func sliderRow(
        _ label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        format: String
    ) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 85, alignment: .leading)
            Slider(value: value, in: range, step: step)
                .controlSize(.small)
            Text(String(format: format, value.wrappedValue))
                .font(.caption.monospacedDigit())
                .frame(width: 60, alignment: .trailing)
        }
    }

    private func preflightSymbol(for severity: TikTokPreflightService.Severity) -> String {
        switch severity {
        case .info:    return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error:   return "xmark.octagon.fill"
        }
    }

    private func preflightColor(for severity: TikTokPreflightService.Severity) -> Color {
        switch severity {
        case .info:    return .blue
        case .warning: return .orange
        case .error:   return .red
        }
    }
}
