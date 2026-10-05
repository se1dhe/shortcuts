import SwiftUI

/// Dedicated UI component for managing Anti-Copyright and TikTok/Reels fingerprint evasion settings.
/// Adheres to Single Responsibility Principle (SRP).
struct AntiCopyrightEditor: View {
    @Bindable var clip: ShortClip
    @State private var isCustomExpanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header with master toggle and badge
            HStack {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Защита от Content ID (TikTok Shield)")
                            .font(.callout.weight(.semibold))
                        Text("Предотвращает страйки, мут звука и теневые баны в TikTok / Reels")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: clip.antiCopyrightEnabled ? "checkmark.shield.fill" : "shield.slash.fill")
                        .font(.title3)
                        .foregroundStyle(clip.antiCopyrightEnabled ? Color.green : Color.secondary)
                }

                Spacer()

                Toggle("", isOn: $clip.antiCopyrightEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }

            if clip.antiCopyrightEnabled {
                Divider()

                // Preset picker
                HStack(spacing: 8) {
                    Text("Пресет:")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)

                    Picker("Пресет защиты", selection: Binding(
                        get: { clip.antiCopyrightPreset },
                        set: { newPreset in
                            clip.antiCopyrightPreset = newPreset
                            if newPreset != .custom {
                                clip.antiCopyrightConfig = newPreset.config
                            }
                        }
                    )) {
                        ForEach(AntiCopyrightPreset.allCases) { preset in
                            Text(preset.displayName).tag(preset)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .controlSize(.small)

                    Spacer()

                    // Quick protection status indicator
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 6, height: 6)
                        Text(statusBadgeText)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }

                // Evasion mechanisms summary card
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "waveform.and.mic")
                            .font(.caption)
                            .foregroundStyle(.tint)
                        Text("Акустический щит:")
                            .font(.caption2.weight(.semibold))
                        Text(acousticSummaryText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 6) {
                        Image(systemName: "eye.fill")
                            .font(.caption)
                            .foregroundStyle(.tint)
                        Text("Визуальный щит:")
                            .font(.caption2.weight(.semibold))
                        Text(visualSummaryText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))

                // Collapsible detailed parameters
                DisclosureGroup(isExpanded: $isCustomExpanded) {
                    VStack(alignment: .leading, spacing: 12) {
                        // Visual transformations
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Видео параметры")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.secondary)

                            Toggle("Зеркалирование видео (hflip)", isOn: Binding(
                                get: { clip.antiCopyrightConfig.enableMirror },
                                set: { val in
                                    clip.antiCopyrightConfig.enableMirror = val
                                    clip.antiCopyrightPreset = .custom
                                }
                            ))
                            .font(.caption)

                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text("Кинематографическое зерно 35мм (ломает pHash):")
                                        .font(.caption2)
                                    Spacer()
                                    Text("\(Int(clip.antiCopyrightConfig.filmGrainIntensity * 100))%")
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                Slider(value: Binding(
                                    get: { clip.antiCopyrightConfig.filmGrainIntensity },
                                    set: { val in
                                        clip.antiCopyrightConfig.filmGrainIntensity = val
                                        clip.antiCopyrightPreset = .custom
                                    }
                                ), in: 0.0...0.60, step: 0.05)
                                .controlSize(.small)
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text("Микро-зум кадра:")
                                        .font(.caption2)
                                    Spacer()
                                    Text(String(format: "%.1f%%", (clip.antiCopyrightConfig.zoomScale - 1.0) * 100))
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                Slider(value: Binding(
                                    get: { clip.antiCopyrightConfig.zoomScale },
                                    set: { val in
                                        clip.antiCopyrightConfig.zoomScale = val
                                        clip.antiCopyrightPreset = .custom
                                    }
                                ), in: 1.0...1.08, step: 0.005)
                                .controlSize(.small)
                            }
                        }

                        Divider()

                        // Audio transformations
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Аудио параметры")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.secondary)

                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text("Смещение тональности (Pitch Shift):")
                                        .font(.caption2)
                                    Spacer()
                                    Text("+\(Int(clip.antiCopyrightConfig.audioPitchShiftCents)) cents")
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                Slider(value: Binding(
                                    get: { clip.antiCopyrightConfig.audioPitchShiftCents },
                                    set: { val in
                                        clip.antiCopyrightConfig.audioPitchShiftCents = val
                                        clip.antiCopyrightPreset = .custom
                                    }
                                ), in: 0.0...25.0, step: 1.0)
                                .controlSize(.small)
                            }

                            Toggle("Спектральный EQ (сдвиг гармоник речи)", isOn: Binding(
                                get: { clip.antiCopyrightConfig.enableAudioWarmthEQ },
                                set: { val in
                                    clip.antiCopyrightConfig.enableAudioWarmthEQ = val
                                    clip.antiCopyrightPreset = .custom
                                }
                            ))
                            .font(.caption)

                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text("Микро-ускорение темпа (темпоральный сдвиг):")
                                        .font(.caption2)
                                    Spacer()
                                    Text(String(format: "+%.1f%%", (clip.antiCopyrightConfig.audioSpeedMultiplier - 1.0) * 100))
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                Slider(value: Binding(
                                    get: { clip.antiCopyrightConfig.audioSpeedMultiplier },
                                    set: { val in
                                        clip.antiCopyrightConfig.audioSpeedMultiplier = val
                                        clip.antiCopyrightPreset = .custom
                                    }
                                ), in: 1.0...1.04, step: 0.005)
                                .controlSize(.small)
                            }
                        }

                        Divider()

                        // Metadata stripping
                        Toggle("Очистка цифровых метаданных рипа", isOn: Binding(
                            get: { clip.antiCopyrightConfig.stripMetadata },
                            set: { val in
                                clip.antiCopyrightConfig.stripMetadata = val
                                clip.antiCopyrightPreset = .custom
                            }
                        ))
                        .font(.caption)
                    }
                    .padding(.top, 4)
                } label: {
                    Text(isCustomExpanded ? "Скрыть параметры" : "Настроить параметры защиты…")
                        .font(.caption2)
                        .foregroundStyle(.tint)
                }
            }
        }
        .padding(12)
        .background(.background.tertiary, in: RoundedRectangle(cornerRadius: 10))
    }

    private var statusBadgeText: String {
        switch clip.antiCopyrightPreset {
        case .cinemaShield: return "YouTube Cinema Shield"
        case .tikTokShield: return "TikTok Shield: активен"
        case .subtle: return "Мягкая защита"
        case .moderate: return "Стандартная защита"
        case .aggressive: return "Максимальная защита"
        case .custom: return "Пользовательский щит"
        case .off: return "Отключено"
        }
    }

    private var acousticSummaryText: String {
        var parts: [String] = []
        if abs(clip.antiCopyrightConfig.audioPitchShiftCents) > 0.0001 {
            parts.append("+\(Int(clip.antiCopyrightConfig.audioPitchShiftCents))¢ питч")
        }
        if clip.antiCopyrightConfig.enableAudioWarmthEQ {
            parts.append("EQ сдвиг")
        }
        if abs(clip.antiCopyrightConfig.audioSpeedMultiplier - 1.0) > 0.0001 {
            parts.append(String(format: "+%.1f%% темп", (clip.antiCopyrightConfig.audioSpeedMultiplier - 1.0) * 100))
        }
        return parts.isEmpty ? "Без изменений" : parts.joined(separator: ", ")
    }

    private var visualSummaryText: String {
        var parts: [String] = []
        if clip.antiCopyrightConfig.enableMirror {
            parts.append("зеркало")
        }
        if clip.antiCopyrightConfig.filmGrainIntensity > 0.01 {
            parts.append("35мм зерно")
        }
        if clip.antiCopyrightConfig.zoomScale > 1.001 {
            parts.append(String(format: "%.1f%% зум", (clip.antiCopyrightConfig.zoomScale - 1.0) * 100))
        }
        return parts.isEmpty ? "Без изменений" : parts.joined(separator: ", ")
    }
}
