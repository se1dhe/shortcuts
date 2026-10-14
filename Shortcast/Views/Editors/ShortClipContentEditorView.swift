import SwiftUI
import AppKit

/// Вкладка «Контент»: редактирование метаданных фильма, хука, описания с тегами и промо-комментария.
/// Single Responsibility Principle (SRP): отвечает исключительно за текстовый контент и метаданные шортса.
struct ShortClipContentEditorView: View {

    @Bindable var clip: ShortClip
    @Environment(AppSettings.self) private var settings
    @Environment(ModelManager.self) private var modelManager
    @Environment(LanguageManager.self) private var languageManager

    @State private var manualMovieTitle = ""
    @State private var manualMovieYear = ""
    @State private var manualMovieError: String?
    @State private var detectedMovie: TMDBMovie?
    @State private var movieCandidates: [TMDBMovie] = []
    @State private var isRegeneratingCinemaContent = false

    @State private var previewPlatform: SocialPlatform = .tiktok
    @State private var didCopyDescription = false
    @State private var didCopyPinnedComment = false
    @State private var isRegeneratingPinnedComment = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // Секция 1: Метаданные фильма и TMDB
                movieMetadataSection

                // Секция 2: Выбор платформы
                platformPickerSection

                // Секция 3: Название (Хук) сцены
                hookSection

                // Секция 4: Описание с тегами
                descriptionSection

                // Секция 5: Закрепленный промо-комментарий
                pinnedCommentSection

                // Ссылка на источник
                if let url = clip.sourceMetadata?.webpageURL {
                    sourceLink(url: url)
                }
            }
            .padding(20)
        }
        .onAppear {
            seedMovieFieldsFromSource()
        }
    }

    // MARK: - 1. Movie Metadata & TMDB

    private var movieMetadataSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("Фильм / Сериал", systemImage: "film.stack")
                    .font(.headline)
                Spacer()

                if isRegeneratingCinemaContent {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        regenerateCinemaContent()
                    } label: {
                        Label("Обновить из TMDB", systemImage: "arrow.clockwise")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .disabled(movieTitleBinding.wrappedValue.trimmed.isEmpty)
                }
            }

            HStack(spacing: 8) {
                TextField("Название фильма", text: movieTitleBinding)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if !manualMovieTitle.trimmed.isEmpty { regenerateCinemaContent() } }

                TextField("Год", text: movieYearBinding)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .onSubmit { if !manualMovieTitle.trimmed.isEmpty { regenerateCinemaContent() } }
            }

            if movieCandidates.count > 1 {
                Picker("Выбрать вариант фильма", selection: selectedCandidateBinding) {
                    ForEach(movieCandidates) { candidate in
                        Text(candidate.pickerLabel).tag(candidate.id)
                    }
                }
                .pickerStyle(.menu)
                .disabled(isRegeneratingCinemaContent)
            }

            if let err = manualMovieError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(14)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - 2. Platform Selector

    private var platformPickerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Целевая платформа для редактирования copy:")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Picker("Платформа", selection: $previewPlatform) {
                ForEach(SocialPlatform.allCases) { platform in
                    Label(platform.rawValue.capitalized, systemImage: platform.symbolName)
                        .tag(platform)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: - 3. Name (Hook)

    private var hookSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Название (Хук сцены)", systemImage: "textformat")
                    .font(.headline)
                Spacer()
                Text(previewPlatform.displayName)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            TextField(platformHookPlaceholder, text: platformHookBinding, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...2)

            Toggle(isOn: $clip.overlayEnabled) {
                HStack(spacing: 6) {
                    Image(systemName: "tv")
                    Text("Показать хук на видео (первые 3 сек)")
                }
                .font(.callout)
            }
            .toggleStyle(.switch)
        }
        .padding(14)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - 4. Description & Hashtags

    private var descriptionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Описание (текст + теги)", systemImage: "doc.text")
                    .font(.headline)
                Spacer()

                Picker("", selection: $clip.descriptionMode) {
                    Text("Фильм").tag(CinemaContentGenerator.DescriptionMode.movie)
                    Text("Сцена").tag(CinemaContentGenerator.DescriptionMode.scene)
                }
                .pickerStyle(.segmented)
                .frame(width: 140)
                .disabled(settings.textAdEnabled)
                .onChange(of: clip.descriptionMode) { _, _ in
                    regenerateCinemaContent()
                }

                Button {
                    copyDescriptionToPasteboard()
                } label: {
                    Label(didCopyDescription ? "Скопировано!" : "Копировать",
                          systemImage: didCopyDescription ? "checkmark" : "doc.on.doc")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
            }

            Toggle(isOn: Binding(
                get: { settings.textAdEnabled },
                set: { settings.textAdEnabled = $0; regenerateCinemaContent() }
            )) {
                Label("Текстовая реклама бота — промо @RedQueenSecurity_Bot",
                      systemImage: "megaphone.fill")
                    .font(.caption)
            }
            .toggleStyle(.switch)

            TextEditor(text: combinedDescriptionBinding)
                .font(.callout)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 130, maxHeight: 220)
                .padding(8)
                .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.2)))
        }
        .padding(14)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - 5. Pinned Comment

    private var pinnedCommentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Закрепленный промо-комментарий", systemImage: "pin.fill")
                    .font(.headline)
                Spacer()

                Button {
                    regeneratePinnedComment()
                } label: {
                    if isRegeneratingPinnedComment {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Сгенерировать промо", systemImage: "sparkles")
                            .font(.caption.weight(.medium))
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isRegeneratingPinnedComment)

                Button {
                    copyPinnedCommentToPasteboard()
                } label: {
                    Label(didCopyPinnedComment ? "Скопировано!" : "Копировать",
                          systemImage: didCopyPinnedComment ? "checkmark" : "doc.on.doc")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
            }

            TextEditor(text: pinnedCommentBinding)
                .font(.callout)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 70, maxHeight: 110)
                .padding(8)
                .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.2)))
        }
        .padding(14)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    private func sourceLink(url: URL) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.up.right.square")
                .font(.caption2)
            Text("Открыть оригинал на YouTube")
                .font(.caption)
        }
        .foregroundStyle(Color.accentColor)
        .contentShape(Rectangle())
        .onTapGesture {
            NSWorkspace.shared.open(url)
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Bindings

    private var movieTitleBinding: Binding<String> {
        Binding(
            get: {
                if !manualMovieTitle.trimmed.isEmpty { return manualMovieTitle }
                return clip.detectedMovieTitle
            },
            set: { newValue in
                manualMovieTitle = newValue
                clip.detectedMovieTitle = newValue
            })
    }

    private var movieYearBinding: Binding<String> {
        Binding(
            get: {
                if !manualMovieYear.trimmed.isEmpty { return manualMovieYear }
                return clip.detectedMovieYear
            },
            set: { newValue in
                manualMovieYear = newValue
                clip.detectedMovieYear = newValue
            })
    }

    private var platformHookBinding: Binding<String> {
        Binding(
            get: {
                let target = clip.variants.first(where: { $0.platform == previewPlatform }) ?? clip.variants.first
                return target?.hook ?? ""
            },
            set: { newValue in
                let oldHook = clip.variants.first(where: { $0.platform == previewPlatform })?.hook ?? ""
                if let idx = clip.variants.firstIndex(where: { $0.platform == previewPlatform }) {
                    clip.variants[idx].hook = newValue
                } else {
                    clip.variants.append(PostVariant(
                        platform: previewPlatform,
                        hook: newValue,
                        summary: "",
                        hashtags: [],
                        pinnedComment: ""
                    ))
                }
                let overlayMatchedOldHook = clip.overlayText.trimmed == oldHook.trimmed || clip.overlayText.trimmed.isEmpty
                if overlayMatchedOldHook || previewPlatform == .tiktok {
                    clip.overlayText = newValue.truncatingToHook(limit: 60)
                }
            })
    }

    private var platformHookPlaceholder: String {
        switch previewPlatform {
        case .tiktok:    return "Ударный виральный хук сцены..."
        case .instagram: return "🎬 Кинематографичный заголовок..."
        case .youtube:   return "Интригующий заголовок... #Shorts"
        case .telegram:  return "🎬 Название фильма (Год)"
        }
    }

    private var combinedDescriptionBinding: Binding<String> {
        Binding(
            get: {
                let target = clip.variants.first(where: { $0.platform == previewPlatform }) ?? clip.variants.first
                return target?.fullDescriptionWithTags ?? ""
            },
            set: { newValue in
                if let idx = clip.variants.firstIndex(where: { $0.platform == previewPlatform }) {
                    clip.variants[idx].updateFromCombinedDescription(newValue)
                } else {
                    var newVariant = PostVariant(
                        platform: previewPlatform,
                        hook: clip.displayTitle,
                        summary: "",
                        hashtags: [],
                        pinnedComment: ""
                    )
                    newVariant.updateFromCombinedDescription(newValue)
                    clip.variants.append(newVariant)
                }
            })
    }

    private var pinnedCommentBinding: Binding<String> {
        Binding(
            get: {
                let target = clip.variants.first(where: { $0.platform == previewPlatform }) ?? clip.variants.first
                return target?.pinnedComment ?? ""
            },
            set: { newValue in
                if let idx = clip.variants.firstIndex(where: { $0.platform == previewPlatform }) {
                    clip.variants[idx].pinnedComment = newValue
                } else {
                    clip.variants.append(PostVariant(
                        platform: previewPlatform,
                        hook: clip.displayTitle,
                        summary: "",
                        hashtags: [],
                        pinnedComment: newValue
                    ))
                }
            })
    }

    private var selectedCandidateBinding: Binding<String> {
        Binding(
            get: { detectedMovie?.id ?? movieCandidates.first?.id ?? "" },
            set: { newID in
                guard let picked = movieCandidates.first(where: { $0.id == newID }) else { return }
                applyCinemaContent(for: picked)
            })
    }

    // MARK: - Actions

    private func copyDescriptionToPasteboard() {
        let text = combinedDescriptionBinding.wrappedValue
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        didCopyDescription = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            didCopyDescription = false
        }
    }

    private func copyPinnedCommentToPasteboard() {
        let text = pinnedCommentBinding.wrappedValue
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        didCopyPinnedComment = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            didCopyPinnedComment = false
        }
    }

    private func regeneratePinnedComment() {
        isRegeneratingPinnedComment = true
        let generated = PinnedCommentGenerator.generate(promoCode: clip.promoCode)
        for idx in clip.variants.indices {
            clip.variants[idx].pinnedComment = generated
        }
        isRegeneratingPinnedComment = false
    }

    private var effectiveDescriptionLanguage: String {
        let override = settings.languageOverride.trimmed
        if !override.isEmpty { return override }
        if let detected = clip.detectedLanguage?.trimmed, !detected.isEmpty { return detected }
        return languageManager.selectedLanguage.rawValue
    }

    private func regenerateCinemaContent(preselected: TMDBMovie? = nil) {
        let title = manualMovieTitle.trimmed
        let year = sanitizedMovieYear(manualMovieYear)
        guard !title.isEmpty else {
            manualMovieError = "Укажите название фильма."
            return
        }

        manualMovieYear = year
        manualMovieError = nil
        isRegeneratingCinemaContent = true

        Task {
            let query = CinemaContentGenerator.MovieSearchQuery(
                title: title,
                year: year.isEmpty ? nil : year
            )
            let sourceText = [
                clip.sourceMetadata?.title,
                clip.sourceMetadata?.description,
                clip.displayTitle
            ]
            .compactMap { $0?.trimmed }
            .joined(separator: " ")

            await modelManager.prepareDirectorIfNeeded()
            let mode = clip.descriptionMode
            let result = await CinemaContentGenerator.generate(
                query: query,
                sourceText: sourceText,
                tmdbAPIKey: settings.tmdbAPIKey,
                descriptionMode: mode,
                textAd: settings.textAdEnabled,
                preselectedMovie: preselected,
                candidateHook: clip.candidate.hook,
                candidateSummary: clip.candidate.why,
                transcriptSlice: clip.transcriptSlice,
                sceneDescriptionProvider: {
                    await modelManager.momentFinder.describeScene(
                        transcriptSlice: clip.transcriptSlice,
                        movieTitle: title,
                        language: effectiveDescriptionLanguage
                    )
                },
                fallbackMovieProvider: {
                    await modelManager.momentFinder.inferMovie(query: query, sourceText: sourceText)
                }
            )

            movieCandidates = result.candidates
            detectedMovie = result.movie
            manualMovieTitle = result.query.title
            manualMovieYear = result.query.year ?? ""
            clip.detectedMovieTitle = result.query.title
            clip.detectedMovieYear = result.query.year ?? ""
            manualMovieError = result.error

            CinemaContentGenerator.apply(
                content: result.content,
                to: clip,
                replaceHook: true,
                saveToHistory: true,
                settings: settings
            )

            isRegeneratingCinemaContent = false
        }
    }

    private func applyCinemaContent(for movie: TMDBMovie) {
        manualMovieError = nil
        isRegeneratingCinemaContent = true

        Task {
            let query = CinemaContentGenerator.MovieSearchQuery(title: movie.title, year: movie.year)
            await modelManager.prepareDirectorIfNeeded()
            let mode = clip.descriptionMode
            let result = await CinemaContentGenerator.generate(
                query: query,
                sourceText: "",
                tmdbAPIKey: settings.tmdbAPIKey,
                descriptionMode: mode,
                textAd: settings.textAdEnabled,
                preselectedMovie: movie,
                candidateHook: clip.candidate.hook,
                candidateSummary: clip.candidate.why,
                transcriptSlice: clip.transcriptSlice,
                sceneDescriptionProvider: {
                    await modelManager.momentFinder.describeScene(
                        transcriptSlice: clip.transcriptSlice,
                        movieTitle: movie.title,
                        language: effectiveDescriptionLanguage
                    )
                }
            )

            detectedMovie = result.movie
            manualMovieTitle = result.query.title
            manualMovieYear = result.query.year ?? ""
            clip.detectedMovieTitle = result.query.title
            clip.detectedMovieYear = result.query.year ?? ""

            CinemaContentGenerator.apply(
                content: result.content,
                to: clip,
                replaceHook: true,
                saveToHistory: true,
                settings: settings
            )

            isRegeneratingCinemaContent = false
        }
    }

    private func seedMovieFieldsFromSource() {
        var seeded = false
        if !clip.detectedMovieTitle.trimmed.isEmpty {
            manualMovieTitle = clip.detectedMovieTitle
            manualMovieYear = clip.detectedMovieYear
            seeded = true
        } else {
            let candidateSources = [
                clip.sourceMetadata?.description,
                clip.sourceMetadata?.title,
            ]
            for source in candidateSources.compactMap({ $0?.trimmed }).filter({ !$0.isEmpty }) {
                if let query = CinemaContentGenerator.movieTitleGuess(from: source) {
                    manualMovieTitle = query.title
                    manualMovieYear = query.year ?? ""
                    clip.detectedMovieTitle = query.title
                    clip.detectedMovieYear = query.year ?? ""
                    seeded = true
                    break
                }
            }
        }

        if seeded && !manualMovieTitle.trimmed.isEmpty {
            let tiktokHook = clip.variants.first(where: { $0.platform == .tiktok })?.hook ?? ""
            let needsRegenerate = tiktokHook.isEmpty || tiktokHook == "Short clip" || !tiktokHook.contains("🎬")
            if needsRegenerate && !isRegeneratingCinemaContent {
                regenerateCinemaContent()
            }
        }
    }

    private func sanitizedMovieYear(_ raw: String) -> String {
        String(raw.filter(\.isNumber).prefix(4))
    }
}
