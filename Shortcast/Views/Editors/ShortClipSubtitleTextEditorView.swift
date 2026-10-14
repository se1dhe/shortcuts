import SwiftUI

/// Вкладка «Субтитры»: полноценный редактор текста субтитров Whisper с двухоконным
/// интерфейсом (список фраз слева и 9:16 видеомонитор MiniPhone с живыми правками справа).
/// Single Responsibility Principle (SRP): отвечает за точную проверку текста, правку опечаток
/// распознавания речи и синхронизацию экранных титров шортса.
struct ShortClipSubtitleTextEditorView: View {

    @Bindable var clip: ShortClip
    @State private var searchText = ""
    @State private var activeSeekTime: Double? = nil
    @State private var selectedSegmentId: UUID? = nil

    private var filteredSegments: [SubtitleSegment] {
        if searchText.trimmed.isEmpty {
            return clip.subtitleSegments
        }
        let q = searchText.lowercased()
        return clip.subtitleSegments.filter { $0.text.lowercased().contains(q) }
    }

    private var selectedSegment: SubtitleSegment? {
        if let id = selectedSegmentId, let found = clip.subtitleSegments.first(where: { $0.id == id }) {
            return found
        }
        return filteredSegments.first ?? clip.subtitleSegments.first
    }

    var body: some View {
        HSplitView {
            // Левая панель: список фраз с поиском и авто-инструментами
            phrasesListPanel
                .frame(minWidth: 480, idealWidth: 560)

            // Правая панель: 9:16 видеомонитор MiniPhone и инспектор реплики
            monitorPanel
                .frame(minWidth: 360, idealWidth: 420, maxWidth: 500)
        }
        .padding(16)
        .onAppear {
            if selectedSegmentId == nil {
                selectedSegmentId = clip.subtitleSegments.first?.id
            }
        }
    }

    // MARK: - Left Panel: Phrases List

    private var phrasesListPanel: some View {
        VStack(spacing: 12) {
            // Панель инструментов: поиск, авто-исправления и добавление
            toolbarSection

            // Список карточек фраз
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        if filteredSegments.isEmpty {
                            emptyStateView
                        } else {
                            ForEach(Array(filteredSegments.enumerated()), id: \.element.id) { index, segment in
                                subtitleSegmentCard(segment: segment, displayIndex: index + 1)
                                    .id(segment.id)
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 4)
                }
            }
        }
    }

    // MARK: - Toolbar Section

    private var toolbarSection: some View {
        HStack(spacing: 10) {
            // Поле поиска
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                TextField("Поиск по субтитрам…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.callout)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

            Spacer()

            // Меню авто-исправления текста
            Menu {
                Button("Сделать заглавной первую букву в каждой фразе") {
                    capitalizeFirstLetters()
                }
                Button("Удалить лишние пробелы") {
                    trimExtraWhitespace()
                }
                Button("Поставить точку в конце фраз") {
                    addTrailingPeriods()
                }
            } label: {
                Label("Авто-исправление", systemImage: "sparkles")
            }
            .menuStyle(.borderedButton)
            .controlSize(.small)

            // Кнопка добавления новой реплики
            Button {
                addNewSubtitleSegment()
            } label: {
                Label("Добавить", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Subtitle Segment Card

    private func subtitleSegmentCard(segment: SubtitleSegment, displayIndex: Int) -> some View {
        let isSelected = (selectedSegment?.id == segment.id)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("#\(displayIndex)")
                    .font(.caption2.monospaced().weight(.bold))
                    .foregroundStyle(.secondary)

                Text(segment.timecodeDisplay)
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)

                Text(String(format: "%.1f с", segment.duration))
                    .font(.caption2.monospacedDigit())
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
                    .foregroundStyle(.secondary)

                Spacer()

                // Кнопка перемотки плеера к этой фразе
                Button {
                    activeSeekTime = segment.start
                    selectedSegmentId = segment.id
                } label: {
                    Image(systemName: "play.circle.fill")
                        .font(.body)
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .help("Воспроизвести с этой секунды")

                // Кнопка удаления фразы
                Button {
                    deleteSegment(segment.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Удалить реплику из субтитров")
            }

            // Поле редактирования текста фразы
            if let idx = clip.subtitleSegments.firstIndex(where: { $0.id == segment.id }) {
                TextField("Текст реплики субтитров", text: $clip.subtitleSegments[idx].text, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .font(.system(size: 13, weight: .medium))
                    .onTapGesture {
                        selectedSegmentId = segment.id
                    }

                // Кнопки точной подстройки таймингов начала и конца фразы (±0.1с)
                HStack(spacing: 12) {
                    HStack(spacing: 4) {
                        Text("Start:")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Button("-0.1") {
                            adjustSegmentTiming(idx: idx, startDelta: -0.1, endDelta: 0)
                        }
                        .buttonStyle(.borderless)
                        .font(.caption2)
                        Button("+0.1") {
                            adjustSegmentTiming(idx: idx, startDelta: +0.1, endDelta: 0)
                        }
                        .buttonStyle(.borderless)
                        .font(.caption2)
                    }

                    HStack(spacing: 4) {
                        Text("End:")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Button("-0.1") {
                            adjustSegmentTiming(idx: idx, startDelta: 0, endDelta: -0.1)
                        }
                        .buttonStyle(.borderless)
                        .font(.caption2)
                        Button("+0.1") {
                            adjustSegmentTiming(idx: idx, startDelta: 0, endDelta: +0.1)
                        }
                        .buttonStyle(.borderless)
                        .font(.caption2)
                    }

                    Spacer()
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.15), lineWidth: isSelected ? 1.5 : 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            selectedSegmentId = segment.id
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 8) {
            Image(systemName: "text.magnifyingglass")
                .font(.title)
                .foregroundStyle(.secondary)
            Text(clip.subtitleSegments.isEmpty ? "Субтитры отсутствуют" : "Фразы не найдены по запросу")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if clip.subtitleSegments.isEmpty {
                Button("Добавить первую фразу") {
                    addNewSubtitleSegment()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    // MARK: - Right Panel: 9:16 Monitor & Inspector

    private var monitorPanel: some View {
        VStack(spacing: 12) {
            HStack {
                Label("Экранный монитор (9:16)", systemImage: "tv.fill")
                    .font(.subheadline.weight(.bold))
                Spacer()
                Text("1080×1920")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)

            // 9:16 ShortClipLivePhoneView монитор
            ShortClipLivePhoneView(
                clip: clip,
                seekTime: activeSeekTime,
                showPlatformChrome: false
            )
            .frame(maxHeight: 460)

            // Инспектор выделенной реплики
            if let curr = selectedSegment {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Текущая реплика в кадре:")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(curr.timecodeDisplay)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 8) {
                        statPill(label: "Длительность", value: String(format: "%.1f с", curr.duration))
                        statPill(label: "Слов", value: "\(curr.text.split(whereSeparator: { $0.isWhitespace }).count)")
                        statPill(label: "Символов", value: "\(curr.text.count)")
                    }

                    Text("💡 Правки текста отображаются на экране сразу же. Выберите стиль и кегль субтитров на вкладке «Стиль и звук».")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            }

            Spacer()
        }
    }

    private func statPill(label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.subheadline.weight(.bold))
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Actions

    private func deleteSegment(_ id: UUID) {
        clip.subtitleSegments.removeAll(where: { $0.id == id })
        if selectedSegmentId == id {
            selectedSegmentId = clip.subtitleSegments.first?.id
        }
    }

    private func addNewSubtitleSegment() {
        let lastEnd = clip.subtitleSegments.last?.end ?? 0.0
        let newStart = (lastEnd * 10).rounded() / 10
        let newEnd = ((lastEnd + 2.0) * 10).rounded() / 10
        let newSegment = SubtitleSegment(
            start: newStart,
            end: newEnd,
            text: "Новая реплика"
        )
        clip.subtitleSegments.append(newSegment)
        selectedSegmentId = newSegment.id
        activeSeekTime = newStart
    }

    private func adjustSegmentTiming(idx: Int, startDelta: Double, endDelta: Double) {
        guard idx >= 0 && idx < clip.subtitleSegments.count else { return }
        var seg = clip.subtitleSegments[idx]
        let newStart = max(0.0, ((seg.start + startDelta) * 10).rounded() / 10)
        let newEnd = max(newStart + 0.2, ((seg.end + endDelta) * 10).rounded() / 10)
        seg.start = newStart
        seg.end = newEnd
        clip.subtitleSegments[idx] = seg
        activeSeekTime = newStart
    }

    private func capitalizeFirstLetters() {
        for idx in clip.subtitleSegments.indices {
            let str = clip.subtitleSegments[idx].text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let first = str.first else { continue }
            clip.subtitleSegments[idx].text = String(first).uppercased() + String(str.dropFirst())
        }
    }

    private func trimExtraWhitespace() {
        for idx in clip.subtitleSegments.indices {
            let components = clip.subtitleSegments[idx].text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
            clip.subtitleSegments[idx].text = components.joined(separator: " ")
        }
    }

    private func addTrailingPeriods() {
        for idx in clip.subtitleSegments.indices {
            var str = clip.subtitleSegments[idx].text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !str.isEmpty && !str.hasSuffix(".") && !str.hasSuffix("!") && !str.hasSuffix("?") {
                str += "."
            }
            clip.subtitleSegments[idx].text = str
        }
    }
}
