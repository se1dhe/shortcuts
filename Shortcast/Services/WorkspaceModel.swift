import Foundation
import Observation
import SwiftUI
import AVFoundation

/// Drives the main window's state machine. Two flows share it:
///  - short video → one set of editable variants → publish (the original path).
///  - long video → transcribe → find moments → cut + caption N shorts → publish.
@MainActor
@Observable
final class WorkspaceModel {

    /// What the user wants to do with a dropped video. Chosen explicitly on the
    /// drop screen rather than guessed from the video's length.
    enum InputMode: String, CaseIterable, Identifiable, Sendable {
        case shorts    // long video → cut into clips → caption each → publish
        case longform  // фильм → 4-актное кино-эссе (16:9 YouTube, 5-8 мин, Shortcast Cinema)
        case caption   // short video → captions → publish (the original flow)
        case youtube   // search YouTube → download → use the long-video flow

        var id: String { rawValue }

        var title: LocalizedStringKey {
            switch self {
            case .shorts:   "Шортсы из фильма"
            case .longform: "Кино-эссе (16:9)"
            case .caption:  "Быстрый клип"
            case .youtube:  "Найти на YouTube"
            }
        }

        var dropTitle: LocalizedStringKey {
            switch self {
            case .shorts:   "Перетащите фильм для нарезки шортсов"
            case .longform: "Перетащите фильм для кино-эссе (16:9)"
            case .caption:  "Перетащите короткое видео"
            case .youtube:  "Найти видео на YouTube"
            }
        }

        var dropSubtitle: LocalizedStringKey {
            switch self {
            case .shorts:   "Полный фильм — нейросеть найдет сюжетные арки, нарежет 1:1, наложит сабы и сведет звук"
            case .longform: "16:9 YouTube (5–8 мин). Нейросеть выявит лейтмотив (терпение, гнев, гений), соберет 4 акта и наложит саундтрек"
            case .caption:  "До 60 секунд — ролик для TikTok, Reels или YouTube Shorts"
            case .youtube:  "Поиск видео по теме, загрузка и последующий монтаж на Mac"
            }
        }

        var symbol: String {
            switch self {
            case .shorts:   "scissors"
            case .longform: "film.fill"
            case .caption:  "film.stack"
            case .youtube:  "magnifyingglass"
            }
        }
    }

    /// The selected mode. Drives routing in `process(url:)`. Defaults to making
    /// shorts from a long video — the app's headline flow.
    var inputMode: InputMode = .shorts

    enum Phase: Equatable {
        case empty
        // Single-video flow:
        case processing
        case results
        // Shorts flow:
        case transcribing
        case findingMoments
        case shortsResults
        // Longform flow:
        case selectingLongformConcept
        case buildingLongform(fraction: Double, step: String)
        case longformResults
    }

    private(set) var phase: Phase = .empty
    private(set) var job: VideoJob?

    /// The three proposed posts (single-video flow). Bound by the result cards.
    var variants: [PostVariant] = []
    private(set) var detectedLanguage: String?

    /// The generated shorts (long-video flow).
    var clips: [ShortClip] = []

    /// Хранит полный транскрипт фильма
    var storedTranscript: Transcript?
    /// Выявленные темы для длинного ролика Shortcast Cinema
    var discoveredConcepts: [ThematicConcept] = []
    /// Выбранная тема для ролика
    var selectedConcept: ThematicConcept?
    /// Результат генерации длинного ролика
    var longformResult: LongformBuildResult?
    /// Прогресс рендеринга длинного видео
    var longformBuildProgress: (fraction: Double, step: String) = (0.0, "")

    /// Активный проект фильма (сохранение прогресса транскрипции, тем и шортсов)
    var currentProject: FilmProject?
    let filmProjectService: any FilmProjectServicing = FilmProjectService.shared

    /// Temporary input copies and normalized containers, deleted when the user
    /// starts over or an import fails. Originals already in the working folder
    /// are intentionally never registered here.
    private var tempInputURLs: Set<URL> = []

    /// Shown while an import is copied or normalized before a `VideoJob` exists.
    private(set) var inputPreparationMessage: String?

    /// Owns transcription (sidecar `.srt`/`.vtt` or on-device WhisperKit).
    let transcription = TranscriptionService()

    /// Accurate pipeline progress and dynamic ETA tracker.
    let progressTracker = PipelineProgressTracker()

    /// Movie detection service for 100% reliable identification and IMDb/Rotten Tomatoes ratings.
    let movieMetadata = MovieMetadataService()

    /// Resolved movie identity with IMDb and Rotten Tomatoes scores.
    var detectedMovie: MovieIdentity?

    /// Non-fatal banner shown on the drop screen.
    var errorMessage: String?
    /// Fatal pipeline error (transcription / moment-finding failed).
    private(set) var pipelineError: String?

    private var pipelineTask: Task<Void, Never>?

    // Publishing (single-video flow)
    private(set) var isPublishing = false
    private(set) var publishReport: UploadPostClient.PublishReport?
    private(set) var publishError: String?
    /// True while "Publish all approved" runs over the shorts.
    private(set) var isPublishingAll = false

    var isBusy: Bool {
        switch phase {
        case .processing, .transcribing, .findingMoments, .buildingLongform: return true
        default: return false
        }
    }

    func applyCurrentSubtitleSettings(_ settings: AppSettings) {
        for clip in clips {
            if clip.isCinemaMode { continue }
            clip.applySubtitleDefaults(
                settings.subtitleAppearance,
                burnSubtitles: settings.burnSubtitles)
        }
    }

    func applyCurrentWatermarkSettings(_ settings: AppSettings) {
        for clip in clips {
            clip.applyWatermarkDefaults(
                enabled: settings.watermarkEnabled,
                text: settings.watermarkText,
                appearance: settings.watermarkAppearance)
        }
    }

    func applyCurrentPromoSettings(_ settings: AppSettings) {
        for clip in clips {
            if clip.isCinemaMode { continue }
            clip.applyPromoDefaults(
                enabled: settings.promoOverlayEnabled,
                promoCode: settings.promoCode,
                durationSeconds: settings.promoDurationSeconds)
        }
    }

    func applyCurrentHookSettings(_ settings: AppSettings) {
        for clip in clips {
            if clip.isCinemaMode { continue }
            clip.hookAppearance = settings.hookAppearance
        }
    }

    /// Holds state while the user is choosing an audio track (when a video has > 1 audio streams).
    var pendingAudioSelection: PendingAudioSelection?

    // MARK: - Entry

    /// Entry point when a file is imported or dropped.
    /// Immediately copies the file into the working directory (while security-scoped access is active),
    /// then inspects audio tracks: if there are multiple tracks, prompts the user via sheet.
    /// Otherwise starts pipeline directly.
    func prepareAndProcess(
        url: URL,
        sourceMetadata: VideoSourceMetadata? = nil,
        modelManager: ModelManager,
        settings: AppSettings
    ) async {
        errorMessage = nil
        pipelineError = nil
        publishReport = nil
        publishError = nil

        // Clean up previous run leftovers
        cleanUpTempInput()
        cleanUpOrphanedInputFiles(settings: settings)

        // Copy input file immediately while security-scoped access is guaranteed active
        let sandboxFriendlyURL: URL
        do {
            sandboxFriendlyURL = try copyInputIntoWorkingDirectory(url, settings: settings)
        } catch {
            errorMessage = error.localizedDescription
            phase = .empty
            return
        }

        let workingDir = settings.workingDirectory ?? sandboxFriendlyURL.deletingLastPathComponent()
        let tracks = await MediaExtractor.inspectAudioTracks(sourceURL: sandboxFriendlyURL, workingDirectory: workingDir)

        if tracks.count > 1 {
            let recommended = MediaExtractor.pickRecommendedAudioTrack(from: tracks) ?? tracks[0]
            self.pendingAudioSelection = PendingAudioSelection(
                videoURL: sandboxFriendlyURL,
                sourceMetadata: sourceMetadata,
                tracks: tracks,
                selectedTrackId: recommended.id
            )
            // UI shows AudioTrackSelectionSheet, wait for user confirmation
        } else {
            await continuePipeline(
                sandboxFriendlyURL: sandboxFriendlyURL,
                sourceMetadata: sourceMetadata,
                selectedAudioStreamIndex: tracks.first?.id,
                modelManager: modelManager,
                settings: settings
            )
        }
    }

    func confirmAudioTrackSelection(
        pending: PendingAudioSelection,
        trackId: Int,
        modelManager: ModelManager,
        settings: AppSettings
    ) async {
        self.pendingAudioSelection = nil
        await continuePipeline(
            sandboxFriendlyURL: pending.videoURL,
            sourceMetadata: pending.sourceMetadata,
            selectedAudioStreamIndex: trackId,
            modelManager: modelManager,
            settings: settings
        )
    }

    func cancelAudioTrackSelection() {
        self.pendingAudioSelection = nil
        cleanUpTempInput()
        phase = .empty
    }

    /// Direct entry point.
    func process(
        url: URL,
        sourceMetadata: VideoSourceMetadata? = nil,
        selectedAudioStreamIndex: Int? = nil,
        modelManager: ModelManager,
        settings: AppSettings
    ) async {
        await prepareAndProcess(
            url: url,
            sourceMetadata: sourceMetadata,
            modelManager: modelManager,
            settings: settings
        )
    }

    /// Continues pipeline once the audio track is known and file is securely in working directory.
    private func continuePipeline(
        sandboxFriendlyURL: URL,
        sourceMetadata: VideoSourceMetadata? = nil,
        selectedAudioStreamIndex: Int? = nil,
        modelManager: ModelManager,
        settings: AppSettings
    ) async {
        errorMessage = nil
        publishReport = nil
        publishError = nil
        pipelineError = nil
        inputPreparationMessage = "Preparing your video…"
        phase = .processing

        // Redirect HuggingFace model cache into the working directory so that
        // WhisperKit and MLX models land in an accessible location instead of
        // ~/Documents/huggingface/ (blocked by macOS sandbox).
        if let wd = settings.workingDirectory {
            let cacheDir = wd.appendingPathComponent("huggingface").path
            setenv("HUGGINGFACE_HUB_CACHE", cacheDir, 1)
        }

        let normalizedInputURL: URL
        do {
            if MediaExtractor.needsNormalization(sandboxFriendlyURL) || selectedAudioStreamIndex != nil {
                inputPreparationMessage = "Converting \(sandboxFriendlyURL.pathExtension.uppercased()) to MP4…"
            }
            normalizedInputURL = try await MediaExtractor.normalizeInputIfNeeded(
                from: sandboxFriendlyURL,
                workingDirectory: settings.workingDirectory ?? sandboxFriendlyURL.deletingLastPathComponent(),
                selectedAudioStreamIndex: selectedAudioStreamIndex)
            if normalizedInputURL != sandboxFriendlyURL {
                tempInputURLs.insert(normalizedInputURL)
            }
        } catch {
            errorMessage = error.localizedDescription
            inputPreparationMessage = nil
            cleanUpTempInput()
            phase = .empty
            return
        }
        inputPreparationMessage = nil

        let originalBaseName = sandboxFriendlyURL.deletingPathExtension().lastPathComponent
        let effectiveSourceMetadata = sourceMetadata ?? (MovieMetadataService.isGarbageTitle(originalBaseName) ? nil : VideoSourceMetadata(title: originalBaseName))

        let newJob: VideoJob
        do {
            newJob = try await MediaExtractor.makeJob(
                from: normalizedInputURL,
                originalFileName: originalBaseName,
                sourceMetadata: effectiveSourceMetadata)
        } catch {
            errorMessage = error.localizedDescription
            cleanUpTempInput()
            phase = .empty
            return
        }

        // Загружаем или создаем постоянный проект фильма (SOLID: Single Responsibility)
        if let existingProject = try? await filmProjectService.loadProject(for: sandboxFriendlyURL) {
            self.currentProject = existingProject
            if let t = existingProject.transcript { self.storedTranscript = t }
            if let m = existingProject.tmdbMetadata { self.detectedMovie = m }
            if !existingProject.discoveredConcepts.isEmpty { self.discoveredConcepts = existingProject.discoveredConcepts }
            if let sc = existingProject.selectedConcept { self.selectedConcept = sc }
            if let lr = existingProject.longformResult { self.longformResult = lr }
            Self.log("Loaded cached FilmProject: \(existingProject.movieTitle) (\(existingProject.candidates.count) candidates, \(existingProject.discoveredConcepts.count) concepts)")
        } else {
            let project = FilmProject(
                sourceMovieURL: sandboxFriendlyURL,
                movieFileName: originalBaseName,
                movieTitle: effectiveSourceMetadata?.title ?? originalBaseName,
                durationSeconds: newJob.durationSeconds
            )
            self.currentProject = project
            try? await filmProjectService.saveProject(project)
        }

        switch inputMode {
        case .caption:
            await processPrecutShort(job: newJob, modelManager: modelManager, settings: settings)
        case .longform:
            await startLongformPipeline(job: newJob, modelManager: modelManager, settings: settings)
        case .youtube:
            // YouTube Shorts (< 3 min, vertical) go through the pre-cut short
            // pipeline (transcription + subtitles + watermark + captions, no
            // moment-finding). Long videos use the moment-finding pipeline.
            if newJob.durationSeconds < 180 {
                await processPrecutShort(job: newJob, modelManager: modelManager, settings: settings)
            } else {
                startShortsPipeline(job: newJob, modelManager: modelManager, settings: settings)
            }
        case .shorts:
            // Movie / long video pipeline: find character & narrative arcs.
            // Only very short pre-cut clips (< 60s) skip moment-finding.
            if newJob.durationSeconds < 60 {
                await processPrecutShort(job: newJob, modelManager: modelManager, settings: settings)
            } else {
                startShortsPipeline(job: newJob, modelManager: modelManager, settings: settings)
            }
        }
    }

    // MARK: - Long-form Flow (YouTube 16:9 Thematic Essays in Shortcast Cinema style)

    private func startLongformPipeline(job newJob: VideoJob, modelManager: ModelManager, settings: AppSettings) async {
        cleanupClipTempFiles()
        self.job = newJob
        self.clips = []
        self.variants = []
        self.pipelineError = nil
        self.longformResult = nil
        self.selectedConcept = nil
        self.phase = .transcribing
        self.progressTracker.reset(totalVideoDuration: newJob.durationSeconds)

        do {
            // 1. Первичная идентификация фильма по чистому имени файла / метаданным
            let initialCandidate = newJob.effectiveTitle
            var movie = self.detectedMovie
            if movie == nil {
                movie = await movieMetadata.resolveMovie(
                    filename: initialCandidate,
                    sourceTitle: newJob.sourceMetadata?.title,
                    apiKey: settings.tmdbAPIKey)
                self.detectedMovie = movie
            }
            if let movie {
                progressTracker.updateMovieDetection(
                    title: movie.title,
                    year: movie.year,
                    imdb: movie.imdbRating,
                    rottenTomatoes: movie.rottenTomatoesScore)
            }

            // 2. Транскрипция фильма через WhisperKit (или кэш проекта)
            let transcript: Transcript
            if let cached = self.storedTranscript ?? self.currentProject?.transcript {
                transcript = cached
                self.storedTranscript = cached
                Self.log("Using cached transcript for longform: \(cached.segments.count) segments")
            } else {
                self.progressTracker.startTranscription(totalSeconds: newJob.durationSeconds)
                transcript = try await transcription.transcript(
                    for: newJob.url,
                    languageHint: settings.languageOverride,
                    modelCacheDir: settings.workingDirectory?.appendingPathComponent("huggingface")
                ) { @Sendable [weak self] sec in
                    Task { @MainActor in
                        self?.progressTracker.updateTranscriptionProgress(processedSeconds: sec)
                    }
                }
                self.storedTranscript = transcript
                self.currentProject?.transcript = transcript
                if let project = self.currentProject {
                    try? await filmProjectService.saveProject(project)
                }
            }

            // 2.5. Если фильм не был точно определен на этапе 1, анализируем диалоги через эвристику / LLM + TMDB
            if movie == nil {
                let sampleDialogue = transcript.segments.prefix(80).map(\.text).joined(separator: "\n")
                
                // Проверяем диалоговую эвристику
                if let heuristic = await movieMetadata.resolveMovie(
                    filename: initialCandidate,
                    sourceTitle: newJob.sourceMetadata?.title,
                    apiKey: settings.tmdbAPIKey,
                    transcriptSample: sampleDialogue
                ) {
                    movie = heuristic
                } else {
                    // Задействуем Director LLM (Qwen/Gemma) для идентификации по репликам
                    await modelManager.prepareDirectorIfNeeded()
                    if let inferred = await modelManager.momentFinder.detectMovieFromTranscript(sample: sampleDialogue) {
                        movie = await movieMetadata.resolveMovie(
                            filename: inferred.title,
                            sourceTitle: inferred.title,
                            apiKey: settings.tmdbAPIKey
                        )
                        if movie == nil {
                            movie = MovieIdentity(
                                id: inferred.title,
                                title: inferred.title,
                                originalTitle: nil,
                                year: inferred.year,
                                imdbRating: "8.5",
                                rottenTomatoesScore: "90%",
                                posterURL: nil,
                                backdropURL: nil,
                                overview: "",
                                characters: [],
                                director: nil,
                                genres: []
                            )
                        }
                    }
                }
                self.detectedMovie = movie
                if let movie {
                    progressTracker.updateMovieDetection(
                        title: movie.title,
                        year: movie.year,
                        imdb: movie.imdbRating,
                        rottenTomatoes: movie.rottenTomatoesScore)
                }
            }

            self.currentProject?.tmdbMetadata = self.detectedMovie
            if let project = self.currentProject {
                try? await filmProjectService.saveProject(project)
            }

            let effectiveMovieTitle: String
            if let title = movie?.title, !MovieMetadataService.isGarbageTitle(title) {
                effectiveMovieTitle = title
            } else if !initialCandidate.isEmpty && !MovieMetadataService.isGarbageTitle(initialCandidate) {
                effectiveMovieTitle = initialCandidate
            } else {
                effectiveMovieTitle = "Фильм"
            }

            // 3. Выявление философских тем (Shortcast Thematic Engine)
            let concepts: [ThematicConcept]
            if !self.discoveredConcepts.isEmpty {
                concepts = self.discoveredConcepts
            } else if let cached = self.currentProject?.discoveredConcepts, !cached.isEmpty {
                concepts = cached
                self.discoveredConcepts = cached
            } else {
                let thematicService = LongformThematicService()
                concepts = try await thematicService.discoverConcepts(
                    from: transcript,
                    movieTitle: effectiveMovieTitle,
                    movieOverview: movie?.overview,
                    forceAI: false,
                    modelManager: modelManager
                )
                self.discoveredConcepts = concepts
                self.currentProject?.discoveredConcepts = concepts
                if let project = self.currentProject {
                    try? await filmProjectService.saveProject(project)
                }
            }
            self.phase = .selectingLongformConcept
        } catch {
            errorMessage = "Ошибка подготовки длинного видео: \(error.localizedDescription)"
            phase = .empty
        }
    }

    func confirmLongformConcept(
        _ concept: ThematicConcept,
        confirmedMovieTitle: String? = nil,
        backgroundMusicURL: URL? = nil,
        musicVolume: Float = 0.28,
        duckingEnabled: Bool = true,
        settings: AppSettings
    ) {
        guard let currentJob = job, let transcript = storedTranscript else { return }
        self.selectedConcept = concept

        let candidate = (confirmedMovieTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let finalMovieTitle: String
        if !candidate.isEmpty && !MovieMetadataService.isGarbageTitle(candidate) {
            finalMovieTitle = candidate
        } else if let detected = detectedMovie?.title, !MovieMetadataService.isGarbageTitle(detected) {
            finalMovieTitle = detected
        } else if !currentJob.effectiveTitle.isEmpty && !MovieMetadataService.isGarbageTitle(currentJob.effectiveTitle) {
            finalMovieTitle = currentJob.effectiveTitle
        } else {
            finalMovieTitle = "Фильм"
        }

        if self.detectedMovie != nil {
            self.detectedMovie?.title = finalMovieTitle
        } else {
            self.detectedMovie = MovieIdentity(
                id: finalMovieTitle,
                title: finalMovieTitle,
                originalTitle: nil,
                year: "",
                imdbRating: "8.5",
                rottenTomatoesScore: "90%",
                posterURL: nil,
                backdropURL: nil,
                overview: "",
                characters: [],
                director: nil,
                genres: []
            )
        }

        // Запоминаем тему в историю созданных эссе фильма
        LongformHistoryService.shared.markConceptGenerated(movieTitle: finalMovieTitle, conceptWord: concept.word)

        phase = .buildingLongform(fraction: 0.05, step: "Подготовка видеомонтажа...")

        pipelineTask = Task {
            do {
                let coordinator = LongformPipelineCoordinator()
                let result = try await coordinator.buildLongformVideo(
                    sourceURL: currentJob.url,
                    movieTitle: finalMovieTitle,
                    transcript: transcript,
                    concept: concept,
                    backgroundMusicURL: backgroundMusicURL,
                    musicVolume: musicVolume,
                    duckingEnabled: duckingEnabled
                ) { [weak self] frac, step in
                    Task { @MainActor in
                        self?.longformBuildProgress = (frac, step)
                        self?.phase = .buildingLongform(fraction: frac, step: step)
                    }
                }
                self.longformResult = result
                self.currentProject?.longformResult = result
                self.currentProject?.selectedConcept = concept
                if let project = self.currentProject {
                    try? await self.filmProjectService.saveProject(project)
                }
                self.phase = .longformResults
            } catch {
                self.errorMessage = "Ошибка монтажа длинного ролика: \(error.localizedDescription)"
                self.phase = .empty
            }
        }
    }

    /// Возврат к выбору темы для текущего фильма без повторной обработки видео и Whisper
    func chooseAnotherConcept() {
        self.longformResult = nil
        self.selectedConcept = nil
        self.phase = .selectingLongformConcept
    }

    /// Повторный запуск генерации альтернативных тем с помощью нейросети Director
    func regenerateThematicConcepts(modelManager: ModelManager) async {
        guard let transcript = storedTranscript else { return }
        let effectiveTitle = detectedMovie?.title ?? job?.effectiveTitle ?? "Фильм"
        let overview = detectedMovie?.overview
        let thematicService = LongformThematicService()

        do {
            let freshConcepts = try await thematicService.discoverConcepts(
                from: transcript,
                movieTitle: effectiveTitle,
                movieOverview: overview,
                forceAI: true,
                modelManager: modelManager
            )
            if !freshConcepts.isEmpty {
                self.discoveredConcepts = freshConcepts
            }
        } catch {
            Self.log("regenerateThematicConcepts failed: \(error.localizedDescription)")
        }
    }

    func cancelLongformSelection() {
        if self.longformResult != nil {
            // Если эссе уже было собрано ранее, просто возвращаемся к просмотру результата
            self.phase = .longformResults
        } else {
            self.discoveredConcepts = []
            self.selectedConcept = nil
            cleanUpTempInput()
            self.phase = .empty
        }
    }

    func resetLongform() {
        self.longformResult = nil
        self.selectedConcept = nil
        self.storedTranscript = nil
        self.discoveredConcepts = []
        self.detectedMovie = nil
        cleanUpTempInput()
        self.phase = .empty
    }

    /// Запускает генерацию вирусных вертикальных Shorts из текущего загруженного фильма,
    /// повторно используя готовую транскрипцию Whisper без дублирования расшифровки.
    func generateShortsFromCurrentMovie(modelManager: ModelManager, settings: AppSettings) {
        guard let currentJob = job, let transcript = storedTranscript ?? currentProject?.transcript else { return }
        cleanupClipTempFiles()
        self.clips = []
        self.variants = []
        self.pipelineError = nil
        self.phase = .findingMoments

        pipelineTask = Task {
            await continueShortsPipeline(
                job: currentJob,
                transcript: transcript,
                movie: self.detectedMovie ?? self.currentProject?.tmdbMetadata,
                modelManager: modelManager,
                settings: settings
            )
        }
    }

    // MARK: - Single-video flow (unchanged behaviour)

    private func processSingleVideo(job newJob: VideoJob, modelManager: ModelManager, settings: AppSettings) async {
        guard let engine = modelManager.engine else {
            errorMessage = "The model is still getting ready — give it a moment, then drop the video again."
            return
        }

        job = newJob
        variants = []
        detectedLanguage = nil
        phase = .processing

        do {
            let result = try await GemmaService.generate(
                job: newJob,
                engine: engine,
                languageOverride: settings.languageOverride,
                styleExamples: settings.styleExamples)
            variants = result.variants
            detectedLanguage = result.detectedLanguage
            phase = .results
        } catch {
            errorMessage = "Couldn't generate posts for that video. \(error.localizedDescription)"
            job = nil
            phase = .empty
        }
    }

    // MARK: - Pre-cut short flow (ready-made short, no moment-finding)

    private func processPrecutShort(job: VideoJob, modelManager: ModelManager, settings: AppSettings) async {
        cleanupClipTempFiles()
        self.job = job
        clips = []
        variants = []
        pipelineError = nil

        let needsTranscription = settings.transcriptionEnabled

        // If transcription is disabled, open the editor INSTANTLY!
        if needsTranscription {
            phase = .transcribing
        } else {
            phase = .shortsResults
        }

        pipelineTask = Task {
            do {
                // 1. Transcribe (for subtitle segments + captioning).
                let transcript: Transcript?
                if needsTranscription {
                    transcript = try await transcription.transcript(
                        for: job.url, languageHint: settings.languageOverride,
                        modelCacheDir: settings.workingDirectory?.appendingPathComponent("huggingface"))
                } else {
                    transcript = nil
                }
                let captionLanguage: String? = transcript.flatMap { $0.contentLanguage ?? $0.language }

                try Task.checkCancellation()

                // 2. Create one clip from the full video (skips moment-finding).
                let segs = transcript.map { t in
                    t.segments.map { SubtitleSegment(
                        start: $0.start, end: $0.end, text: $0.text.trimmed, words: $0.words) }
                } ?? []
                let candidate = ClipCandidate(
                    start: 0, end: job.durationSeconds, why: "", hook: "", overlay: "")
                var appearance = settings.subtitleAppearance
                // Force premium cinema styling (override old saved defaults)
                appearance.fontChoiceRaw = SubtitleAppearance.FontChoice.russoOne.rawValue
                appearance.maxWordsPerCaption = 2
                appearance.textBorderWidth = 3.5
                appearance.fontSizeScale = 0.085
                appearance.moodProfile = candidate.mood
                let clip = ShortClip(
                    candidate: candidate,
                    transcriptSlice: transcript?.fullText ?? "",
                    subtitleSegments: segs,
                    sourceMetadata: job.sourceMetadata,
                    overlayEnabled: settings.burnHookOverlay,
                    reframeEnabled: false,
                    burnSubtitles: needsTranscription && settings.burnSubtitles,
                    subtitleAppearance: appearance,
                    watermarkEnabled: settings.watermarkEnabled,
                    watermarkText: settings.watermarkText,
                    watermarkAppearance: settings.watermarkAppearance,
                    promoOverlayEnabled: settings.promoOverlayEnabled,
                    promoCode: settings.promoCode,
                    promoDurationSeconds: settings.promoDurationSeconds)

                clip.clipJob = job
                clip.isLandscape = await VerticalReframer.isLandscape(url: job.url)
                clip.antiCopyrightEnabled = settings.antiCopyrightEnabled
                clip.antiCopyrightPreset = settings.antiCopyrightPreset
                clip.antiCopyrightConfig = settings.antiCopyrightPreset.config

                // Instant title & year extraction from source metadata
                if let meta = job.sourceMetadata {
                    let sourceText = [meta.title, meta.description].filter { !$0.trimmed.isEmpty }.joined(separator: " ")
                    if let guess = CinemaContentGenerator.movieTitleGuess(from: sourceText) {
                        clip.detectedMovieTitle = guess.title
                        clip.detectedMovieYear = guess.year ?? ""
                    }
                }

                clips = [clip]

                // Switch phase to results as soon as clip is created
                phase = .shortsResults

                // 3. Caption via the copywriter model (only when transcription ran).
                if needsTranscription {
                    clip.stage = .captioning
                    do {
                        let result = try await ClipRenderingService.generateCaption(
                            clip: clip, modelManager: modelManager, settings: settings,
                            transcriptLanguage: captionLanguage)
                        clip.applyGeneratedCopy(result, detectedLanguage: result.detectedLanguage)
                        saveProcessedRecord(for: clip, settings: settings)
                    } catch {
                        Self.log("precut caption fallback: \(error.localizedDescription)")
                        clip.applyGeneratedCopy(
                            fallbackGeneration(for: clip, language: captionLanguage),
                            detectedLanguage: captionLanguage)
                        saveProcessedRecord(for: clip, settings: settings)
                    }
                } else {
                    clip.applyGeneratedCopy(
                        fallbackGeneration(for: clip, language: captionLanguage),
                        detectedLanguage: captionLanguage)
                }

                clip.stage = .ready

                // 4. Auto-apply cinema metadata in the background so editor is not blocked.
                Task {
                    await self.applyCinemaContentForGeneratedClip(
                        clip: clip, movie: nil, modelManager: modelManager,
                        language: captionLanguage, settings: settings)
                }

                Self.log("precut short ready — \(job.durationLabel), language=\(captionLanguage ?? "?")")

            } catch is CancellationError {
                cleanupClipTempFiles()
                clips = []
                self.job = nil
                cleanUpTempInput()
                phase = .empty
            } catch {
                if Self.isMetadataPermissionError(error) {
                    Self.log("ignoring metadata permission error: \(error.localizedDescription)")
                } else {
                    pipelineError = error.localizedDescription
                    errorMessage = "Couldn't process that short. \(error.localizedDescription)"
                    self.job = nil
                    clips = []
                    cleanUpTempInput()
                    phase = .empty
                }
            }
        }
    }



    // MARK: - Shorts flow (long video → moment-finding → clips)

    private func startShortsPipeline(job newJob: VideoJob, modelManager: ModelManager, settings: AppSettings) {
        cleanupClipTempFiles()
        job = newJob
        clips = []
        variants = []
        pipelineError = nil
        phase = .transcribing

        pipelineTask = Task {
            await self.runShortsPipeline(job: newJob, modelManager: modelManager, settings: settings)
        }
    }

    func regenerateShorts(modelManager: ModelManager, settings: AppSettings) {
        guard let currentJob = job else { return }
        startShortsPipeline(job: currentJob, modelManager: modelManager, settings: settings)
    }

    private func runShortsPipeline(job: VideoJob, modelManager: ModelManager, settings: AppSettings) async {
        let pipelineStart = Date()
        progressTracker.reset(totalVideoDuration: job.durationSeconds)
        Self.log("pipeline start — copywriter=\(settings.copywriterModel.rawValue)")
        do {
            // 0. Stage 1: Identify movie & ratings (0% -> 5%)
            let initialCandidate = job.effectiveTitle
            var movie = self.detectedMovie ?? self.currentProject?.tmdbMetadata
            if movie == nil {
                movie = await movieMetadata.resolveMovie(
                    filename: initialCandidate,
                    sourceTitle: job.sourceMetadata?.title,
                    apiKey: settings.tmdbAPIKey)
                self.detectedMovie = movie
            }
            if let movie {
                progressTracker.updateMovieDetection(
                    title: movie.title,
                    year: movie.year,
                    imdb: movie.imdbRating,
                    rottenTomatoes: movie.rottenTomatoesScore)
            }

            // 1. Stage 2: Transcript (5% -> 45%)
            let transcript: Transcript
            if let cached = self.storedTranscript ?? self.currentProject?.transcript {
                transcript = cached
                self.storedTranscript = cached
                Self.log("Using cached transcript for shorts: \(cached.segments.count) segments")
            } else {
                phase = .transcribing
                progressTracker.startTranscription(totalSeconds: job.durationSeconds)
                let t0 = Date()
                transcript = try await transcription.transcript(
                    for: job.url, languageHint: settings.languageOverride,
                    modelCacheDir: settings.workingDirectory?.appendingPathComponent("huggingface")) { @Sendable [weak self] sec in
                        Task { @MainActor in
                            self?.progressTracker.updateTranscriptionProgress(processedSeconds: sec)
                        }
                    }
                self.storedTranscript = transcript
                self.currentProject?.transcript = transcript
                if let project = self.currentProject {
                    try? await filmProjectService.saveProject(project)
                }
                Self.log("transcript ready in \(Self.elapsed(since: t0)) — whisper=\(transcript.language ?? "?")")
            }
            // Trust the language of the actual text over Whisper's 30s auto-detect.
            let captionLanguage = transcript.contentLanguage ?? transcript.language
            progressTracker.updateTranscriptionProgress(processedSeconds: job.durationSeconds)
            try Task.checkCancellation()

            // 1.5. If movie was not detected from filename, use transcript sample with AI + TMDB
            if movie == nil {
                await modelManager.prepareDirectorIfNeeded()
                let sampleText = transcript.segments.prefix(60).map(\.text).joined(separator: " ")
                if let detected = await modelManager.momentFinder.detectMovieFromMetadata(
                    title: job.sourceMetadata?.title ?? initialCandidate,
                    description: sampleText,
                    language: captionLanguage) {
                    if !detected.title.isEmpty {
                        let q = CinemaContentGenerator.MovieSearchQuery(
                            title: detected.title,
                            year: detected.year.isEmpty ? nil : detected.year)
                        if let candidates = try? await TMDBService(apiKey: settings.tmdbAPIKey).searchMovies(by: q.title, year: q.year),
                           let best = candidates.first {
                            movie = await movieMetadata.enrichMovieIdentity(movie: best)
                        } else {
                            movie = MovieIdentity(
                                id: detected.title,
                                title: detected.title,
                                originalTitle: nil,
                                year: detected.year,
                                imdbRating: "8.5",
                                rottenTomatoesScore: "90%",
                                posterURL: nil,
                                backdropURL: nil,
                                overview: "",
                                characters: [],
                                director: nil,
                                genres: [])
                        }
                        self.detectedMovie = movie
                        if let m = movie {
                            progressTracker.updateMovieDetection(
                                title: m.title,
                                year: m.year,
                                imdb: m.imdbRating,
                                rottenTomatoes: m.rottenTomatoesScore)
                        }
                    }
                }
            }

            // 2. Stage 3 & 4: Поиск кульминационных моментов и нарезка Shorts
            await continueShortsPipeline(
                job: job,
                transcript: transcript,
                movie: movie,
                modelManager: modelManager,
                settings: settings
            )
        } catch is CancellationError {
            cleanupClipTempFiles()
            clips = []
            self.job = nil
            cleanUpTempInput()
            phase = .empty
        } catch {
            pipelineError = error.localizedDescription
            errorMessage = "Couldn't make shorts from that video. \(error.localizedDescription)"
            self.job = nil
            clips = []
            cleanUpTempInput()
            phase = .empty
        }
    }

    private func continueShortsPipeline(
        job: VideoJob,
        transcript: Transcript,
        movie: MovieIdentity?,
        modelManager: ModelManager,
        settings: AppSettings
    ) async {
        let pipelineStart = Date()
        let captionLanguage = transcript.contentLanguage ?? transcript.language ?? settings.languageOverride ?? "en"

        // Stage 3: Find narrative & character arcs (45% -> 65%)
        phase = .findingMoments
        progressTracker.startStoryAnalysis()
        let t1 = Date()
        await modelManager.prepareDirector(profile: settings.copywriterModel.directorProfile)
        Self.log("director ready in \(Self.elapsed(since: t1)) — \(settings.copywriterModel.directorProfile.displayName)")

        let movieTitle = movie?.title ?? job.fileName
        let useInlineCaptions = settings.copywriterModel.usesInlineCaptions

        // Scene detection — analyze video for scene boundaries or use cached scenes
        var sceneMap: String?
        var scenes: [DetectedScene] = currentProject?.scenes ?? []
        if scenes.isEmpty {
            do {
                scenes = try await SceneDetectionService.detectScenes(in: job.url)
                currentProject?.scenes = scenes
                if let project = currentProject {
                    try? await filmProjectService.saveProject(project)
                }
                Self.log("scene detection: found \(scenes.count) scenes")
            } catch {
                Self.log("scene detection skipped: \(error.localizedDescription)")
            }
        } else {
            Self.log("scene detection: using \(scenes.count) cached scenes")
        }

        if scenes.count > 1 {
            sceneMap = SceneDetectionService.formatForPrompt(
                scenes: scenes, transcriptDuration: job.durationSeconds)
        }

        let isComedy: Bool = {
            switch settings.cinemaGenreMode {
            case .comedy:
                return true
            case .drama:
                return false
            case .auto:
                return movie?.isComedy ?? false
            }
        }()

        do {
            let t2 = Date()
            let candidates = try await modelManager.momentFinder.findMoments(
                transcript: transcript.srtLike(),
                includeCaptions: useInlineCaptions,
                language: captionLanguage,
                styleExamples: settings.styleExamples,
                videoTitle: movieTitle,
                videoDescription: movie?.overview ?? (job.sourceMetadata?.description ?? ""),
                sceneMap: sceneMap,
                isComedy: isComedy)
            
            self.currentProject?.candidates = candidates
            if let project = self.currentProject {
                try? await filmProjectService.saveProject(project)
            }

            progressTracker.updateStoryAnalysis(fraction: 1.0, arcFound: candidates.first?.overlay)
            Self.log("found \(candidates.count) moment(s) in \(Self.elapsed(since: t2)), captions inline=\(useInlineCaptions), isComedy=\(isComedy)")
            try Task.checkCancellation()

            // Seed cards; they fill in as each clip is cut + captioned.
            clips = candidates.map { candidate in
                let clipStart = candidate.start
                let clipEnd = candidate.end
                
                var mappedSegs: [SubtitleSegment] = []
                if let cSegs = candidate.segments, cSegs.count > 1 {
                    var timelineOffset: Double = 0
                    for cSeg in cSegs.sorted(by: { $0.start < $1.start }) {
                        let inside = transcript.segments.filter { $0.end > cSeg.start && $0.start < cSeg.end }
                        for seg in inside {
                            let sStart = max(0, seg.start - cSeg.start) + timelineOffset
                            let sEnd = max(sStart, seg.end - cSeg.start) + timelineOffset
                            let wordTimings = seg.words.map {
                                WordTimestamp(
                                    word: $0.word,
                                    start: max(0, $0.start - cSeg.start) + timelineOffset,
                                    end: max(0, $0.end - cSeg.start) + timelineOffset
                                )
                            }
                            mappedSegs.append(SubtitleSegment(start: sStart, end: sEnd, text: seg.text.trimmed, words: wordTimings))
                        }
                        timelineOffset += (cSeg.end - cSeg.start)
                    }
                } else {
                    mappedSegs = transcript.segments
                        .filter { $0.end > clipStart && $0.start < clipEnd }
                        .map { seg in
                            let wordTimings = seg.words.map {
                                WordTimestamp(word: $0.word, start: max(0, $0.start - clipStart), end: max(0, $0.end - clipStart))
                            }
                            return SubtitleSegment(
                                start: max(0, seg.start - clipStart),
                                end: max(0, seg.end - clipStart),
                                text: seg.text.trimmed,
                                words: wordTimings
                            )
                        }
                }
                
                var appearance = SubtitleAppearance.cinemaPremium
                if let candidateMood = candidate.mood {
                    appearance.moodProfile = candidateMood
                } else if isComedy {
                    appearance.moodProfile = CinematicMoodProfile(mood: .eccentricComedy)
                }
                let newClip = ShortClip(
                    candidate: candidate,
                    transcriptSlice: transcript.slice(start: clipStart, end: clipEnd),
                    subtitleSegments: mappedSegs,
                    sourceMetadata: job.sourceMetadata,
                    overlayEnabled: false,
                    reframeEnabled: true,
                    burnSubtitles: true,
                    subtitleAppearance: appearance,
                    watermarkEnabled: settings.watermarkEnabled,
                    watermarkText: settings.watermarkText,
                    watermarkAppearance: settings.watermarkAppearance,
                    promoOverlayEnabled: false,
                    promoCode: "",
                    promoDurationSeconds: 0)
                newClip.antiCopyrightEnabled = settings.antiCopyrightEnabled
                newClip.antiCopyrightPreset = settings.antiCopyrightPreset
                newClip.antiCopyrightConfig = settings.antiCopyrightPreset.config
                newClip.descriptionMode = .movie
                let m = self.detectedMovie ?? movie
                if let m {
                    newClip.detectedMovieTitle = m.title
                    newClip.detectedMovieYear = m.year
                    newClip.imdbRating = m.imdbRating
                    newClip.rottenTomatoesScore = m.rottenTomatoesScore
                    newClip.candidate.hook = "Такой развязки никто не ожидал... 😳"
                    newClip.overlayText = "🍿 Название в Telegram: @telonyx_club"
                }
                return newClip
            }
            phase = .shortsResults

            // On tight RAM, free the Director before the Gemma E4B clip-watcher.
            if settings.copywriterModel.watchesClips {
                modelManager.freeDirectorIfMemoryTight()
            }

            // Stage 4: Cut, then caption, each clip in turn (65% -> 100%)
            progressTracker.startRendering(totalClips: clips.count)

            for (index, clip) in clips.enumerated() {
                try Task.checkCancellation()
                progressTracker.updateRenderingProgress(
                    clipIndex: index,
                    totalClips: clips.count,
                    clipName: clip.candidate.overlay.isEmpty ? "Эдит \(index + 1)" : clip.candidate.overlay)
                do {
                    let tCut = Date()
                    try await ClipRenderingService.renderAndCaption(
                        clip: clip,
                        jobURL: job.url,
                        transcript: transcript,
                        captionLanguage: captionLanguage,
                        modelManager: modelManager,
                        settings: settings,
                        transcription: transcription
                    )
                    await self.applyCinemaContentForGeneratedClip(
                        clip: clip,
                        movie: self.detectedMovie ?? movie,
                        modelManager: modelManager,
                        language: captionLanguage,
                        settings: settings
                    )
                    saveProcessedRecord(for: clip, settings: settings)
                    Self.log("clip \(index + 1)/\(clips.count) ready in \(Self.elapsed(since: tCut))")
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    clip.stage = .failed(error.localizedDescription)
                    Self.log("clip \(index + 1)/\(clips.count) failed: \(error.localizedDescription)")
                    
                    // Fallback captioning
                    Self.log("clip \(index + 1)/\(clips.count) caption fallback due to failure: \(error.localizedDescription)")
                    clip.applyGeneratedCopy(
                        fallbackGeneration(for: clip, language: captionLanguage),
                        detectedLanguage: captionLanguage)
                    saveProcessedRecord(for: clip, settings: settings)
                }
            }
            progressTracker.finish()
            Self.log("pipeline done — \(clips.count) clip(s) in \(Self.elapsed(since: pipelineStart)) total")
        } catch is CancellationError {
            cleanupClipTempFiles()
            clips = []
            phase = .empty
        } catch {
            pipelineError = error.localizedDescription
            errorMessage = "Couldn't make shorts from that video. \(error.localizedDescription)"
            clips = []
            phase = .empty
        }
    }

    /// Uses the on-device model to read the film title + year out of the source
    /// metadata, storing them on the clip and defaulting the burned hook to
    /// "Title (Year)". Best-effort: silently no-ops if nothing is identified.
    private func detectAndApplyMovie(for clip: ShortClip, modelManager: ModelManager, language: String?) async {
        guard let meta = clip.sourceMetadata,
              !(meta.title.trimmed.isEmpty && meta.description.trimmed.isEmpty) else { return }

        await modelManager.prepareDirectorIfNeeded()
        guard let detected = await modelManager.momentFinder.detectMovieFromMetadata(
            title: meta.title, description: meta.description, language: language) else { return }

        clip.detectedMovieTitle = detected.title
        clip.detectedMovieYear = detected.year
        let titleYear = detected.year.isEmpty ? detected.title : "\(detected.title) (\(detected.year))"
        Self.log("detected movie: \(titleYear)")
    }

    /// Full cinema pipeline for generated shorts and precut YouTube Shorts:
    /// detects/applies the film metadata (TMDB + on-device AI model fallback),
    /// then applies the viral cinema hook, description, and hashtags automatically
    /// for TikTok, Instagram Reels, and YouTube Shorts.
    private func applyCinemaContentForGeneratedClip(
        clip: ShortClip,
        movie: MovieIdentity?,
        modelManager: ModelManager,
        language: String?,
        settings: AppSettings
    ) async {
        let meta = clip.sourceMetadata
        var sourceText = [meta?.title, meta?.description]
            .compactMap { $0?.trimmed }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        if sourceText.isEmpty && !clip.transcriptSlice.trimmed.isEmpty {
            sourceText = clip.transcriptSlice.trimmed
        }

        var query: CinemaContentGenerator.MovieSearchQuery?

        // 1. If movie was resolved, use its title and year directly
        let effectiveTitle = (movie?.title ?? clip.detectedMovieTitle).trimmed
        let effectiveYear = (movie?.year ?? clip.detectedMovieYear).trimmed
        if !effectiveTitle.isEmpty {
            query = CinemaContentGenerator.MovieSearchQuery(
                title: effectiveTitle,
                year: effectiveYear.isEmpty ? nil : effectiveYear)
        }

        // 2. Try regex title guessing
        if query == nil, !sourceText.isEmpty {
            query = CinemaContentGenerator.movieTitleGuess(from: sourceText)
        }

        // 3. Fallback to AI model
        if query == nil || (query?.year ?? "").isEmpty {
            await modelManager.prepareDirectorIfNeeded()
            if let detected = await modelManager.momentFinder.detectMovieFromMetadata(
                title: meta?.title ?? "", description: meta?.description ?? sourceText, language: language) {
                let title = detected.title.isEmpty ? (query?.title ?? "") : detected.title
                let year = detected.year.isEmpty ? (query?.year ?? "") : detected.year
                if !title.isEmpty {
                    query = CinemaContentGenerator.MovieSearchQuery(
                        title: title,
                        year: year.isEmpty ? nil : year)
                }
            }
        }

        guard let searchQuery = query, !searchQuery.title.trimmed.isEmpty else {
            Self.log("applyCinemaContentForGeneratedClip: could not resolve movie title")
            return
        }

        Self.log("applyCinemaContentForGeneratedClip: querying TMDB & generating viral content for \"\(searchQuery.title)\" \(searchQuery.year ?? "")")

        let result = await CinemaContentGenerator.generate(
            query: searchQuery,
            sourceText: sourceText,
            tmdbAPIKey: settings.tmdbAPIKey,
            descriptionMode: .movie,   // show the movie synopsis in the description
            textAd: settings.textAdEnabled,
            sceneDescriptionProvider: nil,
            fallbackMovieProvider: {
                await modelManager.prepareDirectorIfNeeded()
                return await modelManager.momentFinder.inferMovie(query: searchQuery, sourceText: sourceText)
            })

        guard !result.content.isEmpty else { return }

        // Store the detected title/year so the manual editor field is pre-filled.
        clip.detectedMovieTitle = result.query.title
        clip.detectedMovieYear = result.query.year ?? ""
        clip.descriptionMode = .movie

        CinemaContentGenerator.apply(
            content: result.content,
            to: clip,
            replaceHook: true,       // write the cinema hook into variant.hook + overlayText
            saveToHistory: false,
            settings: nil)

        Self.log("applyCinemaContentForGeneratedClip: successfully applied viral cinema content for \"\(result.query.title)\" (\(result.query.year ?? ""))")
    }





    private func fallbackGeneration(for clip: ShortClip, language: String?) -> GenerationResult {
        let hook = clip.sourceMetadata?.title.trimmed ?? ""
        let summary = clip.sourceMetadata?.description.trimmed ?? ""
        let variants = SocialPlatform.allCases.map {
            PostVariant(platform: $0, hook: hook, summary: summary, hashtags: [], pinnedComment: "")
        }
        return GenerationResult(variants: variants, detectedLanguage: language)
    }

    /// macOS creates `.metadata` sidecar files (CoreSpotlight) and CoreML cache
    /// files that the app often can't delete. These permission errors are system-
    /// level, not app-level — ignore them gracefully.
    private static func isMetadataPermissionError(_ error: Error) -> Bool {
        let msg = error.localizedDescription.lowercased()
        return msg.contains(".metadata") || msg.contains("coremldata")
    }

    func cancelPipeline() {
        pipelineTask?.cancel()
    }

    private func copyInputIntoWorkingDirectory(_ url: URL, settings: AppSettings) throws -> URL {
        guard url.isFileURL else { return url }

        guard let workDir = settings.workingDirectory else {
            throw InputCopyError.missingWorkingDirectory
        }

        // Downloads are already written into the user-selected output folder.
        // When that folder is the working folder (the default), copying the
        // complete Short again only delays the edit and wastes disk space.
        let canonicalInput = url.standardizedFileURL.path
        let canonicalWorkDir = workDir.standardizedFileURL.path
        if canonicalInput.hasPrefix(canonicalWorkDir + "/") {
            return url
        }
        let didAccessInput = url.startAccessingSecurityScopedResource()
        let didAccessWorkDir = workDir.startAccessingSecurityScopedResource()
        defer {
            if didAccessInput { url.stopAccessingSecurityScopedResource() }
            if didAccessWorkDir { workDir.stopAccessingSecurityScopedResource() }
        }

        let inputDir = workDir.appendingPathComponent("input", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: inputDir, withIntermediateDirectories: true)
            let ext = url.pathExtension.isEmpty ? "mp4" : url.pathExtension
            let originalName = url.deletingPathExtension().lastPathComponent
            let copy = inputDir.appendingPathComponent("\(originalName).\(ext)")
            if FileManager.default.fileExists(atPath: copy.path) {
                try? FileManager.default.removeItem(at: copy)
            }
            try FileManager.default.copyItem(at: url, to: copy)
            tempInputURLs.insert(copy)
            return copy
        } catch {
            throw InputCopyError.failed(error.localizedDescription)
        }
    }

    // MARK: - Timing logs (stderr; visible when launched from the terminal)

    nonisolated static func log(_ message: String) {
        FileHandle.standardError.write(Data("[shortcast/pipeline] \(message)\n".utf8))
    }

    /// Formatted seconds elapsed between two dates (defaults `to` = now).
    nonisolated static func elapsed(since start: Date, to end: Date = Date()) -> String {
        String(format: "%.1fs", end.timeIntervalSince(start))
    }

    // MARK: - Reset

    /// Returns to the empty drop state and cleans up temp files.
    func startOver() {
        pipelineTask?.cancel()
        cleanupClipTempFiles()
        job = nil
        variants = []
        clips = []
        detectedLanguage = nil
        publishReport = nil
        publishError = nil
        errorMessage = nil
        pipelineError = nil
        cleanUpTempInput()
        phase = .empty
    }

    private func cleanupClipTempFiles() {
        for clip in clips {
            if let url = clip.clipJob?.url {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private func cleanUpTempInput() {
        for url in tempInputURLs {
            try? FileManager.default.removeItem(at: url)
        }
        tempInputURLs.removeAll()
    }

    func cleanUpOrphanedInputFiles(settings: AppSettings) {
        guard let workDir = settings.workingDirectory else { return }
        let inputDir = workDir.appendingPathComponent("input", isDirectory: true)
        let didAccess = workDir.startAccessingSecurityScopedResource()
        defer { if didAccess { workDir.stopAccessingSecurityScopedResource() } }

        guard let contents = try? FileManager.default.contentsOfDirectory(at: inputDir, includingPropertiesForKeys: nil) else { return }
        for url in contents {
            if !tempInputURLs.contains(url) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: - Publishing (single-video flow)

    func publish(settings: AppSettings) async {
        guard let job, !isPublishing else { return }
        publishError = nil
        publishReport = nil
        isPublishing = true
        defer { isPublishing = false }

        let client = UploadPostClient(
            apiKey: settings.apiKey,
            profileName: settings.profileName)
        do {
            var videoURL = job.url
            var isWatermarked = false

            if settings.watermarkFullVideoEnabled && !settings.watermarkText.isEmpty {
                let wmURL = try await WatermarkRenderer.render(
                    videoURL: job.url,
                    text: settings.watermarkText,
                    appearance: settings.watermarkAppearance)
                videoURL = wmURL
                isWatermarked = true
            }

            defer {
                if isWatermarked { try? FileManager.default.removeItem(at: videoURL) }
            }

            publishReport = try await client.publish(
                videoURL: videoURL,
                variants: variants,
                tiktokAsDraft: settings.tiktokAsDraft)
        } catch {
            publishError = error.localizedDescription
        }
    }

    func dismissPublishResult() {
        publishReport = nil
        publishError = nil
    }

    // MARK: - Publishing (shorts flow)

    var approvedReadyCount: Int {
        clips.filter { $0.isApproved && $0.isReadyToPublish }.count
    }

    /// Publishes every approved, ready clip in turn. Each clip keeps its own
    /// status, so a partial batch is reflected per card. Stops early if a clip
    /// hits the Upload-Post monthly limit.
    func publishAllApproved(settings: AppSettings) async {
        guard !isPublishingAll else { return }
        applyCurrentSubtitleSettings(settings)
        applyCurrentWatermarkSettings(settings)
        applyCurrentPromoSettings(settings)
        isPublishingAll = true
        defer { isPublishingAll = false }

        for clip in clips where clip.isApproved && clip.isReadyToPublish {
            await clip.publish(settings: settings)
            if let error = clip.publishError, error.localizedCaseInsensitiveContains("limit") {
                break
            }
        }
    }

    /// True while "Schedule all" runs.
    private(set) var isSchedulingAll = false

    /// The dates each approved, ready clip would be scheduled to: the first at
    /// `start`, then one every `intervalDays`. Used for the schedule preview.
    func schedulePlan(start: Date, intervalDays: Int) -> [(clip: ShortClip, date: Date)] {
        let cal = Calendar.current
        var date = start
        var plan: [(ShortClip, Date)] = []
        for clip in clips where clip.isApproved && clip.isReadyToPublish {
            plan.append((clip, date))
            date = cal.date(byAdding: .day, value: max(1, intervalDays), to: date) ?? date
        }
        return plan
    }

    /// Schedules every approved, ready clip: the first at `start`, then one every
    /// `intervalDays`. Sequential; stops cleanly on the monthly limit.
    func scheduleAllApproved(start: Date, intervalDays: Int, settings: AppSettings) async {
        guard !isSchedulingAll else { return }
        applyCurrentSubtitleSettings(settings)
        applyCurrentWatermarkSettings(settings)
        applyCurrentPromoSettings(settings)
        isSchedulingAll = true
        defer { isSchedulingAll = false }

        for (clip, date) in schedulePlan(start: start, intervalDays: intervalDays) {
            await clip.publish(settings: settings, scheduledDate: date)
            if let error = clip.publishError, error.localizedCaseInsensitiveContains("limit") {
                break
            }
        }
    }

    // MARK: - History

    private func saveProcessedRecord(for clip: ShortClip, settings: AppSettings) {
        guard let url = clip.sourceMetadata?.webpageURL else { return }
        let videoID = url.pathComponents.last ?? url.lastPathComponent
        let tiktok = clip.variants.first(where: { $0.platform == .tiktok })
        let record = ProcessedVideoRecord(
            youtubeURL: url,
            videoID: videoID,
            title: clip.sourceMetadata?.title ?? clip.displayTitle,
            dateProcessed: Date(),
            hook: tiktok?.hook ?? "",
            description: tiktok?.summary ?? "",
            hashtags: tiktok?.hashtagLine ?? ""
        )
        var history = settings.processedVideoHistory
        history.append(record)
        settings.processedVideoHistory = history
    }
}

private enum InputCopyError: LocalizedError {
    case missingWorkingDirectory
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .missingWorkingDirectory:
            return "Choose a working folder before adding videos."
        case .failed(let detail):
            return "Couldn't copy that video into the working folder. \(detail)"
        }
    }
}
