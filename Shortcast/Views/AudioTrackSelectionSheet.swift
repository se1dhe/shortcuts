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
                        .foregroundStyle(Color.accentColor)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Выбор аудиодорожки озвучки")
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
                    Text("В фильме обнаружено \(pending.tracks.count) аудиодорожки. Выберите дорожку с нужной озвучкой (дубляж, закадровый перевод или оригинал) для транскрибации и монтажа:")
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
                    Button("Отмена") {
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
                        Text("Начать обработку")
                            .frame(minWidth: 130)
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }
            .frame(width: 580, height: 480)
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
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.6))

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(track.displayName)
                            .font(.body.weight(isSelected ? .semibold : .regular))
                            .foregroundStyle(.primary)

                        if track.isRussianVoiceover {
                            Text("Рекомендуется")
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
                            badge(text: "По умолчанию")
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
                    .fill(isSelected ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: isSelected ? 1.5 : 1)
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
