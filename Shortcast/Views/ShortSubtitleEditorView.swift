import SwiftUI

/// Редактор текста субтитров для коротких клипов — аналог `LongformSubtitleEditorView`
/// для кино-эссе. Позволяет править распознанный Whisper текст, объединять и
/// разбивать строки; правки пишутся прямо в `clip.subtitleSegments`, которые
/// используются при рендере, поэтому пересборка клипа учитывает изменения.
struct ShortSubtitleEditorView: View {

    /// Локальная редактируемая копия `SubtitleSegment` (у того все поля `let`).
    private struct EditableLine: Identifiable {
        let id = UUID()
        var start: Double
        var end: Double
        var text: String
        var words: [WordTimestamp]

        var timecode: String {
            String(format: "%02d:%02d.%d", Int(start) / 60, Int(start) % 60, Int((start.truncatingRemainder(dividingBy: 1)) * 10))
        }
    }

    @Bindable var clip: ShortClip
    @Environment(\.dismiss) private var dismiss

    @State private var lines: [EditableLine] = []
    @State private var selectedId: UUID?
    @State private var hasUnsavedChanges = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 620, minHeight: 540)
        .onAppear(perform: loadLines)
    }

    // MARK: - Panels

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "captions.bubble")
                .font(.title3)
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text("Субтитры клипа")
                    .font(.headline)
                Text("\(lines.count) стр. · правки применяются при пересборке клипа")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button("Заглавные в начале строк", action: capitalizeFirstLetters)
                Button("Убрать лишние пробелы", action: trimWhitespaceInAll)
                Divider()
                Button("Сбросить все правки", role: .destructive, action: loadLines)
            } label: {
                Label("Автоправка", systemImage: "wand.and.stars")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(lines.isEmpty)
        }
        .padding(14)
    }

    @ViewBuilder
    private var content: some View {
        if lines.isEmpty {
            ContentUnavailableView(
                "Субтитров нет",
                systemImage: "text.bubble",
                description: Text("Для этого клипа субтитры ещё не сгенерированы или транскрипт пуст."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HSplitView {
                listPanel
                    .frame(minWidth: 380, idealWidth: 440)
                previewPanel
                    .frame(minWidth: 220, idealWidth: 260)
            }
        }
    }

    private var listPanel: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                        lineCard(line: line, index: index)
                            .id(line.id)
                    }
                }
                .padding(12)
            }
            .onChange(of: selectedId) { _, newId in
                guard let newId else { return }
                withAnimation { proxy.scrollTo(newId, anchor: .center) }
            }
        }
    }

    private func lineCard(line: EditableLine, index: Int) -> some View {
        let isSelected = selectedId == line.id
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("#\(index + 1)")
                    .font(.caption2.monospaced().weight(.bold))
                    .foregroundStyle(.secondary)
                Text(line.timecode)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    mergeDown(at: index)
                } label: {
                    Image(systemName: "arrow.down.to.line")
                }
                .buttonStyle(.borderless)
                .help("Объединить со следующей строкой")
                .disabled(index >= lines.count - 1)

                Button {
                    split(at: index)
                } label: {
                    Image(systemName: "scissors")
                }
                .buttonStyle(.borderless)
                .help("Разбить строку пополам")

                Button {
                    deleteLine(at: index)
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
                .help("Удалить строку")
            }

            TextField("Текст субтитра", text: binding(for: line.id).text, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
                .font(.system(size: 13, weight: .medium))
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.05)))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.15), lineWidth: isSelected ? 1.5 : 1))
        .contentShape(Rectangle())
        .onTapGesture { selectedId = line.id }
    }

    private var previewPanel: some View {
        VStack(spacing: 10) {
            Text("Предпросмотр")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.black)
                .overlay(
                    VStack {
                        Spacer()
                        Text(selectedLine?.text.trimmed.isEmpty == false ? selectedLine!.text : "…")
                            .font(.system(size: 18, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .shadow(color: .black.opacity(0.9), radius: 3, y: 1)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 40)
                    })
                .aspectRatio(9.0 / 16.0, contentMode: .fit)
                .padding(.horizontal, 24)
            if let selectedLine {
                Text("\(selectedLine.text.count) симв. · \(String(format: "%.1f", max(0, selectedLine.end - selectedLine.start)))с")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 12)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if hasUnsavedChanges {
                Label("Есть несохранённые правки", systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Spacer()
            Button("Отмена") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Сохранить") { saveLines() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!hasUnsavedChanges)
        }
        .padding(14)
    }

    // MARK: - State

    private var selectedLine: EditableLine? {
        guard let selectedId else { return nil }
        return lines.first { $0.id == selectedId }
    }

    private func binding(for id: UUID) -> Binding<EditableLine> {
        Binding(
            get: { lines.first { $0.id == id } ?? EditableLine(start: 0, end: 0, text: "", words: []) },
            set: { newValue in
                guard let idx = lines.firstIndex(where: { $0.id == id }) else { return }
                if lines[idx].text != newValue.text { hasUnsavedChanges = true }
                lines[idx] = newValue
            })
    }

    private func loadLines() {
        lines = clip.subtitleSegments.map {
            EditableLine(start: $0.start, end: $0.end, text: $0.text, words: $0.words)
        }
        selectedId = lines.first?.id
        hasUnsavedChanges = false
    }

    private func saveLines() {
        clip.subtitleSegments = lines
            .filter { !$0.text.trimmed.isEmpty }
            .map { SubtitleSegment(start: $0.start, end: $0.end, text: $0.text, words: $0.words) }
        hasUnsavedChanges = false
        dismiss()
    }

    // MARK: - Edits

    private func mergeDown(at index: Int) {
        guard index >= 0, index < lines.count - 1 else { return }
        let a = lines[index]
        let b = lines[index + 1]
        let mergedText = [a.text.trimmed, b.text.trimmed].filter { !$0.isEmpty }.joined(separator: " ")
        let merged = EditableLine(
            start: a.start,
            end: b.end,
            text: mergedText,
            words: a.words + b.words)
        lines[index] = merged
        lines.remove(at: index + 1)
        selectedId = merged.id
        hasUnsavedChanges = true
    }

    private func split(at index: Int) {
        guard index >= 0, index < lines.count else { return }
        let line = lines[index]
        let trimmed = line.text.trimmed
        let words = trimmed.split(separator: " ").map(String.init)
        guard words.count >= 2 else { return }

        // Разбиваем по границе слова, ближайшей к середине строки.
        var bestIndex = 1
        var bestDistance = Int.max
        let middle = words.count / 2
        for candidate in 1..<words.count {
            let distance = abs(candidate - middle)
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = candidate
            }
        }

        let firstText = words[0..<bestIndex].joined(separator: " ")
        let secondText = words[bestIndex...].joined(separator: " ")
        let ratio = line.end > line.start ? Double(bestIndex) / Double(words.count) : 0.5
        let splitTime = line.start + (line.end - line.start) * ratio
        let firstWords = line.words.filter { $0.end <= splitTime }
        let secondWords = line.words.filter { $0.end > splitTime }

        let first = EditableLine(start: line.start, end: splitTime, text: firstText, words: firstWords)
        let second = EditableLine(start: splitTime, end: line.end, text: secondText, words: secondWords)
        lines.replaceSubrange(index...index, with: [first, second])
        selectedId = second.id
        hasUnsavedChanges = true
    }

    private func deleteLine(at index: Int) {
        guard index >= 0, index < lines.count else { return }
        lines.remove(at: index)
        if lines.isEmpty {
            selectedId = nil
        } else {
            selectedId = lines[min(index, lines.count - 1)].id
        }
        hasUnsavedChanges = true
    }

    private func capitalizeFirstLetters() {
        for idx in lines.indices {
            let str = lines[idx].text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let first = str.first else { continue }
            let updated = String(first).uppercased() + str.dropFirst()
            if updated != lines[idx].text { hasUnsavedChanges = true }
            lines[idx].text = updated
        }
    }

    private func trimWhitespaceInAll() {
        for idx in lines.indices {
            let collapsed = lines[idx].text
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            if collapsed != lines[idx].text { hasUnsavedChanges = true }
            lines[idx].text = collapsed
        }
    }
}
