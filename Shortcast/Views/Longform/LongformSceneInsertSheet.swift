import AVFoundation
import AVKit
import SwiftUI

/// Lets an editor find a passage in the film transcript, preview it and insert
/// a concrete source range into the selected act.
struct LongformSceneInsertSheet: View {
    let transcriptSegments: [TranscriptSegment]
    let existingRanges: [TimeSegment]
    let sourceURL: URL?
    let sourceDuration: Double
    let onInsert: (TimeSegment) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selectedLineID: Int?
    @State private var start = 0.0
    @State private var end = 0.0
    @State private var movieDuration = 0.0
    @State private var player: AVPlayer?
    @State private var previewTask: Task<Void, Never>?

    private struct TranscriptRow: Identifiable {
        let id: Int
        let segment: TranscriptSegment
    }

    private var rows: [TranscriptRow] {
        transcriptSegments.enumerated().compactMap { index, segment in
            guard query.isEmpty || segment.text.localizedCaseInsensitiveContains(query) else { return nil }
            return TranscriptRow(id: index, segment: segment)
        }
    }

    private var effectiveDuration: Double {
        if movieDuration.isFinite, movieDuration > 0 { return movieDuration }
        if sourceDuration.isFinite, sourceDuration > 0 { return sourceDuration }
        return transcriptSegments.map(\.end).max() ?? 0
    }

    private var selectedSegment: TranscriptSegment? {
        guard let selectedLineID, transcriptSegments.indices.contains(selectedLineID) else { return nil }
        return transcriptSegments[selectedLineID]
    }

    private var selectedRange: TimeSegment {
        TimeSegment(start: start, end: end)
    }

    private var validationMessage: String? {
        guard selectedSegment != nil else { return "Выберите реплику или момент в транскрипте." }
        guard start.isFinite, end.isFinite, start >= 0, end <= effectiveDuration else {
            return "Границы выходят за пределы исходного фильма."
        }
        guard EssayDurationPolicy.sceneLength.contains(end - start) else {
            return "Длина сцены должна быть от 18 до 40 секунд."
        }
        guard let selectedSegment, start <= selectedSegment.start, end >= selectedSegment.end else {
            return "Выбранная реплика должна целиком попасть в сцену."
        }
        guard existingRanges.allSatisfy({ $0.end <= start || end <= $0.start }) else {
            return "Этот фрагмент пересекается с уже выбранной сценой."
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Добавить сцену из фильма")
                    .font(.title2.weight(.bold))
                Text("Найдите реплику, проверьте контекст и вставьте фрагмент в выбранное место акта.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Поиск по репликам фильма", text: $query)
                        .textFieldStyle(.roundedBorder)
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(rows) { row in
                                Button {
                                    select(row)
                                } label: {
                                    HStack(alignment: .top, spacing: 10) {
                                        Text(timecode(row.segment.start))
                                            .font(.caption.monospacedDigit().weight(.bold))
                                            .foregroundStyle(.secondary)
                                        Text(row.segment.text)
                                            .font(.caption)
                                            .lineLimit(2)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        if selectedLineID == row.id {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundStyle(StudioTheme.accent)
                                        }
                                    }
                                    .padding(8)
                                    .background(selectedLineID == row.id
                                        ? StudioTheme.accent.opacity(0.12) : Color.secondary.opacity(0.05),
                                        in: RoundedRectangle(cornerRadius: 7))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(maxHeight: .infinity)
                }
                .frame(minWidth: 280, maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 10) {
                    if let player {
                        VideoPlayer(player: player)
                            .aspectRatio(16 / 9, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    } else {
                        ContentUnavailableView("Исходное видео недоступно", systemImage: "film")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }

                    if let selectedSegment {
                        Text("Выбрано: «\(selectedSegment.text)»")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    Button("Предпросмотр выбранного фрагмента", systemImage: "play.fill") {
                        playSelection()
                    }
                    .buttonStyle(.bordered)
                    .disabled(player == nil || selectedSegment == nil)

                    HStack(spacing: 8) {
                        timeControl(title: "IN", value: $start)
                        timeControl(title: "OUT", value: $end)
                        Text("\(timecode(max(0, end - start)))")
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(StudioTheme.accent)
                    }

                    HStack(spacing: 6) {
                        adjustmentButton("IN −1с") { start = max(0, start - 1) }
                        adjustmentButton("IN +1с") { start = min(max(0, end - 18), start + 1) }
                        adjustmentButton("OUT −1с") { end = max(start + 18, end - 1) }
                        adjustmentButton("OUT +1с") { end = min(min(effectiveDuration, start + 40), end + 1) }
                    }
                }
                .frame(minWidth: 300, maxWidth: .infinity)
            }

            HStack {
                if let validationMessage {
                    Label(validationMessage, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else {
                    Label("Фрагмент готов к вставке", systemImage: "checkmark.circle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(StudioTheme.success)
                }
                Spacer()
                Button("Отмена") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Вставить сцену", systemImage: "plus") {
                    onInsert(selectedRange)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(StudioTheme.accent)
                .keyboardShortcut(.defaultAction)
                .disabled(validationMessage != nil)
            }
        }
        .padding(20)
        .frame(minWidth: 680, minHeight: 580)
        .background(StudioTheme.background)
        .preferredColorScheme(.dark)
        .task {
            if let sourceURL {
                player = AVPlayer(url: sourceURL)
                let asset = AVURLAsset(url: sourceURL)
                if let duration = try? await asset.load(.duration), duration.seconds.isFinite, duration.seconds > 0 {
                    movieDuration = duration.seconds
                }
            }
            if selectedLineID == nil, let first = rows.first { select(first) }
        }
        .onDisappear {
            previewTask?.cancel()
            player?.pause()
            player = nil
        }
    }

    private func select(_ row: TranscriptRow) {
        selectedLineID = row.id
        let segment = row.segment
        let duration = effectiveDuration > 0 ? effectiveDuration : segment.end + 30
        start = max(0, segment.start - 6)
        end = min(duration, max(start + 24, segment.end + 3))
        if end - start > 40 { end = start + 40 }
        if end - start < 18 { start = max(0, end - 18) }
    }

    private func timeControl(title: String, value: Binding<Double>) -> some View {
        HStack(spacing: 4) {
            Text(title).font(.caption2.weight(.black)).foregroundStyle(.secondary)
            TextField(title, value: value, format: .number.precision(.fractionLength(1)))
                .textFieldStyle(.roundedBorder)
                .frame(width: 88)
        }
    }

    private func adjustmentButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.bordered)
            .controlSize(.small)
    }

    private func playSelection() {
        guard let player else { return }
        previewTask?.cancel()
        player.seek(to: CMTime(seconds: max(0, start), preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { finished in
            guard finished else { return }
            Task { @MainActor in player.play() }
        }
        previewTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(max(0.2, end - start) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            player.pause()
        }
    }

    private func timecode(_ seconds: Double) -> String {
        let value = max(0, seconds)
        let minutes = Int(value) / 60
        let wholeSeconds = Int(value) % 60
        let tenths = Int((value.truncatingRemainder(dividingBy: 1)) * 10)
        return String(format: "%02d:%02d.%d", minutes, wholeSeconds, tenths)
    }
}
