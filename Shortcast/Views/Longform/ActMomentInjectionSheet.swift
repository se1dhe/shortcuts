import AVFoundation
import AVKit
import SwiftUI

/// Позиция вставки момента в акт
enum InjectionPosition: String, CaseIterable, Identifiable, Sendable {
    case beginning = "В начало акта"
    case end = "В конец акта"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .beginning: return "arrow.left.to.line"
        case .end: return "arrow.right.to.line"
        }
    }

    var subtitle: String {
        switch self {
        case .beginning: return "Станет первой сценой акта (Cold Open / Вступление)"
        case .end: return "Станет финальной сценой акта (Кульминация / Punchline)"
        }
    }
}

/// Модальный экран поиска культовых диалоговых моментов в транскрипте фильма
/// с интерактивным предпросмотром и точной подгонкой точек входа/выхода (In/Out Trimmer).
struct ActMomentInjectionSheet: View {

    let transcriptSegments: [TranscriptSegment]
    let sourceURL: URL?
    let acts: [EditableActModel]
    let initialActIndex: Int
    let searchService: TranscriptMomentSearchingProtocol
    let onInsert: (Int, InjectionPosition, Double, Double) -> Void
    let onCancel: () -> Void

    @State private var query: String = ""
    @State private var searchResults: [TranscriptMomentMatch] = []
    @State private var selectedMatch: TranscriptMomentMatch?

    @State private var targetActIndex: Int = 0
    @State private var targetPosition: InjectionPosition = .end

    // Точки тримминга выбранной сцены
    @State private var currentStart: Double = 0.0
    @State private var currentEnd: Double = 0.0
    @State private var sourceDuration: Double = .infinity

    // Видеоплеер
    @State private var player: AVPlayer?
    @State private var isPlaying: Bool = false
    @State private var stopTask: Task<Void, Never>?

    init(
        transcriptSegments: [TranscriptSegment],
        sourceURL: URL?,
        acts: [EditableActModel],
        initialActIndex: Int = 0,
        searchService: TranscriptMomentSearchingProtocol = TranscriptMomentSearchService(),
        onInsert: @escaping (Int, InjectionPosition, Double, Double) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.transcriptSegments = transcriptSegments
        self.sourceURL = sourceURL
        self.acts = acts
        self.initialActIndex = initialActIndex
        self.searchService = searchService
        self.onInsert = onInsert
        self.onCancel = onCancel
    }

    private var currentSceneDuration: Double {
        max(0.0, currentEnd - currentStart)
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar

            Divider()

            HStack(spacing: 0) {
                // Левая панель: строка поиска и список найденных сцен
                searchAndResultsPanel
                    .frame(minWidth: 380, maxWidth: 440)

                Divider()

                // Правая панель: плеер, триммер и параметры вставки
                detailAndTrimmingPanel
                    .frame(minWidth: 540)
            }

            Divider()

            footerBar
        }
        .frame(minWidth: 980, minHeight: 680)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            targetActIndex = min(max(0, initialActIndex), max(0, acts.count - 1))
            setupPlayer()
        }
        .onDisappear {
            stopPlayback()
            player = nil
        }
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.title2)
                .foregroundStyle(.yellow)

            VStack(alignment: .leading, spacing: 2) {
                Text("Поиск и вставка культовых моментов")
                    .font(.headline)

                Text("Найдите ключевую реплику по транскрипту диалогов, настройте начало и конец сцены и вставьте её в акт")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Закрыть") {
                onCancel()
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Left Panel: Search & Results

    private var searchAndResultsPanel: some View {
        VStack(spacing: 12) {
            // Поисковая строка
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                TextField("Поиск реплики или сцены...", text: $query)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .onChange(of: query) { _, newValue in
                        performSearch(query: newValue)
                    }

                if !query.isEmpty {
                    Button {
                        query = ""
                        searchResults = []
                        selectedMatch = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1)))

            // Результаты поиска
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                emptySearchPromptView
            } else if searchResults.isEmpty {
                noResultsFoundView
            } else {
                resultsListView
            }
        }
        .padding(16)
    }

    private var emptySearchPromptView: some View {
        VStack(spacing: 14) {
            Spacer()

            Image(systemName: "quote.bubble.fill")
                .font(.system(size: 40))
                .foregroundStyle(.yellow.opacity(0.8))

            Text("Введите фразу из фильма")
                .font(.headline)

            Text("Например:\n«Мы встретились в странный период...»\n«Ты просишь без уважения...»\n«Я собираюсь сделать ему предложение...»")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .lineSpacing(4)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noResultsFoundView: some View {
        VStack(spacing: 12) {
            Spacer()

            Image(systemName: "text.magnifyingglass")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)

            Text("Фраза не найдена")
                .font(.headline)

            Text("Попробуйте сократить запрос или использовать другие ключевые слова из диалога.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var resultsListView: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(searchResults) { match in
                    let isSelected = selectedMatch?.id == match.id
                    resultRow(match: match, isSelected: isSelected)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func resultRow(match: TranscriptMomentMatch, isSelected: Bool) -> some View {
        Button {
            selectMatch(match)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("\(formatTimecode(match.start)) — \(formatTimecode(match.end))")
                        .font(.caption.monospacedDigit().weight(.bold))
                        .foregroundStyle(isSelected ? Color.yellow : Color.primary)

                    Text("(\(formatDurationWithTenths(match.duration)))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)

                    Spacer()

                    scoreBadge(for: match.score)
                }

                Text("«\(match.matchedDialogue)»")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.primary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)

                if !match.fullContextText.isEmpty {
                    Text(match.fullContextText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Color.yellow.opacity(0.12) : Color.secondary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isSelected ? Color.yellow.opacity(0.6) : Color.white.opacity(0.04), lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }

    private func scoreBadge(for score: Double) -> some View {
        let text: String
        let color: Color

        if score >= 100.0 {
            text = "Точно"
            color = .green
        } else if score >= 80.0 {
            text = "Высоко"
            color = .yellow
        } else {
            text = "Частично"
            color = .orange
        }

        return Text(text)
            .font(.caption2.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    // MARK: - Right Panel: Detail, Player & Trimming

    private var detailAndTrimmingPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let match = selectedMatch {
                    selectedMomentHeader(match: match)

                    if player != nil {
                        videoPlayerSection
                    }

                    inOutTrimmerCard

                    insertionTargetCard
                } else {
                    noSelectionPromptView
                }
            }
            .padding(20)
        }
    }

    private var noSelectionPromptView: some View {
        VStack(spacing: 14) {
            Spacer()

            Image(systemName: "film")
                .font(.system(size: 48))
                .foregroundStyle(.secondary.opacity(0.4))

            Text("Выберите момент из списка слева")
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)

            Text("Вы сможете настроить точные границы сцены с помощью In/Out триммера и выбрать позицию вставки.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 360)

            Spacer()
        }
        .frame(maxWidth: .infinity, minHeight: 460)
    }

    private func selectedMomentHeader(match: TranscriptMomentMatch) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Выбранный момент диалога", systemImage: "quote.opening")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.yellow)

                Spacer()

                Text("Длительность: \(formatDurationWithTenths(currentSceneDuration))")
                    .font(.callout.monospacedDigit().weight(.bold))
                    .foregroundStyle(.yellow)
            }

            Text("«\(match.matchedDialogue)»")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)

            if !match.fullContextText.isEmpty {
                Text("Контекст: \(match.fullContextText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.06)))
    }

    // MARK: - Video Player Section

    private var videoPlayerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Предпросмотр сцены")
                    .font(.subheadline.weight(.bold))

                Spacer()

                HStack(spacing: 6) {
                    Button {
                        seekToStart()
                    } label: {
                        Label("К началу сцены", systemImage: "backward.end.fill")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button {
                        if isPlaying {
                            stopPlayback()
                        } else {
                            playCurrentRange()
                        }
                    } label: {
                        Label(isPlaying ? "Пауза" : "Воспроизвести сцену", systemImage: isPlaying ? "pause.fill" : "play.fill")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.yellow)
                    .controlSize(.small)
                }
            }

            if let player {
                VideoPlayer(player: player)
                    .aspectRatio(16/9, contentMode: .fit)
                    .frame(maxHeight: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
                    )
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.04)))
    }

    // MARK: - In/Out Precision Trimmer

    private var inOutTrimmerCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Точный тримминг In / Out", systemImage: "slider.horizontal.2")
                    .font(.subheadline.weight(.bold))

                Spacer()

                Text("Подстройте границы для захвата вступительных или финальных кадров (например, небоскребов)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Divider()

            // In-point (Начало сцены)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("НАЧАЛО СЦЕНЫ (IN):", systemImage: "arrow.right.to.line")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)

                    Text(formatTimecode(currentStart))
                        .font(.callout.monospacedDigit().weight(.bold))
                        .foregroundStyle(.primary)

                    Spacer()

                    HStack(spacing: 3) {
                        Button {
                            playRange(start: currentStart, end: min(currentStart + 3.0, currentEnd))
                        } label: {
                            Image(systemName: "play.fill")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .help("Прослушать вход сцены")

                        trimStepButton(label: "-5с", delta: -5.0) { adjustStart(by: -5.0) }
                        trimStepButton(label: "-1с", delta: -1.0) { adjustStart(by: -1.0) }
                        trimStepButton(label: "-0.1с", delta: -0.1) { adjustStart(by: -0.1) }
                        trimStepButton(label: "+0.1с", delta: 0.1) { adjustStart(by: 0.1) }
                        trimStepButton(label: "+1с", delta: 1.0) { adjustStart(by: 1.0) }
                        trimStepButton(label: "+5с", delta: 5.0) { adjustStart(by: 5.0) }
                    }
                }

                Slider(
                    value: Binding(
                        get: { currentStart },
                        set: { setStart($0) }
                    ),
                    in: 0...max(0.01, currentEnd - 1.0)
                )
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.04)))

            // Out-point (Конец сцены)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("КОНЕЦ СЦЕНЫ (OUT):", systemImage: "arrow.left.to.line")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)

                    Text(formatTimecode(currentEnd))
                        .font(.callout.monospacedDigit().weight(.bold))
                        .foregroundStyle(.primary)

                    Spacer()

                    HStack(spacing: 3) {
                        Button {
                            playRange(start: max(currentStart, currentEnd - 3.0), end: currentEnd)
                        } label: {
                            Image(systemName: "play.fill")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .help("Прослушать выход сцены")

                        trimStepButton(label: "-5с", delta: -5.0) { adjustEnd(by: -5.0) }
                        trimStepButton(label: "-1с", delta: -1.0) { adjustEnd(by: -1.0) }
                        trimStepButton(label: "-0.1с", delta: -0.1) { adjustEnd(by: -0.1) }
                        trimStepButton(label: "+0.1с", delta: 0.1) { adjustEnd(by: 0.1) }
                        trimStepButton(label: "+1с", delta: 1.0) { adjustEnd(by: 1.0) }
                        trimStepButton(label: "+5с", delta: 5.0) { adjustEnd(by: 5.0) }
                    }
                }

                let maxBound = sourceDuration.isFinite ? sourceDuration : max(currentEnd + 120.0, 600.0)
                Slider(
                    value: Binding(
                        get: { currentEnd },
                        set: { setEnd($0) }
                    ),
                    in: (currentStart + 1.0)...max(currentStart + 1.01, maxBound)
                )
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.04)))
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.06)))
    }

    private func trimStepButton(label: String, delta: Double, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption2.monospacedDigit().weight(.bold))
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
        }
        .buttonStyle(.bordered)
        .controlSize(.mini)
        .tint(delta > 0 ? .yellow : .secondary)
    }

    // MARK: - Target Act & Position

    private var insertionTargetCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Куда вставить сцену", systemImage: "arrow.down.right.and.arrow.up.left")
                .font(.subheadline.weight(.bold))

            HStack(spacing: 20) {
                // Выбор целевого акта
                VStack(alignment: .leading, spacing: 4) {
                    Text("Целевой акт:")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Picker("Акт", selection: $targetActIndex) {
                        ForEach(0..<acts.count, id: \.self) { idx in
                            let act = acts[idx]
                            Text("Акт \(idx + 1): \(act.type.rawValue) — \(act.title)")
                                .tag(idx)
                        }
                    }
                    .labelsHidden()
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Выбор позиции вставки
                VStack(alignment: .leading, spacing: 4) {
                    Text("Позиция вставки:")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Picker("Позиция", selection: $targetPosition) {
                        ForEach(InjectionPosition.allCases) { pos in
                            HStack {
                                Image(systemName: pos.iconName)
                                Text(pos.rawValue)
                            }
                            .tag(pos)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text(targetPosition.subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.06)))
    }

    // MARK: - Footer Bar

    private var footerBar: some View {
        HStack(spacing: 14) {
            if selectedMatch != nil {
                HStack(spacing: 6) {
                    Image(systemName: "clock")
                        .foregroundStyle(.yellow)
                    Text("Хронометраж добавляемой сцены: \(formatDurationWithTenths(currentSceneDuration))")
                        .font(.callout.monospacedDigit().weight(.semibold))
                }
            }

            Spacer()

            Button("Отмена") {
                onCancel()
            }
            .buttonStyle(.bordered)

            Button {
                commitInsertion()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: targetPosition.iconName)
                    Text("Вставить сцену в Акт \(targetActIndex + 1)")
                }
                .font(.headline)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(.yellow)
            .disabled(selectedMatch == nil || currentSceneDuration < 1.0)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Actions & Logic

    private func performSearch(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults = []
            selectedMatch = nil
            return
        }

        let results = searchService.searchMoments(
            query: trimmed,
            in: transcriptSegments,
            contextPaddingBefore: 1.0,
            contextPaddingAfter: 2.5
        )

        searchResults = results

        // Если есть совпадение и ничего еще не выбрано, выбираем первое (наиболее релевантное)
        if let first = results.first, selectedMatch == nil {
            selectMatch(first)
        } else if let current = selectedMatch, !results.contains(where: { $0.id == current.id }) {
            if let first = results.first {
                selectMatch(first)
            } else {
                selectedMatch = nil
            }
        }
    }

    private func selectMatch(_ match: TranscriptMomentMatch) {
        selectedMatch = match
        currentStart = match.start
        currentEnd = match.end
        seekToStart()
    }

    private func commitInsertion() {
        guard selectedMatch != nil else { return }
        onInsert(targetActIndex, targetPosition, currentStart, currentEnd)
    }

    // MARK: - Trimming adjustments

    private func adjustStart(by delta: Double) {
        setStart(currentStart + delta)
    }

    private func setStart(_ value: Double) {
        currentStart = max(0.0, min(value, currentEnd - 1.0))
        seekToStart()
    }

    private func adjustEnd(by delta: Double) {
        setEnd(currentEnd + delta)
    }

    private func setEnd(_ value: Double) {
        let maxBound = sourceDuration.isFinite ? sourceDuration : currentStart + 600.0
        currentEnd = min(maxBound, max(currentStart + 1.0, value))
    }

    // MARK: - AVPlayer Playback

    private func setupPlayer() {
        guard let sourceURL else { return }
        player = AVPlayer(url: sourceURL)
        Task {
            let asset = AVURLAsset(url: sourceURL)
            if let duration = try? await asset.load(.duration), duration.seconds.isFinite, duration.seconds > 0 {
                sourceDuration = duration.seconds
            }
        }
    }

    private func playCurrentRange() {
        playRange(start: currentStart, end: currentEnd)
    }

    private func playRange(start: Double, end: Double) {
        guard let player else { return }
        stopPlayback()

        let startCM = CMTime(seconds: max(0.0, start), preferredTimescale: 600)
        player.seek(to: startCM, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
            guard finished else { return }
            Task { @MainActor in
                player.play()
                isPlaying = true
            }
        }

        let holdDuration = max(0.3, end - start)
        stopTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(holdDuration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            player.pause()
            isPlaying = false
        }
    }

    private func seekToStart() {
        guard let player else { return }
        stopPlayback()
        let startCM = CMTime(seconds: max(0.0, currentStart), preferredTimescale: 600)
        player.seek(to: startCM, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func stopPlayback() {
        stopTask?.cancel()
        stopTask = nil
        player?.pause()
        isPlaying = false
    }

    // MARK: - Formatting Helpers

    private func formatTimecode(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        let tenths = Int((seconds.truncatingRemainder(dividingBy: 1)) * 10)
        return String(format: "%02d:%02d.%d", mins, secs, tenths)
    }

    private func formatDurationWithTenths(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        let tenths = Int((seconds.truncatingRemainder(dividingBy: 1)) * 10)
        return String(format: "%02d:%02d.%dc", mins, secs, tenths)
    }
}
