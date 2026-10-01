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
        case caption   // short video → captions → publish (the original flow)
        case youtube   // search YouTube → download → use the long-video flow

        var id: String { rawValue }

        var title: LocalizedStringKey {
            switch self {
            case .caption: "Caption a short"
            case .shorts:  "Сделать шортсы из фильма"
            case .youtube: "Find on YouTube"
            }
        }

        var dropTitle: LocalizedStringKey {
            switch self {
            case .caption: "Drop a short video here"
            case .shorts:  "Перетащите фильм сюда"
            case .youtube: "Find a YouTube video"
            }
        }

        var dropSubtitle: LocalizedStringKey {
            switch self {
            case .caption: "Up to 60 seconds — a TikTok, Reel or Short"
            case .shorts:  "Полный фильм — нейросеть найдет сюжетные арки, нарежет 1:1, наложит сабы и сведет звук"
            case .youtube: "Search by topic, download a result, then edit it like any long video"
            }
        }

        var symbol: String {
            switch self {
            case .caption: "film.stack"
            case .shorts:  "scissors"
            case .youtube: "magnifyingglass"
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
    }

    private(set) var phase: Phase = .empty
    private(set) var job: VideoJob?

    /// The three proposed posts (single-video flow). Bound by the result cards.
    var variants: [PostVariant] = []
    private(set) var detectedLanguage: String?

    /// The generated shorts (long-video flow).
    var clips: [ShortClip] = []

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
        case .processing, .transcribing, .findingMoments: return true
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

    // MARK: - Entry

    /// Validates a dropped file and routes to the right flow based on length.
    func process(
        url: URL,
        sourceMetadata: VideoSourceMetadata? = nil,
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

        // Delete any leftover from the previous run.
        cleanUpTempInput()

        // Copy the input file into the working directory so every downstream
        // consumer (AVAsset, Gemma4VideoProcessor, etc.) has unrestricted file-
        // system access regardless of sandbox-scope or external-volume quirks.
        let sandboxFriendlyURL: URL
        do {
            sandboxFriendlyURL = try copyInputIntoWorkingDirectory(url, settings: settings)
        } catch {
            errorMessage = error.localizedDescription
            inputPreparationMessage = nil
            phase = .empty
            return
        }

        let normalizedInputURL: URL
        do {
            if MediaExtractor.needsNormalization(sandboxFriendlyURL) {
                inputPreparationMessage = "Converting \(sandboxFriendlyURL.pathExtension.uppercased()) to MP4…"
            }
            normalizedInputURL = try await MediaExtractor.normalizeInputIfNeeded(
                from: sandboxFriendlyURL,
                workingDirectory: settings.workingDirectory ?? sandboxFriendlyURL.deletingLastPathComponent())
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

        let newJob: VideoJob
        do {
            newJob = try await MediaExtractor.makeJob(
                from: normalizedInputURL,
                sourceMetadata: sourceMetadata)
        } catch {
            errorMessage = error.localizedDescription
            cleanUpTempInput()
            phase = .empty
            return
        }

        switch inputMode {
        case .caption:
            await processPrecutShort(job: newJob, modelManager: modelManager, settings: settings)
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
                    await self.detectAndApplyMovieCinema(for: clip, modelManager: modelManager,
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
            let movie = await movieMetadata.resolveMovie(
                filename: job.fileName,
                sourceTitle: job.sourceMetadata?.title)
            self.detectedMovie = movie
            if let movie {
                progressTracker.updateMovieDetection(
                    title: movie.title,
                    year: movie.year,
                    imdb: movie.imdbRating,
                    rottenTomatoes: movie.rottenTomatoesScore)
            }

            // 1. Stage 2: Transcript (5% -> 45%)
            phase = .transcribing
            progressTracker.startTranscription(totalSeconds: job.durationSeconds)
            let t0 = Date()
            let transcript = try await transcription.transcript(
                for: job.url, languageHint: settings.languageOverride,
                modelCacheDir: settings.workingDirectory?.appendingPathComponent("huggingface")) { @Sendable [weak self] sec in
                    Task { @MainActor in
                        self?.progressTracker.updateTranscriptionProgress(processedSeconds: sec)
                    }
                }
            // Trust the language of the actual text over Whisper's 30s auto-detect.
            let captionLanguage = transcript.contentLanguage ?? transcript.language
            progressTracker.updateTranscriptionProgress(processedSeconds: job.durationSeconds)
            Self.log("transcript ready in \(Self.elapsed(since: t0)) — whisper=\(transcript.language ?? "?"), text=\(captionLanguage ?? "?")")
            try Task.checkCancellation()

            // 2. Stage 3: Find narrative & character arcs (45% -> 65%)
            phase = .findingMoments
            progressTracker.startStoryAnalysis()
            let t1 = Date()
            await modelManager.prepareDirector(profile: settings.copywriterModel.directorProfile)
            Self.log("director ready in \(Self.elapsed(since: t1)) — \(settings.copywriterModel.directorProfile.displayName)")

            let movieTitle = movie?.title ?? job.fileName
            let useInlineCaptions = settings.copywriterModel.usesInlineCaptions

            // 2.5. Scene detection — analyze video for scene boundaries so the
            // LLM picks COMPLETE scenes instead of cross-cutting from different
            // parts of the movie.
            var sceneMap: String?
            do {
                let scenes = try await SceneDetectionService.detectScenes(in: job.url)
                if scenes.count > 1 {
                    sceneMap = SceneDetectionService.formatForPrompt(
                        scenes: scenes, transcriptDuration: job.durationSeconds)
                    Self.log("scene detection: found \(scenes.count) scenes")
                }
            } catch {
                Self.log("scene detection skipped: \(error.localizedDescription)")
            }

            let t2 = Date()
            let candidates = try await modelManager.momentFinder.findMoments(
                transcript: transcript.srtLike(),
                includeCaptions: useInlineCaptions,
                language: captionLanguage,
                styleExamples: settings.styleExamples,
                videoTitle: movieTitle,
                videoDescription: movie?.overview ?? (job.sourceMetadata?.description ?? ""),
                sceneMap: sceneMap)
            
            progressTracker.updateStoryAnalysis(fraction: 1.0, arcFound: candidates.first?.overlay)
            Self.log("found \(candidates.count) moment(s) in \(Self.elapsed(since: t2)), captions inline=\(useInlineCaptions)")
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
                appearance.moodProfile = candidate.mood
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
                if let m = movie {
                    newClip.detectedMovieTitle = m.title
                    newClip.detectedMovieYear = m.year
                    newClip.imdbRating = m.imdbRating
                    newClip.rottenTomatoesScore = m.rottenTomatoesScore
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

            // 3+4. Cut, then caption, each clip in turn (one MLX engine → serial).
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

    /// Full cinema pipeline for a pre-cut YouTube Short: detects the film from
    /// source metadata (TMDB + on-device model fallback), then applies the
    /// cinema hook, description, and hashtags automatically — so the user sees
    /// the correct «🎬 Title (Year)» hook immediately without clicking Regenerate.
    ///
    /// Only runs when `sourceMetadata` is present and has a webpage URL (i.e.
    /// the clip came from a YouTube download, not a local file drop).
    private func detectAndApplyMovieCinema(
        for clip: ShortClip,
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

        guard !sourceText.isEmpty else { return }

        // 1. Try fast title guessing via regex first.
        var query = CinemaContentGenerator.movieTitleGuess(from: sourceText)

        // 2. If regex guessing was incomplete or missed the release year, use the on-device AI model
        //    to parse the text for the film name and year.
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
            Self.log("detectAndApplyMovieCinema: could not guess or detect a movie title")
            return
        }

        Self.log("detectAndApplyMovieCinema: querying TMDB for \"\(searchQuery.title)\" \(searchQuery.year ?? "")")

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

        CinemaContentGenerator.apply(
            content: result.content,
            to: clip,
            replaceHook: true,       // ← write the cinema hook into variant.hook + overlayText
            saveToHistory: false,    // history is already saved by captionClip
            settings: nil)

        Self.log("detectAndApplyMovieCinema: applied cinema content for \"\(result.query.title)\" (\(result.query.year ?? ""))")
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
