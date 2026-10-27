import Foundation
import Gemma4Swift
import HuggingFace
import MLX
import MLXLMCommon
import MLXHuggingFace
import MLXVLM
import Observation
import Tokenizers

/// The "Director": owns the Qwen 3.5 9B text model and turns a full transcript
/// into a ranked list of viral clip candidates in one pass.
///
/// Adapted from Hermes-Jarvis' MLXChatService, stripped of skills/tools, draft
/// models and speculative decoding — this is single-shot structured generation.
/// Qwen 3.5 9B's huge context window swallows an hour-long transcript at once,
/// so there is no chunking. Thinking is forced OFF.
@MainActor
@Observable
final class MomentFinderService {

    enum Phase: Equatable {
        case idle
        case downloading(fraction: Double)
        case loading
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private var container: ModelContainer?

    /// The single in-flight download/load. Callers join it rather than reading
    /// `container == nil` as "ready" — that race is what let the essay theme
    /// silently fall back to the hardcoded tables.
    private var loadTask: Task<Void, Never>?

    /// Bumped whenever the selection changes so an in-flight load can tell it is
    /// stale and must not install its container.
    private var loadGeneration = 0

    /// Generation whose load ended in `.failed`. A joined waiter must not turn a
    /// failure into a retry loop inside one call; the next call (or a retry from
    /// the UI) gets the fresh attempt.
    private var failedGeneration: Int?

    /// Which model plays the Director. Defaults to Qwen 3.5 9B; switched to match
    /// the user's pick via `setProfile(_:)` before the model loads.
    private(set) var profile = ChatModelProfile.qwen35_9b

    var isReady: Bool { container != nil }
    var isBusy: Bool {
        switch phase {
        case .downloading, .loading: return true
        default: return false
        }
    }

    /// Why the last load failed, else nil. Without it a caller that only sees
    /// `isReady == false` can't tell "still loading" from "download refused".
    var loadFailureDescription: String? {
        if case .failed(let message) = phase { return message }
        return nil
    }

    var displayName: String { profile.displayName }

    init() {
        // Cap MLX's Metal buffer cache so long sessions don't balloon RAM.
        MLX.Memory.cacheLimit = 1024 * 1024 * 1024
    }

    // MARK: - Lifecycle

    /// Switches the Director model. If a different model is already loaded, it's
    /// unloaded so the next `prepareIfNeeded()` brings up the new one.
    func setProfile(_ newProfile: ChatModelProfile) {
        guard newProfile.modelID != profile.modelID else { return }
        if container != nil { unload() }
        profile = newProfile
        loadGeneration += 1
    }

    /// Downloads (if needed) and loads the selected Director model and BLOCKS
    /// until the outcome is known. Safe to call repeatedly and concurrently: a
    /// second caller waits for the in-flight load instead of returning early
    /// with `container == nil`, and a `.failed` phase falls through so a later
    /// call really retries the download rather than no-oping.
    func prepareIfNeeded() async {
        var joinedInFlightLoad = false
        while container == nil, let inflight = loadTask {
            await inflight.value
            joinedInFlightLoad = true
        }
        guard container == nil else { return }
        if joinedInFlightLoad, case .failed = phase, failedGeneration == loadGeneration {
            return
        }

        let requested = profile
        let generation = loadGeneration
        let task = Task { @MainActor in
            await self.load(requested, generation: generation)
            // Cleared as the task's last act, so a joiner that resumes after it
            // sees "no load in flight" and can start a fresh attempt if needed.
            loadTask = nil
        }
        loadTask = task
        await task.value
    }

    /// One download + load pass for `requested`. Kept separate from
    /// `prepareIfNeeded()` so the in-flight bookkeeping has a single owner.
    private func load(_ requested: ChatModelProfile, generation: Int) async {
        phase = .downloading(fraction: 0)

        do {
            let downloader = #hubDownloader()
            let localDir = try await downloader.download(
                id: requested.modelID,
                revision: nil,
                matching: ["*.safetensors", "*.json", "*.txt", "*.jinja"],
                useLatest: false,
                progressHandler: { [weak self] progress in
                    Task { @MainActor in
                        guard let self else { return }
                        let f = progress.fractionCompleted
                        self.phase = f < 1.0 ? .downloading(fraction: f) : .loading
                    }
                })

            phase = .loading
            // Both models feed plain text and generate via ChatSession; they only
            // differ in how the container is built.
            let loaded: ModelContainer
            switch requested.loader {
            case .vlm:
                // Qwen 3.5 9B ships only as a VLM package on HF → VLMModelFactory.
                // No chat-template patch is needed for plain text generation.
                loaded = try await VLMModelFactory.shared.loadContainer(
                    from: localDir, using: #huggingFaceTokenizerLoader())
            case .gemma4Text:
                // Gemma 4 isn't in mlx-swift-lm's registry — register the custom
                // "gemma4" type (text-only: we never pass it media) and load with
                // the package's tokenizer loader.
                await Gemma4Registration.register(multimodal: false)
                loaded = try await loadModelContainer(
                    from: localDir, using: Gemma4TokenizerLoader())
            }

            guard generation == loadGeneration else {
                // The user picked another model while this was running; publishing
                // this container would silently run the wrong Director.
                phase = .idle
                Self.log("director load discarded (profile changed mid-load): \(requested.modelID)")
                return
            }
            container = loaded
            failedGeneration = nil
            phase = .ready
            Self.log("director loaded: \(requested.displayName) (\(requested.modelID))")
        } catch {
            Self.log("director load FAILED for \(requested.modelID): \(error)")
            phase = .failed(error.localizedDescription)
            failedGeneration = generation
        }
    }

    /// Frees the loaded model and its Metal cache. Used by ModelManager to make
    /// room for the Gemma copywriter on memory-constrained Macs.
    func unload() {
        container = nil
        phase = .idle
        failedGeneration = nil
        loadGeneration += 1
        MLX.Memory.clearCache()
    }

    func resetForRetry() {
        if case .failed = phase { phase = .idle }
    }

    // MARK: - Generation

    /// Runs one pass over the full transcript and returns ranked clip candidates.
    /// Builds a fresh session per call so one video's KV never leaks into the next.
    ///
    /// When `includeCaptions` is true, the same pass also writes each clip's
    /// 3-platform caption package — so no separate captioning step is needed.
    func findMoments(
        transcript: String,
        includeCaptions: Bool = false,
        language: String? = nil,
        styleExamples: String = "",
        videoTitle: String = "",
        videoDescription: String = "",
        sceneMap: String? = nil,
        isComedy: Bool = false
    ) async throws -> [ClipCandidate] {
        guard let container else { throw MomentFinderError.notReady }

        let s = profile.sampling
        var params = GenerateParameters(
            // Captions per clip need much more room than bare moments — a long
            // video can yield 5-6 clips, each with three platforms' caption
            // package (Instagram alone wants 20-30 hashtags). 6144 covers that;
            // the repetition penalty stops runaway loops from filling it.
            maxTokens: includeCaptions ? 6144 : s.maxTokens,
            temperature: s.temperature,
            topP: s.topP,
            topK: s.topK,
            minP: s.minP,
            repetitionPenalty: s.repetitionPenalty)
        params.maxKVSize = s.maxKVSize
        params.kvBits = s.kvBits

        let instructions = CinemaMomentDirector.cinemaSystemPrompt(
            movieTitle: videoTitle,
            language: language,
            sceneMap: sceneMap,
            isComedy: isComedy)
        
        let maxChunkSize = 35000
        let chunks: [String]
        if transcript.count > maxChunkSize {
            Self.log("Transcript too long (\(transcript.count) chars), chunking into \(maxChunkSize) character parts")
            var currentChunks: [String] = []
            var currentIndex = transcript.startIndex
            while currentIndex < transcript.endIndex {
                let nextIndex = transcript.index(currentIndex, offsetBy: maxChunkSize, limitedBy: transcript.endIndex) ?? transcript.endIndex
                
                var chunkEnd = nextIndex
                if nextIndex < transcript.endIndex {
                    if let range = transcript.range(of: "\n", options: .backwards, range: currentIndex..<nextIndex) {
                        chunkEnd = range.upperBound
                    }
                }
                
                let chunkText = String(transcript[currentIndex..<chunkEnd])
                currentChunks.append(chunkText)
                currentIndex = chunkEnd
            }
            chunks = currentChunks
        } else {
            chunks = [transcript]
        }
        
        var allClips: [ClipCandidate] = []
        
        for chunk in chunks {
            let userPrompt = CinemaMomentDirector.cinemaUserPrompt(
                transcript: chunk,
                movieTitle: videoTitle,
                sceneMap: sceneMap,
                isComedy: isComedy)

            Self.log("findMoments: chunk \(chunk.count) chars, using CinemaMomentDirector, isComedy=\(isComedy), sceneMap=\(sceneMap != nil)")

            // The model occasionally returns malformed JSON or prose instead of the
            // arc array, which parses to zero clips. Nudge it and retry up to twice
            // before giving up on this chunk.
            var clips: [ClipCandidate] = []
            let maxAttempts = 3
            for attempt in 1...maxAttempts {
                let prompt = attempt == 1
                    ? userPrompt
                    : userPrompt + "\n\nУВАГА: попередня відповідь була невалідною. Відповідь ТІЛЬКИ валідним JSON-масивом об'єктів без markdown, без пояснень і без тексту до або після масиву."

                let session = ChatSession(
                    container,
                    instructions: instructions,
                    generateParameters: params,
                    additionalContext: ["enable_thinking": false])

                var raw = ""
                for try await token in session.streamResponse(to: prompt) {
                    raw += token
                }
                Self.log("findMoments raw output (attempt \(attempt), \(raw.count) chars):\n\(raw)")

                let arcs = CinemaMomentDirector.parseArcs(from: raw, isComedy: isComedy)
                clips = arcs.map { $0.toClipCandidate() }
                Self.log("findMoments: parsed \(clips.count) clip(s) from chunk (attempt \(attempt))")
                if !clips.isEmpty { break }
            }
            allClips.append(contentsOf: clips)
        }
        
        allClips.sort { $0.viralScore > $1.viralScore }
        if allClips.count > 6 {
            allClips = Array(allClips.prefix(6))
        }

        guard !allClips.isEmpty else { throw MomentFinderError.noClips }
        return allClips
    }

    nonisolated static func log(_ message: String) {
        DirectorRunLog.write(message)
    }

    /// Captions one clip from its transcript slice (the text-only Copywriter
    /// path). Reuses the social-content-coach prompt and the standard variant
    /// parser, so it returns the same `GenerationResult` shape as Gemma.
    func caption(
        transcriptSlice: String,
        hook: String,
        languageOverride: String,
        styleExamples: String,
        videoTitle: String = "",
        videoDescription: String = ""
    ) async throws -> GenerationResult {
        guard let container else { throw MomentFinderError.notReady }

        let s = profile.sampling
        var params = GenerateParameters(
            maxTokens: 1536,
            temperature: s.temperature,
            topP: s.topP,
            topK: s.topK,
            minP: s.minP,
            repetitionPenalty: s.repetitionPenalty)
        params.maxKVSize = s.maxKVSize
        params.kvBits = s.kvBits

        let session = ChatSession(
            container,
            instructions: PromptBuilder.buildTranscriptPrompt(
                languageOverride: languageOverride, styleExamples: styleExamples,
                videoTitle: videoTitle, videoDescription: videoDescription),
            generateParameters: params,
            additionalContext: ["enable_thinking": false])

        let user = Self.userPromptForCaption(hook: hook, transcriptSlice: transcriptSlice, language: languageOverride,
                                              videoTitle: videoTitle, videoDescription: videoDescription)
        var raw = ""
        for try await chunk in session.streamResponse(to: user) {
            raw += chunk
        }
        Self.log("caption raw output (\(raw.count) chars):\n\(raw)")
        return try JSONVariantParser.parse(raw)
    }

    /// Asks the Director to infer movie metadata from the title/year and any source context.
    /// Used as a fallback when TMDB has no result.
    func inferMovie(query: CinemaContentGenerator.MovieSearchQuery, sourceText: String) async -> TMDBMovie? {
        guard let container else {
            Self.log("inferMovie skipped: no model container loaded")
            return nil
        }

        let s = profile.sampling
        var params = GenerateParameters(
            maxTokens: 1024,
            temperature: 0.3,
            topP: s.topP,
            topK: s.topK,
            minP: s.minP,
            repetitionPenalty: s.repetitionPenalty)
        params.maxKVSize = s.maxKVSize
        params.kvBits = s.kvBits

        let instructions = """
        You are a concise movie database. The user gives a movie or TV series title and year, plus optional context from a video source.
        Return ONLY a valid JSON object with this exact shape:
        {"title":"original or Ukrainian title","year":"YYYY","genres":["genre1","genre2"],"cast":["actor1","actor2","actor3"],"director":"director name"}
        Use Ukrainian names for people and genres if possible. If you do not know the work, return {"title":"","year":"","genres":[],"cast":[],"director":""}.
        """

        let session = ChatSession(
            container,
            instructions: instructions,
            generateParameters: params,
            additionalContext: ["enable_thinking": false])

        let yearPart = query.year?.trimmed.isEmpty == false ? " (\(query.year!.trimmed))" : ""
        let userPrompt = "Title: \"\(query.title.trimmed)\"\(yearPart)\n\nContext:\n\(sourceText.prefix(1000))\n\nReturn JSON metadata."

        do {
            var raw = ""
            for try await chunk in session.streamResponse(to: userPrompt) {
                raw += chunk
            }
            Self.log("inferMovie raw output (\(raw.count) chars):\n\(raw)")
            return parseMovieInference(raw, fallbackTitle: query.title, fallbackYear: query.year)
        } catch {
            Self.log("inferMovie failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Writes a short, engaging description of the actual scene from the clip's
    /// transcript, on-device. Used for the "scene" description mode. Returns nil
    /// when no model is loaded or the transcript is empty, so the caller can fall
    /// back to the movie synopsis.
    func describeScene(transcriptSlice: String, movieTitle: String, language: String?) async -> String? {
        let transcript = transcriptSlice.trimmed
        guard let container, !transcript.isEmpty else {
            Self.log("describeScene skipped: \(container == nil ? "no model" : "empty transcript")")
            return nil
        }

        let s = profile.sampling
        var params = GenerateParameters(
            maxTokens: 400,
            temperature: 0.6,
            topP: s.topP,
            topK: s.topK,
            minP: s.minP,
            repetitionPenalty: s.repetitionPenalty)
        params.maxKVSize = s.maxKVSize
        params.kvBits = s.kvBits

        let resolved = Self.resolvedPromptLanguage(language)
        let titlePart = movieTitle.trimmed.isEmpty ? "" : " (фільм: \(movieTitle.trimmed))"
        let instructions: String
        switch resolved {
        case .ru:
            instructions = """
            Ты пишешь короткое описание сцены из фильма для подписи в соцсетях (TikTok/Reels/Shorts).
            По реплике/диалогу из клипа опиши, что происходит в сцене: 2-3 живых предложения, интригующе, без спойлеров концовки.
            Пиши по-русски. Верни ТОЛЬКО текст описания, без хэштегов, без кавычек, без пояснений.
            """
        case .uk:
            instructions = """
            Ти пишеш короткий опис сцени з фільму для підпису в соцмережах (TikTok/Reels/Shorts).
            За реплікою/діалогом із кліпу опиши, що відбувається у сцені: 2-3 живих речення, інтригуюче, без спойлерів фіналу.
            Пиши українською. Поверни ТІЛЬКИ текст опису, без хештегів, без лапок, без пояснень.
            """
        case .en:
            instructions = """
            You write a short scene description for a social caption (TikTok/Reels/Shorts).
            From the clip's dialogue, describe what happens in the scene: 2-3 vivid sentences, intriguing, no ending spoilers.
            Return ONLY the description text — no hashtags, no quotes, no explanations.
            """
        }

        let session = ChatSession(
            container,
            instructions: instructions,
            generateParameters: params,
            additionalContext: ["enable_thinking": false])

        let userPrompt = "Транскрипція кліпу\(titlePart):\n\(transcript.prefix(2000))"

        do {
            var raw = ""
            for try await chunk in session.streamResponse(to: userPrompt) {
                raw += chunk
            }
            let cleaned = raw
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"«»"))
                .trimmed
            Self.log("describeScene output (\(cleaned.count) chars)")
            return cleaned.isEmpty ? nil : cleaned
        } catch {
            Self.log("describeScene failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Identifies the film/series (title + release year) from a YouTube Shorts'
    /// own title and description. Used to prefill the "Movie metadata" fields and
    /// the default hook — the raw video title is usually too noisy to parse with
    /// regex alone. Returns nil when no model is loaded or nothing is identified.
    func detectMovieFromMetadata(title: String, description: String, language: String?) async -> (title: String, year: String)? {
        guard let container else {
            Self.log("detectMovieFromMetadata skipped: no model loaded")
            return nil
        }
        let source = "\(title)\n\(description)".trimmed
        guard !source.isEmpty else { return nil }

        let s = profile.sampling
        var params = GenerateParameters(
            maxTokens: 200,
            temperature: 0.1,
            topP: s.topP,
            topK: s.topK,
            minP: s.minP,
            repetitionPenalty: s.repetitionPenalty)
        params.maxKVSize = s.maxKVSize
        params.kvBits = s.kvBits

        let instructions = """
        You identify the ORIGINAL film or TV series from a YouTube Shorts title and description \
        (these are clips of foreign movies with Ukrainian dub). \
        Return ONLY a JSON object: {"title":"movie title","year":"YYYY"}. \
        Prefer the Ukrainian-release title when the clip is in Ukrainian. \
        Give the year the film/series was released. \
        If you cannot identify it, return {"title":"","year":""}. No other text.
        """

        let session = ChatSession(
            container,
            instructions: instructions,
            generateParameters: params,
            additionalContext: ["enable_thinking": false])

        let userPrompt = "Title: \(title)\nDescription: \(description.prefix(800))\n\nReturn the JSON."

        do {
            var raw = ""
            for try await chunk in session.streamResponse(to: userPrompt) {
                raw += chunk
            }
            Self.log("detectMovieFromMetadata output: \(raw.prefix(200))")
            guard let jsonString = JSONVariantParser.extractJSONObject(from: raw),
                  let root = JSONVariantParser.deserializeTolerant(jsonString) as? [String: Any] else {
                return nil
            }
            let detectedTitle = (root["title"] as? String)?.trimmed ?? ""
            let detectedYear = (root["year"] as? String)?.trimmed
                ?? (root["year"] as? Int).map(String.init)
                ?? ""
            guard !detectedTitle.isEmpty else { return nil }
            return (detectedTitle, detectedYear)
        } catch {
            Self.log("detectMovieFromMetadata failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Identifies the movie/series (title + year) from dialogue lines and quotes in the transcript.
    func detectMovieFromTranscript(sample: String, candidateTitle: String? = nil) async -> (title: String, year: String)? {
        guard let container else {
            Self.log("detectMovieFromTranscript skipped: no model loaded")
            return nil
        }
        let cleanedSample = sample.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedSample.isEmpty else { return nil }

        let s = profile.sampling
        var params = GenerateParameters(
            maxTokens: 200,
            temperature: 0.1,
            topP: s.topP,
            topK: s.topK,
            minP: s.minP,
            repetitionPenalty: s.repetitionPenalty)
        params.maxKVSize = s.maxKVSize
        params.kvBits = s.kvBits

        let instructions = """
        You are an expert film scholar. Given spoken dialogue lines, character names, and quotes from a movie's transcript, \
        identify the exact movie or TV series and its release year. \
        Return ONLY a JSON object: {"title":"Movie Title","year":"YYYY"}. \
        Prefer the Ukrainian title if the dialogue is in Ukrainian, or the original title. \
        If you cannot identify the movie with certainty, return {"title":"","year":""}. No other text.
        """

        let session = ChatSession(
            container,
            instructions: instructions,
            generateParameters: params,
            additionalContext: ["enable_thinking": false])

        var promptParts: [String] = []
        if let candidate = candidateTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !candidate.isEmpty {
            promptParts.append("Candidate title from filename or metadata: \"\(candidate)\". Verify if the dialogue matches this film or identify the correct one.")
        }
        promptParts.append("Movie dialogue sample:\n\"\"\"\n\(cleanedSample.prefix(2500))\n\"\"\"")
        promptParts.append("Return JSON:")
        let userPrompt = promptParts.joined(separator: "\n\n")

        do {
            var raw = ""
            for try await chunk in session.streamResponse(to: userPrompt) {
                raw += chunk
            }
            Self.log("detectMovieFromTranscript output: \(raw.prefix(200))")
            guard let jsonString = JSONVariantParser.extractJSONObject(from: raw),
                  let root = JSONVariantParser.deserializeTolerant(jsonString) as? [String: Any] else {
                return nil
            }
            let detectedTitle = (root["title"] as? String)?.trimmed ?? ""
            let detectedYear = (root["year"] as? String)?.trimmed
                ?? (root["year"] as? Int).map(String.init)
                ?? ""
            guard !detectedTitle.isEmpty, !MovieMetadataService.isGarbageTitle(detectedTitle) else {
                return nil
            }
            return (detectedTitle, detectedYear)
        } catch {
            Self.log("detectMovieFromTranscript failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Глубоко анализирует полный срез сценария по всем 4 актам и выбирает ОДНУ главную тему эссе с разбором ИИ
    ///
    /// Every failure is an error, never a nil: the caller cannot tell "the model
    /// chose this" from "the model was never asked" otherwise, and the pipeline
    /// used to paper over it with the hardcoded theme tables.
    func analyzeThematicCore(
        transcriptSample: String,
        movieTitle: String,
        movieOverview: String? = nil
    ) async throws -> ThematicAnalysisResult {
        guard let container else {
            Self.log("analyzeThematicCore: no model loaded")
            throw ThematicDiscoveryError.directorUnavailable("модель не завантажена")
        }
        let sample = transcriptSample.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sample.isEmpty else { throw ThematicDiscoveryError.transcriptEmpty }

        let s = profile.sampling
        var params = GenerateParameters(
            maxTokens: Self.thematicMaxTokens,
            temperature: 0.35,
            topP: s.topP,
            topK: s.topK,
            minP: s.minP,
            repetitionPenalty: s.repetitionPenalty)
        params.maxKVSize = s.maxKVSize
        params.kvBits = s.kvBits

        let instructions = LongformThematicService.thematicSystemPrompt(movieTitle: movieTitle)

        // The overview is prompt material too: cap it so it can't eat the budget
        // the transcript was sized for.
        let overview = (movieOverview?.trimmed ?? "").prefix(Self.thematicOverviewCharCap)
        let headerChars = Self.thematicFrameCharOverhead + overview.count
        let budgetChars = Self.thematicContextBudgetChars(
            maxKVSize: s.maxKVSize, maxTokens: Self.thematicMaxTokens, headerChars: headerChars)

        // Never `prefix(_:)` the tail away: thin every act evenly so the third
        // act still reaches the model when the transcript exceeds the budget.
        let (dialogue, lineStride) = Self.downsampleChronologically(sample, to: budgetChars)

        var promptParts: [String] = ["Фільм: «\(movieTitle)»"]
        if !overview.isEmpty {
            promptParts.append("Синопсис/сюжет фільму:\n\"\"\"\n\(overview)\n\"\"\"")
        }
        // Критически важно: явно объясняем модели формат таймкодов.
        // Без этой инструкции LLM интерпретирует `[754.5]` как абстрактное число
        // и выдаёт моменты кластерами в первых ~130 секундах вместо распределения
        // по всему фильму (проблема: 10 моментов ~1 с каждый в первые 132 с фильма 9700 с).
        promptParts.append("Зріз ключових діалогів фільму (хронологічно по всьому сюжету, таймкоди — секунди від початку фільму, наприклад [754.5] означає 12 хвилин 34.5 секунди):\n\"\"\"\n\(dialogue)\n\"\"\"")
        promptParts.append("""
            Обери ОДНУ ГОЛОВНУ тему есе (primaryConcept), докладно обґрунтуй вибір (aiReasoning).
            Склади план есе (essayPlan): thesis, 3 hookVariants, 2 ctaVariants, actFocus для form/psychology/philosophy/catharsis.
            ВИЗНАЧ 16-24 КОНКРЕТНИХ МОМЕНТІВ для монтажу (selectedMoments) з точними таймкодами.
            Кожен момент — цілісна сцена 20-60 с; сумарна тривалість усіх сцен — 720-900 с.
            Кожному моменту признач actRole (hook|form|psychology|philosophy|catharsis), supports і featured.
            Розподіляй сцени за РОЛЛЮ В ІСТОРІЇ, а не рівномірно по хронометражу: хук може бути з будь-якої частини фільму.
            ТАЙМКОДИ — секунди від початку фільму: якщо дія біля діалогу [754.5], то startTime ≈ 754.5.
            Запропонуй альтернативні грані (alternativeConcepts).
            Поверни СУВОРО валідний JSON-об'єкт у форматі системної інструкції.
            """)
        let userPrompt = promptParts.joined(separator: "\n\n")

        let estimatedPromptTokens = Int(Double(userPrompt.count + instructions.count) / Self.approxCharsPerToken)
        Self.log("""
            analyzeThematicCore: profile=\(profile.displayName) maxKVSize=\(s.maxKVSize.map { "\($0)" } ?? "nil") \
            budget=\(budgetChars) chars sample=\(sample.count)→\(dialogue.count) chars (stride \(lineStride)) \
            maxTokens=\(Self.thematicMaxTokens) estPromptTokens=\(estimatedPromptTokens)
            """)

        // Same shape as `findMoments`: the model sometimes answers with prose or
        // broken JSON, so nudge and retry before declaring it a failure.
        var latestText: String?
        var lastError: (any Error)?
        let maxAttempts = 3
        for attempt in 1...maxAttempts {
            let prompt = attempt == 1
                ? userPrompt
                : userPrompt + "\n\nУВАГА: попередня відповідь була невалідною або обірваною. Скороти reasoning до 300 символів, почни об'єкт з primaryConcept і поверни ТІЛЬКИ валідний JSON-об'єкт без markdown, без пояснень і без тексту до або після об'єкта."

            let session = ChatSession(
                container,
                instructions: instructions,
                generateParameters: params,
                additionalContext: ["enable_thinking": false])

            do {
                var raw = ""
                for try await chunk in session.streamResponse(to: prompt) {
                    raw += chunk
                }
                Self.log("analyzeThematicCore attempt \(attempt): \(raw.count) chars")
                guard !raw.trimmed.isEmpty else { continue }
                latestText = raw
                DirectorRunLog.dumpRaw(raw, attempt: attempt)
                if let parsed = LongformThematicService.parseThematicAnalysis(from: raw) {
                    Self.log(
                        "analyzeThematicCore attempt \(attempt): theme '\(parsed.primaryConcept.word)' with \(parsed.selectedMoments.count) moment(s)"
                    )
                    // Спеллчекер украинского: коррекция concept.word через LLM (Задача 1)
                    var corrected = parsed
                    let correctedPrimary = await self.correctConceptWord(corrected.primaryConcept)
                    corrected.primaryConcept = correctedPrimary
                    corrected.alternativeConcepts = await withTaskGroup(of: (Int, ThematicConcept).self) { group in
                        var results: [(Int, ThematicConcept)] = []
                        for (index, concept) in corrected.alternativeConcepts.enumerated() {
                            group.addTask { (index, await self.correctConceptWord(concept)) }
                        }
                        for await result in group { results.append(result) }
                        return results.sorted { $0.0 < $1.0 }.map { $0.1 }
                    }
                    return corrected
                }
                Self.log(
                    "analyzeThematicCore attempt \(attempt): unparseable, head: \(raw.prefix(200))"
                )
            } catch {
                lastError = error
                Self.log("analyzeThematicCore attempt \(attempt) failed: \(error.localizedDescription)")
            }
        }

        if let text = latestText {
            throw ThematicDiscoveryError.unparseableOutput(String(text.prefix(200)))
        }
        if let error = lastError {
            Self.log("analyzeThematicCore: every attempt errored")
            throw error
        }
        throw ThematicDiscoveryError.modelReturnedNoText
    }

    /// Сырой ответ модели на произвольный промпт — для второго прохода по материалу актов,
    /// где парсер и повторы живёт в вызывающем сервисе. Возвращает `nil`, когда модель не
    /// загружена или поток не дал ни одного куска: вызывающий трактует это как «нет LLM».
    func completeForActTitles(instructions: String, prompt: String, maxTokens: Int) async -> String? {
        guard let container else {
            Self.log("completeForActTitles: no model loaded — falling back to transcript-line titles")
            return nil
        }
        let session = ChatSession(
            container,
            instructions: instructions,
            generateParameters: GenerateParameters(
                maxTokens: maxTokens,
                temperature: 0.35,
                topP: profile.sampling.topP,
                topK: profile.sampling.topK,
                minP: profile.sampling.minP,
                repetitionPenalty: profile.sampling.repetitionPenalty),
            additionalContext: ["enable_thinking": false])
        var raw = ""
        do {
            for try await chunk in session.streamResponse(to: prompt) {
                raw += chunk
            }
        } catch {
            Self.log("completeForActTitles stream failed: \(error.localizedDescription)")
            return raw.trimmed.isEmpty ? nil : raw
        }
        return raw.trimmed.isEmpty ? nil : raw
    }

    /// Chars/token measured on the real Blade Runner 2049 corpus (~3.9 for this
    /// Cyrillic/Ukrainian mix); 3.7 keeps the estimate pessimistic so the rotating
    /// KV cache never trips mid-prompt and silently eats the first acts.
    nonisolated static let approxCharsPerToken = 3.7

    /// Tokens the thematic call burns on framing: system prompt, section headers
    /// and the chat template. Increased to 1500 for chain-of-thought reasoning.
    nonisolated static let thematicPromptOverheadTokens = 1_500

    /// Assumed token budget when a profile leaves KV unbounded (`maxKVSize == nil`).
    /// Increased to 40k tokens for ~100-120k character context (M3 18GB RAM limit).
    nonisolated static let unboundedKVTokenBudget = 40_000

    /// Room for chain-of-thought reasoning + primaryConcept + selectedMoments + 3 alternatives as JSON.
    /// Increased from 3072 to 8192 for detailed analysis and moment selection.
    nonisolated static let thematicMaxTokens = 8_192

    nonisolated static let thematicOverviewCharCap = 2_000

    /// Non-transcript characters in the user prompt (title line, section headers,
    /// the closing instruction).
    nonisolated static let thematicFrameCharOverhead = 900

    /// Transcript character budget that provably fits the profile's KV window
    /// together with the generation cap — `maxKVSize` is a rotation point, not a
    /// context window, so anything larger silently loses the head of the film.
    nonisolated static func thematicContextBudgetChars(
        maxKVSize: Int?,
        maxTokens: Int,
        headerChars: Int
    ) -> Int {
        let kvTokens = maxKVSize ?? unboundedKVTokenBudget
        let transcriptTokens = max(1_024, kvTokens - maxTokens - thematicPromptOverheadTokens)
        let rawChars = Int(Double(transcriptTokens) * approxCharsPerToken)
        return max(2_000, rawChars - headerChars)
    }

    /// Even-stride thinning over the WHOLE chronology; the first and the last
    /// line always survive, unlike a head cut that drops the payoff.
    nonisolated static func downsampleChronologically(
        _ sample: String,
        to budgetChars: Int
    ) -> (text: String, stride: Int) {
        let budget = max(1, budgetChars)
        guard sample.count > budget else { return (sample, 1) }

        let lines = sample.components(separatedBy: "\n")
        guard lines.count > 1 else { return (String(sample.prefix(budget)), 1) }

        var thin = max(2, Int(ceil(Double(sample.count) / Double(budget))))
        while thin < lines.count {
            var indices = Array(stride(from: 0, to: lines.count, by: thin))
            if indices.last != lines.count - 1 { indices.append(lines.count - 1) }
            let text = indices.map { lines[$0] }.joined(separator: "\n")
            if text.count <= budget { return (text, thin) }
            thin += max(1, thin / 2)
        }
        let text = [lines.first ?? "", lines.last ?? ""].joined(separator: "\n")
        return (String(text.prefix(budget)), lines.count)
    }

    private func parseMovieInference(_ raw: String, fallbackTitle: String, fallbackYear: String?) -> TMDBMovie? {
        guard let jsonString = JSONVariantParser.extractJSONObject(from: raw),
              let root = JSONVariantParser.deserializeTolerant(jsonString) as? [String: Any]
        else { return nil }

        let title = (root["title"] as? String)?.trimmed ?? fallbackTitle
        let year = (root["year"] as? String)?.trimmed ?? fallbackYear ?? ""
        let genres = stringArray(root["genres"])
        let cast = stringArray(root["cast"])
        let director = (root["director"] as? String)?.trimmed

        guard !title.isEmpty else { return nil }
        return TMDBMovie(title: title, year: year, genres: genres, overview: "", cast: cast, director: director)
    }

    /// Исправляет украинское слово/тему через LLM, возвращая правильное литературное слово.
    /// Используется для коррекции неологизмов и русизмов, которые модель может генерировать.
    func correctUkrainianWord(_ word: String, context: String? = nil) async -> String? {
        guard let container else {
            Self.log("correctUkrainianWord: no model loaded")
            return nil
        }

        let instructions = """
        Ти — експерт з української літературної мови. Твоє завдання — виправити слово або фразу на правильну українську літературну форму.
        
        ПРАВИЛА:
        - Використовуй ВИКЛЮЧНО правильну українську літературну мову
        - ЗАБОРОНЕНО використовувати русизми, суржик або неологізми
        - Якщо слово вже правильне — поверни його без змін
        - Повертай ТІЛЬКИ виправлене слово, без пояснень і додаткового тексту
        """

        var prompt = "Виправ це слово/фразу на правильну українську літературну форму:\n\n"
        prompt += "СЛОВО: \"\(word)\""
        
        if let context = context {
            prompt += "\n\nКОНТЕКСТ: \(context)"
        }
        
        prompt += "\n\nПоверни ТІЛЬКИ виправлене слово без лапок і пояснень:"

        let session = ChatSession(
            container,
            instructions: instructions,
            generateParameters: GenerateParameters(
                maxTokens: 50,
                temperature: 0.2,
                topP: profile.sampling.topP,
                topK: profile.sampling.topK,
                minP: profile.sampling.minP,
                repetitionPenalty: profile.sampling.repetitionPenalty),
            additionalContext: ["enable_thinking": false])

        var raw = ""
        do {
            for try await chunk in session.streamResponse(to: prompt) {
                raw += chunk
            }
        } catch {
            Self.log("correctUkrainianWord failed: \(error.localizedDescription)")
            return nil
        }

        let corrected = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'«»"))
            .trimmed
        
        Self.log("correctUkrainianWord: '\(word)' → '\(corrected)'")
        return corrected.isEmpty ? nil : corrected
    }

    /// Корректирует word концепта через спеллчекер, логируя исправления (Задача 1).
    private func correctConceptWord(_ concept: ThematicConcept) async -> ThematicConcept {
        guard let corrected = await correctUkrainianWord(concept.word) else { return concept }
        if corrected != concept.word {
            Self.log("spellcheck correction: '\(concept.word)' → '\(corrected)'")
            var updated = concept
            updated.word = corrected
            return updated
        }
        return concept
    }

    private func stringArray(_ value: Any?) -> [String] {
        if let array = value as? [String] {
            return array.map { $0.trimmed }.filter { !$0.isEmpty }
        } else if let array = value as? [Any] {
            return array.compactMap { ($0 as? String)?.trimmed }.filter { !$0.isEmpty }
        }
        return []
    }

    // MARK: - Prompt

    static func systemPrompt(language: String? = nil) -> String {
        resolvedPromptLanguage(language).systemPrompt
    }

    static func captioningPrompt(language: String?, styleExamples: String) -> String {
        let lang = (language ?? "").trimmed
        let resolved = resolvedPromptLanguage(language)

        let languageRule = lang.isEmpty
            ? resolved.languageRuleAuto
            : resolved.languageRuleFixed(lang)

        let style = styleExamples.trimmed
        let styleRule = style.isEmpty ? "" : resolved.styleRule(style)

        return resolved.captioningPrompt(languageRule: languageRule, styleRule: styleRule)
    }

    static func userPrompt(transcript: String, language: String? = nil,
                            videoTitle: String = "", videoDescription: String = "") -> String {
        resolvedPromptLanguage(language).userPrompt(transcript, videoTitle: videoTitle, videoDescription: videoDescription)
    }

    // MARK: - Prompt Language Support

    /// Normalizes a raw language string into an AppLanguage prompt variant.
    nonisolated static func resolvedPromptLanguage(_ raw: String?) -> PromptLanguage {
        let normalized = (raw ?? "").trimmed.lowercased()
        switch normalized {
        case "ru", "rus", "russian", "русский", "рус", "russkiy":
            return .ru
        case "uk", "ukr", "ukrainian", "українська", "укр", "ukrayinska", "ua":
            return .uk
        case "en", "eng", "english", "английский", "анг", "angliyskiy":
            return .en
        default:
            return .en
        }
    }

        static func userPromptForCaption(hook: String, transcriptSlice: String, language: String?,
                                          videoTitle: String = "", videoDescription: String = "") -> String {
            resolvedPromptLanguage(language).captionUserPrompt(hook, transcriptSlice,
                                                               videoTitle: videoTitle, videoDescription: videoDescription)
        }

    /// All AI prompt strings for a single prompt language.
    enum PromptLanguage {
        case en, ru, uk

        var debugName: String {
            switch self {
            case .en: return "en"
            case .ru: return "ru"
            case .uk: return "uk"
            }
        }

        // MARK: Caption user prompt

        func captionUserPrompt(_ hook: String, _ transcriptSlice: String,
                                videoTitle: String = "", videoDescription: String = "") -> String {
            var ctx = ""
            if !videoTitle.isEmpty {
                ctx = videoContextSection(videoTitle, description: videoDescription) + "\n\n---\n\n"
            }
            switch self {
            case .en:
                return ctx + "Suggested hook: \(hook)\n\nClip transcript:\n\(transcriptSlice)\n\nReturn the JSON package."
            case .ru:
                return ctx + "Предложенный хук: \(hook)\n\nТранскрипция клипа:\n\(transcriptSlice)\n\nВерни пакет JSON."
            case .uk:
                return ctx + "Запропонований хук: \(hook)\n\nТранскрипція кліпу:\n\(transcriptSlice)\n\nПоверни пакет JSON."
            }
        }

        // MARK: System Prompt (moments-only)

        var systemPrompt: String {
            switch self {
            case .en:
                return """
                You are an expert short-form viral content editor (TikTok, Reels, YouTube Shorts). \
                I give you the transcript of a long video, with timestamps. \
                Your job: find the BEST moments to cut into vertical clips that work \
                standalone and hook viewers in the first 2 seconds.

                Rules:
                - Each clip lasts between 15 and 50 seconds; prefer 25-45 seconds unless the payoff is naturally shorter.
                - The first spoken line must work as the hook. Do not start with setup, filler, greetings, silence, or "so / well / okay" lead-in.
                - Choose moments with a clear TikTok/Shorts arc: hook -> tension/question -> payoff.
                - The clip must work standalone for someone who has not seen the long video. Avoid context-dependent fragments.
                - Reject generic advice, slow exposition, repeated points, and clips whose payoff happens outside the selected range.
                - A COMPLETE IDEA. The clip MUST start at the beginning of a topic and MUST end where that topic naturally concludes. Never cut mid-sentence or mid-idea. If needed, move the start to the strongest sentence and the end to the completed payoff.
                - Align clip boundaries to sentence ends. The start should be the first sentence of a new thought, and the end should be the last sentence before the speaker transitions to a different topic.
                - If the clip ends at the end of the transcript, that is fine if the topic concludes there.
                - The "hook" must be a COMPLETE, self-contained thought that stops the scroll. It MUST fit within 50 characters WITHOUT being cut off mid-word or mid-sentence. If the spoken first line is longer, rewrite it into a complete, shorter hook that preserves the core idea.
                - Return ONLY valid JSON, no text around it, in this exact shape:
                {"clips":[{"start":"MM:SS","end":"MM:SS","why":"why it goes viral","hook":"first line that stops the scroll, max 50 chars","overlay":"main idea in 2-3 words, max 50 chars"}]}
                - "overlay" is 2-3 words capturing the main idea of the clip, in the video's language, designed to appear big on top of the video in the first few seconds.
                - Between 3 and 6 clips, ranked from best to worst. If fewer than 3 moments are genuinely strong, return only the strong ones.
                """
            case .ru:
                return """
                Ты — экспертный редактор вирусного short-контента (TikTok, Reels, YouTube Shorts). \
                Я даю тебе транскрипцию длинного видео с таймкодами. \
                Твоя задача: найти ЛУЧШИЕ моменты для нарезки вертикальных клипов, \
                которые работают сами по себе и цепляют за первые 2 секунды.

                Правила:
                - Каждый клип длится от 15 до 50 секунд; лучше 25-45 секунд, если смысл не требует короче.
                - Первая произнесенная фраза должна работать как хук. Не начинай с подводки, паузы, приветствия, слов-паразитов или «ну / так / окей».
                - Выбирай моменты со структурой TikTok/Shorts: хук -> напряжение/вопрос -> payoff.
                - Клип должен работать сам по себе для зрителя, который не видел длинное видео. Не бери фрагменты, понятные только из контекста.
                - Отбрасывай общие советы, медленное объяснение, повторы и моменты, где payoff остается за пределами выбранного диапазона.
                - ЗАКОНЧЕННАЯ ТЕМА. Клип ОБЯЗАН начинаться с начала темы и заканчиваться там, где тема естественно завершается. Никогда не обрывай на полуслове или на середине мысли. Если нужно, сдвинь начало к самой сильной фразе, а конец — к завершенной мысли.
                - Выравнивай границы клипа по концам предложений. Начало = первое предложение новой темы, конец = последнее предложение перед переходом к другой теме.
                - Если клип заканчивается на обрыве транскрипции — это нормально, если тема завершилась.
                - Поле "hook" должно быть ЗАКОНЧЕННОЙ, самодостаточной мыслью, которая останавливает скролл. Оно ОБЯЗАНО уложиться в 50 символов БЕЗ обрыва на полуслове или середине предложения. Если первая произнесённая фраза длиннее, перепиши её в законченный, более короткий хук, сохранив суть.
                - Верни ТОЛЬКО валидный JSON, без текста вокруг, в таком формате:
                {"clips":[{"start":"MM:SS","end":"MM:SS","why":"почему это вирусное","hook":"первая фраза клипа, которая останавливает скролл, макс 50 символов","overlay":"главная мысль в 2-3 слова, макс 50 символов"}]}
                - «overlay» — это 2-3 слова, передающие главную мысль клипа, на языке видео. Этот текст должен крупно появиться поверх видео в первые несколько секунд.
                - От 3 до 6 клипов, отсортированных от лучшего к худшему. Если по-настоящему сильных моментов меньше трех, верни только сильные.
                """
            case .uk:
                return """
                Ти — експертний редактор вірусного short-контенту (TikTok, Reels, YouTube Shorts). \
                Я даю тобі транскрипцію довгого відео з таймкодами. \
                Твоє завдання: знайти НАЙКРАЩІ моменти для нарізки вертикальних кліпів, \
                які працюють самі по собі та захоплюють за перші 2 секунди.

                Правила:
                - Кожен кліп триває від 15 до 50 секунд; краще 25-45 секунд, якщо сенс не потребує коротше.
                - Перша вимовлена фраза має працювати як хук. Не починай із підводки, паузи, привітання, слів-паразитів або «ну / так / окей».
                - Вибирай моменти зі структурою TikTok/Shorts: хук -> напруга/питання -> payoff.
                - Кліп має працювати сам по собі для глядача, який не бачив довге відео. Не бери фрагменти, зрозумілі тільки з контексту.
                - Відкидай загальні поради, повільне пояснення, повтори та моменти, де payoff лишається за межами вибраного діапазону.
                - ЗАВЕРШЕНА ТЕМА. Кліп ОБОВ'ЯЗКОВО має починатися з початку теми і закінчуватися там, де тема природно завершується. Ніколи не обривай на півслові або на середині думки. Якщо потрібно, посунь початок до найсильнішої фрази, а кінець — до завершеної думки.
                - Вирівнюй межі кліпу за кінцями речень. Початок = перше речення нової теми, кінець = останнє речення перед переходом до іншої теми.
                - Поверни ТІЛЬКИ валідний JSON, без тексту навколо, у такому форматі:
                {"clips":[{"start":"MM:SS","end":"MM:SS","why":"чому це вірусне","hook":"перша фраза кліпу, яка зупиняє скролл, макс 50 символів","overlay":"головна думка в 2-3 слова, макс 50 символів"}]}
                - Поле "hook" має бути ЗАВЕРШЕНОЮ, самодостатньою думкою, яка зупиняє скролл. Воно ЗОБОВ'ЯЗАНЕ вміститися в 50 символів БЕЗ обриву на півслові або середині речення. Якщо перша вимовлена фраза довша, перепиши її в завершений, коротший хук, зберігши суть.
                - «overlay» — це 2-3 слова, що передають головну думку кліпу, мовою відео. Цей текст має крупно з'явитися поверх відео в перші кілька секунд.
                - Від 3 до 6 кліпів, відсортованих від найкращого до найгіршого. Якщо по-справжньому сильних моментів менше трьох, поверни тільки сильні.
                """
            }
        }

        // MARK: User prompt

        func userPrompt(_ transcript: String, videoTitle: String = "", videoDescription: String = "") -> String {
            var ctx = ""
            if !videoTitle.isEmpty {
                ctx = videoContextSection(videoTitle, description: videoDescription) + "\n\n---\n\n"
            }
            switch self {
            case .en:
                return ctx + "Video transcript (with timestamps):\n\n\(transcript)\n\nReturn the clips JSON."
            case .ru:
                return ctx + "Транскрипция видео (с таймкодами):\n\n\(transcript)\n\nВерни JSON клипов."
            case .uk:
                return ctx + "Транскрипція відео (з таймкодами):\n\n\(transcript)\n\nПоверни JSON кліпов."
            }
        }

        // MARK: Captioning prompt

        func captioningPrompt(languageRule: String, styleRule: String) -> String {
            switch self {
            case .en:
                return """
                You are an expert short-form viral content editor (TikTok, Reels, YouTube Shorts). \
                I give you the transcript of a long video, with timestamps. \
                Your job: find the BEST moments to cut into vertical clips that hook in the first 2 seconds, \
                AND for each clip write the 3-platform publishing package.

                Rules:
                - Each clip lasts between 15 and 50 seconds; prefer 25-45 seconds unless the payoff is naturally shorter.
                - The first spoken line must work as the hook. Do not start with setup, filler, greetings, silence, or "so / well / okay" lead-in.
                - Pick clips with a clear TikTok/Shorts arc: hook -> tension/question -> payoff.
                - Each clip must work standalone for someone who has not seen the long video. Avoid context-dependent fragments.
                - Reject generic advice, slow exposition, repeated points, and clips whose payoff happens outside the selected range.
                - A COMPLETE IDEA. The clip MUST start at the beginning of a topic and end where that topic naturally concludes. Never cut mid-sentence or mid-idea. Align boundaries to sentence ends.
                - If the clip ends at the end of the transcript, that is fine if the topic concludes there.
                - Between 3 and 6 clips, ranked from best to worst. If fewer than 3 moments are genuinely strong, return only the strong ones.
                - \(languageRule)
                - The "hook" must be a COMPLETE, self-contained thought that stops the scroll. It MUST fit within 50 characters WITHOUT being cut off mid-word or mid-sentence. If the spoken first line is longer, rewrite it into a complete, shorter hook that preserves the core idea.
                - Hashtags are individual words WITHOUT '#', each unique (no repeats). Every clip MUST have hashtags for every platform — at least 3 for TikTok, 5 for Instagram, 3 for YouTube.
                - Return ONLY valid JSON, no text around it, in this EXACT shape:
                {"clips":[{
                  "start":"MM:SS",
                  "end":"MM:SS",
                  "why":"why it goes viral",
                  "hook":"first line that stops the scroll, max 50 chars",
                  "overlay":"main idea in 2-3 words, max 50 chars",
                  "captions":{
                    "tiktok":{"hook":"first scroll-stopping line, max 50 chars","description":"short, punchy caption","hashtags":["tag","tag","tag"]},
                    "instagram":{"hook":"strong first line, max 50 chars","description":"2-4 short paragraphs, storytelling, ending with call to action","hashtags":["...20-30 tags mixing broad reach and niche..."]},
                    "youtube":{"hook":"concise, searchable title, 50 chars","description":"keyword-rich description for search","hashtags":["...3-5 tags..."]}
                  }
                }]}
                - Do not invent anything not in the transcript.\(styleRule)
                """
            case .ru:
                return """
                Ты — экспертный редактор вирусного short-контента (TikTok, Reels, YouTube Shorts). \
                Я даю тебе транскрипцию длинного видео с таймкодами. \
                Твоя задача: найти ЛУЧШИЕ моменты для нарезки вертикальных клипов, \
                которые цепляют за первые 2 секунды, И для каждого клипа написать \
                пакет публикации для трёх платформ.

                Правила:
                - Каждый клип длится от 15 до 50 секунд; лучше 25-45 секунд, если смысл не требует короче.
                - Первая произнесенная фраза должна работать как хук. Не начинай с подводки, паузы, приветствия, слов-паразитов или «ну / так / окей».
                - Выбирай клипы со структурой TikTok/Shorts: хук -> напряжение/вопрос -> payoff.
                - Каждый клип должен работать сам по себе для зрителя, который не видел длинное видео. Не бери фрагменты, понятные только из контекста.
                - Отбрасывай общие советы, медленное объяснение, повторы и моменты, где payoff остается за пределами выбранного диапазона.
                - ЗАКОНЧЕННАЯ ТЕМА. Клип ОБЯЗАН начинаться с начала темы и заканчиваться там, где тема естественно завершается. Никогда не обрывай на полуслове или на середине мысли. Выравнивай границы по концам предложений.
                - От 3 до 6 клипов, отсортированных от лучшего к худшему. Если по-настоящему сильных моментов меньше трех, верни только сильные.
                - \(languageRule)
                - Поле "hook" должно быть ЗАКОНЧЕННОЙ, самодостаточной мыслью, которая останавливает скролл. Оно ОБЯЗАНО уложиться в 50 символов БЕЗ обрыва на полуслове или середине предложения. Если первая произнесённая фраза длиннее, перепиши её в законченный, более короткий хук, сохранив суть.
                - Хештеги — отдельные слова БЕЗ '#', каждый уникальный (без повторов). У КАЖДОГО клипа ОБЯЗАТЕЛЬНО должны быть хештеги для каждой платформы — минимум 3 для TikTok, 5 для Instagram, 3 для YouTube.
                - Верни ТОЛЬКО валидный JSON, без текста вокруг, в ТАКОМ формате:
                {"clips":[{
                  "start":"MM:SS",
                  "end":"MM:SS",
                  "why":"почему это вирусное",
                  "hook":"первая фраза, которая останавливает скролл, макс 50 символов",
                  "overlay":"главная мысль в 2-3 слова, макс 50 символов",
                  "captions":{
                    "tiktok":{"hook":"первая цепляющая строка, макс 50 символов","description":"короткий, броский текст","hashtags":["тег","тег","тег"]},
                    "instagram":{"hook":"первая сильная строка, макс 50 символов","description":"2-4 коротких абзаца, сторителлинг, заканчивается призывом к действию","hashtags":["...20-30 тегов, смесь широкого охвата и ниши..."]},
                    "youtube":{"hook":"лаконичный, поисковый заголовок, 50 символов","description":"описание с ключевыми словами для поиска","hashtags":["...3-5 тегов..."]}
                  }
                }]}
                - Не выдумывай ничего, чего нет в транскрипции.\(styleRule)
                """
            case .uk:
                return """
                Ти — експертний редактор вірусного short-контенту (TikTok, Reels, YouTube Shorts). \
                Я даю тобі транскрипцію довгого відео з таймкодами. \
                Твоє завдання: найти НАЙКРАЩІ моменти для нарізки вертикальних кліпів, \
                які захоплюють за перші 2 секунди, І для кожного кліпу написати \
                пакет публікації для трьох платформ.

                Правила:
                - Кожен кліп триває від 15 до 50 секунд; краще 25-45 секунд, якщо сенс не потребує коротше.
                - Перша вимовлена фраза має працювати як хук. Не починай із підводки, паузи, привітання, слів-паразитів або «ну / так / окей».
                - Вибирай кліпи зі структурою TikTok/Shorts: хук -> напруга/питання -> payoff.
                - Кожен кліп має працювати сам по собі для глядача, який не бачив довге відео. Не бери фрагменти, зрозумілі тільки з контексту.
                - Відкидай загальні поради, повільне пояснення, повтори та моменти, де payoff лишається за межами вибраного діапазону.
                - ЗАВЕРШЕНА ТЕМА. Кліп ОБОВ'ЯЗКОВО має починатися з початку теми і закінчуватися там, де тема природно завершується. Ніколи не обривай на півслові або на середині думки. Вирівнюй межі за кінцями речень.
                - Від 3 до 6 кліпів, відсортованих від найкращого до найгіршого. Якщо по-справжньому сильних моментів менше трьох, поверни тільки сильні.
                - \(languageRule)
                - Поле "hook" має бути ЗАВЕРШЕНОЮ, самодостатньою думкою, яка зупиняє скролл. Воно ЗОБОВ'ЯЗАНЕ вміститися в 50 символів БЕЗ обриву на півслові або середині речення. Якщо перша вимовлена фраза довша, перепиши її в завершений, коротший хук, зберігши суть.
                - Хештеги — окремі слова БЕЗ '#', кожен унікальний (без повторів). У КОЖНОГО кліпу ОБОВ'ЯЗКОВО мають бути хештеги для кожної платформи — мінімум 3 для TikTok, 5 для Instagram, 3 для YouTube.
                - Поверни ТІЛЬКИ валідний JSON, без тексту навколо, у ТАКОМУ форматі:
                {"clips":[{
                  "start":"MM:SS",
                  "end":"MM:SS",
                  "why":"чому це вірусне",
                  "hook":"перша фраза, яка зупиняє скролл, макс 50 символів",
                  "overlay":"головна думка в 2-3 слова, макс 50 символів",
                  "captions":{
                    "tiktok":{"hook":"перша цепляюча строка, макс 50 символів","description":"короткий, броский текст","hashtags":["тег","тег","тег"]},
                    "instagram":{"hook":"перва сильна строка, максимум 50 символів","description":"2-4 коротких абзаци, сторітелінг, закінчується закликом до дії","hashtags":["...20-30 тегів, суміш широкого охоплення та ніші..."]},
                    "youtube":{"hook":"лаконічний, пошуковий заголовок, 50 символів","description":"опис з ключовими словами для пошуку","hashtags":["...3-5 тегів..."]}
                  }
                }]}
                - Не вигадуй нічого, чого немає в транскрипції.\(styleRule)
                """
            }
        }

        // MARK: Language rules

        var languageRuleAuto: String {
            switch self {
            case .en:
                return "Write ALL text (why, hook, overlay and captions) in the same language spoken in the video. Do not translate to English."
            case .ru:
                return "ВЕСЬ текст (why, hook, overlay и captions) пиши на том же языке, на котором говорят в видео. Не переводи на английский."
            case .uk:
                return "ВЕСЬ текст (why, hook, overlay та captions) пиши тією ж мовою, якою говорять у відео. Не перекладай англійською."
            }
        }

        func languageRuleFixed(_ lang: String) -> String {
            switch self {
            case .en:
                return "Write ALL text (why, hook, overlay and captions) in this language: \(lang). Use it even if the video is in another language."
            case .ru:
                return "ВЕСЬ текст (why, hook, overlay и captions) пиши на этом языке: \(lang). Используй его, даже если видео на другом языке."
            case .uk:
                return "ВЕСЬ текст (why, hook, overlay та captions) пиши цією мовою: \(lang). Використовуй її, навіть якщо відео на іншій мові."
            }
        }

        // MARK: Style rule

        func styleRule(_ style: String) -> String {
            switch self {
            case .en:
                return """

                Creator voice — match this style (tone, rhythm, emojis, format):
                \(style)
                """
            case .ru:
                return """

                Голос автора — копируй этот стиль (тон, темп, эмодзи, формат):
                \(style)
                """
            case .uk:
                return """

                Голос автора — копіюй цей стиль (тон, темп, емодзі, формат):
                \(style)
                """
            }
        }
    }
}

enum MomentFinderError: LocalizedError {
    case notReady
    case noClips

    var errorDescription: String? {
        switch self {
        case .notReady:
            return "The moment-finder model is still loading."
        case .noClips:
            return "Couldn't find any usable moments in that video."
        }
    }
}

/// Tolerant parser for the Director's JSON output. Mirrors the balanced-brace
/// scan in `JSONVariantParser`, but reads a `clips` array, normalizes timestamps
/// (numeric seconds, `MM:SS`, or `HH:MM:SS,mmm`) and validates clip durations.
enum MomentJSONParser {

    /// Acceptable clip duration window, in seconds. The model often picks
    /// punchy ~10s moments, so the floor is generous; anything genuinely tiny
    /// is dropped and anything too long is clamped.
    static let minDuration = 8.0
    static let maxDuration = 90.0

    static func parse(_ raw: String) -> [ClipCandidate] {
        var entries: [[String: Any]] = []
        if let jsonString = JSONVariantParser.extractJSONObject(from: raw),
           let root = JSONVariantParser.deserializeTolerant(jsonString) as? [String: Any],
           let clipsArray = root["clips"] as? [[String: Any]] {
            entries = clipsArray
        }
        // Fallback: the whole array failed to parse (a token drifted, or the
        // generation was truncated mid-JSON). Salvage every complete clip object
        // on its own, so one broken/cut-off clip doesn't drop all the good ones.
        if entries.isEmpty {
            entries = salvageClipEntries(from: raw)
            if !entries.isEmpty {
                MomentFinderService.log("parser: strict parse failed — salvaged \(entries.count) clip object(s)")
            }
        }
        MomentFinderService.log("parser: \(entries.count) raw clip entries")
        return entries.compactMap(buildClip)
            .sorted { qualityScore($0) > qualityScore($1) }
            .prefix(6)
            .map { $0 }
    }

    /// Builds a validated `ClipCandidate` from one raw clip object, or nil if it
    /// lacks a usable time range / is too short.
    private static func buildClip(from entry: [String: Any]) -> ClipCandidate? {
        guard let start = seconds(from: entry["start"]),
              let end = seconds(from: entry["end"]),
              end > start
        else { return nil }

        var clip = ClipCandidate(
            start: start,
            end: end,
            why: string(entry, "why", "reason", "rationale"),
            hook: string(entry, "hook", "title", "headline"),
            overlay: string(entry, "overlay", "onscreen", "caption"))

        if let captions = entry["captions"] ?? entry["posts"] {
            do {
                let result = try JSONVariantParser.parse(object: captions)
                clip.variants = result.variants
                if clip.variants.isEmpty {
                    MomentFinderService.log("parser: captions object found but produced 0 variants — keys=\(captions)")
                }
            } catch {
                MomentFinderService.log("parser: captions parsing failed — \(error)")
            }
        }

        if clip.duration > maxDuration {
            clip.end = clip.start + maxDuration
        }
        guard clip.duration >= minDuration else { return nil }
        return clip
    }

    /// Scans the raw text for complete balanced `{…}` objects that look like
    /// clips (they carry a "start" and "end"), parsing each independently. This
    /// recovers the good clips even when the enclosing array is truncated (token
    /// limit) or one clip is malformed.
    private static func salvageClipEntries(from raw: String) -> [[String: Any]] {
        let chars = Array(raw)
        var entries: [[String: Any]] = []
        var i = 0
        while i < chars.count {
            guard chars[i] == "{", let close = matchingBrace(chars, from: i) else {
                i += 1
                continue
            }
            let candidate = String(chars[i...close])
            if let obj = JSONVariantParser.deserializeTolerant(candidate) as? [String: Any],
               obj["start"] != nil, obj["end"] != nil {
                entries.append(obj)
                i = close + 1
            } else {
                i += 1
            }
        }
        return entries
    }

    /// Index of the `}` matching the `{` at `start`, respecting string literals,
    /// or nil if the object is unbalanced (e.g. truncated).
    private static func matchingBrace(_ chars: [Character], from start: Int) -> Int? {
        var depth = 0
        var inString = false
        var escaped = false
        var i = start
        while i < chars.count {
            let c = chars[i]
            if inString {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
            } else {
                switch c {
                case "\"": inString = true
                case "{": depth += 1
                case "}":
                    depth -= 1
                    if depth == 0 { return i }
                default: break
                }
            }
            i += 1
        }
        return nil
    }

    /// Parses a timestamp value into seconds. Accepts a number, or strings like
    /// `"95"`, `"1:35"`, `"01:35"`, `"00:01:35,200"`, `"1:35.2"`.
    static func seconds(from value: Any?) -> Double? {
        if let n = value as? Double { return n }
        if let n = value as? Int { return Double(n) }
        guard let str = (value as? String)?.trimmingCharacters(in: .whitespaces),
              !str.isEmpty else { return nil }

        // Plain number string.
        if let n = Double(str.replacingOccurrences(of: ",", with: ".")),
           !str.contains(":") {
            return n
        }

        // Colon-separated H:M:S / M:S. Last field may use ',' or '.' for ms.
        let parts = str.split(separator: ":").map {
            Double($0.replacingOccurrences(of: ",", with: ".")) ?? 0
        }
        switch parts.count {
        case 3: return parts[0] * 3600 + parts[1] * 60 + parts[2]
        case 2: return parts[0] * 60 + parts[1]
        case 1: return parts[0]
        default: return nil
        }
    }

    private static func string(_ entry: [String: Any], _ keys: String...) -> String {
        for key in keys {
            if let value = (entry[key] as? String)?.trimmed, !value.isEmpty {
                return value
            }
        }
        return ""
    }

    private static func qualityScore(_ clip: ClipCandidate) -> Double {
        var score = 0.0
        let duration = clip.duration

        if (25...45).contains(duration) {
            score += 3
        } else if (15...50).contains(duration) {
            score += 1.5
        }

        let hook = clip.hook.trimmed
        if !hook.isEmpty { score += 1 }
        if hook.count <= 90 { score += 0.5 }
        if !startsWithFiller(hook) { score += 1 }
        if !clip.overlay.trimmed.isEmpty { score += 0.5 }

        return score
    }

    private static func startsWithFiller(_ text: String) -> Bool {
        let normalized = text
            .lowercased()
            .replacingOccurrences(of: #"^[\p{P}\p{S}\s]+"#, with: "", options: .regularExpression)
        let fillers = [
            "so ", "well ", "okay ", "ok ", "um ", "uh ", "like ",
            "ну ", "так ", "окей ", "короче ", "типа ",
            "ну ", "так ", "окей ", "коротше ", "типу ",
        ]
        return fillers.contains { normalized.hasPrefix($0) }
    }
}
