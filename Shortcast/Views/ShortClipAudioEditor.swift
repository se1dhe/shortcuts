import SwiftUI
import AVKit
import UniformTypeIdentifiers

/// Dedicated audio mastering and background music editor for a short clip.
/// Adheres to Single Responsibility Principle (SRP) by isolating all audio mixing,
/// track selection, trimming, volume control, and ducking UI.
struct ShortClipAudioEditor: View {
    @Bindable var clip: ShortClip
    @Environment(AppSettings.self) private var settings

    @State private var availableTracks: [BackgroundMusicTrack] = []
    @State private var isPlayingPreview = false
    @State private var previewPlayer: AVPlayer?
    @State private var isDetectingDrop = false
    @State private var audioImportError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            originalAudioSection
            Divider()
            backgroundMusicSection
        }
        .padding(14)
        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1)
        )
        .task(id: settings.customMusicDirectory) {
            await loadTracks()
        }
        .onDisappear {
            stopPreview()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Label("Аудио-микширование и музыка", systemImage: "waveform.badge.magnifyingglass")
                .font(.headline)
            Spacer()
            Text("-14 LUFS Mobile Standard")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.accentColor.opacity(0.15), in: Capsule())
                .foregroundStyle(Color.accentColor)
        }
    }

    // MARK: - Section 1: Original Video Audio

    private var originalAudioSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Оригинальный звук видео", systemImage: clip.isOriginalAudioMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(clip.isOriginalAudioMuted ? .secondary : .primary)

                Spacer()

                Button {
                    clip.isOriginalAudioMuted.toggle()
                } label: {
                    Label(clip.isOriginalAudioMuted ? "Включить звук" : "Заглушить (Mute)",
                          systemImage: clip.isOriginalAudioMuted ? "speaker.wave.2" : "speaker.slash")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(clip.isOriginalAudioMuted ? .orange : .secondary)
            }

            if !clip.isOriginalAudioMuted {
                HStack(spacing: 12) {
                    Slider(value: $clip.originalAudioVolume, in: 0.0...2.0, step: 0.05)
                        .frame(maxWidth: .infinity)

                    Text("\(Int(clip.originalAudioVolume * 100))%")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .frame(width: 44, alignment: .trailing)
                }

                HStack(spacing: 6) {
                    Text("Быстро:")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    presetVolumeButton("Тихо (30%)", volume: 0.30)
                    presetVolumeButton("Норма (100%)", volume: 1.00)
                    presetVolumeButton("Буст (150%)", volume: 1.50)
                }
            } else {
                Text("Исходная дорожка полностью заглушена. В шортсе будет слышна только музыка.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func presetVolumeButton(_ title: String, volume: Double) -> some View {
        Button(title) {
            clip.originalAudioVolume = volume
        }
        .buttonStyle(.borderless)
        .font(.caption2)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
    }

    // MARK: - Section 2: Overlaid Background Music

    private var backgroundMusicSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Toggle(isOn: $clip.backgroundMusicEnabled) {
                    Label("Наложенная фоновая музыка", systemImage: "music.note")
                        .font(.subheadline.weight(.medium))
                }
                .toggleStyle(.switch)

                Spacer()

                if clip.backgroundMusicEnabled {
                    Button {
                        togglePreview()
                    } label: {
                        Label(isPlayingPreview ? "Стоп" : "Слушать",
                              systemImage: isPlayingPreview ? "stop.fill" : "play.fill")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            if clip.backgroundMusicEnabled {
                trackPickerRow
                trackTrimRow
                musicVolumeRow
                duckingAndFadeRow
            }
        }
    }

    // MARK: - Track Picker & Custom File Import

    private var trackPickerRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Picker("Трек:", selection: Binding<String>(
                    get: { clip.selectedMusicURL?.absoluteString ?? "auto" },
                    set: { newId in
                        if newId == "auto" {
                            clip.selectedMusicURL = nil
                            clip.musicStartOffsetSeconds = 0.0
                        } else if let track = availableTracks.first(where: { $0.url.absoluteString == newId }) {
                            clip.selectedMusicURL = track.url
                            updateTrackDuration(for: track.url)
                        }
                    }
                )) {
                    let mood = clip.candidate.mood?.mood.rawValue ?? "Динамика"
                    Text("🪄 Автоподбор по настроению (\(mood))").tag("auto")
                    Divider()
                    ForEach(availableTracks) { track in
                        Text("\(track.isBuiltIn ? "🎬" : "📁") \(track.name) (\(track.moodTag.capitalized))")
                            .tag(track.url.absoluteString)
                    }
                }
                .frame(maxWidth: 320)

                Button {
                    importCustomAudioFile()
                } label: {
                    Label("Добавить свой трек…", systemImage: "plus.circle")
                        .font(.caption)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            if let err = audioImportError {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Track Trim / Start Offset

    private var trackTrimRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Обрезка трека (момент старта):")
                    .font(.caption.weight(.medium))
                Spacer()

                Button {
                    detectTrackDrop()
                } label: {
                    Label(isDetectingDrop ? "Анализ…" : "Кульминация (Дроп)", systemImage: "sparkles")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                .disabled(isDetectingDrop)
                .help("Автоматически найти кульминацию или дроп в треке")
            }

            HStack(spacing: 12) {
                let maxDuration = max(60.0, clip.musicTrackDurationSeconds > 0 ? clip.musicTrackDurationSeconds : 180.0)
                Slider(value: $clip.musicStartOffsetSeconds, in: 0.0...maxDuration, step: 1.0)
                    .frame(maxWidth: .infinity)

                HStack(spacing: 4) {
                    Text(formatTime(clip.musicStartOffsetSeconds))
                        .font(.caption.monospacedDigit().weight(.semibold))
                    if clip.musicTrackDurationSeconds > 0 {
                        Text("/ \(formatTime(clip.musicTrackDurationSeconds))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 90, alignment: .trailing)
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Master Music Volume

    private var musicVolumeRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Громкость музыки на видео:")
                    .font(.caption.weight(.medium))
                Spacer()
                Text("\(Int(clip.musicVolume * 100))%")
                    .font(.caption.monospacedDigit().weight(.semibold))
            }

            HStack(spacing: 12) {
                Slider(value: $clip.musicVolume, in: 0.0...1.5, step: 0.05)
                    .frame(maxWidth: .infinity)

                HStack(spacing: 4) {
                    presetMusicVolumeButton("30%", volume: 0.30)
                    presetMusicVolumeButton("70%", volume: 0.70)
                    presetMusicVolumeButton("100%", volume: 1.00)
                }
            }
        }
    }

    private func presetMusicVolumeButton(_ title: String, volume: Double) -> some View {
        Button(title) {
            clip.musicVolume = volume
        }
        .buttonStyle(.borderless)
        .font(.caption2)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
    }

    // MARK: - Ducking & Fade Out

    private var duckingAndFadeRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle(isOn: $clip.musicDuckingEnabled) {
                    Text("Авто-приглушение музыки под голос (Voice Ducking)")
                        .font(.caption)
                }
                .toggleStyle(.checkbox)

                Spacer()

                if clip.musicDuckingEnabled {
                    HStack(spacing: 4) {
                        Text("Уровень в речи:")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Slider(value: $clip.musicDuckingDB, in: -24.0...(-6.0), step: 1.0)
                            .frame(width: 80)
                        Text("\(Int(clip.musicDuckingDB)) dB")
                            .font(.caption2.monospacedDigit())
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }

            if !clip.musicDuckingEnabled {
                Text("Музыка играет с постоянной заданной громкостью (\(Int(clip.musicVolume * 100))%) на всей продолжительности шортса.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 16) {
                HStack(spacing: 4) {
                    Text("Плавное затухание в конце:")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Slider(value: $clip.musicFadeOutDuration, in: 0.0...2.0, step: 0.2)
                        .frame(width: 70)
                    Text(String(format: "%.1f с", clip.musicFadeOutDuration))
                        .font(.caption2.monospacedDigit())
                        .frame(width: 32, alignment: .trailing)
                }
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Actions & Helpers

    private func formatTime(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    private func loadTracks() async {
        availableTracks = await BackgroundMusicService.shared.loadAvailableTracks(customDirectory: settings.customMusicDirectory)
        if let currentURL = clip.selectedMusicURL {
            updateTrackDuration(for: currentURL)
        }
    }

    private func updateTrackDuration(for url: URL) {
        Task {
            let duration = await BackgroundMusicService.getTrackDuration(url: url)
            await MainActor.run {
                clip.musicTrackDurationSeconds = duration
            }
        }
    }

    private func importCustomAudioFile() {
        audioImportError = nil
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            .audio,
            .mp3,
            .wav,
            .mpeg4Audio,
            .aiff
        ]
        panel.message = "Выберите аудиофайл для наложения на шортс"
        panel.prompt = "Выбрать трек"

        panel.begin { response in
            guard response == .OK, let sourceURL = panel.url else { return }
            Task {
                do {
                    let track = try await BackgroundMusicService.shared.importUserTrack(from: sourceURL)
                    await MainActor.run {
                        availableTracks.append(track)
                        clip.selectedMusicURL = track.url
                        clip.musicTrackDurationSeconds = track.durationSeconds ?? 0
                        clip.musicStartOffsetSeconds = 0.0
                    }
                } catch {
                    await MainActor.run {
                        audioImportError = "Ошибка импорта: \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    private func detectTrackDrop() {
        guard let url = clip.selectedMusicURL else { return }
        isDetectingDrop = true
        Task {
            let drop = await AudioDropDetector.findDrop(in: url)
            await MainActor.run {
                clip.musicStartOffsetSeconds = drop
                isDetectingDrop = false
            }
        }
    }

    private func togglePreview() {
        if isPlayingPreview {
            stopPreview()
        } else {
            startPreview()
        }
    }

    private func startPreview() {
        stopPreview()
        Task {
            let trackURL: URL?
            if let custom = clip.selectedMusicURL {
                trackURL = custom
            } else {
                let mood = clip.candidate.mood?.mood.rawValue
                trackURL = await BackgroundMusicService.shared.selectBestTrack(from: settings.customMusicDirectory, mood: mood)
            }

            guard let url = trackURL else { return }
            await MainActor.run {
                let player = AVPlayer(url: url)
                let seekTime = CMTime(seconds: clip.musicStartOffsetSeconds, preferredTimescale: 600)
                player.seek(to: seekTime)
                player.volume = Float(clip.musicVolume)
                player.play()
                self.previewPlayer = player
                self.isPlayingPreview = true
            }
        }
    }

    private func stopPreview() {
        previewPlayer?.pause()
        previewPlayer = nil
        isPlayingPreview = false
    }
}
