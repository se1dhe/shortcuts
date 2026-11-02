import AVFoundation
import AppKit
import SwiftUI

/// A minimal AVPlayerLayer host. Unlike SwiftUI VideoPlayer this avoids AVKit's
/// chapter/remote-command controller path, which is where the Oct 30 playback
/// crash entered AVPlayerController before AudioQueueStart trapped.
struct StudioPlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerLayerHostView {
        let view = PlayerLayerHostView(frame: .zero)
        view.wantsLayer = true
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ view: PlayerLayerHostView, context: Context) {
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
        }
    }
}

final class PlayerLayerHostView: NSView {
    override func makeBackingLayer() -> CALayer {
        AVPlayerLayer()
    }

    var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }
}

struct FullscreenEssayPlayerView: View {
    let player: AVPlayer
    let duration: Double
    let onToggle: () -> Void
    let onSeek: (Double) -> Void
    let onClose: () -> Void

    @State private var currentTime: Double = 0
    @State private var isPlaying = false
    @State private var isSeeking = false
    @State private var timeObserver: Any?

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()
            StudioPlayerSurface(player: player).ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button {
                        onClose()
                    } label: {
                        Label("Выйти из полного экрана", systemImage: "xmark")
                            .padding(.horizontal, 12).padding(.vertical, 8)
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                }
                Spacer()
                controls
            }
            .padding(28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .preferredColorScheme(.dark)
        .onAppear {
            timeObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main
            ) { time in
                let seconds = CMTimeGetSeconds(time)
                Task { @MainActor in
                    if seconds.isFinite, !isSeeking { currentTime = max(0, min(seconds, duration)) }
                    isPlaying = player.timeControlStatus == .playing
                }
            }
        }
        .onDisappear {
            if let timeObserver { player.removeTimeObserver(timeObserver) }
            timeObserver = nil
        }
        .onExitCommand(perform: onClose)
    }

    private var controls: some View {
        HStack(spacing: 14) {
            Button {
                onToggle()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 16, weight: .bold))
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .foregroundStyle(StudioTheme.accent)

            Text(format(currentTime))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
            Slider(value: Binding(get: { currentTime }, set: { value in
                currentTime = value
                isSeeking = true
            }), in: 0...max(duration, 0.1), onEditingChanged: { editing in
                isSeeking = editing
                guard !editing else { return }
                onSeek(currentTime)
            })
                .tint(StudioTheme.accent)
            Text(format(duration))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.75))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(maxWidth: 900)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func format(_ seconds: Double) -> String {
        let value = max(0, Int(seconds.isFinite ? seconds : 0))
        return String(format: "%02d:%02d", value / 60, value % 60)
    }
}

/// Uses the same PCM engine as the montage monitor. AVPlayer receives video
/// only, so play/pause cannot enter the crashing AudioQueue implementation.
@MainActor @Observable
final class EssayResultPlaybackAudio {
    private let audio = MontageScenePreviewAudio()
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var prepared = false
    private(set) var isPreparing = false
    private(set) var error: String?

    func toggle(player: AVPlayer, url: URL, duration: Double) {
        if isPreparing || player.rate != 0 {
            pause(player: player)
        } else if prepared && player.currentTime().seconds < duration - 0.1 {
            audio.resume()
            player.play()
        } else {
            start(player: player, url: url, time: player.currentTime().seconds, duration: duration)
        }
    }

    func pause(player: AVPlayer) {
        generation = UUID()
        task?.cancel()
        task = nil
        isPreparing = false
        audio.pause()
        player.pause()
    }

    func seek(player: AVPlayer, url: URL, time: Double, duration: Double) {
        let resume = player.rate != 0 || isPreparing
        pause(player: player)
        audio.stop()
        prepared = false
        player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        if resume { start(player: player, url: url, time: time, duration: duration) }
    }

    private func start(player: AVPlayer, url: URL, time: Double, duration: Double) {
        let start = time.isFinite && time < duration - 0.1 ? max(0, time) : 0
        let token = UUID()
        generation = token
        isPreparing = true
        error = nil
        task = Task {
            do {
                let chunks = try await audio.prepare(url: url, start: start, end: duration)
                guard !Task.isCancelled, generation == token else { return }
                await player.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                guard !Task.isCancelled, generation == token else { return }
                try audio.play(chunks)
                prepared = true
                isPreparing = false
                player.play()
            } catch {
                guard generation == token else { return }
                isPreparing = false
                self.error = error.localizedDescription
            }
        }
    }

    func stop() {
        generation = UUID()
        task?.cancel()
        task = nil
        isPreparing = false
        prepared = false
        audio.stop()
    }
}

/// Shared music inspector; edits remain in the parent montage draft until save.
struct MusicBedEditor: View {
    @Binding var settings: LongformAudioSettings
    let duration: Double
    let suggestedEnvelope: [MusicEnvelopePoint]
    let speechIntervals: [TimeSegment]
    @Environment(\.dismiss) private var dismiss
    @State private var original: LongformAudioSettings
    @State private var musicLibrary = MusicFolderLibrary.shared
    @State private var trackDuration = 0.0
    @State private var audio = MontageScenePreviewAudio()
    @State private var audition: Task<Void, Never>?
    @State private var auditioning = false
    @State private var error: String?

    init(settings: Binding<LongformAudioSettings>, duration: Double,
         suggestedEnvelope: [MusicEnvelopePoint] = [], speechIntervals: [TimeSegment] = []) {
        _settings = settings; self.duration = duration
        self.suggestedEnvelope = suggestedEnvelope; self.speechIntervals = speechIntervals
        _original = State(initialValue: settings.wrappedValue)
    }

    private var offset: Binding<Double> { Binding(get: { settings.musicOffsetSeconds ?? 0 }, set: { settings.musicOffsetSeconds = $0 }) }
    private var fadeIn: Binding<Double> { Binding(get: { settings.musicFadeInSeconds ?? 2 }, set: { settings.musicFadeInSeconds = $0 }) }
    private var fadeOut: Binding<Double> { Binding(get: { settings.musicFadeOutSeconds ?? 4 }, set: { settings.musicFadeOutSeconds = $0 }) }
    private var gainDB: Binding<Double> {
        Binding(get: { max(-60, 20 * log10(Double(max(0.001, settings.musicVolume)))) },
                set: { settings.musicVolume = Float(pow(10, $0 / 20)) })
    }
    private var missingTrack: Bool {
        settings.backgroundMusicURL.map { !FileManager.default.isReadableFile(atPath: $0.path) } ?? false
    }

    private var configurationIssue: String? {
        guard settings.backgroundMusicURL != nil else { return nil }
        if missingTrack { return "Музыкальный файл недоступен." }
        let start = settings.musicOffsetSeconds ?? 0
        if !start.isFinite || start < 0 || (trackDuration > 0 && start >= trackDuration) { return "Начало должно быть внутри выбранного трека." }
        if (settings.musicEnvelope ?? []).contains(where: { !$0.time.isFinite || $0.time < 0 || $0.time > duration || !$0.gain.isFinite || !(0...1).contains($0.gain) }) { return "Точки огибающей должны находиться внутри монтажа, громкость — от 0 до 100%." }
        let fades = [settings.musicFadeInSeconds ?? 2, settings.musicFadeOutSeconds ?? 4]
        if fades.contains(where: { !$0.isFinite || $0 < 0 }) { return "Длительность фейдов должна быть положительной или нулевой." }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "waveform").foregroundStyle(StudioTheme.accent).font(.title2)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Музыка и сведение").font(.title2.bold())
                    Text("Отдельная подложка этого монтажа").font(.caption).foregroundStyle(StudioTheme.muted)
                }
                Spacer()
                Button("Отменить") { settings = original; dismiss() }
                Button("Готово") { dismiss() }.buttonStyle(StudioPrimaryButtonStyle()).disabled(configurationIssue != nil)
            }.padding(22)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("01 / ИСТОЧНИК").font(.caption.bold()).tracking(1.5).foregroundStyle(StudioTheme.accent)
                        HStack {
                            Menu {
                                Button("Без музыки") { stopAudition(); settings.backgroundMusicURL = nil }
                                ForEach(musicLibrary.tracks) { track in
                                    Button(track.name) {
                                        musicLibrary.refresh()
                                        guard FileManager.default.isReadableFile(atPath: track.url.path),
                                              musicLibrary.tracks.contains(track) else { return }
                                        selectTrack(track.url)
                                    }
                                }
                            } label: {
                                Label(settings.backgroundMusicURL?.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " ") ?? "Без музыки", systemImage: "music.note")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }.controlSize(.large)
                            Button("Папка с музыкой…", systemImage: "folder") { musicLibrary.chooseFolder(); reconcileMusicSelection() }.controlSize(.large)
                        }
                        if let directory = musicLibrary.directory {
                            Text("\(directory.path) · треков: \(musicLibrary.tracks.count)")
                                .font(.caption).foregroundStyle(StudioTheme.muted)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        if let message = musicLibrary.error {
                            Text(message).font(.caption).foregroundStyle(StudioTheme.warning)
                        }
                        TextField("Источник музыки / ссылка", text: Binding(get: { settings.musicSource ?? "" }, set: { settings.musicSource = $0 }))
                        TextField("Условия использования / лицензия", text: Binding(get: { settings.musicUsageTerms ?? "" }, set: { settings.musicUsageTerms = $0 }))
                        if let url = settings.backgroundMusicURL {
                            HStack {
                                Text(url.lastPathComponent).font(.caption2).foregroundStyle(StudioTheme.muted).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Button("В Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                                    .buttonStyle(.plain).font(.caption).foregroundStyle(StudioTheme.accent)
                            }
                            if missingTrack { Label("Файл недоступен. Выберите другой трек.", systemImage: "exclamationmark.triangle").foregroundStyle(StudioTheme.warning) }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).studioPanel(padding: 18)
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text("02 / УРОВЕНЬ И РЕЧЬ").font(.caption.bold()).tracking(1.5).foregroundStyle(StudioTheme.accent)
                            Spacer()
                            Text(String(format: "%.1f dB", gainDB.wrappedValue)).font(.headline.monospacedDigit())
                        }
                        Slider(value: gainDB, in: -60...0).tint(StudioTheme.accent)
                        HStack {
                            Button("Тихий фон") { gainDB.wrappedValue = -30 }
                            Button("Атмосфера") { gainDB.wrappedValue = -24 }
                            Button("Акцент") { gainDB.wrappedValue = -18 }
                            Spacer()
                            Text("Громкость подложки").font(.caption).foregroundStyle(StudioTheme.muted)
                        }.buttonStyle(.bordered)
                        Toggle("Приглушать музыку под диалогами", isOn: $settings.duckingEnabled)
                        if settings.duckingEnabled {
                            HStack {
                                Text("Приглушение")
                                Slider(value: Binding(get: { Double(settings.musicDuckingDepth ?? 0.7) },
                                                      set: { settings.musicDuckingDepth = Float($0) }), in: 0...1)
                                Text("\(Int((settings.musicDuckingDepth ?? 0.7) * 100))%").monospacedDigit().frame(width: 48)
                            }.font(.callout)
                            Text("Уровень плавно снижается перед репликой и восстанавливается после неё.")
                                .font(.caption).foregroundStyle(StudioTheme.muted)
                        }
                    }.disabled(settings.backgroundMusicURL == nil).studioPanel(padding: 18)
                    VStack(alignment: .leading, spacing: 16) {
                        Text("03 / ВРЕМЯ И ФЕЙДЫ").font(.caption.bold()).tracking(1.5).foregroundStyle(StudioTheme.accent)
                        HStack {
                            Text("Начать трек с, с")
                            Spacer()
                            TextField("Секунды", value: offset, format: .number.precision(.fractionLength(1)))
                                .textFieldStyle(.roundedBorder).frame(width: 100)
                        }
                        Text("Этот момент трека прозвучит в начале ролика. Длина трека: \(Int(trackDuration)) с.")
                            .font(.caption).foregroundStyle(StudioTheme.muted)
                        Toggle("Бесшовно повторять до конца ролика", isOn: Binding(get: { settings.musicLoopEnabled ?? true }, set: { settings.musicLoopEnabled = $0 }))
                        fadeControl("Плавный вход", value: fadeIn)
                        fadeControl("Плавный выход", value: fadeOut)
                        HStack {
                            Text("Громкость по ходу истории").font(.caption.bold())
                            Spacer()
                            Button("Добавить точку", systemImage: "plus") {
                                var points = settings.musicEnvelope ?? []
                                points.append(MusicEnvelopePoint(time: min(duration, (points.last?.time ?? -30) + 30), gain: 1))
                                settings.musicEnvelopeFollowsActs = false
                                settings.musicEnvelope = points
                            }
                        }
                        HStack {
                            if !suggestedEnvelope.isEmpty {
                                Button("Рекомендуемый микс", systemImage: "waveform.path") {
                                    settings.musicEnvelope = suggestedEnvelope
                                    settings.musicEnvelopeFollowsActs = true
                                    settings.duckingEnabled = true
                                    settings.musicDuckingDepth = 0.7
                                    settings.loudnessNormalizationEnabled = true
                                }
                            }
                            Button("Ровный фон") { settings.musicEnvelopeFollowsActs = false; settings.musicEnvelope = nil }
                            Spacer()
                        }.buttonStyle(.bordered)
                        if !suggestedEnvelope.isEmpty {
                            Text("Профиль следует за актами при изменении монтажа. Кнопка заменяет точки ниже, включает приглушение под речь на 70% и нормализацию громкости. Выбранный трек и его уровень сохраняются. Ручная правка точек отключает привязку к актам.")
                                .font(.caption).foregroundStyle(StudioTheme.muted)
                        }
                        ForEach(Array((settings.musicEnvelope ?? []).enumerated()), id: \.element.id) { index, point in
                            HStack {
                                TextField("Секунды", value: Binding(get: { (settings.musicEnvelope?.indices.contains(index) == true ? settings.musicEnvelope![index].time : 0) }, set: { value in
                                    guard settings.musicEnvelope?.indices.contains(index) == true else { return }; settings.musicEnvelopeFollowsActs = false; settings.musicEnvelope?[index].time = value
                                }), format: .number).frame(width: 100)
                                Slider(value: Binding(get: { (settings.musicEnvelope?.indices.contains(index) == true ? settings.musicEnvelope![index].gain : 1) }, set: { value in
                                    guard settings.musicEnvelope?.indices.contains(index) == true else { return }; settings.musicEnvelopeFollowsActs = false; settings.musicEnvelope?[index].gain = value
                                }), in: 0...1)
                                Text("\(Int(point.gain * 100))%").monospacedDigit().frame(width: 45)
                                Button(role: .destructive) { settings.musicEnvelopeFollowsActs = false; settings.musicEnvelope?.remove(at: index) } label: { Image(systemName: "minus.circle") }
                            }
                        }
                        Canvas { context, size in
                            let total = max(0.1, duration)
                            let points = MusicBedMixing.automation(duration: total, settings: settings, speech: speechIntervals)
                            var path = Path()
                            path.move(to: CGPoint(x: 0, y: size.height))
                            for point in points {
                                let gain = Double(point.gain) / Double(max(0.001, settings.musicVolume))
                                path.addLine(to: CGPoint(x: point.time / total * size.width, y: size.height - gain * (size.height - 10)))
                            }
                            path.addLine(to: CGPoint(x: size.width, y: size.height))
                            path.closeSubpath()
                            context.fill(path, with: .color(StudioTheme.accent.opacity(0.15)))
                            context.stroke(path, with: .color(StudioTheme.accent.opacity(0.8)), lineWidth: 1.5)
                        }.frame(height: 60).background(StudioTheme.background, in: RoundedRectangle(cornerRadius: 8))
                        Text("Огибающая громкости\(speechIntervals.isEmpty ? "" : " с приглушением под реальные реплики") · монтаж \(Int(duration.rounded())) с")
                            .font(.caption2).foregroundStyle(StudioTheme.muted)
                    }.disabled(settings.backgroundMusicURL == nil).studioPanel(padding: 18)
                    if let issue = configurationIssue ?? error { Label(issue, systemImage: "exclamationmark.triangle").foregroundStyle(StudioTheme.warning).font(.callout) }
                }.padding(22)
            }
            Divider()
            HStack {
                Button(auditioning ? "Остановить" : "Трек · 10 с", systemImage: auditioning ? "stop.fill" : "play.fill") {
                    if auditioning { stopAudition() } else { startAudition() }
                }.buttonStyle(.bordered).disabled(settings.backgroundMusicURL == nil || missingTrack)
                Text("Только музыка: без речи, огибающей и приглушения").font(.caption).foregroundStyle(StudioTheme.muted)
                Spacer()
                Text("Применится после сохранения монтажа").font(.caption).foregroundStyle(StudioTheme.accent)
            }.padding(18)
        }.frame(width: 740, height: 760)
            .background(StudioTheme.background).preferredColorScheme(.dark).tint(StudioTheme.accent)
            .task {
                if !suggestedEnvelope.isEmpty {
                    settings = MusicBedMixing.resolvingActEnvelope(settings, points: suggestedEnvelope)
                }
                musicLibrary.refresh()
                reconcileMusicSelection()
                await musicLibrary.monitor()
            }
            .onChange(of: musicLibrary.tracks) { _, _ in reconcileMusicSelection() }
            .task(id: settings.backgroundMusicURL) {
                stopAudition()
                trackDuration = 0
                if let url = settings.backgroundMusicURL,
                   let length = try? await AVURLAsset(url: url).load(.duration).seconds, length.isFinite { trackDuration = length }
            }
            .onChange(of: settings.musicVolume) { _, value in audio.setVolume(value) }
            .onDisappear { stopAudition(); audio.shutdown() }
    }

    private func fadeControl(_ title: String, value: Binding<Double>) -> some View {
        HStack {
            Text(title).frame(width: 120, alignment: .leading)
            Slider(value: value, in: 0...min(15, max(0.1, duration / 2)))
            TextField("Секунды", value: value, format: .number.precision(.fractionLength(1)))
                .textFieldStyle(.roundedBorder).frame(width: 70)
            Text("с").foregroundStyle(StudioTheme.muted)
        }.font(.callout)
    }
    private func stopAudition() { audition?.cancel(); audition = nil; audio.stop(); auditioning = false }
    private func selectTrack(_ url: URL) {
        guard settings.backgroundMusicURL != url else { return }
        stopAudition()
        settings.backgroundMusicURL = url
        settings.musicOffsetSeconds = nil
        // Attribution belongs to the chosen recording, not to the montage.
        settings.musicSource = nil
        settings.musicUsageTerms = nil
    }
    private func startAudition() {
        guard let url = settings.backgroundMusicURL, !missingTrack else { return }
        let start = settings.musicOffsetSeconds ?? 0
        guard start.isFinite, start >= 0, start < trackDuration else { error = "Начало должно быть внутри выбранного трека."; return }
        auditioning = true; error = nil
        audition = Task { @MainActor in
            do {
                let end = min(trackDuration, start + 10)
                let chunks = try await audio.prepare(url: url, start: start, end: end)
                guard !Task.isCancelled else { return }
                audio.setVolume(settings.musicVolume)
                try audio.play(chunks)
                try await Task.sleep(for: .seconds(end - start))
                stopAudition()
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription; auditioning = false
            }
        }
    }
    private func reconcileMusicSelection() {
        guard let url = settings.backgroundMusicURL else { return }
        if !musicLibrary.tracks.contains(where: { $0.url.resolvingSymlinksInPath() == url.resolvingSymlinksInPath() }) {
            stopAudition()
            settings.backgroundMusicURL = nil
        }
    }
}
