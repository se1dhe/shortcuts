import SwiftUI

/// Модель редактируемой фразы субтитров для кино-эссе
struct EditableSubtitlePhrase: Identifiable, Sendable, Equatable {
    let id: UUID
    let originalSegmentIndex: Int
    let actIndex: Int
    let actTitle: String
    let actType: LongformActType
    let start: Double
    let end: Double
    var text: String
    let originalText: String

    var isEdited: Bool {
        text != originalText
    }

    var duration: Double {
        max(0.0, end - start)
    }

    var timecodeDisplay: String {
        let sMin = Int(start) / 60
        let sSec = Int(start) % 60
        let sMs = Int((start.truncatingRemainder(dividingBy: 1)) * 10)
        let eMin = Int(end) / 60
        let eSec = Int(end) % 60
        let eMs = Int((end.truncatingRemainder(dividingBy: 1)) * 10)
        return String(format: "%02d:%02d.%d — %02d:%02d.%d", sMin, sSec, sMs, eMin, eSec, eMs)
    }

    var screenLines: [String] {
        LongformSubtitleRenderer.formatScreenLines(text: text)
    }
}

/// Экран интерактивного редактирования субтитров из Whisper перед финальным монтажом кино-эссе.
/// Single Responsibility Principle (SRP): отвечает за точную проверку текста, правку опечаток
/// и визуальный предпросмотр экранных строк в формате 16:9 Shortcast Cinema.
struct LongformSubtitleEditorView: View {

    let arc: LongformNarrativeArc
    let concept: ThematicConcept
    let movieTitle: String
    let allSegments: [TranscriptSegment]
    let confirmButtonTitle: String
    let backButtonTitle: String
    let onConfirm: ([TranscriptSegment]) -> Void
    let onBack: () -> Void

    @State private var phrases: [EditableSubtitlePhrase] = []
    @State private var selectedPhraseId: UUID? = nil
    @State private var selectedActFilter: Int? = nil // nil = Все акты
    @State private var searchText: String = ""

    init(
        arc: LongformNarrativeArc,
        concept: ThematicConcept,
        movieTitle: String,
        allSegments: [TranscriptSegment],
        confirmButtonTitle: String = "Перерендерить кино-эссе",
        backButtonTitle: String = "Отмена",
        onConfirm: @escaping ([TranscriptSegment]) -> Void,
        onBack: @escaping () -> Void
    ) {
        self.arc = arc
        self.concept = concept
        self.movieTitle = movieTitle
        self.allSegments = allSegments
        self.confirmButtonTitle = confirmButtonTitle
        self.backButtonTitle = backButtonTitle
        self.onConfirm = onConfirm
        self.onBack = onBack
    }

    private var filteredPhrases: [EditableSubtitlePhrase] {
        phrases.filter { phrase in
            let matchesAct = (selectedActFilter == nil || phrase.actIndex == selectedActFilter)
            if searchText.isEmpty {
                return matchesAct
            }
            let query = searchText.lowercased()
            return matchesAct && (phrase.text.lowercased().contains(query) || phrase.originalText.lowercased().contains(query))
        }
    }

    private var selectedPhrase: EditableSubtitlePhrase? {
        if let id = selectedPhraseId, let found = phrases.first(where: { $0.id == id }) {
            return found
        }
        return filteredPhrases.first ?? phrases.first
    }

    private var editedCount: Int {
        phrases.filter(\.isEdited).count
    }

    var body: some View {
        VStack(spacing: 0) {
            // Верхняя панель управления
            headerBar

            Divider()

            // Панель фильтров по актам и поиска
            filterToolbar

            Divider()

            // Двухоконная область: список фраз слева и монитор предпросмотра справа
            HSplitView {
                phraseListPanel
                    .frame(minWidth: 460, idealWidth: 540)

                cinemaMonitorPanel
                    .frame(minWidth: 380, idealWidth: 460)
            }
        }
        .frame(minWidth: 960, minHeight: 640)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            initializePhrases()
        }
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        HStack(spacing: 14) {
            Button {
                onBack()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "xmark")
                    Text(backButtonTitle)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text("Редактор субтитров")
                        .font(.headline)

                    Text("«\(concept.word.uppercased())»")
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.18), in: Capsule())
                        .foregroundStyle(Color.accentColor)

                    if editedCount > 0 {
                        Text("Изменено: \(editedCount)")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.2), in: Capsule())
                            .foregroundStyle(.green)
                    }
                }

                Text("Фильм «\(movieTitle)» • Исправьте текст субтитров и нажмите «\(confirmButtonTitle)»")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                confirmAndProceed()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text(confirmButtonTitle)
                }
                .font(.headline)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(.yellow)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    // MARK: - Filter Toolbar

    private var filterToolbar: some View {
        HStack(spacing: 12) {
            // Вкладки актов
            HStack(spacing: 6) {
                actFilterButton(title: "Все акты (\(phrases.count))", actIndex: nil)

                ForEach(Array(arc.acts.enumerated()), id: \.offset) { idx, act in
                    let count = phrases.filter { $0.actIndex == idx }.count
                    actFilterButton(
                        title: "\(act.type.shortBadge) (\(count))",
                        actIndex: idx
                    )
                }
            }

            Spacer()

            // Быстрые инструменты редактирования
            Menu {
                Button("Сделать заглавной первую букву в каждой фразе") {
                    capitalizeFirstLetters()
                }
                Button("Удалить лишние пробелы") {
                    trimWhitespaceInAll()
                }
                Divider()
                Button("Сбросить все правки к оригиналу Whisper", role: .destructive) {
                    resetAllToOriginal()
                }
            } label: {
                Label("Авто-исправление", systemImage: "sparkles")
            }
            .menuStyle(.borderedButton)
            .controlSize(.small)

            // Поле поиска
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                TextField("Поиск фразы…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.caption)
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
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
            .frame(width: 180)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.04))
    }

    private func actFilterButton(title: String, actIndex: Int?) -> some View {
        Button {
            selectedActFilter = actIndex
        } label: {
            Text(title)
                .font(.caption.weight(selectedActFilter == actIndex ? .bold : .regular))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    selectedActFilter == actIndex ? Color.accentColor.opacity(0.2) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .foregroundStyle(selectedActFilter == actIndex ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Phrase List Panel

    private var phraseListPanel: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        if filteredPhrases.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "text.magnifyingglass")
                                    .font(.title)
                                    .foregroundStyle(.secondary)
                                Text("Фразы не найдены")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 200)
                        } else {
                            ForEach(Array(filteredPhrases.enumerated()), id: \.element.id) { index, phrase in
                                phraseCard(phrase: phrase, displayIndex: index + 1)
                                    .id(phrase.id)
                            }
                        }
                    }
                    .padding(14)
                }
            }
        }
    }

    private func phraseCard(phrase: EditableSubtitlePhrase, displayIndex: Int) -> some View {
        let isSelected = (selectedPhrase?.id == phrase.id)

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("#\(displayIndex)")
                    .font(.caption2.monospaced().weight(.bold))
                    .foregroundStyle(.secondary)

                Text(phrase.actTitle.uppercased())
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(.secondary)

                Text(phrase.timecodeDisplay)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)

                Spacer()

                if phrase.isEdited {
                    Label("Изменено", systemImage: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)

                    Button {
                        resetPhrase(phrase.id)
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .help("Вернуть исходный текст Whisper")
                }
            }

            // Поле редактирования
            if let idx = phrases.firstIndex(where: { $0.id == phrase.id }) {
                TextField("Реплика", text: $phrases[idx].text, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...4)
                    .font(.system(size: 13, weight: .medium))
                    .onTapGesture {
                        selectedPhraseId = phrase.id
                    }
            }

            // Экранные строки (разбивка на экране)
            let lines = phrase.screenLines
            if !lines.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Text("Экран:")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(lines, id: \.self) { line in
                            Text("«\(line)»")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundStyle(Color(hex: concept.accentColorHex) ?? Color.yellow)
                        }
                    }
                    Spacer()
                    Text("\(lines.count) стр.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(6)
                .background(Color.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
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
            selectedPhraseId = phrase.id
        }
    }

    // MARK: - Cinema Monitor Panel

    private var cinemaMonitorPanel: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: "tv.fill")
                        .foregroundStyle(.secondary)
                    Text("Экранный монитор (16:9 Cinema)")
                        .font(.subheadline.weight(.bold))
                    Spacer()
                    Text("1920×1080")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                Text("Живой предпросмотр расположения, кегля и переносов прямо в кадре фильма")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)

            // Монитор 16:9
            ZStack {
                // Черный кино-фон
                Color.black
                    .aspectRatio(16/9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                // Кинематографический каше (Letterbox 2.35:1)
                VStack(spacing: 0) {
                    Color.black.opacity(0.85)
                        .frame(height: 22)
                    Spacer()
                    Color.black.opacity(0.85)
                        .frame(height: 22)
                }

                // Визуализация титров в кадре
                VStack {
                    // Верхний левый угол: бейдж текущего акта
                    HStack {
                        if let curr = selectedPhrase {
                            Text(curr.actTitle.uppercased())
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 3))
                                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.white.opacity(0.2), lineWidth: 0.5))
                                .foregroundStyle(.white)
                        }
                        Spacer()
                    }
                    .padding(14)

                    Spacer()

                    // Центральное слово концепта (в стиле Cold Open)
                    Text(concept.word.uppercased())
                        .font(.system(size: 19, weight: .heavy, design: .rounded))
                        .tracking(3.5)
                        .foregroundStyle(Color(white: 0.96))
                        .shadow(color: .black, radius: 5)
                        .padding(.bottom, 6)

                    // Нижняя треть: живой предпросмотр экранных строк субтитров
                    if let curr = selectedPhrase {
                        VStack(spacing: 3) {
                            ForEach(curr.screenLines, id: \.self) { line in
                                Text(line)
                                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                                    .foregroundStyle(Color(hex: concept.accentColorHex) ?? Color.yellow)
                                    .shadow(color: .black, radius: 4, x: 0, y: 1)
                                    .multilineTextAlignment(.center)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 28)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 14)
            .shadow(color: .black.opacity(0.2), radius: 6, y: 3)

            // Информация о текущей реплике
            if let curr = selectedPhrase {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Параметры реплики:")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(curr.timecodeDisplay)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 14) {
                        statPill(label: "Длительность", value: String(format: "%.1f с", curr.duration))
                        statPill(label: "Слов", value: "\(curr.text.split(whereSeparator: { $0.isWhitespace }).count)")
                        statPill(label: "Строк в кадре", value: "\(curr.screenLines.count)")
                    }

                    Text("💡 Субтитры располагаются строго в нижней трети экрана над каше, ритмично меняясь по 3–5 слов.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
                .padding(12)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 14)
            }

            Spacer()
        }
        .background(Color.secondary.opacity(0.02))
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

    private func initializePhrases() {
        var items: [EditableSubtitlePhrase] = []
        var seenSegmentIndices = Set<Int>()

        for (actIdx, act) in arc.acts.enumerated() {
            for sceneRange in act.segments {
                for (origIdx, seg) in allSegments.enumerated() {
                    if seg.end > sceneRange.start && seg.start < sceneRange.end {
                        if !seenSegmentIndices.contains(origIdx) {
                            seenSegmentIndices.insert(origIdx)
                            items.append(EditableSubtitlePhrase(
                                id: UUID(),
                                originalSegmentIndex: origIdx,
                                actIndex: actIdx,
                                actTitle: act.title,
                                actType: act.type,
                                start: seg.start,
                                end: seg.end,
                                text: seg.text,
                                originalText: seg.text
                            ))
                        }
                    }
                }
            }
        }

        self.phrases = items.sorted { $0.start < $1.start }
        self.selectedPhraseId = self.phrases.first?.id
    }

    private func resetPhrase(_ id: UUID) {
        if let idx = phrases.firstIndex(where: { $0.id == id }) {
            phrases[idx].text = phrases[idx].originalText
        }
    }

    private func capitalizeFirstLetters() {
        for idx in phrases.indices {
            let str = phrases[idx].text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let first = str.first else { continue }
            phrases[idx].text = String(first).uppercased() + String(str.dropFirst())
        }
    }

    private func trimWhitespaceInAll() {
        for idx in phrases.indices {
            let components = phrases[idx].text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
            phrases[idx].text = components.joined(separator: " ")
        }
    }

    private func resetAllToOriginal() {
        for idx in phrases.indices {
            phrases[idx].text = phrases[idx].originalText
        }
    }

    private func confirmAndProceed() {
        var updated = allSegments
        for phrase in phrases {
            guard phrase.originalSegmentIndex >= 0 && phrase.originalSegmentIndex < updated.count else { continue }
            let orig = updated[phrase.originalSegmentIndex]
            updated[phrase.originalSegmentIndex] = TranscriptSegment(
                start: orig.start,
                end: orig.end,
                text: phrase.text,
                words: orig.words
            )
        }
        // Self-learning: remember every manual fix so Whisper is biased toward
        // the corrected vocabulary on future transcriptions.
        for phrase in phrases where phrase.isEdited {
            TranscriptionCorrectionsService.shared.recordCorrection(
                original: phrase.originalText,
                corrected: phrase.text)
        }
        onConfirm(updated)
    }
}

private extension LongformActType {
    var shortBadge: String {
        switch self {
        case .hook: return "Акт I"
        case .downfall: return "Акт II"
        case .struggle: return "Акт III"
        case .catharsis: return "Акт IV"
        }
    }
}
