import AVKit
import SwiftUI

struct EssayShortEditorView: View {
    let result: LongformBuildResult
    let transcript: Transcript
    let sourceURL: URL
    let onSave: (EssayShort) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: EssayShort
    @State private var scenes: [EditableSceneSegment]
    @State private var player: AVPlayer?
    @State private var sourceDuration: Double = 0
    @State private var busy = false
    @State private var error: String?

    init(short: EssayShort, result: LongformBuildResult, transcript: Transcript,
         sourceURL: URL, onSave: @escaping (EssayShort) async throws -> Void) {
        _draft = State(initialValue: short)
        _scenes = State(initialValue: short.segments.enumerated().map {
            EditableSceneSegment(sceneIndex: $0.offset, start: $0.element.start, end: $0.element.end)
        })
        self.result = result; self.transcript = transcript
        self.sourceURL = sourceURL; self.onSave = onSave
    }

    private var editedShort: EssayShort {
        var result = draft
        result.segments = scenes.map { TimeSegment(start: $0.start, end: $0.end) }
        result.captionEdits = draft.captionEdits?.filter { edit in
            selectedCaptions.contains { $0.start == edit.start && $0.end == edit.end }
        }
        return result
    }

    private var captions: [TranscriptSegment] {
        LongformEditorialSupport.captions(transcript.segments, edits: result.arc.captionEdits)
    }
    private var selectedCaptions: [TranscriptSegment] {
        captions.filter { line in scenes.contains { line.start >= $0.start && line.end <= $0.end } }
    }
    private var validationError: String? {
        do { try EssayShortEditing.validate(editedShort, arc: result.arc, sourceDuration: sourceDuration); return nil }
        catch { return error.localizedDescription }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Монтажный стол шортса").font(.title2.bold())
                    Text("\(Int(editedShort.duration.rounded())) с · сцены, хук, тексты и субтитры").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Отмена") { dismiss() }.disabled(busy)
                Button(busy ? "Рендеринг…" : "Сохранить и пересобрать") { save() }
                    .buttonStyle(StudioPrimaryButtonStyle()).disabled(busy || validationError != nil)
            }.padding(20)
            Divider()
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 12) {
                    VideoPlayer(player: player).frame(height: 270)
                    Text("Предпросмотр исходной сцены. Готовый вертикальный монтаж появится в выпуске после пересборки.")
                        .font(.caption).foregroundStyle(.secondary)
                    if busy { ProgressView("Сохраняем монтаж, субтитры и обложку…") }
                    if let message = error ?? validationError { Text(message).font(.callout).foregroundStyle(.red) }
                }.frame(width: 420)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        GroupBox("Тексты шортса") {
                            VStack(spacing: 10) {
                                TextField("Название", text: $draft.title)
                                TextField("Хук в видео", text: $draft.hook, axis: .vertical)
                                TextField("Мысль шортса", text: $draft.angle, axis: .vertical)
                                TextField("Вопрос для обсуждения", text: $draft.question, axis: .vertical)
                                TextField("Опорная реплика", text: $draft.payoffQuote, axis: .vertical)
                            }.textFieldStyle(.roundedBorder).padding(6)
                        }
                        GroupBox("Сцены · порядок и границы в исходном фильме") {
                            VStack(spacing: 12) {
                                ForEach($scenes) { scene in
                                    sceneRow(scene)
                                }
                                Menu("Добавить сцену из эссе", systemImage: "plus") {
                                    ForEach(Array(result.arc.acts.enumerated()), id: \.offset) { _, act in
                                        ForEach(Array(act.segments.enumerated()), id: \.offset) { _, range in
                                            Button("\(act.title) · \(range.start.formatted(.number.precision(.fractionLength(1))))–\(range.end.formatted(.number.precision(.fractionLength(1)))) с") {
                                                scenes.append(EditableSceneSegment(sceneIndex: scenes.count, start: range.start, end: range.end))
                                            }
                                        }
                                    }
                                }
                            }.padding(6)
                        }
                        GroupBox("Субтитры выбранных сцен") {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Правки сохраняются только в этом шортсе. Субтитры эссе и второго шортса остаются самостоятельными.")
                                    .font(.caption).foregroundStyle(.secondary)
                                ForEach(Array(selectedCaptions.enumerated()), id: \.offset) { _, segment in
                                    HStack(alignment: .top) {
                                        Button { preview(TimeSegment(start: segment.start, end: segment.end)) } label: {
                                            Image(systemName: "play.fill")
                                        }
                                        TextField("Субтитр", text: captionBinding(segment), axis: .vertical)
                                            .textFieldStyle(.roundedBorder)
                                    }
                                }
                            }.padding(6)
                        }
                    }.padding(.trailing, 12)
                }
            }.padding(20).disabled(busy)
        }
        .frame(width: 1100, height: 760)
        .background(StudioTheme.background)
        .tint(StudioTheme.accent)
        .interactiveDismissDisabled(busy)
        .task {
            player = AVPlayer(url: sourceURL)
            do { sourceDuration = try await AVURLAsset(url: sourceURL).load(.duration).seconds }
            catch { self.error = error.localizedDescription }
        }
        .onDisappear { player?.pause(); player = nil }
    }

    private func sceneRow(_ scene: Binding<EditableSceneSegment>) -> some View {
        let id = scene.wrappedValue.id
        let index = scenes.firstIndex { $0.id == id } ?? 0
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Сцена \(index + 1)").bold()
                Spacer()
                Button("Смотреть", systemImage: "play.fill") {
                    preview(TimeSegment(start: scene.wrappedValue.start, end: scene.wrappedValue.end))
                }
                Button {
                    if let current = scenes.firstIndex(where: { $0.id == id }), current > 0 { scenes.swapAt(current, current - 1) }
                } label: { Image(systemName: "arrow.up") }.disabled(index == 0)
                Button {
                    if let current = scenes.firstIndex(where: { $0.id == id }), current + 1 < scenes.count { scenes.swapAt(current, current + 1) }
                } label: { Image(systemName: "arrow.down") }.disabled(index + 1 == scenes.count)
                Button(role: .destructive) { scenes.removeAll { $0.id == id } } label: { Image(systemName: "trash") }
            }
            HStack {
                Text("Начало, с")
                TextField("Начало", value: scene.start, format: .number.precision(.fractionLength(2)))
                Text("Конец, с")
                TextField("Конец", value: scene.end, format: .number.precision(.fractionLength(2)))
            }.textFieldStyle(.roundedBorder)
        }.padding(12).background(StudioTheme.panel, in: RoundedRectangle(cornerRadius: 10))
    }

    private func captionBinding(_ segment: TranscriptSegment) -> Binding<String> {
        Binding(get: {
            draft.captionEdits?.first { $0.start == segment.start && $0.end == segment.end && $0.original == segment.text }?.replacement ?? segment.text
        }, set: { text in
            var edits = draft.captionEdits ?? []
            edits.removeAll { $0.start == segment.start && $0.end == segment.end }
            if text != segment.text {
                edits.append(LongformCaptionEdit(start: segment.start, end: segment.end, original: segment.text, replacement: text))
            }
            draft.captionEdits = edits.isEmpty ? nil : edits
        })
    }

    private func preview(_ range: TimeSegment) {
        guard range.start.isFinite, range.end.isFinite, range.start >= 0, range.end > range.start else { return }
        player?.pause()
        player?.currentItem?.forwardPlaybackEndTime = CMTime(seconds: range.end, preferredTimescale: 600)
        player?.seek(to: CMTime(seconds: range.start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        player?.play()
    }

    private func save() {
        busy = true; error = nil; player?.pause()
        Task { @MainActor in
            defer { busy = false }
            do { try await onSave(editedShort); dismiss() }
            catch { self.error = error.localizedDescription }
        }
    }
}
