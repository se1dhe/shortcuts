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

    static func correctionInputs(from phrases: [EditableSubtitlePhrase], arc: LongformNarrativeArc) -> [LongformSubtitleCorrectionInput] {
        func sameScene(_ left: EditableSubtitlePhrase, _ right: EditableSubtitlePhrase) -> Bool {
            guard left.actIndex == right.actIndex, arc.acts.indices.contains(left.actIndex) else { return false }
            let ranges = arc.acts[left.actIndex].segments
            return ranges.contains { range in
                left.start < range.end && left.end > range.start
                    && right.start < range.end && right.end > range.start
            }
        }
        return phrases.enumerated().map { index, phrase in
            let previous = index > 0 ? phrases[index - 1] : nil
            let next = index + 1 < phrases.count ? phrases[index + 1] : nil
            let before = previous.flatMap {
                sameScene($0, phrase) && phrase.start - $0.end <= 8 ? String($0.text.suffix(200)) : nil
            } ?? ""
            let after = next.flatMap {
                sameScene(phrase, $0) && $0.start - phrase.end <= 8 ? String($0.text.prefix(200)) : nil
            } ?? ""
            return LongformSubtitleCorrectionInput(id: phrase.originalSegmentIndex, act: phrase.actTitle,
                timecode: phrase.timecodeDisplay, before: before, text: phrase.text, after: after)
        }
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
    @State private var previewAudio = MontageScenePreviewAudio()
    @State private var reviewingSuggestions = true
    @State private var selectedSuggestionID: Int?
    @State private var showModelEvents = false
    @State private var stopPlayback: Task<Void, Never>?
    @State private var sourceStill: CGImage?
    @State private var correctionMemory = SubtitleCorrectionMemory()
    @State private var rememberedCount = 0
    @State private var memoryWarning: String?
    @State private var pendingWithoutMemory: [TranscriptSegment]?
    @State private var isModelCorrecting = false
    @State private var correctionTask: Task<Void, Never>?
    @State private var correctingPhraseID: UUID?
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
        confirmButtonTitle: String = L10n.tr("Перерендерить кино-эссе"),
        backButtonTitle: String = L10n.tr("Отмена"),
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
                Text(L10n.tr("Память правок: %1$@ • применено к этому эссе: %2$@", String(describing: correctionMemory.examples.filter { $0.original != $0.replacement }.count), String(describing: rememberedCount)))
                Spacer()
                Text(L10n.tr("Подтверждённые правки запоминаются при пересборке"))
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
            if reviewingSuggestions && !modelCorrectionSuggestions.isEmpty {
                suggestionReviewWorkspace
            } else {
                HSplitView {
                    phraseListPanel.frame(minWidth: 460, idealWidth: 540)
                    ScrollView { cinemaMonitorPanel }.frame(minWidth: 380, idealWidth: 460)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isModelCorrecting || !modelCorrectionEvents.isEmpty { OperationLogPanel(isActive: isModelCorrecting) }
        }
        .frame(minWidth: 960, minHeight: 640)
        .background(StudioTheme.background)
        .preferredColorScheme(.dark)
        .tint(StudioTheme.accent)
        .onAppear {
            initializePhrases()
            if let sourceURL { sourcePlayer = MontageVideoPreviewPlayer.makeVideoOnlyPlayer(url: sourceURL) }
        }
        .onDisappear { correctionTask?.cancel(); stopPlayback?.cancel(); previewAudio.stop(); sourcePlayer?.pause() }
        .alert(L10n.tr("Не удалось сохранить память правок"), isPresented: Binding(
            get: { pendingWithoutMemory != nil }, set: { if !$0 { pendingWithoutMemory = nil } })) {
                Button(L10n.tr("Продолжить без памяти")) {
                    if let updated = pendingWithoutMemory { onConfirm(updated) }
                    pendingWithoutMemory = nil
                }
                Button(L10n.tr("Назад"), role: .cancel) { pendingWithoutMemory = nil }
            } message: { Text(memoryWarning ?? L10n.tr("Правки останутся в проекте, но не попадут в общую память.")) }
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
                    Text(L10n.tr("Редактор субтитров"))
                        .font(.headline)

                    Text("«\(concept.displayWord.uppercased())»")
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(StudioTheme.accent.opacity(0.18), in: Capsule())
                        .foregroundStyle(StudioTheme.accent)

                    if editedCount > 0 {
                        Text(L10n.tr("Изменено: %1$@", String(describing: editedCount)))
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.2), in: Capsule())
                            .foregroundStyle(.green)
                    }
                }

                Text(L10n.tr("Фильм «%1$@» • Исправьте текст субтитров и нажмите «%2$@»", String(describing: movieTitle), String(describing: confirmButtonTitle)))
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
                actFilterButton(title: L10n.tr("Все акты (%1$@)", String(describing: phrases.count)), actIndex: nil)

                ForEach(Array(arc.acts.enumerated()), id: \.offset) { idx, _ in
                    let count = phrases.filter { $0.actIndex == idx }.count
                    actFilterButton(
                        title: L10n.tr("Акт %1$@ (%2$@)", String(describing: Self.romanNumeral(idx + 1)), String(describing: count)),
                        actIndex: idx
                    )
                }
            }

            Spacer()

            // Быстрые инструменты редактирования
            Menu {
                Button(L10n.tr("Сделать заглавной первую букву в каждой фразе")) {
                    capitalizeFirstLetters()
                }
                Button(L10n.tr("Удалить лишние пробелы")) {
                    trimWhitespaceInAll()
                }
                Divider()
                Button(L10n.tr("Сбросить все правки к оригиналу Whisper"), role: .destructive) {
                    resetAllToOriginal()
                }
            } label: {
                Label(L10n.tr("Текстовые инструменты"), systemImage: "textformat")
            }
            .menuStyle(.borderedButton)
            .controlSize(.small)

            Button {
                runModelSubtitleCorrection()
            } label: {
                Label(isModelCorrecting ? L10n.tr("Модель проверяет…") : L10n.tr("Исправить моделью"),
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
                TextField(L10n.tr("Поиск фразы…"), text: $searchText)
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

    private var activeSuggestion: LongformSubtitleCorrectionSuggestion? {
        modelCorrectionSuggestions.first(where: { $0.id == selectedSuggestionID }) ?? modelCorrectionSuggestions.first
    }

    private var modelCorrectionPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                if isModelCorrecting { ProgressView().controlSize(.small) }
                else { Image(systemName: modelCorrectionStatusIsError ? "exclamationmark.circle" : "sparkles").foregroundStyle(StudioTheme.accent) }
                VStack(alignment: .leading, spacing: 3) {
                    Text(isModelCorrecting ? L10n.tr("Проверка субтитров") : L10n.tr("Редакторская проверка"))
                        .font(.system(size: 12, weight: .bold))
                    Text(isModelCorrecting ? modelCorrectionProgress : (modelCorrectionStatus ?? L10n.tr("Выберите предложение для сравнения с исходной репликой.")))
                        .font(.caption).foregroundStyle(modelCorrectionStatusIsError ? StudioTheme.warning : StudioTheme.muted)
                        .lineLimit(2)
                }
                Spacer(minLength: 12)
                if isModelCorrecting {
                    Button(L10n.tr("Остановить"), systemImage: "stop.fill") { correctionTask?.cancel() }
                        .buttonStyle(.bordered).fixedSize()
                }
                if !modelCorrectionSuggestions.isEmpty {
                    Button(reviewingSuggestions ? L10n.tr("К субтитрам") : L10n.tr("Проверить предложения (%1$@)", String(describing: modelCorrectionSuggestions.count))) {
                        reviewingSuggestions.toggle()
                    }.buttonStyle(.bordered).fixedSize()
                }
                if !modelCorrectionEvents.isEmpty {
                    Button { showModelEvents.toggle() } label: {
                        Image(systemName: "list.bullet.rectangle").frame(width: 24, height: 24)
                    }.buttonStyle(.plain).help(L10n.tr("Журнал проверки"))
                }
            }
            if showModelEvents {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(modelCorrectionEvents.enumerated()), id: \.offset) { _, event in
                            Text(event).font(.caption.monospaced()).foregroundStyle(StudioTheme.muted)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: 90)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(StudioTheme.panel)
    }

    private var suggestionReviewWorkspace: some View {
        VStack(spacing: 0) {
            HSplitView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text(L10n.tr("ПРЕДЛОЖЕНИЯ")).font(.system(size: 10, weight: .bold)).tracking(1.4)
                        Spacer()
                        Text("\(modelCorrectionSuggestions.count)").font(.caption.monospaced()).foregroundStyle(StudioTheme.accent)
                    }.padding(16)
                    Divider()
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 6) {
                                ForEach(modelCorrectionSuggestions) { suggestion in
                                    if let phrase = phrases.first(where: { $0.originalSegmentIndex == suggestion.id }) {
                                        Button {
                                            selectedSuggestionID = suggestion.id
                                            selectedPhraseId = phrase.id
                                        } label: {
                                            VStack(alignment: .leading, spacing: 7) {
                                                HStack {
                                                    Text(L10n.tr("АКТ %1$@", String(describing: Self.romanNumeral(phrase.actIndex + 1)))).font(.system(size: 9, weight: .bold)).tracking(1)
                                                    Spacer()
                                                    Text(phrase.timecodeDisplay).font(.system(size: 10, design: .monospaced))
                                                }.foregroundStyle(StudioTheme.muted)
                                                Text(suggestion.original).font(.system(size: 12, weight: .medium)).lineLimit(2)
                                                    .frame(maxWidth: .infinity, alignment: .leading)
                                            }
                                            .padding(12).background(activeSuggestion?.id == suggestion.id ? StudioTheme.accent.opacity(0.13) : StudioTheme.panel,
                                                                      in: RoundedRectangle(cornerRadius: 9))
                                            .overlay(RoundedRectangle(cornerRadius: 9).stroke(activeSuggestion?.id == suggestion.id ? StudioTheme.accent.opacity(0.7) : StudioTheme.line))
                                            .contentShape(Rectangle())
                                        }.buttonStyle(.plain).id(suggestion.id)
                                    }
                                }
                            }.padding(10)
                        }
                        .onChange(of: activeSuggestion?.id) { _, id in
                            if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
                        }
                    }
                }.frame(minWidth: 280, idealWidth: 330, maxWidth: 400)
                if let suggestion = activeSuggestion,
                   let index = phrases.firstIndex(where: { $0.originalSegmentIndex == suggestion.id }) {
                    suggestionInspector(suggestion, phraseIndex: index)
                        .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            HStack(spacing: 12) {
                Label(L10n.tr("Правки применяются к тексту. Видео обновится после пересборки."), systemImage: "info.circle")
                    .font(.caption).foregroundStyle(StudioTheme.muted)
                Spacer(minLength: 10)
                Button(L10n.tr("Отклонить оставшиеся")) {
                    modelCorrectionSuggestions = []
                    modelCorrectionStatus = L10n.tr("Оставшиеся предложения отклонены.")
                }.buttonStyle(.bordered).fixedSize()
                Button(L10n.tr("Применить оставшиеся (%1$@)", String(describing: modelCorrectionSuggestions.count))) { applyAllModelSuggestions() }
                    .buttonStyle(.bordered).fixedSize()
            }.padding(14).background(StudioTheme.panel)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func suggestionInspector(_ suggestion: LongformSubtitleCorrectionSuggestion, phraseIndex index: Int) -> some View {
        let phrase = phrases[index]
        return VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.tr("АКТ %1$@ · %2$@", String(describing: Self.romanNumeral(phrase.actIndex + 1)), String(describing: L10n.tr(phrase.actType.displayName))))
                        .font(.system(size: 10, weight: .bold)).tracking(0.8).foregroundStyle(StudioTheme.accent)
                    Text(phrase.timecodeDisplay).font(.system(size: 14, weight: .semibold, design: .monospaced))
                }
                Spacer()
                Text("\((modelCorrectionSuggestions.firstIndex(where: { $0.id == suggestion.id }) ?? 0) + 1) / \(modelCorrectionSuggestions.count)")
                    .font(.caption.monospaced()).foregroundStyle(StudioTheme.muted)
            }.padding(22)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(L10n.tr("Сравните реплики перед применением"))
                        .font(.system(size: 21, weight: .semibold))
                    comparisonText(L10n.tr("СЕЙЧАС В СУБТИТРАХ"), text: phrase.text, proposed: false)
                    comparisonText(L10n.tr("ПРЕДЛОЖЕНИЕ МОДЕЛИ"), text: suggestion.replacement, proposed: true)
                    Label(suggestion.reason, systemImage: "sparkles")
                        .font(.callout).foregroundStyle(StudioTheme.muted).fixedSize(horizontal: false, vertical: true)
                    Divider()
                    Text(L10n.tr("КОНТЕКСТ ИЗ ТРАНСКРИПЦИИ")).font(.system(size: 10, weight: .bold)).tracking(1.2).foregroundStyle(StudioTheme.muted)
                    if index > 0 { contextPhrase(L10n.tr("До"), phrase: phrases[index - 1]) }
                    contextPhrase(L10n.tr("Реплика"), phrase: phrase)
                    if index + 1 < phrases.count { contextPhrase(L10n.tr("После"), phrase: phrases[index + 1]) }
                    Button(L10n.tr("Прослушать исходную реплику"), systemImage: "speaker.wave.2") {
                        selectedPhraseId = phrase.id
                        playSourcePhrase(phrase)
                    }.buttonStyle(.bordered).disabled(sourceURL == nil)
                    if phrase.text != suggestion.original {
                        Label(L10n.tr("Текст уже изменён вручную. Это предложение устарело."), systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(StudioTheme.warning)
                    }
                }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack(spacing: 12) {
                Button(L10n.tr("Показать в редакторе"), systemImage: "text.cursor") {
                    selectedPhraseId = phrase.id
                    selectedActFilter = phrase.actIndex
                    searchText = ""
                    reviewingSuggestions = false
                }.buttonStyle(.bordered)
                Spacer()
                Button(L10n.tr("Отклонить")) { dismissModelSuggestion(suggestion.id) }
                    .buttonStyle(.bordered)
                Button(L10n.tr("Применить и далее"), systemImage: "checkmark") { applyModelSuggestion(suggestion) }
                    .buttonStyle(.borderedProminent).tint(StudioTheme.accent)
                    .disabled(phrase.text != suggestion.original)
            }.fixedSize(horizontal: false, vertical: true).padding(18).background(StudioTheme.panel)
        }
    }

    private func comparisonText(_ title: String, text: String, proposed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 9, weight: .bold)).tracking(1.1).foregroundStyle(proposed ? StudioTheme.accent : StudioTheme.muted)
            Text(text).font(.system(size: 16, weight: proposed ? .semibold : .regular))
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }.padding(16)
            .background(proposed ? StudioTheme.accent.opacity(0.07) : StudioTheme.panel, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(proposed ? StudioTheme.accent.opacity(0.3) : StudioTheme.line))
    }

    private func contextPhrase(_ label: String, phrase: EditableSubtitlePhrase) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(label).font(.caption.weight(.medium)).foregroundStyle(StudioTheme.muted).frame(width: 52, alignment: .leading)
            Text(phrase.text).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
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
                                Text(L10n.tr("Фразы не найдены"))
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
                .onAppear {
                    if let selectedPhraseId { proxy.scrollTo(selectedPhraseId, anchor: .center) }
                }
                .onChange(of: selectedPhraseId) { _, id in
                    if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
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
                    Label(L10n.tr("Изменено"), systemImage: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)

                    Button {
                        resetPhrase(phrase.id)
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .help(L10n.tr("Вернуть исходный текст Whisper"))
                }
            }

            HStack(spacing: 8) {
                Button {
                    selectedPhraseId = phrase.id
                    runModelSubtitleCorrection(phraseID: phrase.id)
                } label: {
                    Label(correctingPhraseID == phrase.id ? L10n.tr("Проверяю эту фразу…") : L10n.tr("Исправить моделью"),
                          systemImage: correctingPhraseID == phrase.id ? "hourglass" : "sparkles")
                }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(isModelCorrecting)
                .help(L10n.tr("Проверить только эту реплику с контекстом соседних. Предложение появится для подтверждения."))
                Spacer()
            }

            // Поле редактирования
            let suspicious = UkrainianTextReview.suspiciousWords(in: phrase.text)
            if !suspicious.isEmpty {
                Text(L10n.tr("Сверьте с дубляжом: ") + suspicious.joined(separator: ", "))
                    .font(.caption2).foregroundStyle(.orange)
            }
            if let idx = phrases.firstIndex(where: { $0.id == phrase.id }) {
                TextField(L10n.tr("Реплика"), text: $phrases[idx].text, axis: .vertical)
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
                    Text(L10n.tr("Экран:"))
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
                    Text(L10n.tr("%1$@ стр.", String(describing: lines.count)))
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
                        Text(L10n.tr("Похожая правка из памяти — сверьте с дубляжом")).font(.caption.bold())
                        Text(suggestion.text).font(.subheadline)
                        Text(L10n.tr("Ранее: «%1$@» → «%2$@»", String(describing: suggestion.example.original), String(describing: suggestion.example.replacement)))
                            .font(.caption).foregroundStyle(.secondary)
                        Button(L10n.tr("Применить к этой реплике")) {
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
                        Text(L10n.tr("Предложение модели — сверьте с дубляжом")).font(.caption.bold())
                        Text(suggestion.replacement).font(.subheadline)
                        Text(suggestion.reason).font(.caption).foregroundStyle(.secondary)
                        Button(L10n.tr("Применить к этой реплике")) {
                            if let index = phrases.firstIndex(where: { $0.id == current.id }) {
                                phrases[index].text = suggestion.replacement
                            }
                        }
                    }.padding(12).background(StudioTheme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                }
                if let sourcePlayer {
                    StudioPlayerSurface(player: sourcePlayer)
                        .frame(height: 150)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    Button(L10n.tr("Прослушать выбранную реплику"), systemImage: "speaker.wave.2") {
                        playSourcePhrase(current)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: "tv.fill")
                        .foregroundStyle(.secondary)
                    Text(L10n.tr("Экранный монитор (16:9 Cinema)"))
                        .font(.subheadline.weight(.bold))
                    Spacer()
                    Text("1920×1080")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                Text(sourceStill == nil ? L10n.tr("Раскладка титров; исходный кадр — в проигрывателе выше.") : L10n.tr("Раскладка титров на исходном кадре выбранной реплики."))
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
                        Text(L10n.tr("Параметры реплики:"))
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(curr.timecodeDisplay)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 14) {
                        statPill(label: L10n.tr("Длительность"), value: String(format: L10n.tr("%.1f с"), curr.duration))
                        statPill(label: L10n.tr("Слов"), value: "\(curr.text.split(whereSeparator: { $0.isWhitespace }).count)")
                        statPill(label: L10n.tr("Строк в кадре"), value: "\(curr.screenLines.count)")
                    }

                    Text(L10n.tr("Субтитры располагаются под главной мыслью с постоянным зазором; длинные реплики растут вниз."))
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

    private func runModelSubtitleCorrection(phraseID: UUID? = nil) {
        guard !isModelCorrecting, !phrases.isEmpty else { return }
        let target = phraseID.flatMap { id in phrases.first(where: { $0.id == id }) }
        isModelCorrecting = true
        correctingPhraseID = target?.id
        reviewingSuggestions = target == nil
        selectedSuggestionID = target?.originalSegmentIndex
        OperationJournal.shared.begin(L10n.tr("Вычитка субтитров"))
        modelCorrectionProgress = L10n.tr("Готовлю фразы и соседний контекст…")
        modelCorrectionEvents = []
        if target == nil { modelCorrectionSuggestions = [] }
        modelCorrectionStatus = nil
        modelCorrectionStatusIsError = false

        let contextualInput = EditableSubtitlePhrase.correctionInputs(from: phrases, arc: arc)

        let input = target.map { target in contextualInput.filter { $0.id == target.originalSegmentIndex } } ?? contextualInput
        correctionTask = Task { @MainActor in
            defer { isModelCorrecting = false; correctingPhraseID = nil; correctionTask = nil }
            do {
                let outcome = try await onAutoCorrect(input) { message in
                    Task { @MainActor in
                        OperationJournal.shared.append(message)
                        modelCorrectionProgress = message
                        if modelCorrectionEvents.last != message {
                            modelCorrectionEvents.append(message)
                            if modelCorrectionEvents.count > 12 { modelCorrectionEvents.removeFirst() }
                        }
                    }
                }
                if let target {
                    modelCorrectionSuggestions.removeAll { $0.id == target.originalSegmentIndex }
                    modelCorrectionSuggestions.append(contentsOf: outcome.suggestions)
                    if outcome.suggestions.contains(where: { $0.id == target.originalSegmentIndex }) {
                        selectedSuggestionID = target.originalSegmentIndex
                        reviewingSuggestions = true
                    }
                } else {
                    modelCorrectionSuggestions = outcome.suggestions
                }
                let discardedNote = outcome.discardedSuggestionCount > 0
                    ? L10n.tr(" Отброшено некорректных ответов модели: %1$@.", String(describing: outcome.discardedSuggestionCount))
                    : ""
                let failedNote = outcome.failedPhraseCount > 0
                    ? L10n.tr(" Не удалось проверить фраз: %1$@.", String(describing: outcome.failedPhraseCount)) : ""
                let status = outcome.wasCancelled ? L10n.tr("Остановлено.") : L10n.tr("Проверка завершена.")
                modelCorrectionStatus = L10n.tr("%1$@ Проверено фраз: %2$@. Предложений: %3$@.%4$@%5$@", String(describing: status), String(describing: outcome.checkedCount), String(describing: outcome.suggestions.count), String(describing: failedNote), String(describing: discardedNote))
                modelCorrectionStatusIsError = outcome.failedPhraseCount > 0
            } catch is CancellationError {
                modelCorrectionStatus = L10n.tr("Проверка остановлена.")
            } catch {
                OperationJournal.shared.append(error.localizedDescription, level: .error)
                modelCorrectionStatus = L10n.tr("Проверка не завершена: %1$@", String(describing: error.localizedDescription))
                modelCorrectionStatusIsError = true
            }
        }
    }

    private func dismissModelSuggestion(_ id: Int) {
        guard let index = modelCorrectionSuggestions.firstIndex(where: { $0.id == id }) else { return }
        modelCorrectionSuggestions.remove(at: index)
        let next = modelCorrectionSuggestions.indices.contains(index)
            ? modelCorrectionSuggestions[index] : modelCorrectionSuggestions.last
        selectedSuggestionID = next?.id
        if let next, let phrase = phrases.first(where: { $0.originalSegmentIndex == next.id }) {
            selectedPhraseId = phrase.id
        }
    }

    private func applyModelSuggestion(_ suggestion: LongformSubtitleCorrectionSuggestion) {
        guard let index = phrases.firstIndex(where: { $0.originalSegmentIndex == suggestion.id }) else { return }
        guard phrases[index].text == suggestion.original else {
            modelCorrectionSuggestions.removeAll { $0.id == suggestion.id }
            modelCorrectionStatus = L10n.tr("Реплика изменилась во время проверки; устаревшее предложение снято.")
            modelCorrectionStatusIsError = false
            return
        }
        phrases[index].text = suggestion.replacement
        dismissModelSuggestion(suggestion.id)
        modelCorrectionStatusIsError = false
        modelCorrectionStatus = modelCorrectionSuggestions.isEmpty
            ? L10n.tr("Предложение применено. Проверьте текст и нажмите «%1$@» для пересборки.", String(describing: confirmButtonTitle))
            : L10n.tr("Предложение применено. Осталось проверить: %1$@.", String(describing: modelCorrectionSuggestions.count))
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
            ? L10n.tr("Предложения не применены; изменённые вручную реплики оставлены как есть.")
            : L10n.tr("Применено: %1$@.", String(describing: appliedCount)) + (skippedCount > 0 ? L10n.tr(" Пропущено устаревших предложений: %1$@.", String(describing: skippedCount)) : "")
                + L10n.tr(" Проверьте текст и нажмите «%1$@» для пересборки.", String(describing: confirmButtonTitle))
    }

    private func initializePhrases() {
        var items: [EditableSubtitlePhrase] = []
        var seenSegmentIndices = Set<Int>()
        do {
            try SubtitleCorrectionStore.shared.update {
                $0.importEdits(arc.captionEdits ?? [], filmKey: correctionFilmKey, language: correctionLanguage)
            }
            correctionMemory = try SubtitleCorrectionStore.shared.load()
        } catch { memoryWarning = L10n.tr("Память правок недоступна: %1$@", String(describing: error.localizedDescription)) }
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
        guard let sourcePlayer, let sourceURL else { return }
        stopPlayback?.cancel()
        sourcePlayer.pause()
        previewAudio.stop()
        stopPlayback = Task { @MainActor in
            do {
                let start = max(0, phrase.start - 0.3)
                let end = phrase.end + 0.5
                let chunks = try await previewAudio.prepare(url: sourceURL, start: start, end: end)
                guard !Task.isCancelled else { return }
                await sourcePlayer.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                guard !Task.isCancelled else { return }
                try previewAudio.play(chunks)
                sourcePlayer.play()
                try await Task.sleep(for: .seconds(end - start))
                sourcePlayer.pause()
                previewAudio.stop()
            } catch {
                guard !Task.isCancelled else { return }
                modelCorrectionStatus = error.localizedDescription
                modelCorrectionStatusIsError = true
            }
        }
    }

    /// Номер акта по позиции: у аналитической арки пять актов и пропуски пустых,
    /// поэтому номер берётся из места в арке, а не из типа.
    static func romanNumeral(_ number: Int) -> String {
        let numerals = ["I", "II", "III", "IV", "V", "VI", "VII", "VIII"]
        return numerals.indices.contains(number - 1) ? numerals[number - 1] : "\(number)"
    }
}
