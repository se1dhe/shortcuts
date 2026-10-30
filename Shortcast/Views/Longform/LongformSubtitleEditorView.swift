import SwiftUI
import AVKit

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
    let correctionFilmKey: String
    let correctionLanguage: String
    let sourceURL: URL?
    let confirmButtonTitle: String
    let backButtonTitle: String
    let onAutoCorrect: ([LongformSubtitleCorrectionInput], @Sendable (String) -> Void) async throws -> LongformSubtitleCorrectionOutcome
    let onConfirm: ([TranscriptSegment]) -> Void
    let onBack: () -> Void

    @State private var phrases: [EditableSubtitlePhrase] = []
    @State private var selectedPhraseId: UUID? = nil
    @State private var selectedActFilter: Int? = nil // nil = Все акты
    @State private var searchText: String = ""
    @State private var sourcePlayer: AVPlayer?
    @State private var stopPlayback: Task<Void, Never>?
    @State private var sourceStill: CGImage?
    @State private var correctionMemory = SubtitleCorrectionMemory()
    @State private var rememberedCount = 0
    @State private var memoryWarning: String?
    @State private var pendingWithoutMemory: [TranscriptSegment]?
    @State private var isModelCorrecting = false
    @State private var modelCorrectionProgress = ""
    @State private var modelCorrectionEvents: [String] = []
    @State private var modelCorrectionSuggestions: [LongformSubtitleCorrectionSuggestion] = []
    @State private var modelCorrectionStatus: String?
    @State private var modelCorrectionStatusIsError = false

    init(
        arc: LongformNarrativeArc,
        concept: ThematicConcept,
        movieTitle: String,
        allSegments: [TranscriptSegment],
        correctionFilmKey: String? = nil,
        correctionLanguage: String = "uk",
        sourceURL: URL? = nil,
        confirmButtonTitle: String = "Перерендерить кино-эссе",
        backButtonTitle: String = "Отмена",
        onAutoCorrect: @escaping ([LongformSubtitleCorrectionInput], @Sendable (String) -> Void) async throws -> LongformSubtitleCorrectionOutcome,
        onConfirm: @escaping ([TranscriptSegment]) -> Void,
        onBack: @escaping () -> Void
    ) {
        self.arc = arc
        self.concept = concept
        self.movieTitle = movieTitle
        self.allSegments = allSegments
        self.correctionFilmKey = correctionFilmKey ?? "title:" + SubtitleCorrectionMemory.key(movieTitle).lowercased()
        self.correctionLanguage = correctionLanguage
        self.sourceURL = sourceURL
        self.confirmButtonTitle = confirmButtonTitle
        self.backButtonTitle = backButtonTitle
        self.onAutoCorrect = onAutoCorrect
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

            HStack {
                Text("Память правок: \(correctionMemory.examples.filter { $0.original != $0.replacement }.count) • применено к этому эссе: \(rememberedCount)")
                Spacer()
                Text("Подтверждённые правки запоминаются при пересборке")
            }
            .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 18).padding(.bottom, 8)
            if let memoryWarning {
                Text(memoryWarning).font(.caption).foregroundStyle(.orange).padding(.horizontal, 18)
            }

            Divider()

            // Панель фильтров по актам и поиска
            filterToolbar

            if isModelCorrecting || !modelCorrectionEvents.isEmpty || !modelCorrectionSuggestions.isEmpty || modelCorrectionStatus != nil {
                modelCorrectionPanel
            }

            Divider()

            // Двухоконная область: список фраз слева и монитор предпросмотра справа
            HSplitView {
                phraseListPanel
                    .frame(minWidth: 460, idealWidth: 540)

                ScrollView { cinemaMonitorPanel }
                    .frame(minWidth: 380, idealWidth: 460)
            }
        }
        .frame(minWidth: 960, minHeight: 640)
        .background(StudioTheme.background)
        .preferredColorScheme(.dark)
        .tint(StudioTheme.accent)
        .onAppear {
            initializePhrases()
            if let sourceURL { sourcePlayer = AVPlayer(url: sourceURL) }
        }
        .onDisappear { stopPlayback?.cancel(); sourcePlayer?.pause() }
        .alert("Не удалось сохранить память правок", isPresented: Binding(
            get: { pendingWithoutMemory != nil }, set: { if !$0 { pendingWithoutMemory = nil } })) {
                Button("Продолжить без памяти") {
                    if let updated = pendingWithoutMemory { onConfirm(updated) }
                    pendingWithoutMemory = nil
                }
                Button("Назад", role: .cancel) { pendingWithoutMemory = nil }
            } message: { Text(memoryWarning ?? "Правки останутся в проекте, но не попадут в общую память.") }
        .task(id: selectedPhrase?.id) {
            sourceStill = nil
            guard let sourceURL, let phrase = selectedPhrase else { return }
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: sourceURL))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 1920, height: 1080)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let frame = try? await generator.image(at: CMTime(seconds: phrase.start + 0.1, preferredTimescale: 600))
            guard !Task.isCancelled else { return }
            sourceStill = frame?.image
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
                        .background(StudioTheme.accent.opacity(0.18), in: Capsule())
                        .foregroundStyle(StudioTheme.accent)

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
            .tint(StudioTheme.accent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(StudioTheme.panel)
    }

    // MARK: - Filter Toolbar

    private var filterToolbar: some View {
        HStack(spacing: 12) {
            // Вкладки актов
            HStack(spacing: 6) {
                actFilterButton(title: "Все акты (\(phrases.count))", actIndex: nil)

                ForEach(Array(arc.acts.enumerated()), id: \.offset) { idx, _ in
                    let count = phrases.filter { $0.actIndex == idx }.count
                    actFilterButton(
                        title: "Акт \(Self.romanNumeral(idx + 1)) (\(count))",
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
                Label("Текстовые инструменты", systemImage: "textformat")
            }
            .menuStyle(.borderedButton)
            .controlSize(.small)

            Button {
                runModelSubtitleCorrection()
            } label: {
                Label(isModelCorrecting ? "Модель проверяет…" : "Исправить моделью",
                      systemImage: isModelCorrecting ? "hourglass" : "sparkles")
            }
            .buttonStyle(.borderedProminent)
            .tint(StudioTheme.accent)
            .controlSize(.small)
            .disabled(isModelCorrecting || phrases.isEmpty)

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
            .background(StudioTheme.raised, in: RoundedRectangle(cornerRadius: 6))
            .frame(width: 180)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(StudioTheme.panel)
    }

    private var modelCorrectionPanel: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: isModelCorrecting ? "sparkles" : "checkmark.seal.fill")
                    .foregroundStyle(StudioTheme.accent)
                Text(isModelCorrecting ? "МОДЕЛЬНАЯ ПРОВЕРКА СУБТИТРОВ" : "ПРЕДЛОЖЕНИЯ МОДЕЛИ")
                    .font(.system(size: 9, weight: .black)).tracking(0.8)
                    .foregroundStyle(StudioTheme.accent)
                Spacer()
                if !modelCorrectionSuggestions.isEmpty {
                    Text("Найдено: \(modelCorrectionSuggestions.count)")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
            }

            if isModelCorrecting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(modelCorrectionProgress.isEmpty ? "Подготавливаю контекст реплик…" : modelCorrectionProgress)
                        .font(.caption.weight(.medium))
                }
            }

            ForEach(Array(modelCorrectionEvents.suffix(4).enumerated()), id: \.offset) { _, event in
                Label(event, systemImage: "arrow.turn.down.right")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            if let modelCorrectionStatus, !isModelCorrecting {
                Text(modelCorrectionStatus)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(modelCorrectionStatusIsError ? StudioTheme.warning
                        : (modelCorrectionSuggestions.isEmpty ? StudioTheme.muted : StudioTheme.success))
            }

            ForEach(modelCorrectionSuggestions) { suggestion in
                if let phrase = phrases.first(where: { $0.originalSegmentIndex == suggestion.id }) {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("\(phrase.actTitle) · \(phrase.timecodeDisplay)")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundStyle(StudioTheme.muted)
                            Text(suggestion.original)
                                .font(.caption).foregroundStyle(.secondary)
                                .strikethrough(color: StudioTheme.warning)
                            Text(suggestion.replacement)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.primary)
                            Text(suggestion.reason)
                                .font(.caption2).foregroundStyle(StudioTheme.muted)
                        }
                        Spacer(minLength: 8)
                        Button(phrase.text == suggestion.original ? "Применить" : "Текст изменён") {
                            applyModelSuggestion(suggestion)
                        }
                            .buttonStyle(.borderedProminent).tint(StudioTheme.accent)
                        .disabled(phrase.text != suggestion.original)
                        Button {
                            modelCorrectionSuggestions.removeAll { $0.id == suggestion.id }
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.bordered)
                        .help("Отклонить предложение")
                    }
                    .padding(10)
                    .background(StudioTheme.raised.opacity(0.7), in: RoundedRectangle(cornerRadius: 9))
                }
            }

            if !modelCorrectionSuggestions.isEmpty {
                HStack {
                    Button("Применить все предложения", systemImage: "checkmark") {
                        applyAllModelSuggestions()
                    }
                    .buttonStyle(.borderedProminent).tint(StudioTheme.accent)
                    Button("Отклонить все") {
                        modelCorrectionSuggestions = []
                        modelCorrectionStatus = "Предложения отклонены; субтитры оставлены без изменений."
                        modelCorrectionStatusIsError = false
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(12)
        .background(StudioTheme.raised.opacity(0.55), in: RoundedRectangle(cornerRadius: 11))
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
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
                    selectedActFilter == actIndex ? StudioTheme.accent.opacity(0.2) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .foregroundStyle(selectedActFilter == actIndex ? StudioTheme.accent : Color.primary)
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
            let suspicious = UkrainianTextReview.suspiciousWords(in: phrase.text)
            if !suspicious.isEmpty {
                Text("Сверьте с дубляжом: " + suspicious.joined(separator: ", "))
                    .font(.caption2).foregroundStyle(.orange)
            }
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
                                .foregroundStyle(Color(hex: concept.accentColorHex) ?? StudioTheme.accent)
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
                .fill(isSelected ? StudioTheme.accent.opacity(0.08) : StudioTheme.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? StudioTheme.accent : StudioTheme.line, lineWidth: isSelected ? 1.5 : 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            selectedPhraseId = phrase.id
        }
    }

    // MARK: - Cinema Monitor Panel

    private var cinemaMonitorPanel: some View {
        VStack(spacing: 16) {
            if let current = selectedPhrase {
                ForEach(Array(correctionMemory.suggestions(for: current.text, filmKey: correctionFilmKey,
                    language: correctionLanguage).enumerated()), id: \.offset) { _, suggestion in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Похожая правка из памяти — сверьте с дубляжом").font(.caption.bold())
                        Text(suggestion.text).font(.subheadline)
                        Text("Ранее: «\(suggestion.example.original)» → «\(suggestion.example.replacement)»")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Применить к этой реплике") {
                            if let index = phrases.firstIndex(where: { $0.id == current.id }) {
                                phrases[index].text = suggestion.text
                            }
                        }
                    }.padding(12).background(.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
                if let suggestion = arc.captionSuggestions?.first(where: {
                    $0.start == current.start && $0.end == current.end && $0.original == current.text
                }) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Предложение модели — сверьте с дубляжом").font(.caption.bold())
                        Text(suggestion.replacement).font(.subheadline)
                        Text(suggestion.reason).font(.caption).foregroundStyle(.secondary)
                        Button("Применить к этой реплике") {
                            if let index = phrases.firstIndex(where: { $0.id == current.id }) {
                                phrases[index].text = suggestion.replacement
                            }
                        }
                    }.padding(12).background(StudioTheme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                }
                if let sourcePlayer {
                    VideoPlayer(player: sourcePlayer).frame(height: 150)
                    Button("Прослушать выбранную реплику", systemImage: "speaker.wave.2") {
                        playSourcePhrase(current)
                    }
                }
            }
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
                Text(sourceStill == nil ? "Раскладка титров; исходный кадр — в проигрывателе выше." : "Раскладка титров на исходном кадре выбранной реплики.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)

            // Та же геометрия и тот же шрифт, что у экспортного оверлея.
            if let preview = LongformSubtitleRenderer().renderPreviewImage(
                renderSize: CGSize(width: 1920, height: 1080), concept: concept,
                currentPhrase: previewText, backgroundImage: sourceStill) {
                Image(decorative: preview, scale: 1)
                    .resizable().aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal, 14)
            }


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

                    Text("Субтитры располагаются под главной мыслью с постоянным зазором; длинные реплики растут вниз.")
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

    private func runModelSubtitleCorrection() {
        guard !isModelCorrecting, !phrases.isEmpty else { return }
        isModelCorrecting = true
        modelCorrectionProgress = "Готовлю фразы и соседний контекст…"
        modelCorrectionEvents = []
        modelCorrectionSuggestions = []
        modelCorrectionStatus = nil
        modelCorrectionStatusIsError = false

        let input = phrases.enumerated().map { index, phrase in
            LongformSubtitleCorrectionInput(
                id: phrase.originalSegmentIndex,
                act: phrase.actTitle,
                timecode: phrase.timecodeDisplay,
                before: index > 0 ? phrases[index - 1].text : "",
                text: phrase.text,
                after: index + 1 < phrases.count ? phrases[index + 1].text : ""
            )
        }

        Task { @MainActor in
            defer { isModelCorrecting = false }
            do {
                let outcome = try await onAutoCorrect(input) { message in
                    Task { @MainActor in
                        modelCorrectionProgress = message
                        if modelCorrectionEvents.last != message {
                            modelCorrectionEvents.append(message)
                            if modelCorrectionEvents.count > 12 { modelCorrectionEvents.removeFirst() }
                        }
                    }
                }
                modelCorrectionSuggestions = outcome.suggestions
                modelCorrectionStatus = outcome.suggestions.isEmpty
                    ? "Проверено реплик: \(outcome.checkedCount). Уверенных исправлений не найдено."
                    : "Модель проверила \(outcome.checkedCount) реплик. Сверьте предложения и примените подходящие."
            } catch {
                modelCorrectionStatus = "Проверка не завершена: \(error.localizedDescription)"
                modelCorrectionStatusIsError = true
            }
        }
    }

    private func applyModelSuggestion(_ suggestion: LongformSubtitleCorrectionSuggestion) {
        guard let index = phrases.firstIndex(where: { $0.originalSegmentIndex == suggestion.id }) else { return }
        guard phrases[index].text == suggestion.original else {
            modelCorrectionSuggestions.removeAll { $0.id == suggestion.id }
            modelCorrectionStatus = "Реплика изменилась во время проверки; устаревшее предложение снято."
            modelCorrectionStatusIsError = false
            return
        }
        phrases[index].text = suggestion.replacement
        modelCorrectionSuggestions.removeAll { $0.id == suggestion.id }
        modelCorrectionStatusIsError = false
        modelCorrectionStatus = modelCorrectionSuggestions.isEmpty
            ? "Предложение применено. Проверьте текст и нажмите «\(confirmButtonTitle)» для пересборки."
            : "Предложение применено. Осталось проверить: \(modelCorrectionSuggestions.count)."
    }

    private func applyAllModelSuggestions() {
        let suggestions = modelCorrectionSuggestions
        var appliedCount = 0
        var skippedCount = 0
        for suggestion in suggestions {
            guard let index = phrases.firstIndex(where: { $0.originalSegmentIndex == suggestion.id }) else { continue }
            guard phrases[index].text == suggestion.original else {
                skippedCount += 1
                continue
            }
            phrases[index].text = suggestion.replacement
            appliedCount += 1
        }
        modelCorrectionSuggestions = []
        modelCorrectionStatusIsError = false
        modelCorrectionStatus = appliedCount == 0
            ? "Предложения не применены; изменённые вручную реплики оставлены как есть."
            : "Применено: \(appliedCount)." + (skippedCount > 0 ? " Пропущено устаревших предложений: \(skippedCount)." : "")
                + " Проверьте текст и нажмите «\(confirmButtonTitle)» для пересборки."
    }

    private func initializePhrases() {
        var items: [EditableSubtitlePhrase] = []
        var seenSegmentIndices = Set<Int>()
        do {
            try SubtitleCorrectionStore.shared.update {
                $0.importEdits(arc.captionEdits ?? [], filmKey: correctionFilmKey, language: correctionLanguage)
            }
            correctionMemory = try SubtitleCorrectionStore.shared.load()
        } catch { memoryWarning = "Память правок недоступна: \(error.localizedDescription)" }
        let rememberedEdits = correctionMemory.edits(for: allSegments, filmKey: correctionFilmKey, language: correctionLanguage)
        // Явная правка текущего проекта всегда важнее общей памяти.
        let combined = (arc.captionEdits ?? []) + rememberedEdits
        let displaySegments = LongformEditorialSupport.captions(allSegments, edits: combined)

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
                                text: displaySegments[origIdx].text,
                                originalText: seg.text
                            ))
                        }
                    }
                }
            }
        }

        self.phrases = items.sorted { $0.start < $1.start }
        self.rememberedCount = items.filter { phrase in
            rememberedEdits.contains { $0.start == phrase.start && $0.end == phrase.end && $0.replacement == phrase.text }
        }.count
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

    private var previewText: String {
        guard let phrase = selectedPhrase else { return "" }
        return LongformSubtitleRenderer.chunkTimedPhrases([
            TimedSubtitlePhrase(start: 0, end: max(1, phrase.duration), text: phrase.text)
        ]).first?.text ?? ""
    }

    private func confirmAndProceed() {
        var updated = LongformEditorialSupport.captions(allSegments, edits: arc.captionEdits)
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
        do {
            let shown = phrases.map { TranscriptSegment(start: $0.start, end: $0.end, text: $0.originalText) }
            try SubtitleCorrectionStore.shared.update {
                $0.record(original: shown, updated: updated, filmKey: correctionFilmKey, language: correctionLanguage)
            }
            onConfirm(updated)
        } catch {
            memoryWarning = error.localizedDescription
            pendingWithoutMemory = updated
        }
    }

    private func playSourcePhrase(_ phrase: EditableSubtitlePhrase) {
        guard let sourcePlayer else { return }
        stopPlayback?.cancel()
        sourcePlayer.pause()
        stopPlayback = Task { @MainActor in
            let start = max(0, phrase.start - 0.3)
            await sourcePlayer.seek(to: CMTime(seconds: start, preferredTimescale: 600),
                                    toleranceBefore: .zero, toleranceAfter: .zero)
            guard !Task.isCancelled else { return }
            sourcePlayer.play()
            try? await Task.sleep(for: .seconds(phrase.end - start + 0.5))
            guard !Task.isCancelled else { return }
            sourcePlayer.pause()
        }
    }

    /// Номер акта по позиции: у аналитической арки пять актов и пропуски пустых,
    /// поэтому номер берётся из места в арке, а не из типа.
    static func romanNumeral(_ number: Int) -> String {
        let numerals = ["I", "II", "III", "IV", "V", "VI", "VII", "VIII"]
        return numerals.indices.contains(number - 1) ? numerals[number - 1] : "\(number)"
    }
}
