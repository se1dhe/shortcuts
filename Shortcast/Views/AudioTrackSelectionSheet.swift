import SwiftUI

/// Modal sheet presented when an imported video contains multiple audio tracks (e.g. Russian Dub, Original, Commentary).
/// Lets the user preview and select the exact voiceover track before pipeline normalization and Whisper transcription begin.
/// Adheres to Single Responsibility Principle (SRP).
struct AudioTrackSelectionSheet: View {
    let workspace: WorkspaceModel
    let modelManager: ModelManager
    let settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTrackId: Int = 0

    var body: some View {
        guard let pending = workspace.pendingAudioSelection else {
            return AnyView(EmptyView())
        }

        return AnyView(
            VStack(spacing: 0) {
                // Header
                HStack(spacing: 14) {
                    Image(systemName: "waveform.badge.magnifyingglass")
                        .font(.system(size: 32))
                        .foregroundStyle(StudioTheme.accent)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.tr("Выбор аудиодорожки озвучки"))
                            .font(.title3.weight(.bold))
                        Text(pending.videoURL.lastPathComponent)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer()
                }
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 16)

                Divider()

                // Description
                HStack {
                    Text(L10n.tr("В фильме обнаружено %1$@ аудиодорожки. Выберите дорожку с нужной озвучкой (дубляж, закадровый перевод или оригинал) для транскрибации и монтажа:", String(describing: pending.tracks.count)))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 14)

                // Track list
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(pending.tracks) { track in
                            trackRow(track, isSelected: track.id == selectedTrackId)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
                }

                Divider()

                // Actions Footer
                HStack {
                    Button(L10n.tr("Отмена")) {
                        workspace.cancelAudioTrackSelection()
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)

                    Spacer()

                    Button {
                        let chosen = selectedTrackId
                        dismiss()
                        Task {
                            await workspace.confirmAudioTrackSelection(
                                pending: pending,
                                trackId: chosen,
                                modelManager: modelManager,
                                settings: settings
                            )
                        }
                    } label: {
                        Text(L10n.tr("Начать обработку"))
                            .frame(minWidth: 130)
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }
            .frame(width: 580, height: 480)
            .background(StudioTheme.background)
            .preferredColorScheme(.dark)
            .tint(StudioTheme.accent)
            .onAppear {
                if let initial = workspace.pendingAudioSelection?.selectedTrackId {
                    selectedTrackId = initial
                }
            }
        )
    }

    private func trackRow(_ track: AudioTrackInfo, isSelected: Bool) -> some View {
        Button {
            selectedTrackId = track.id
        } label: {
            HStack(spacing: 14) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? StudioTheme.accent : Color.secondary.opacity(0.6))

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(track.interfaceDisplayName)
                            .font(.body.weight(isSelected ? .semibold : .regular))
                            .foregroundStyle(.primary)

                        if track.isRussianVoiceover {
                            Text(L10n.tr("Рекомендуется"))
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.green.opacity(0.18))
                                .foregroundStyle(.green)
                                .clipShape(Capsule())
                        }
                    }

                    HStack(spacing: 6) {
                        badge(text: track.codec.uppercased())
                        if track.channels > 0 {
                            badge(text: track.channels == 6 ? "5.1 Surround" : (track.channels == 2 ? "2.0 Stereo" : "\(track.channels) ch"))
                        }
                        if track.isDefault {
                            badge(text: L10n.tr("По умолчанию"))
                        }
                        if track.isForced {
                            badge(text: "Forced")
                        }
                    }
                }

                Spacer()
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? StudioTheme.accent.opacity(0.10) : StudioTheme.panel)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isSelected ? StudioTheme.accent : StudioTheme.line, lineWidth: isSelected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func badge(text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.12))
            .foregroundStyle(.secondary)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

extension AudioTrackInfo {
    /// Localize track controls, preserving the file's own metadata title.
    @MainActor var interfaceDisplayName: String {
        let locale = InterfaceLocalization.shared.language.locale
        let code = language?.lowercased() ?? ""
        let codes = ["rus": "ru", "eng": "en", "ukr": "uk", "fra": "fr", "fre": "fr", "deu": "de", "ger": "de", "ita": "it", "spa": "es", "jpn": "ja", "kor": "ko", "zho": "zh", "chi": "zh", "kaz": "kk"]
        var parts: [String] = []
        if !code.isEmpty {
            parts.append(locale.localizedString(forLanguageCode: codes[code] ?? code) ?? code)
        }
        if let title, !title.isEmpty { parts.append("(\(title))") }
        if parts.isEmpty { parts.append(L10n.tr("Дорожка №%1$@", String(audioIndex + 1))) }
        var detail = [codec.uppercased()]
        if channels > 0 { detail.append(channels == 1 ? "Mono" : channels == 2 ? "2.0 Stereo" : channels == 6 ? "5.1 Surround" : "\(channels) ch") }
        if isDefault { detail.append(L10n.tr("По умолчанию")) }
        return parts.joined(separator: " ") + " · " + detail.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}
