import SwiftUI
import AVKit

/// Вкладка «Монтаж сцены»: интерактивный 9:16 видеоплеер, точный In/Out триммер
/// с шаговыми кнопками подстройки и интерактивный список реплик диалога.
/// Single Responsibility Principle (SRP): отвечает за хронометраж и границы видеоряда сцены.
struct ShortClipSceneEditorView: View {

    @Bindable var clip: ShortClip

    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var currentTime: Double = 0
    @State private var timeObserverToken: Any?
    @State private var activeSeekTime: Double?

    private var duration: Double {
        clip.clipJob?.durationSeconds ?? max(clip.candidate.duration, 1.0)
    }

    private var effectiveEnd: Double {
        clip.trimEndSeconds > 0 ? min(clip.trimEndSeconds, duration) : duration
    }

    private var trimmedDuration: Double {
        max(0.0, effectiveEnd - clip.trimStartSeconds)
    }

    var body: some View {
        HSplitView {
            // Левая колонка: 9:16 интерактивный видеоплеер
            playerColumn
                .frame(minWidth: 340, idealWidth: 380, maxWidth: 460)

            // Правая колонка: In/Out триммер и список диалогов
            controlsColumn
                .frame(minWidth: 520, idealWidth: 640)
        }
        .padding(16)
        .onAppear {
            setupPlayer()
        }
        .onDisappear {
            teardownPlayer()
        }
        .onChange(of: clip.clipJob?.url) { _, _ in
            setupPlayer()
        }
    }

    // MARK: - Player Column

    private var playerColumn: some View {
        VStack(spacing: 12) {
            ZStack {
                Color.black
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                if let player {
                    SceneAVPlayerRepresentable(player: player)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    ProgressView("Загрузка видео…")
                }
            }
            .aspectRatio(9/16, contentMode: .fit)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.3), radius: 8, y: 4)

            // Панель управления воспроизведением
            HStack(spacing: 14) {
                Button {
                    togglePlayPause()
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)

                Button {
                    seekPlayer(to: clip.trimStartSeconds)
                } label: {
                    Image(systemName: "backward.end.fill")
                        .font(.subheadline)
                }
                .buttonStyle(.plain)
                .help("Перемотать к началу сцены (In)")

                // Слайдер текущей позиции
                Slider(value: Binding(
                    get: { currentTime },
                    set: { seekPlayer(to: $0) }
                ), in: 0...duration)
                .controlSize(.small)

                // Таймкод текущей позиции
                Text(formatTimecode(currentTime))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    // MARK: - Controls Column

    private var controlsColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // Карточка In/Out тримминга
                trimmerCard

                // Список диалогов в сцене
                transcriptPhrasesCard
            }
            .padding(.horizontal, 8)
        }
    }

    // MARK: - Trimmer Card

    private var trimmerCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Границы сцены (In / Out Trimming)", systemImage: "scissors")
                    .font(.headline)
                Spacer()

                if clip.hasCustomTrim {
                    Button("Сбросить тримминг") {
                        resetTrim()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            // Статистика хронометража
            HStack(spacing: 12) {
                timeStatPill(title: "Начало (In)", timecode: formatTimecode(clip.trimStartSeconds))
                timeStatPill(title: "Конец (Out)", timecode: formatTimecode(effectiveEnd))
                timeStatPill(title: "Хронометраж", timecode: String(format: "%.1f с", trimmedDuration), isAccent: true)
            }

            // Интерактивный таймлайн-стрип (если есть url видео)
            if let url = clip.clipJob?.url, duration > 0 {
                ClipTrimEditor(
                    videoURL: url,
                    duration: duration,
                    trimStart: $clip.trimStartSeconds,
                    trimEnd: $clip.trimEndSeconds
                )
            }

            Divider()

            // Шаговые кнопки точной подстройки In (начала)
            VStack(alignment: .leading, spacing: 6) {
                Text("Точная подстройка начала (In):")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    stepButton(label: "-1.0с") { nudgeStart(-1.0) }
                    stepButton(label: "-0.1с") { nudgeStart(-0.1) }
                    stepButton(label: "+0.1с") { nudgeStart(+0.1) }
                    stepButton(label: "+1.0с") { nudgeStart(+1.0) }

                    Spacer()

                    Button {
                        clip.trimStartSeconds = (currentTime * 10).rounded() / 10
                    } label: {
                        Label("Поставить In здесь", systemImage: "arrow.down.to.line")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                }
            }

            // Шаговые кнопки точной подстройки Out (конца)
            VStack(alignment: .leading, spacing: 6) {
                Text("Точная подстройка конца (Out):")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    stepButton(label: "-1.0с") { nudgeEnd(-1.0) }
                    stepButton(label: "-0.1с") { nudgeEnd(-0.1) }
                    stepButton(label: "+0.1с") { nudgeEnd(+0.1) }
                    stepButton(label: "+1.0с") { nudgeEnd(+1.0) }

                    Spacer()

                    Button {
                        clip.trimEndSeconds = (currentTime * 10).rounded() / 10
                    } label: {
                        Label("Поставить Out здесь", systemImage: "arrow.up.to.line")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(14)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    private func timeStatPill(title: String, timecode: String, isAccent: Bool = false) -> some View {
        VStack(spacing: 3) {
            Text(timecode)
                .font(.system(.body, design: .monospaced).weight(.bold))
                .foregroundStyle(isAccent ? Color.accentColor : Color.primary)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(isAccent ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private func stepButton(label: String, action: @escaping () -> Void) -> some View {
        Button(label) {
            action()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    // MARK: - Transcript Phrases Card

    private var transcriptPhrasesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Реплики диалога в сцене", systemImage: "bubble.left.and.bubble.right.fill")
                    .font(.headline)
                Spacer()
                let inRangeCount = clip.subtitleSegments.filter { isSegmentInRange($0) }.count
                Text("\(inRangeCount) из \(clip.subtitleSegments.count) в кадре")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if clip.subtitleSegments.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "waveform.slash")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("В этом фрагменте нет распознанных фраз речи")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(Array(clip.subtitleSegments.enumerated()), id: \.element.id) { index, segment in
                        phraseRow(segment: segment, index: index + 1)
                    }
                }
            }
        }
        .padding(14)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    private func phraseRow(segment: SubtitleSegment, index: Int) -> some View {
        let inRange = isSegmentInRange(segment)

        return HStack(alignment: .top, spacing: 10) {
            Text("#\(index)")
                .font(.caption2.monospaced().weight(.bold))
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .leading)

            VStack(alignment: .leading, spacing: 3) {
                Text(segment.timecodeDisplay)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(inRange ? Color.accentColor : Color.secondary)

                Text(segment.text)
                    .font(.callout)
                    .foregroundStyle(inRange ? Color.primary : Color.secondary)
            }

            Spacer()

            HStack(spacing: 6) {
                Button {
                    seekPlayer(to: segment.start)
                } label: {
                    Image(systemName: "play.circle.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .help("Перемотать к началу реплики")

                Menu {
                    Button("Сделать началом сцены (In)") {
                        clip.trimStartSeconds = (segment.start * 10).rounded() / 10
                    }
                    Button("Сделать концом сцены (Out)") {
                        clip.trimEndSeconds = (segment.end * 10).rounded() / 10
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.body)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(inRange ? Color.secondary.opacity(0.08) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(inRange ? Color.accentColor.opacity(0.3) : Color.secondary.opacity(0.1), lineWidth: 1)
        )
    }

    private func isSegmentInRange(_ segment: SubtitleSegment) -> Bool {
        segment.end > clip.trimStartSeconds && segment.start < effectiveEnd
    }

    // MARK: - Trimming Nudge

    private func nudgeStart(_ delta: Double) {
        let newStart = max(0.0, min(clip.trimStartSeconds + delta, effectiveEnd - 0.5))
        clip.trimStartSeconds = (newStart * 10).rounded() / 10
        seekPlayer(to: clip.trimStartSeconds)
    }

    private func nudgeEnd(_ delta: Double) {
        let currentEnd = clip.trimEndSeconds > 0 ? clip.trimEndSeconds : duration
        let newEnd = min(duration, max(clip.trimStartSeconds + 0.5, currentEnd + delta))
        clip.trimEndSeconds = (newEnd * 10).rounded() / 10
        seekPlayer(to: max(0, clip.trimEndSeconds - 0.5))
    }

    private func resetTrim() {
        clip.trimStartSeconds = 0.0
        clip.trimEndSeconds = 0.0
        seekPlayer(to: 0.0)
    }

    // MARK: - AVPlayer Logic

    private func setupPlayer() {
        guard let url = clip.clipJob?.url else { return }
        teardownPlayer()

        let item = AVPlayerItem(url: url)
        let newPlayer = AVPlayer(playerItem: item)
        self.player = newPlayer

        let interval = CMTime(seconds: 0.05, preferredTimescale: 600)
        timeObserverToken = newPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak newPlayer] time in
            guard let newPlayer else { return }
            let sec = CMTimeGetSeconds(time)
            currentTime = sec
            isPlaying = (newPlayer.timeControlStatus == .playing)

            // Loop inside trim window if playing
            let endBound = effectiveEnd
            if sec >= endBound {
                newPlayer.seek(to: CMTime(seconds: clip.trimStartSeconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            }
        }
    }

    private func teardownPlayer() {
        if let token = timeObserverToken, let player {
            player.removeTimeObserver(token)
            timeObserverToken = nil
        }
        player?.pause()
        player = nil
    }

    private func togglePlayPause() {
        guard let player else { return }
        if player.timeControlStatus == .playing {
            player.pause()
            isPlaying = false
        } else {
            if currentTime >= effectiveEnd {
                player.seek(to: CMTime(seconds: clip.trimStartSeconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            }
            player.play()
            isPlaying = true
        }
    }

    private func seekPlayer(to time: Double) {
        guard let player else { return }
        currentTime = time
        let cmTime = CMTime(seconds: max(0, min(time, duration)), preferredTimescale: 600)
        player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func formatTimecode(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        let ms = Int((seconds.truncatingRemainder(dividingBy: 1)) * 10)
        return String(format: "%02d:%02d.%d", total / 60, total % 60, ms)
    }
}

// MARK: - AVPlayer Representable

private struct SceneAVPlayerRepresentable: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }
}
