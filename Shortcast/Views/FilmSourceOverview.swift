import AVKit
import SwiftUI

struct FilmSourceOverview: View {
    let job: VideoJob
    let onContinue: () -> Void
    @Environment(WorkspaceModel.self) private var workspace
    @State private var playbackAudio = EssayResultPlaybackAudio()
    @State private var player: AVPlayer?
    @State private var playbackTime = 0.0
    @State private var isPlaying = false
    @State private var timeObserver: Any?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("ИСХОДНЫЙ МАТЕРИАЛ").font(.system(size: 10, weight: .bold)).tracking(2).foregroundStyle(StudioTheme.accent)
                    Text(workspace.currentProject?.movieTitle ?? job.effectiveTitle)
                        .font(.system(size: 30, weight: .medium, design: .serif))
                }
                HStack(alignment: .top, spacing: 24) {
                    ZStack(alignment: .bottom) {
                        if let player {
                            StudioPlayerSurface(player: player)
                        } else {
                            Color.black
                        }
                        HStack(spacing: 10) {
                            Button {
                                guard let player else { return }
                                playbackAudio.toggle(player: player, url: job.url, duration: job.durationSeconds)
                            } label: {
                                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                    .foregroundStyle(StudioTheme.accent)
                            }
                            .buttonStyle(.plain)
                            Slider(value: Binding(get: { playbackTime }, set: { value in
                                playbackTime = value
                                if let player { playbackAudio.seek(player: player, url: job.url, time: value, duration: job.durationSeconds) }
                            }), in: 0...max(job.durationSeconds, 0.1))
                            .tint(StudioTheme.accent)
                        }
                        .padding(12)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                        .padding(12)
                    }
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    VStack(alignment: .leading, spacing: 20) {
                        Label("Фильм в проекте", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        LabeledContent("Длительность", value: job.durationLabel)
                        LabeledContent("Транскрипция", value: workspace.storedTranscript == nil ? "Подготовка" : "Сохранена")
                        LabeledContent("Эссе", value: workspace.longformResult == nil ? "В работе" : "Собрано")
                        Divider()
                        Text(job.fileName).font(.caption).foregroundStyle(StudioTheme.muted).textSelection(.enabled)
                        Text("Исходный фильм используется для монтажа эссе и шортсов. Готовые версии сохраняются отдельно.")
                            .font(.callout).foregroundStyle(StudioTheme.muted)
                        Button(action: onContinue) { Label("К монтажу эссе", systemImage: "arrow.right") }
                            .buttonStyle(StudioPrimaryButtonStyle())
                    }.frame(width: 300).studioPanel()
                }
            }.padding(32).frame(maxWidth: 1160).frame(maxWidth: .infinity)
        }
        .task {
            let next = MontageVideoPreviewPlayer.makeVideoOnlyPlayer(url: job.url)
            player = next
            timeObserver = next.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main
            ) { time in
                let seconds = CMTimeGetSeconds(time)
                if seconds.isFinite { playbackTime = max(0, min(seconds, job.durationSeconds)) }
                isPlaying = next.timeControlStatus == .playing
            }
        }
        .onDisappear {
            if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
            timeObserver = nil
            playbackAudio.stop()
            player?.pause()
            player = nil
        }
    }
}
