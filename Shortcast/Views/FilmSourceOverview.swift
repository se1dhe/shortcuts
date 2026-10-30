import AVKit
import SwiftUI

struct FilmSourceOverview: View {
    let job: VideoJob
    let onContinue: () -> Void
    @Environment(WorkspaceModel.self) private var workspace
    @State private var player: AVPlayer?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("ИСХОДНЫЙ МАТЕРИАЛ").font(.system(size: 10, weight: .bold)).tracking(2).foregroundStyle(StudioTheme.accent)
                    Text(workspace.currentProject?.movieTitle ?? job.effectiveTitle)
                        .font(.system(size: 30, weight: .medium, design: .serif))
                }
                HStack(alignment: .top, spacing: 24) {
                    VideoPlayer(player: player).aspectRatio(16 / 9, contentMode: .fit)
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
        .task { player = AVPlayer(url: job.url) }
        .onDisappear { player?.pause(); player = nil }
    }
}
