import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct CompilationSourceView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var sources: [CompilationSource] = []
    @State private var tracks: [UUID: [AudioTrackInfo]] = [:]
    @State private var busy = false
    @State private var error: String?
    @State private var preparation: Task<Void, Never>?
    let onChooseFile: (URL, VideoSourceMetadata?) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Несколько источников в одном эссе").font(.title2.bold()); Spacer(); Button("Закрыть") { dismiss() }.disabled(busy) }
            Text("Добавьте фильмы, серии или интервью, выберите дорожки и нужные фрагменты. Названия и исходные таймкоды сохранятся. Оригиналы останутся на месте.").font(.callout).foregroundStyle(.secondary)
            TextField("Название тематической подборки", text: $title).textFieldStyle(.roundedBorder)
            ScrollView {
                ForEach($sources) { $source in
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Название фильма / сериала / интервью", text: $source.title)
                        Text(source.url.path).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        HStack {
                            Text("От, с"); TextField("In", value: $source.start, format: .number).frame(width: 90)
                            Text("До, с"); TextField("Out", value: $source.end, format: .number).frame(width: 90)
                            Picker("Озвучка", selection: $source.audioStreamIndex) { ForEach(tracks[source.id] ?? []) { track in Text(track.displayName).tag(track.id) } }
                            Button(role: .destructive) { sources.removeAll { $0.id == source.id } } label: { Image(systemName: "minus.circle") }
                        }.textFieldStyle(.roundedBorder)
                    }.padding(14).background(StudioTheme.panel, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if busy { ProgressView("Готовлю монтажную основу… Подробности — в журнале операций.") }
            HStack {
                Button("Добавить источники…", systemImage: "plus") { choose() }.disabled(busy)
                Spacer()
                if busy { Button("Остановить") { preparation?.cancel() } }
                Button("Подготовить и открыть") { build() }.buttonStyle(StudioPrimaryButtonStyle()).disabled(busy || sources.count < 2 || title.trimmed.isEmpty || settings.workingDirectory == nil)
            }
            OperationLogPanel(isActive: busy)
        }.padding(24).frame(width: 1040, height: 700)
    }
    private func choose() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        panel.allowedContentTypes = [.movie, .mpeg4Movie, UTType(filenameExtension: "mkv") ?? .data]
        guard panel.runModal() == .OK, let working = settings.workingDirectory else { return }
        let urls = panel.urls; busy = true
        preparation = Task { defer { busy = false }
            for url in urls {
                let audio = await MediaExtractor.inspectAudioTracks(sourceURL: url, workingDirectory: working)
                guard let recommended = MediaExtractor.pickRecommendedAudioTrack(from: audio) else { error = "Нет аудиодорожки: " + url.lastPathComponent; continue }
                let source = CompilationSource(title: url.deletingPathExtension().lastPathComponent, url: url, start: 0, end: 180, audioStreamIndex: recommended.id)
                sources.append(source); tracks[source.id] = audio
            }
        }
    }
    private func build() {
        guard let directory = settings.workingDirectory else { return }
        busy = true; error = nil
        preparation = Task { defer { busy = false }
            do {
                let url = try await CompilationSourceService.build(title: title, sources: sources, directory: directory)
                dismiss(); onChooseFile(url, VideoSourceMetadata(title: title, description: CompilationManifest.load(for: url)?.overview ?? ""))
            } catch { self.error = error.localizedDescription }
        }
    }
}
