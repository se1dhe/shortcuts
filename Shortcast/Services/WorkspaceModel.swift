import Foundation
import Observation
import SwiftUI
import AVFoundation

/// Film → thematic essay → editable shorts → release.
@MainActor
@Observable
final class WorkspaceModel {

    enum Phase: Equatable {
        case empty
        case processing
        case transcribing
        case selectingLongformConcept
        case editingLongformSubtitles
        case buildingLongform(fraction: Double, step: String)
        case longformResults
    }

    private(set) var phase: Phase = .empty
    private(set) var job: VideoJob?

    /// Хранит полный транскрипт фильма
    var storedTranscript: Transcript?
    /// Полный анализ фильма с ОДНОЙ главной темой и разбором ИИ — единственный
    /// источник правды про темы; всё остальное выводится из него.
    var thematicAnalysis: ThematicAnalysisResult?
    /// Выбранная тема для ролика
    var selectedConcept: ThematicConcept?
    /// Драматургический разбор сценария от ИИ (производное от thematicAnalysis)
    var thematicReasoning: String? { discoveredConcepts.isEmpty ? nil : thematicAnalysis?.aiReasoning }
    /// Выявленные темы для длинного ролика Shortcast Cinema (производное от thematicAnalysis)
    var discoveredConcepts: [ThematicConcept] {
        guard let analysis = thematicAnalysis,
              let transcript = storedTranscript ?? currentProject?.transcript,
              ThematicAnalysisCache.isReusable(analysis, transcript: transcript) else { return [] }
        let stems = DirectorArtifactGate.groundingStems(
            from: LongformThematicService.stratifiedThematicSample(from: transcript))
        return analysis.allConcepts.filter {
            if case .rejected = DirectorArtifactGate.concept($0, in: stems) { return false }
            return true
        }
    }
    /// Промежуточные параметры эссе для редактора субтитров
    var stagedConcept: ThematicConcept?
    var stagedConfirmedMovieTitle: String?
    var stagedAudioSettings: LongformAudioSettings?
    var stagedArc: LongformNarrativeArc?
    var stagedEssayPlan: EssayPlan?
    /// Результат генерации длинного ролика
    var longformResult: LongformBuildResult?
    /// Прогресс рендеринга длинного видео
    var longformBuildProgress: (fraction: Double, step: String) = (0.0, "")
    /// Идёт ли прямо сейчас повторный анализ сценария моделью Director
    private(set) var isRegeneratingConcepts = false

    /// Активный проект фильма (сохранение прогресса транскрипции, тем и шортсов)
    var currentProject: FilmProject?
    let filmProjectService: any FilmProjectServicing
    let thematicService: any ThematicConceptDiscovering

    init(
        filmProjectService: any FilmProjectServicing = FilmProjectService.shared,
        thematicService: any ThematicConceptDiscovering = LongformThematicService()
    ) {
        self.filmProjectService = filmProjectService
        self.thematicService = thematicService
    }

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

    private(set) var isRefreshingLongformPackaging = false
    private(set) var isRegeneratingLongformCover = false
    private(set) var longformPackagingError: String?
    private var previousLongformCoverTimes: [String: Set<Double>] = [:]
    var isWorkingOnEssayRelease = false

    var isBusy: Bool {
        isRefreshingLongformPackaging || isRegeneratingLongformCover || isWorkingOnEssayRelease || showsPipelineProgress
    }

    /// Only the main pipeline replaces the editor with a full-screen progress
    /// view. Sheet-owned tasks must keep their presenting editor mounted so
    /// their progress, errors and publication receipts remain visible.
    var showsPipelineProgress: Bool {
        switch phase {
        case .processing, .transcribing, .buildingLongform: return true
        default: return false
        }
    }

    /// Holds state while the user is choosing an audio track (when a video has > 1 audio streams).
    var pendingAudioSelection: PendingAudioSelection?

    /// Очищает только состояние фильма, не удаляет файлы и архивы.
    func clearFilmAnalysisState() {
        storedTranscript = nil
        thematicAnalysis = nil
        selectedConcept = nil
        detectedMovie = nil
        longformResult = nil
        stagedConcept = nil
        stagedConfirmedMovieTitle = nil
        stagedAudioSettings = nil
        stagedArc = nil
        stagedEssayPlan = nil
    }

    /// Восстановление идёт присваиванием всех полей, а не только ненулевых:
    /// отсутствие анализа во втором проекте не означает «оставить первый».
    func restoreFilmProjectState(_ project: FilmProject?) {
        clearFilmAnalysisState()
        currentProject = project
        guard let project else { return }
        storedTranscript = project.transcript
        detectedMovie = project.tmdbMetadata
        if let edits = project.longformResult?.arc.captionEdits, !edits.isEmpty {
            do {
                try SubtitleCorrectionStore.shared.update {
                    $0.importEdits(edits, filmKey: subtitleCorrectionFilmKey, language: subtitleCorrectionLanguage)
                }
            } catch { Self.log("Subtitle correction memory import failed: \(error.localizedDescription)") }
        }
        guard let transcript = project.transcript,
              let analysis = project.thematicAnalysis,
              ThematicAnalysisCache.isReusable(analysis, transcript: transcript) else {
            currentProject?.thematicAnalysis = nil
            currentProject?.discoveredConcepts = []
            currentProject?.selectedConcept = nil
            if let analysis = project.thematicAnalysis, let transcript = project.transcript,
               ThematicAnalysisCache.hasMatchingSource(analysis, transcript: transcript) {
                longformResult = project.longformResult
                stagedAudioSettings = project.longformResult?.audioSettings
            } else {
                currentProject?.longformResult = nil
            }
            Self.log("Cached thematic analysis requires regeneration for '\(project.movieTitle)'; transcript retained")
            return
        }
        thematicAnalysis = analysis
        if let selected = project.selectedConcept,
           SelectedThemeAnalysisResolver.matches(analysis, selection: selected) {
            selectedConcept = selected
        } else {
            selectedConcept = analysis.primaryConcept
        }
        if let result = project.longformResult,
           result.arc.concept.word.caseInsensitiveCompare(analysis.primaryConcept.word) == .orderedSame {
            longformResult = LongformPackagingService.updatingText(result)
            currentProject?.longformResult = longformResult
            stagedAudioSettings = result.audioSettings
        }
    }

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
        pipelineTask?.cancel()
        restoreFilmProjectState(nil)
        job = nil
        pendingAudioSelection = nil
        errorMessage = nil
        pipelineError = nil

        // Clean up previous run leftovers

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
            if MediaExtractor.needsNormalization(sandboxFriendlyURL) {
                inputPreparationMessage = "Preparing \(sandboxFriendlyURL.pathExtension.uppercased()) for playback…"
            }
            normalizedInputURL = try await MediaExtractor.normalizeInputIfNeeded(
                from: sandboxFriendlyURL,
                workingDirectory: settings.workingDirectory ?? sandboxFriendlyURL.deletingLastPathComponent(),
                selectedAudioStreamIndex: selectedAudioStreamIndex)

        } catch {
            errorMessage = error.localizedDescription
            inputPreparationMessage = nil
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
            phase = .empty
            return
        }

        // Загружаем проект без переноса состояния предыдущего фильма.
        if var existingProject = try? await filmProjectService.loadProject(for: sandboxFriendlyURL) {
            if let trackId = selectedAudioStreamIndex, existingProject.selectedAudioTrackId != trackId {
                existingProject.selectedAudioTrackId = trackId
                existingProject.transcript = nil
                existingProject.thematicAnalysis = nil
                existingProject.discoveredConcepts = []
                existingProject.selectedConcept = nil
                existingProject.longformResult = nil
                try? await filmProjectService.saveProject(existingProject)
            }
            restoreFilmProjectState(existingProject)

            // Проверяем сохраненные метаданные фильма на предмет старых галлюцинаций LLM
            let fileQuery = MovieMetadataService.parseCandidate(originalBaseName)
            if let m = existingProject.tmdbMetadata {
                let hasValidFileTitle = !fileQuery.title.isEmpty && !MovieMetadataService.isGarbageTitle(fileQuery.title)
                let matchesTitle = m.title.localizedCaseInsensitiveContains(fileQuery.title) ||
                    (fileQuery.originalTitle.map { m.title.localizedCaseInsensitiveContains($0) } ?? false) ||
                    (m.originalTitle.map { $0.localizedCaseInsensitiveContains(fileQuery.title) } ?? false)
                let isPlaceholder = m.overview.isEmpty && (m.posterURL == nil)

                if hasValidFileTitle && !matchesTitle && isPlaceholder {
                    Self.log("Discarding mismatched cached movie metadata: '\(m.title)' vs filename candidate '\(fileQuery.title)'")
                    self.detectedMovie = nil
                    self.currentProject?.tmdbMetadata = nil
                } else {
                    self.detectedMovie = m
                }
            }
            Self.log("Loaded cached FilmProject: \(existingProject.movieTitle) (\(existingProject.discoveredConcepts.count) concepts)")
        } else {
            let project = FilmProject(
                sourceMovieURL: sandboxFriendlyURL,
                movieFileName: originalBaseName,
                movieTitle: effectiveSourceMetadata?.title ?? originalBaseName,
                durationSeconds: newJob.durationSeconds,
                fileSizeBytes: (try? sandboxFriendlyURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) },
                selectedAudioTrackId: selectedAudioStreamIndex
            )
            self.currentProject = project
            // Архив на диске есть, но мы его не прочитали: пустой проект стёр бы
            // тему и результат последнего рендера. Держим его, ничего не сохраняем.
            let unreadableArchiveOnDisk = await filmProjectService.hasStoredProjectFile(matching: sandboxFriendlyURL)
            if unreadableArchiveOnDisk {
                Self.log("Unreadable project archive kept for '\(originalBaseName)': blank project is not written to disk")
            } else {
                try? await filmProjectService.saveProject(project)
            }
        }

        let task = Task {
            await self.startLongformPipeline(job: newJob, modelManager: modelManager, settings: settings)
        }
        pipelineTask = task
        await task.value
    }

    // MARK: - Theme persistence

    /// Создаёт координатор монтажа с проброшенным шлюзом к прогретому Director'у.
    /// `LongformActTitleService` получает `MomentFinderService` через `DirectorChatGateway`:
    /// модель переиспользуется уже прогретая, без повторной холодной загрузки (политика RAM).
    private func makeLongformCoordinator(modelManager: ModelManager, settings: AppSettings) -> LongformPipelineCoordinator {
        let gateway = makeDirectorGateway(modelManager: modelManager)
        let actTitleService = LongformActTitleService(model: gateway)
        return LongformPipelineCoordinator(thumbnailGenerator: LongformPackagingService.makeThumbnailGenerator(modelManager: modelManager, movie: detectedMovie),
            actTitling: actTitleService,
            editorialReview: makeEditorialReview(model: gateway),
            discussionURL: LongformEditorialSupport.telegramURL(channelID: settings.telegramChannelId), modelManager: modelManager)
    }

    var subtitleCorrectionFilmKey: String {
        if let movie = detectedMovie ?? currentProject?.tmdbMetadata { return "movie:\(movie.id)" }
        let title = currentProject?.longformResult?.arc.movieTitle ?? stagedConfirmedMovieTitle
            ?? currentProject?.movieTitle ?? job?.effectiveTitle ?? ""
        return "title:" + SubtitleCorrectionMemory.key(title).lowercased()
    }

    var subtitleCorrectionLanguage: String { storedTranscript?.language?.lowercased() ?? "uk" }

    private func makeEditorialReview(model: any LongformActTitleModeling) -> LongformEditorialReview {
        let memory: SubtitleCorrectionMemory
        do { memory = try SubtitleCorrectionStore.shared.load() }
        catch {
            Self.log("Subtitle correction memory load failed: \(error.localizedDescription)")
            memory = SubtitleCorrectionMemory()
        }
        return LongformEditorialReview(model: model, correctionMemory: memory,
            correctionFilmKey: subtitleCorrectionFilmKey, correctionLanguage: subtitleCorrectionLanguage)
    }

    func refreshLongformPackaging(modelManager: ModelManager) async {
        guard !isRefreshingLongformPackaging, let original = longformResult,
              let source = job?.url ?? currentProject?.sourceMovieURL else { return }
        isRefreshingLongformPackaging = true
        longformPackagingError = nil
        let projectID = currentProject?.id
        defer { isRefreshingLongformPackaging = false }
        let generator = LongformPackagingService.makeThumbnailGenerator(modelManager: modelManager, movie: detectedMovie ?? currentProject?.tmdbMetadata)
        do {
            let updated = try await LongformPackagingService(thumbnailGenerator: generator).refresh(original, sourceURL: source)
            guard currentProject?.id == projectID, longformResult?.outputURL == original.outputURL else { return }
            longformResult = updated
            longformPackagingError = updated.packagingWarning
            if var project = currentProject {
                project.longformResult = updated
                try await filmProjectService.saveProject(project)
                currentProject = project
            }
        } catch is CancellationError { }
        catch { longformPackagingError = error.localizedDescription }
    }

    func regenerateLongformCover(modelManager: ModelManager) async {
        guard !isRefreshingLongformPackaging, !isRegeneratingLongformCover,
              let original = longformResult,
              let source = job?.url ?? currentProject?.sourceMovieURL else { return }
        isRegeneratingLongformCover = true
        longformPackagingError = nil
        let projectID = currentProject?.id
        let resultKey = original.outputURL.standardizedFileURL.path
        var excludedTimes = previousLongformCoverTimes[resultKey] ?? []
        if let currentTime = original.thumbnailSubject?.sourceTime { excludedTimes.insert(currentTime) }
        defer { isRegeneratingLongformCover = false }

        let generator = LongformPackagingService.makeThumbnailGenerator(
            modelManager: modelManager, movie: detectedMovie ?? currentProject?.tmdbMetadata)
        do {
            let updated = try await LongformPackagingService(thumbnailGenerator: generator)
                .regenerateCover(original, sourceURL: source, avoidingTimes: Array(excludedTimes))
            guard currentProject?.id == projectID,
                  longformResult?.outputURL == original.outputURL else { return }
            if let sourceTime = updated.thumbnailSubject?.sourceTime {
                previousLongformCoverTimes[resultKey, default: []].insert(sourceTime)
            }
            longformResult = updated
            longformPackagingError = nil
            if var project = currentProject {
                project.longformResult = updated
                try await filmProjectService.saveProject(project)
                currentProject = project
            }
        } catch is CancellationError { }
        catch { longformPackagingError = error.localizedDescription }
    }

    private func makeDirectorGateway(modelManager: ModelManager) -> DirectorChatGateway {
        DirectorChatGateway(
            readiness: { [weak modelManager] in await modelManager?.momentFinder.isReady ?? false },
            identifier: { [weak modelManager] in await modelManager?.momentFinder.profile.modelID },
            completion: { [weak modelManager] instructions, prompt, maxTokens in
                await modelManager?.momentFinder.completeForActTitles(
                    instructions: instructions,
                    prompt: prompt,
                    maxTokens: maxTokens
                )
            }
        )
    }

    /// Единственная точка, которая пишет состояние темы в архив: анализ, выбранная
    /// тема, транскрипт и результат рендера копируются в проект все вместе, одним сохранением.
    /// Раздельные записи и рождали рассинхрон «тема в проекте не та, что анализ».
    func persistThemeState(reason: String) async {
        guard var project = currentProject else {
            Self.log("persistThemeState(\(reason)): no current project, theme not persisted")
            return
        }
        project.thematicAnalysis = thematicAnalysis
        project.selectedConcept = selectedConcept
        project.longformResult = longformResult
        // Сохраняем транскрипт вместе с темой: при reopen проекта Whisper не
        // перезапускается, и без этой записи longformResult терял основание.
        project.transcript = storedTranscript
        project.discoveredConcepts = thematicAnalysis?.allConcepts ?? project.discoveredConcepts
        currentProject = project
        let savedSource = thematicAnalysis?.source.rawValue ?? "nil"
        Self.log("persistThemeState(\(reason)): theme '\(selectedConcept?.word ?? "—")' saved with analysis source=\(savedSource)")
        do {
            try await filmProjectService.saveProject(project)
        } catch {
            Self.log("persistThemeState(\(reason)) failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Long-form Flow (YouTube 16:9 Thematic Essays in Shortcast Cinema style)

    private func resolveLongformAnalysis(
        for concept: ThematicConcept,
        transcript: Transcript,
        movieTitle: String,
        userPlan: EssayPlan?,
        modelManager: ModelManager,
        settings: AppSettings
    ) async throws -> ThematicAnalysisResult {
        let cached = thematicAnalysis
        let sourceURL = job?.url
        let analysis = try await SelectedThemeAnalysisResolver.resolve(
            selection: concept, cached: cached, transcript: transcript, userPlan: userPlan
        ) {
            try await self.thematicService.planThematicAnalysis(
                for: concept, candidates: cached?.allConcepts ?? [concept],
                from: transcript, movieTitle: movieTitle,
                movieOverview: self.detectedMovie?.overview,
                modelManager: modelManager,
                directorProfile: settings.copywriterModel.directorProfile)
        }
        try Task.checkCancellation()
        guard job?.url == sourceURL else { throw CancellationError() }
        if let old = longformResult,
           old.arc.concept.word.caseInsensitiveCompare(analysis.primaryConcept.word) != .orderedSame
            || old.arc.concept.philosophicalPremise != analysis.primaryConcept.philosophicalPremise {
            // Старое видео остаётся в Exports, но не выдаётся за результат нового тезиса.
            longformResult = nil
        }
        thematicAnalysis = analysis
        selectedConcept = analysis.primaryConcept
        stagedEssayPlan = analysis.essayPlan
        return analysis
    }

    private func startLongformPipeline(job newJob: VideoJob, modelManager: ModelManager, settings: AppSettings) async {
        self.job = newJob
        self.pipelineError = nil
        // Не затираем longformResult, если проект уже имеет сохранённый результат:
        // при reopen проекта пользователь должен увидеть готовое эссе, а не пустой экран.
        if currentProject?.longformResult == nil {
            self.longformResult = nil
        }

        // МГНОВЕННЫЙ СТАРТ: если проект уже имеет транскрипт Whisper и анализ,
        // реально выданный моделью, открываем экран выбора концепта мгновенно
        // (0.01 сек), без повторного Whisper и Director.
        if let existingAnalysis = self.thematicAnalysis ?? self.currentProject?.thematicAnalysis,
           let cachedTranscript = self.storedTranscript ?? self.currentProject?.transcript,
           ThematicAnalysisCache.isReusable(existingAnalysis, transcript: cachedTranscript) {
            self.storedTranscript = cachedTranscript
            self.thematicAnalysis = existingAnalysis
            if self.selectedConcept == nil {
                self.selectedConcept = self.currentProject?.selectedConcept ?? existingAnalysis.primaryConcept
            }
            if let movie = self.detectedMovie ?? self.currentProject?.tmdbMetadata {
                self.detectedMovie = movie
                progressTracker.updateMovieDetection(
                    title: movie.title,
                    year: movie.year,
                    imdb: movie.imdbRating,
                    rottenTomatoes: movie.rottenTomatoesScore)
            }
            Self.log("Instantly loaded cached thematic analysis for '\(newJob.effectiveTitle)': primary concept '\(existingAnalysis.primaryConcept.word)'")
            if let result = longformResult, FileManager.default.fileExists(atPath: result.outputURL.path) {
                self.phase = .longformResults
            } else {
                self.phase = .selectingLongformConcept
            }
            return
        }
        if let staleAnalysis = self.thematicAnalysis ?? self.currentProject?.thematicAnalysis,
           staleAnalysis.source != .llm {
            Self.log("Discarding non-model thematic analysis (source=\(staleAnalysis.source.rawValue)) for '\(newJob.effectiveTitle)': Director must re-derive the theme")
        }

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
                    // Задействуем Director LLM в выбранном пользователем профиле
                    await modelManager.prepareDirector(profile: settings.copywriterModel.directorProfile)
                    if let inferred = await modelManager.momentFinder.detectMovieFromTranscript(sample: sampleDialogue, candidateTitle: initialCandidate) {
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
                                imdbRating: nil,
                                rottenTomatoesScore: nil,
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

            // 3. Выявление философских тем: кэш годен только когда анализ реально
            // выдала модель, иначе обязан отработать Director.
            let analysis: ThematicAnalysisResult
            if let existing = self.thematicAnalysis ?? self.currentProject?.thematicAnalysis,
               ThematicAnalysisCache.isReusable(existing, transcript: transcript) {
                analysis = existing
                self.thematicAnalysis = existing
                if self.selectedConcept == nil {
                    self.selectedConcept = existing.primaryConcept
                }
                Self.log("Reusing model-produced thematic analysis for '\(effectiveMovieTitle)': \(existing.primaryConcept.word)")
            } else {
                progressTracker.startStoryAnalysis()
                // Тема, не полученная от модели, не подставляется: ошибка уходит
                // в catch ниже, и эссе не откроется с выдуманным лейтмотивом.
                analysis = try await thematicService.discoverThematicAnalysis(
                    from: transcript,
                    movieTitle: effectiveMovieTitle,
                    movieOverview: movie?.overview,
                    modelManager: modelManager,
                    directorProfile: settings.copywriterModel.directorProfile
                )
                guard ThematicAnalysisCache.isReusable(analysis, transcript: transcript) else {
                    throw ThematicDiscoveryError.noGroundedTheme("анализ не подтверждён текущим транскриптом")
                }
                // Новое редакторское решение требует нового рендера. Старый файл остаётся в Exports.
                self.longformResult = nil
                self.thematicAnalysis = analysis
                // АВТОНОМНЫЙ ВЫБОР: модель сама выбирает и предлагает ОДНУ главную тему
                self.selectedConcept = analysis.primaryConcept
                Self.log("Director produced thematic analysis for '\(effectiveMovieTitle)': \(analysis.primaryConcept.word) (source=\(analysis.source.rawValue))")
                if analysis.source == .llm {
                    await persistThemeState(reason: "director-analysis")
                }
            }
            self.phase = .selectingLongformConcept
        } catch {
            errorMessage = "Ошибка подготовки длинного видео: \(error.localizedDescription)"
            phase = .empty
        }
    }

    /// Переход в окно редактирования субтитров из Whisper перед финальным монтажом кино-эссе
    func openLongformSubtitleEditor(
        _ concept: ThematicConcept,
        confirmedMovieTitle: String? = nil,
        audioSettings: LongformAudioSettings = LongformAudioSettings(),
        essayPlan: EssayPlan? = nil,
        settings: AppSettings,
        modelManager: ModelManager
    ) {
        guard let transcript = storedTranscript else { return }
        self.stagedConcept = concept
        self.stagedConfirmedMovieTitle = confirmedMovieTitle
        self.stagedAudioSettings = audioSettings
        self.stagedEssayPlan = essayPlan

        let candidate = (confirmedMovieTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let finalMovieTitle: String
        if !candidate.isEmpty && !MovieMetadataService.isGarbageTitle(candidate) {
            finalMovieTitle = candidate
        } else if let detected = detectedMovie?.title, !MovieMetadataService.isGarbageTitle(detected) {
            finalMovieTitle = detected
        } else if let jobTitle = job?.effectiveTitle, !jobTitle.isEmpty && !MovieMetadataService.isGarbageTitle(jobTitle) {
            finalMovieTitle = jobTitle
        } else {
            finalMovieTitle = "Фильм"
        }

        pipelineTask?.cancel()
        phase = .buildingLongform(fraction: 0.01, step: "Проверка сцен выбранной темы...")
        pipelineTask = Task {
            do {
                let analysis = try await resolveLongformAnalysis(
                    for: concept, transcript: transcript, movieTitle: finalMovieTitle,
                    userPlan: essayPlan, modelManager: modelManager, settings: settings)
                let narrativeDirector = LongformNarrativeDirector()
                var selectedMoments = analysis.selectedMoments
                
                // Семантическая валидация таймкодов
                let validator = SemanticTimecodeValidator()
                let validations = validator.validateAll(moments: selectedMoments, transcript: transcript)
                for validation in validations {
                    if let index = selectedMoments.firstIndex(where: { $0.id == validation.moment.id }) {
                        var moment = selectedMoments[index]
                        switch validation.confidence {
                        case .high: moment.semanticConfidence = .high
                        case .medium: moment.semanticConfidence = .medium
                        case .low: moment.semanticConfidence = .low
                        }
                        selectedMoments[index] = moment
                    }
                }
                
                let builtArc = try await narrativeDirector.buildArc(
                    from: transcript,
                    concept: analysis.primaryConcept,
                    selectedMoments: selectedMoments,
                    movieTitle: finalMovieTitle,
                    targetDuration: analysis.essayPlan?.effectiveTargetDuration ?? EssayDurationPolicy.defaultRenderedTarget,
                    essayPlan: analysis.essayPlan,
                    sourceMovieURL: self.currentProject?.sourceMovieURL
                )
                try Task.checkCancellation()
                try await modelManager.requireDirector(profile: settings.copywriterModel.directorProfile)
                let gateway = makeDirectorGateway(modelManager: modelManager)
                let reviewed = await makeEditorialReview(model: gateway).review(arc: builtArc,
                    transcript: transcript, coldOpenEnabled: audioSettings.coldOpenEnabled)
                let titled = await LongformActTitleService(model: gateway).applyTitles(to: reviewed,
                    transcript: transcript, movieTitle: finalMovieTitle, progress: nil)
                try Task.checkCancellation()
                self.stagedArc = titled.arc
                self.phase = .editingLongformSubtitles
            } catch {
                if Task.isCancelled { return }
                self.phase = .selectingLongformConcept
                self.errorMessage = "Ошибка построения арки: \(error.localizedDescription)"
            }
        }
    }

    /// Возврат из редактора субтитров обратно к выбору темы
    func returnToConceptSelection() {
        self.phase = .selectingLongformConcept
    }

    /// Подтверждение отредактированных субтитров и запуск пайплайна генерации
    func confirmLongformSubtitlesAndBuild(
        updatedSegments: [TranscriptSegment],
        modelManager: ModelManager,
        settings: AppSettings
    ) {
        if let stored = storedTranscript {
            stagedArc?.captionEdits = LongformEditorialSupport.captionEdits(
                original: stored.segments, updated: updatedSegments)
        }
        guard let concept = stagedConcept, let audioSettings = stagedAudioSettings else { return }
        confirmLongformConceptInternal(
            concept,
            confirmedMovieTitle: stagedConfirmedMovieTitle,
            audioSettings: audioSettings,
            essayPlan: stagedEssayPlan,
            approvedArc: stagedArc,
            modelManager: modelManager,
            settings: settings
        )
    }

    func confirmLongformConcept(
        _ concept: ThematicConcept,
        confirmedMovieTitle: String? = nil,
        audioSettings: LongformAudioSettings = LongformAudioSettings(),
        essayPlan: EssayPlan? = nil,
        modelManager: ModelManager,
        settings: AppSettings
    ) {
        confirmLongformConceptInternal(
            concept,
            confirmedMovieTitle: confirmedMovieTitle,
            audioSettings: audioSettings,
            essayPlan: essayPlan,
            modelManager: modelManager,
            settings: settings
        )
    }

    func confirmLongformConcept(
        _ concept: ThematicConcept,
        confirmedMovieTitle: String? = nil,
        backgroundMusicURL: URL? = nil,
        musicVolume: Float = 0.28,
        duckingEnabled: Bool = true,
        essayPlan: EssayPlan? = nil,
        modelManager: ModelManager,
        settings: AppSettings
    ) {
        let audioSettings = LongformAudioSettings(
            backgroundMusicURL: backgroundMusicURL,
            musicVolume: musicVolume,
            duckingEnabled: duckingEnabled
        )
        confirmLongformConceptInternal(
            concept,
            confirmedMovieTitle: confirmedMovieTitle,
            audioSettings: audioSettings,
            essayPlan: essayPlan,
            modelManager: modelManager,
            settings: settings
        )
    }

    /// Перерендер готового кино-эссе с исправленными субтитрами (сохраняя тот же монтаж сцен и звук)
    func rebuildLongformWithUpdatedSubtitles(
        updatedSegments: [TranscriptSegment],
        existingResult: LongformBuildResult,
        modelManager: ModelManager,
        settings: AppSettings
    ) {
        var editedArc = existingResult.arc
        if let stored = storedTranscript {
            editedArc.captionEdits = LongformEditorialSupport.captionEdits(
                original: stored.segments, updated: updatedSegments)
        }
        startLongformRebuild(
            concept: existingResult.arc.concept,
            existingArc: editedArc,
            modelManager: modelManager,
            settings: settings,
            initialStep: "Перерендер видео с обновленными субтитрами...",
            errorPrefix: "Ошибка перерендера кино-эссе"
        )
    }

    /// Запрашивает у Director новый план сцен на ту же тему, затем собирает его в монтаж.
    func regenerateLongformFromScratch(
        concept: ThematicConcept,
        movieTitle: String,
        modelManager: ModelManager,
        settings: AppSettings
    ) {
        pipelineTask?.cancel()
        Self.log("regenerateLongformFromScratch: concept=\(concept.word) movie=\(movieTitle)")
        // Сброс кэша анализа обязателен: иначе resolver переиспользует старый пул
        // и кнопка лишь повторно отрендерит те же сцены, не вызывая модель.
        thematicAnalysis = nil
        stagedEssayPlan = nil
        confirmLongformConceptInternal(
            concept,
            confirmedMovieTitle: movieTitle,
            audioSettings: stagedAudioSettings ?? LongformAudioSettings(),
            essayPlan: nil,
            modelManager: modelManager,
            settings: settings
        )
    }

    /// Перерендер кино-эссе с обрезанными актами: титры, склейки и музыка пересчитываются по новой длительности.
    func rebuildLongformWithModifiedArc(
        modifiedArc: LongformNarrativeArc,
        existingResult: LongformBuildResult,
        modelManager: ModelManager,
        settings: AppSettings
    ) {
        self.stagedArc = modifiedArc
        Self.log("rebuildLongformWithModifiedArc: acts=\(modifiedArc.acts.count) duration=\(modifiedArc.totalDuration)")
        startLongformRebuild(
            concept: existingResult.arc.concept,
            existingArc: modifiedArc,
            modelManager: modelManager,
            settings: settings,
            initialStep: "Перерендер монтажа с обрезанными актами...",
            errorPrefix: "Ошибка перерендера монтажа"
        )
    }

    /// Runs the Director's editorial pass on the current montage draft without starting a render.
    func reviewLongformEditorDraft(
        _ draft: LongformNarrativeArc,
        modelManager: ModelManager,
        settings: AppSettings
    ) async throws -> LongformNarrativeArc {
        guard let transcript = storedTranscript ?? currentProject?.transcript else {
            throw NSError(domain: "LongformEditorialReview", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Транскрипт фильма недоступен."])
        }
        try await modelManager.requireDirector(profile: settings.copywriterModel.directorProfile)
        let gateway = makeDirectorGateway(modelManager: modelManager)
        let coldOpenEnabled = longformResult?.audioSettings?.coldOpenEnabled
            ?? stagedAudioSettings?.coldOpenEnabled ?? true
        return await makeEditorialReview(model: gateway).review(
            arc: draft, transcript: transcript, coldOpenEnabled: coldOpenEnabled)
    }

    func improveLongform(existingResult: LongformBuildResult, modelManager: ModelManager, settings: AppSettings) {
        startLongformRebuild(concept: existingResult.arc.concept, existingArc: existingResult.arc,
            modelManager: modelManager, settings: settings,
            initialStep: "Редакторская проверка диалогов и границ сцен...",
            errorPrefix: "Ошибка редакторской пересборки", editorialPass: true)
    }

    private func startLongformRebuild(
        concept: ThematicConcept,
        existingArc: LongformNarrativeArc,
        modelManager: ModelManager,
        settings: AppSettings,
        initialStep: String,
        errorPrefix: String,
        editorialPass: Bool = false
    ) {
        guard let currentJob = job, let transcript = storedTranscript else { return }
        pipelineTask?.cancel()

        let finalMovieTitle = detectedMovie?.title ?? (currentJob.effectiveTitle.isEmpty ? "Фильм" : currentJob.effectiveTitle)
        let audioSettings = stagedAudioSettings ?? longformResult?.audioSettings ?? LongformAudioSettings()
        let workDir = settings.outputDirectory ?? settings.workingDirectory ?? currentJob.url.deletingLastPathComponent()

        phase = .buildingLongform(fraction: 0.10, step: initialStep)

        pipelineTask = Task {
            do {
                var renderArc = existingArc
                if editorialPass {
                    try await modelManager.requireDirector(profile: settings.copywriterModel.directorProfile)
                    let gateway = makeDirectorGateway(modelManager: modelManager)
                    renderArc = await makeEditorialReview(model: gateway)
                        .review(arc: existingArc, transcript: transcript, coldOpenEnabled: audioSettings.coldOpenEnabled)
                    let titled = await LongformActTitleService(model: gateway).applyTitles(to: renderArc,
                        transcript: transcript, movieTitle: finalMovieTitle, progress: nil)
                    renderArc = titled.arc
                    try Task.checkCancellation()
                }
                // Пробрасываем модель в LongformActTitleService через DirectorChatGateway
                let coordinator = self.makeLongformCoordinator(modelManager: modelManager, settings: settings)
                let selectedMoments = self.thematicAnalysis?.selectedMoments ?? []
                let result = try await coordinator.buildLongformVideo(
                    sourceURL: currentJob.url,
                    movieTitle: finalMovieTitle,
                    transcript: transcript,
                    concept: concept,
                    selectedMoments: selectedMoments,
                    essayPlan: stagedEssayPlan ?? thematicAnalysis?.essayPlan,
                    audioSettings: audioSettings,
                    existingArc: renderArc,
                    workingDirectory: workDir,
                    channelLogoEnabled: settings.channelLogoWatermarkEnabled
                ) { [weak self] frac, step in
                    Task { @MainActor in
                        self?.longformBuildProgress = (frac, step)
                        self?.phase = .buildingLongform(fraction: frac, step: step)
                    }
                }
                self.longformResult = result
                self.selectedConcept = concept
                await self.persistThemeState(reason: "longform-rebuild")
                self.phase = .longformResults
            } catch {
                if Task.isCancelled { return }
                self.errorMessage = "\(errorPrefix): \(error.localizedDescription)"
                self.phase = .longformResults
            }
        }
    }

    private func confirmLongformConceptInternal(
        _ concept: ThematicConcept,
        confirmedMovieTitle: String? = nil,
        audioSettings: LongformAudioSettings,
        essayPlan: EssayPlan? = nil,
        approvedArc: LongformNarrativeArc? = nil,
        modelManager: ModelManager,
        settings: AppSettings
    ) {
        guard let currentJob = job, let transcript = storedTranscript else { return }
        errorMessage = nil
        self.selectedConcept = concept
        self.stagedAudioSettings = audioSettings
        self.stagedEssayPlan = essayPlan

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
                imdbRating: nil,
                rottenTomatoesScore: nil,
                posterURL: nil,
                backdropURL: nil,
                overview: "",
                characters: [],
                director: nil,
                genres: []
            )
        }

        phase = .buildingLongform(fraction: 0.05, step: "Подготовка видеомонтажа...")

        let workDir = settings.outputDirectory ?? settings.workingDirectory ?? currentJob.url.deletingLastPathComponent()

        pipelineTask?.cancel()
        pipelineTask = Task {
            do {
                let analysis = try await resolveLongformAnalysis(
                    for: concept, transcript: transcript, movieTitle: finalMovieTitle,
                    userPlan: essayPlan, modelManager: modelManager, settings: settings)
                await persistThemeState(reason: "selected-theme-analysis")
                try Task.checkCancellation()
                if approvedArc == nil {
                    self.phase = .buildingLongform(fraction: 0.08, step: "Подготовка редакторской проверки сцен...")
                    try await modelManager.requireDirector(profile: settings.copywriterModel.directorProfile)
                }
                let coordinator = self.makeLongformCoordinator(modelManager: modelManager, settings: settings)
                let result = try await coordinator.buildLongformVideo(
                    sourceURL: currentJob.url,
                    movieTitle: finalMovieTitle,
                    transcript: transcript,
                    concept: analysis.primaryConcept,
                    selectedMoments: analysis.selectedMoments,
                    essayPlan: analysis.essayPlan,
                    audioSettings: audioSettings,
                    existingArc: approvedArc,
                    workingDirectory: workDir,
                    channelLogoEnabled: settings.channelLogoWatermarkEnabled
                ) { [weak self] frac, step in
                    Task { @MainActor in
                        self?.longformBuildProgress = (frac, step)
                        self?.phase = .buildingLongform(fraction: frac, step: step)
                    }
                }
                try Task.checkCancellation()
                self.longformResult = result
                LongformHistoryService.shared.markConceptGenerated(
                    movieTitle: finalMovieTitle, conceptWord: analysis.primaryConcept.word)
                await self.persistThemeState(reason: "longform-render")
                self.phase = .longformResults
            } catch is CancellationError {
                // A reset or a new render explicitly cancels this task. Do not
                // replace the new screen state with a spurious export error.
                return
            } catch {
                if Task.isCancelled { return }
                self.errorMessage = "Ошибка монтажа длинного ролика: \(error.localizedDescription)"
                self.phase = .selectingLongformConcept
            }
        }
    }

    /// Возврат к выбору темы для текущего фильма без повторной обработки видео и Whisper
    func chooseAnotherConcept() {
        self.longformResult = nil
        self.selectedConcept = nil
        self.phase = .selectingLongformConcept
    }

    /// Повторный запуск генерации тем нейросетью Director в выбранном профиле модели
    func regenerateThematicConcepts(modelManager: ModelManager, directorProfile: ChatModelProfile) async {
        guard let transcript = storedTranscript, !isRegeneratingConcepts else { return }
        // Флаг держится всё время анализа — Director считает минуты, а не 1.2 секунды.
        isRegeneratingConcepts = true
        defer { isRegeneratingConcepts = false }
        let effectiveTitle = detectedMovie?.title ?? job?.effectiveTitle ?? "Фильм"
        let overview = detectedMovie?.overview
        let projectID = currentProject?.id

        do {
            let freshAnalysis = try await thematicService.discoverThematicAnalysis(
                from: transcript,
                movieTitle: effectiveTitle,
                movieOverview: overview,
                modelManager: modelManager,
                directorProfile: directorProfile
            )
            guard currentProject?.id == projectID,
                  storedTranscript.flatMap({ ThematicAnalysisCache.fingerprint(of: $0) })
                    == ThematicAnalysisCache.fingerprint(of: transcript) else { return }
            guard ThematicAnalysisCache.isReusable(freshAnalysis, transcript: transcript) else {
                throw ThematicDiscoveryError.noGroundedTheme("анализ не подтверждён текущим транскриптом")
            }
            self.longformResult = nil
            self.thematicAnalysis = freshAnalysis
            self.selectedConcept = freshAnalysis.primaryConcept
            Self.log("Director regenerated themes for '\(effectiveTitle)': \(freshAnalysis.primaryConcept.word) (source=\(freshAnalysis.source.rawValue))")
            if freshAnalysis.source == .llm {
                await persistThemeState(reason: "director-regenerate")
            }
        } catch {
            errorMessage = "Ошибка подбора тем: \(error.localizedDescription)"
            Self.log("regenerateThematicConcepts failed: \(error.localizedDescription)")
        }
    }

    func cancelLongformSelection() {
        if self.longformResult != nil {
            // Если эссе уже было собрано ранее, просто возвращаемся к просмотру результата
            self.phase = .longformResults
        } else {
            self.thematicAnalysis = nil
            self.selectedConcept = nil
                self.phase = .empty
        }
    }

    func resetLongform() {
        self.longformResult = nil
        self.thematicAnalysis = nil
        self.selectedConcept = nil
        self.stagedEssayPlan = nil
        self.storedTranscript = nil
        self.detectedMovie = nil
        self.phase = .empty
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
            return copy
        } catch {
            throw InputCopyError.failed(error.localizedDescription)
        }
    }

    // MARK: - Timing logs (stderr + ~/Library/Logs/Shortcast/director.log)

    nonisolated static func log(_ message: String) {
        DirectorRunLog.write(message, source: "pipeline")
    }

    /// Formatted seconds elapsed between two dates (defaults `to` = now).
    nonisolated static func elapsed(since start: Date, to end: Date = Date()) -> String {
        String(format: "%.1fs", end.timeIntervalSince(start))
    }

    // MARK: - Reset

    /// Returns to the empty drop state and cleans up temp files.
    func startOver() {
        pipelineTask?.cancel()
        job = nil
        errorMessage = nil
        pipelineError = nil
        // Состояние эссе чистим обязательно: иначе второй фильм стартует с темой,
        // транскриптом и рендером первого.
        thematicAnalysis = nil
        selectedConcept = nil
        longformResult = nil
        storedTranscript = nil
        stagedConcept = nil
        stagedConfirmedMovieTitle = nil
        stagedAudioSettings = nil
        stagedArc = nil
        stagedEssayPlan = nil
        detectedMovie = nil
        isRegeneratingConcepts = false
        currentProject = nil
        phase = .empty
    }


}
enum InputCopyError: LocalizedError {
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
