import Foundation
import Gemma4Swift
import HuggingFace
import MLX
import MLXLMCommon
import MLXHuggingFace
import MLXVLM
import Observation
import Tokenizers

/// The "Director": owns the local text model (Gemma 4 12B by default) and turns a
/// full transcript into an essay theme plus a ranked pool of scenes in one pass.
///
/// Adapted from Hermes-Jarvis' MLXChatService, stripped of skills/tools, draft
/// models and speculative decoding — this is single-shot structured generation.
/// Transcript digests fit each stage to the selected model’s context budget.
/// Thinking is forced OFF.
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

    /// Which model plays the Director. Gemma 4 12B is the default because it is
    /// the profile `AppSettings` persists — a second, different default here was a
    /// second truth about which model writes the essay theme. Switched to match
    /// the user's pick via `setProfile(_:)` before the model loads.
    private(set) var profile = ChatModelProfile.gemma12B

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

    nonisolated static func log(_ message: String) {
        DirectorRunLog.write(message)
    }

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

    /// Двухэтапный Director: этап 1 ищет темы-кандидаты, этап 2 строит эссе
    /// вокруг той, что прошла приёмочный гейт.
    ///
    /// Every failure is an error, never a nil: the caller cannot tell "the model
    /// chose this" from "the model was never asked" otherwise, and the pipeline
    /// used to paper over it with the hardcoded theme tables.
    func analyzeThematicCore(
        transcriptSample: String,
        movieTitle: String,
        movieOverview: String? = nil,
        transcript: Transcript? = nil
    ) async throws -> ThematicAnalysisResult {
        guard container != nil else {
            Self.log("analyzeThematicCore: no model loaded")
            throw ThematicDiscoveryError.directorUnavailable("модель не завантажена")
        }
        let sample = transcriptSample.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sample.isEmpty else { throw ThematicDiscoveryError.transcriptEmpty }
        // The overview is prompt material too: cap it so it can't eat the budget
        // the transcript was sized for.
        let overview = String((movieOverview?.trimmed ?? "").prefix(Self.thematicOverviewCharCap))

        var candidates = try await proposeThemeCandidates(
            sample: sample, movieTitle: movieTitle, overview: overview)
        guard var winner = candidates.first else {
            throw ThematicDiscoveryError.noGroundedTheme(
                "етап 1 не дав жодної теми, яка пройшла б перевірку")
        }
        var attempted = Set<String>()
        var refreshedCandidates = false
        for _ in 0..<4 {
            attempted.insert(Self.themeKey(winner.word))
            do {
                return try await planEssay(around: winner, approvedCandidates: candidates,
                    sample: sample, movieTitle: movieTitle, overview: overview, transcript: transcript)
            } catch let rejection as EssayThemeRejected {
                Self.log("semantic theme rejected: \(winner.word) — \(rejection.reason)")
                if let replacement = rejection.preferredTheme,
                   let next = candidates.first(where: { Self.themeKey($0.word) == Self.themeKey(replacement)
                       && !attempted.contains(Self.themeKey($0.word)) }) {
                    winner = next // альтернативу определил редактор-модель
                } else if !refreshedCandidates {
                    refreshedCandidates = true
                    candidates = try await proposeThemeCandidates(sample: sample, movieTitle: movieTitle,
                        overview: overview, feedback: rejection.reason)
                    guard let next = candidates.first(where: { !attempted.contains(Self.themeKey($0.word)) })
                    else { throw rejection }
                    winner = next
                } else { throw rejection }
            }
        }
        throw ThematicDiscoveryError.noGroundedTheme("модель не подтвердила прямую связь темы со сценами")
    }

    /// Альтернативная или ручная тема получает собственный Stage 2. Если
    /// рекомендованная ИИ тема не проходит семантическую проверку, заменяем её
    /// только после повторной проверки кандидата тем же редактором.
    func analyzeSelectedTheme(
        _ concept: ThematicConcept,
        candidates: [ThematicConcept],
        transcript: Transcript,
        movieTitle: String,
        movieOverview: String?
    ) async throws -> ThematicAnalysisResult {
        guard container != nil else {
            throw ThematicDiscoveryError.directorUnavailable("модель не завантажена")
        }
        let sample = LongformThematicService.stratifiedThematicSample(from: transcript)
        guard !sample.trimmed.isEmpty else { throw ThematicDiscoveryError.transcriptEmpty }
        var approved = [concept] + candidates.filter { Self.themeKey($0.word) != Self.themeKey(concept.word) }
        var winner = concept
        var attempted = Set<String>()
        var refreshedCandidates = false
        let overview = String((movieOverview?.trimmed ?? "").prefix(Self.thematicOverviewCharCap))

        for _ in 0..<12 {
            attempted.insert(Self.themeKey(winner.word))
            do {
                return try await planEssay(
                    around: winner, approvedCandidates: approved, sample: sample,
                    movieTitle: movieTitle, overview: overview, transcript: transcript)
            } catch let rejection as EssayThemeRejected {
                // Keep an explicit user-authored theme fixed. AI recommendations
                // are replaceable: the semantic editor's preferred candidate wins.
                guard concept.source == .llm else { throw rejection }
                Self.log("selected AI theme rejected: \(winner.word) — \(rejection.reason)")

                if let replacement = rejection.preferredTheme,
                   let next = approved.first(where: {
                       Self.themeKey($0.word) == Self.themeKey(replacement)
                           && !attempted.contains(Self.themeKey($0.word))
                   }) {
                    winner = next
                    continue
                }

                if let next = approved.first(where: {
                    !attempted.contains(Self.themeKey($0.word))
                }) {
                    winner = next
                    continue
                }

                guard !refreshedCandidates else { throw rejection }
                refreshedCandidates = true
                let refreshed = try await proposeThemeCandidates(
                    sample: sample, movieTitle: movieTitle, overview: overview,
                    feedback: "Тема «\(winner.word)» відхилена: \(rejection.reason). Не повторюй її; знайди точне українське слово для цього конфлікту.")
                var knownKeys = Set(approved.map { Self.themeKey($0.word) })
                for candidate in refreshed where !attempted.contains(Self.themeKey(candidate.word)) {
                    if knownKeys.insert(Self.themeKey(candidate.word)).inserted {
                        approved.append(candidate)
                    }
                }
                guard let next = approved.first(where: {
                    !attempted.contains(Self.themeKey($0.word))
                }) else { throw rejection }
                winner = next
            }
        }
        throw ThematicDiscoveryError.noGroundedTheme("модель не знайшла тему, що відповідає сценам")
    }

    /// Этап 1: пять тем-кандидатов на коротком дайджесте. Ответ маленький,
    /// поэтому он закрывается, а не обрывается на середине — и тему мы теряем
    /// только вместе с по-настоящему пустым ответом модели.
    private func proposeThemeCandidates(
        sample: String,
        movieTitle: String,
        overview: String,
        feedback: String? = nil
    ) async throws -> [ThematicConcept] {
        let s = profile.sampling
        var params = GenerateParameters(
            maxTokens: DirectorStagedAnalysis.stage1MaxTokens,
            temperature: 0.35,
            topP: s.topP,
            topK: s.topK,
            minP: s.minP,
            repetitionPenalty: nil)
        // Профиль без `maxKVSize` — не «бесконечный контекст»: на 18 ГБ это
        // обрыв процесса, поэтому один и тот же потолок идёт и в MLX, и в
        // арифметику бюджета дайджеста.
        params.maxKVSize = s.maxKVSize ?? Self.unboundedKVTokenBudget
        params.kvBits = s.kvBits

        let reviewedOverview = overview + (feedback.map {
            "\nРедактор відхилив попередній набір: " + String($0.prefix(600))
            + "\nЗнайди нові, точніші літературні назви центрального конфлікту."
        } ?? "")
        let plan = Self.candidatesDigestPlan(
            movieTitle: movieTitle, overview: reviewedOverview, maxKVSize: params.maxKVSize)
        let (digest, digestStride) = Self.downsampleChronologically(
            sample, to: plan.digestChars)
        let instructions = DirectorStagedAnalysis.candidatesInstructions(movieTitle: movieTitle)
        let basePrompt = DirectorStagedAnalysis.candidatesPrompt(
            movieTitle: movieTitle, overview: reviewedOverview, digest: digest)
        // Здесь проверяется форма слова; смысл подтверждается отдельным
        // проходом по выбранным сценам, а не наличием того же корня в диалогах.
        let estimatedPromptTokens = Self.estimatedTokens(of: instructions + basePrompt)
        Self.log("""
            stage=candidates: profile=\(profile.displayName) digest=\(digest.count)/\(plan.digestChars) chars \
            (stride \(digestStride)) overheadTokens=\(plan.promptOverheadTokens) \
            estPromptTokens=\(estimatedPromptTokens) maxTokens=\(DirectorStagedAnalysis.stage1MaxTokens) \
            kvCap=\(params.maxKVSize ?? -1)
            """)
        Self.warnIfPromptOverKVCap(
            stage: "candidates", estimatedPromptTokens: estimatedPromptTokens,
            maxTokens: DirectorStagedAnalysis.stage1MaxTokens, kvCap: params.maxKVSize ?? Self.unboundedKVTokenBudget)

        var lastReply: DirectorReply?
        var lastError: (any Error)?
        var rejectionNote: String?
        for attempt in 1...Self.stagedAttemptsPerStage {
            var prompt = attempt == 1
                ? basePrompt
                : basePrompt + DirectorStagedAnalysis.candidatesRetryNote
            if attempt > 1, let rejectionNote { prompt += "\nВиправ: " + String(rejectionNote.prefix(300)) }
            do {
                let reply = try await streamReply(
                    instructions: instructions,
                    prompt: prompt,
                    parameters: params,
                    stage: "candidates",
                    attempt: attempt)
                lastReply = reply
                // Дамп пишется ДО вердикта полноты: оборванный ответ — это главный
                // документ для форензики, раньше он терялся вместе с попыткой.
                DirectorRunLog.dumpRaw(reply.text, stage: "candidates", attempt: attempt)
                guard reply.completeness.isAcceptable else {
                    Self.log("stage=candidates attempt \(attempt): обірвана відповідь, не парсим")
                    continue
                }
                let parsed = LongformThematicService.parseThemeCandidates(from: reply.text)
                var accepted: [ThematicConcept] = []
                var seen = Set<String>()
                for concept in parsed {
                    switch DirectorArtifactGate.concept(concept) {
                    case .accepted(let passed), .repaired(let passed, _):
                        if seen.insert(passed.word.lowercased()).inserted { accepted.append(passed) }
                    case .rejected(let reason, let code):
                        rejectionNote = reason
                        Self.log("stage=candidates: «\(concept.word)» відхилено (\(code.rawValue)): \(reason)")
                    }
                }
                if !accepted.isEmpty {
                    Self.log("stage=candidates attempt \(attempt): гейт пропустив \(accepted.count)/\(parsed.count): \(accepted.map(\.word).joined(separator: ", "))")
                    return accepted
                }
                Self.log("stage=candidates attempt \(attempt): жоден з \(parsed.count) кандидатів не пройшов гейт")
            } catch {
                lastError = error
                Self.log("stage=candidates attempt \(attempt) failed: \(error.localizedDescription)")
            }
        }
        if let reply = lastReply, reply.completeness == .truncated {
            throw ThematicDiscoveryError.replyTruncated(
                tokens: reply.generatedTokens, cap: reply.maxTokens)
        }
        if let error = lastError { throw error }
        throw ThematicDiscoveryError.noGroundedTheme(
            rejectionNote ?? "етап 1: модель не видала жодної теми, яка пройшла б перевірку")
    }

    /// Этап 2: план эссе и пул сцен вокруг уже отобранной темы.
    private func planEssay(
        around winner: ThematicConcept,
        approvedCandidates: [ThematicConcept],
        sample: String,
        movieTitle: String,
        overview: String,
        transcript: Transcript? = nil
    ) async throws -> ThematicAnalysisResult {
        let s = profile.sampling
        var params = GenerateParameters(
            maxTokens: DirectorStagedAnalysis.stage2MaxTokens,
            temperature: 0.35,
            topP: s.topP,
            topK: s.topK,
            minP: s.minP,
            repetitionPenalty: s.repetitionPenalty)
        // Тот же потолок, из которого считается бюджет дайджеста: промпт длиннее
        // бюджета не должен ни обрезаться молча, ни ронять процесс.
        params.maxKVSize = s.maxKVSize ?? Self.unboundedKVTokenBudget
        params.kvBits = s.kvBits

        let catalogue = transcript.map(EssaySceneCatalogue.init(transcript:))
        let instructions = Self.essayInstructions(
            movieTitle: movieTitle, winner: winner, approvedCandidates: approvedCandidates,
            catalogueMode: catalogue != nil)
        let plan = Self.essayDigestPlan(
            movieTitle: movieTitle,
            overview: overview,
            winner: winner,
            approvedCandidates: approvedCandidates,
            maxKVSize: params.maxKVSize, catalogueMode: catalogue != nil)

        // Never `prefix(_:)` the tail away: thin every act evenly so the third
        // act still reaches the model when the transcript exceeds the budget.
        let sceneMaterial = catalogue?.digest ?? sample
        let (sampledDialogue, lineStride) = Self.downsampleChronologically(sceneMaterial, to: plan.digestChars)
        let presentedCatalogue = catalogue?.presented(in: sampledDialogue).denselyNumbered()
        let dialogue = presentedCatalogue?.digest ?? sampledDialogue
        if let presentedCatalogue, presentedCatalogue.scenes.count < 8 {
            throw ThematicDiscoveryError.noGroundedTheme(
                "каталог не содержит достаточно цельных диалогов для эссе; нужен разбор границ сцен")
        }
        let userPrompt: String
        if catalogue != nil {
            userPrompt = DirectorStagedAnalysis.cataloguePrompt(
                movieTitle: movieTitle, overview: overview, digest: dialogue)
        } else {
            userPrompt = DirectorStagedAnalysis.essayPrompt(
                movieTitle: movieTitle, overview: overview, theme: winner.word,
                tagline: winner.tagline, digest: dialogue)
        }

        let estimatedPromptTokens = Self.estimatedTokens(of: instructions + userPrompt)
        Self.log("""
            stage=essay: profile=\(profile.displayName) maxKVSize=\(s.maxKVSize.map { "\($0)" } ?? "nil") \
            kvCap=\(params.maxKVSize ?? -1) overheadTokens=\(plan.promptOverheadTokens) \
            budget=\(plan.digestChars) chars sample=\(sample.count)→\(dialogue.count) chars (stride \(lineStride)) \
            maxTokens=\(DirectorStagedAnalysis.stage2MaxTokens) estPromptTokens=\(estimatedPromptTokens)
            """)
        Self.warnIfPromptOverKVCap(
            stage: "essay", estimatedPromptTokens: estimatedPromptTokens,
            maxTokens: DirectorStagedAnalysis.stage2MaxTokens,
            kvCap: params.maxKVSize ?? Self.unboundedKVTokenBudget)

        var latestReply: DirectorReply?
        var lastError: (any Error)?
        var gateRejection: String?
        var selectionFailure: String?
        var themeMismatch: String?
        var previousSceneContext: String?
        for attempt in 1...Self.essayPlanAttempts {
            var prompt = attempt == 1
                ? userPrompt
                : userPrompt + DirectorStagedAnalysis.essayRetryNote
            if attempt > 1, let previousSceneContext {
                prompt += "\n" + previousSceneContext
            }
            if attempt > 1, let gateRejection {
                prompt += "\nВиправ помилки попереднього відбору: "
                    + String(gateRejection.prefix(DirectorStagedAnalysis.evidenceFeedbackChars))
            }

            do {
                let reply = try await streamReply(
                    instructions: instructions,
                    prompt: prompt,
                    parameters: params,
                    stage: "essay",
                    attempt: attempt)
                let raw = reply.text
                guard !raw.trimmed.isEmpty else { continue }
                latestReply = reply
                DirectorRunLog.dumpRaw(raw, stage: "essay", attempt: attempt)
                guard reply.completeness.isAcceptable else {
                    Self.log("analyzeThematicCore stage=essay attempt \(attempt): обірвана відповідь, не парсим")
                    continue
                }
                let decoded: ThematicAnalysisResult?
                if let presentedCatalogue {
                    do {
                        decoded = try LongformThematicService.decodeCatalogueAnalysis(from: raw, catalogue: presentedCatalogue)
                    } catch {
                        selectionFailure = error.localizedDescription
                        gateRejection = error.localizedDescription
                        Self.log("stage=essay attempt \(attempt): selection rejected — \(error.localizedDescription)")
                        continue
                    }
                } else {
                    decoded = LongformThematicService.parseThematicAnalysis(from: raw)
                }
                guard var parsed = decoded else {
                    gateRejection = "Поверни валідний JSON. selection — масив рядків [ID, роль, число, true/false, пояснення]; ID тільки з каталогу, без повторів."
                    Self.log("analyzeThematicCore stage=essay attempt \(attempt): unparseable, head: \(raw.prefix(200))")
                    continue
                }
                previousSceneContext = Self.essaySceneRetryContext(
                    parsed.selectedMoments,
                    catalogue: presentedCatalogue)
                parsed.replyCompleteness = reply.completeness
                let verdict = DirectorArtifactGate.analysis(
                    parsed, completeness: reply.completeness)
                switch verdict {
                case .accepted(let passed), .repaired(let passed, _):
                    // Этап 2 не має права непомітно змінити затверджену тему.
                    // Без цієї перевірки есе могло будуватись навколо іншої теми, а
                    // ми все одно підписували б її як «знайдену етапом 1».
                    if let mismatch = Self.essayThemeMismatch(passed, approved: winner) {
                        themeMismatch = mismatch
                        Self.log("analyzeThematicCore stage=essay attempt \(attempt): gate=rejected(themeMismatch) — \(mismatch)")
                        continue
                    }
                    if case .repaired(_, let reason) = verdict {
                        Self.log("analyzeThematicCore stage=essay attempt \(attempt): gate=repaired theme='\(passed.primaryConcept.word)' — \(reason)")
                    } else {
                        Self.log("analyzeThematicCore stage=essay attempt \(attempt): gate=accepted theme='\(passed.primaryConcept.word)' moments=\(passed.selectedMoments.count)")
                    }
                    if let transcript {
                        do {
                            try EssaySceneEvidence.validate(passed, transcript: transcript)
                        } catch {
                            selectionFailure = error.localizedDescription
                            gateRejection = error.localizedDescription
                            Self.log("stage=essay attempt \(attempt): scene evidence rejected — \(error.localizedDescription)")
                            continue
                        }
                    }
                    var accepted = withStage1Candidates(passed, approvedCandidates)
                    accepted.plannedConcept = winner
                    if let transcript {
                        accepted = try await reviewThemeAndHook(accepted, candidates: approvedCandidates, transcript: transcript)
                        accepted = ThematicAnalysisCache.binding(accepted, to: transcript)
                    }
                    return accepted
                case .rejected(let reason, let code):
                    gateRejection = reason
                    Self.log("analyzeThematicCore stage=essay attempt \(attempt): gate=rejected(\(code.rawValue)) — \(reason)")
                    continue
                }
            } catch let rejection as EssayThemeRejected {
                throw rejection
            } catch {
                lastError = error
                Self.log("analyzeThematicCore stage=essay attempt \(attempt) failed: \(error.localizedDescription)")
            }
        }

        if let reply = latestReply, reply.completeness == .truncated {
            Self.log("analyzeThematicCore: every essay attempt ended truncated, cap=\(reply.maxTokens ?? -1) generated=\(reply.generatedTokens)")
            throw ThematicDiscoveryError.replyTruncated(
                tokens: reply.generatedTokens, cap: reply.maxTokens)
        }
        // Жодна спроба не написала про схвалену тему: це чесний провал. Нову тему
        // ми самі не вигадуємо і не «підставляємо» слово етапу 1 замість того, що
        // видала модель, — есе без теми етапу 2 не існує.
        if let mismatch = themeMismatch {
            throw ThematicDiscoveryError.noGroundedTheme(mismatch)
        }
        if let failure = selectionFailure {
            throw ThematicDiscoveryError.invalidEssaySelection(failure)
        }
        // Ни одна тема не прошла гейт: это честный провал, а не повод подставить
        // слово из эвристики.
        if let rejection = gateRejection {
            throw ThematicDiscoveryError.noGroundedTheme(rejection)
        }
        if let text = latestReply?.text {
            throw ThematicDiscoveryError.unparseableOutput(String(text.prefix(200)))
        }
        if let error = lastError {
            Self.log("analyzeThematicCore: every attempt errored")
            throw error
        }
        throw ThematicDiscoveryError.modelReturnedNoText
    }

    /// Альтернативные грани пользователю — те, что реально выдал и проверил
    /// этап 1, а не то, что модель дописала в обрезанном хвосте этапа 2.
    ///
    /// Вызывающая сторона (`planEssay`) спершу перевіряє, що тема етапу 2 — це і є
    /// схвалений winner; без цієї перевірки тут ми б підписували чужу тему як
    /// «знайдену етапом 1».
    private func withStage1Candidates(
        _ result: ThematicAnalysisResult,
        _ candidates: [ThematicConcept]
    ) -> ThematicAnalysisResult {
        var updated = result
        let winner = Self.themeKey(result.primaryConcept.word)
        updated.alternativeConcepts = candidates
            .filter { Self.themeKey($0.word) != winner }
            .prefix(3)
            .map { $0 }
        return updated
    }

    /// Спільний путь генерації для обох етапів Director.
    ///
    /// Стримим `streamDetails`, а не `streamResponse(to:)`: только в `Generation`
    /// есть `.info` со счётчиками токенов и причиной остановки. Без них «ответ не
    /// обрезан» было мнением — теперь это число в director.log.
    private func streamReply(
        instructions: String,
        prompt: String,
        parameters: GenerateParameters,
        stage: String,
        attempt: Int
    ) async throws -> DirectorReply {
        guard let container else { throw ThematicDiscoveryError.directorUnavailable("модель не завантажена") }
        let session = ChatSession(
            container,
            instructions: instructions,
            generateParameters: parameters,
            additionalContext: ["enable_thinking": false])
        var text = ""
        var info: GenerateCompletionInfo?
        for try await piece in session.streamDetails(to: prompt) {
            if let chunk = piece.chunk { text += chunk }
            if let received = piece.info { info = received }
        }
        let reply = DirectorReply(text: text, info: info, maxTokens: parameters.maxTokens)
        Self.log("stage=\(stage) attempt=\(attempt) chars=\(reply.text.count) \(reply.logLine)")
        return reply
    }

    /// Независимая смысловая приёмка после отбора сцен. Возвращает один выбранный
    /// хук; при натянутой теме модель указывает подходящего кандидата для нового Stage 2.
    func reviewThemeAndHook(_ analysis: ThematicAnalysisResult, candidates: [ThematicConcept],
                            transcript: Transcript) async throws -> ThematicAnalysisResult {
        let sampling = profile.sampling
        var params = GenerateParameters(maxTokens: EssaySemanticSelection.maxTokens, temperature: 0.2,
            topP: sampling.topP, topK: sampling.topK, minP: sampling.minP,
            repetitionPenalty: nil)
        params.maxKVSize = sampling.maxKVSize ?? Self.unboundedKVTokenBudget
        params.kvBits = sampling.kvBits
        let frame = EssaySemanticSelection.prompt(analysis: analysis, candidates: candidates,
                                                  transcript: transcript, materialChars: 0)
        let overhead = Self.estimatedTokens(of: EssaySemanticSelection.instructions + frame)
            + Self.estimatedTokens(of: String(repeating: "я", count: 400))
        let budget = min(10_000, Self.thematicContextBudgetChars(maxKVSize: params.maxKVSize,
            maxTokens: EssaySemanticSelection.maxTokens, promptOverheadTokens: overhead))
        let base = EssaySemanticSelection.prompt(analysis: analysis, candidates: candidates,
                                                 transcript: transcript, materialChars: budget)
        var feedback = ""
        var lastError: (any Error)?
        for attempt in 1...2 {
            try Task.checkCancellation()
            let prompt = base + feedback
            guard Self.estimatedTokens(of: EssaySemanticSelection.instructions + prompt)
                    + EssaySemanticSelection.maxTokens <= (params.maxKVSize ?? Self.unboundedKVTokenBudget) else {
                throw ThematicDiscoveryError.noGroundedTheme("материал смысловой проверки не помещается в контекст модели")
            }
            do {
                let reply = try await streamReply(instructions: EssaySemanticSelection.instructions,
                    prompt: prompt, parameters: params, stage: "semantic", attempt: attempt)
                DirectorRunLog.dumpRaw(reply.text, stage: "semantic", attempt: attempt)
                guard reply.completeness.isAcceptable else {
                    throw ThematicDiscoveryError.noGroundedTheme("обрезан ответ смысловой проверки")
                }
                let reviewed = try EssaySemanticSelection.apply(reply.text, to: analysis,
                    candidates: candidates, transcript: transcript, modelID: profile.modelID,
                    presentedLineIDs: EssaySemanticSelection.presentedLineIDs(in: base))
                Self.log("semantic accepted: theme=\(reviewed.primaryConcept.word) hook=\(reviewed.essayPlan?.selectedHook?.text ?? "")")
                return try await polishTitleAndHook(reviewed)
            } catch let rejection as EssayThemeRejected { throw rejection }
            catch is CancellationError { throw CancellationError() }
            catch {
                lastError = error
                let detail: String
                if let discovery = error as? ThematicDiscoveryError, case .noGroundedTheme(let reason) = discovery {
                    detail = reason
                } else { detail = error.localizedDescription }
                feedback = "\nВиправ лише формат або некоректне поле попередньої відповіді: "
                    + String(detail.prefix(220))
                    + ". Не відхиляй тему через помилку формату. Поверни повний JSON."
                Self.log("semantic attempt \(attempt) rejected: \(error.localizedDescription)")
            }
        }
        throw lastError ?? ThematicDiscoveryError.noGroundedTheme("не получено решение по теме и одному хуку")
    }

    /// Короткая вычитка уже выбранных фраз, без повторного выбора темы и сцен.
    func polishTitleAndHook(_ analysis: ThematicAnalysisResult) async throws -> ThematicAnalysisResult {
        let fields = ["title": analysis.primaryConcept.suggestedTitle,
                      "hook": analysis.essayPlan?.selectedHook?.text ?? ""]
        let data = try JSONEncoder().encode(fields)
        let base = String(decoding: data, as: UTF8.self)
        let sampling = profile.sampling
        var parameters = GenerateParameters(maxTokens: 512, temperature: 0.1,
            topP: sampling.topP, topK: sampling.topK, minP: sampling.minP, repetitionPenalty: nil)
        parameters.maxKVSize = sampling.maxKVSize ?? Self.unboundedKVTokenBudget
        parameters.kvBits = sampling.kvBits
        var lastError: (any Error)?
        for attempt in 1...2 {
            try Task.checkCancellation()
            let reply = try await streamReply(instructions: EssaySemanticSelection.languageInstructions,
                prompt: base + (attempt > 1 ? "\nЗбережи лексику й зміст; виправ лише граматику. Тільки JSON." : ""),
                parameters: parameters, stage: "language", attempt: attempt)
            DirectorRunLog.dumpRaw(reply.text, stage: "language", attempt: attempt)
            do {
                guard reply.completeness.isAcceptable else {
                    throw ThematicDiscoveryError.noGroundedTheme("обрезан ответ языковой вычитки")
                }
                return try EssaySemanticSelection.applyingLanguagePolish(reply.text, to: analysis)
            } catch { lastError = error }
        }
        throw lastError ?? ThematicDiscoveryError.modelReturnedNoText
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

    /// Той самий ключ порівняння тем, що й у гейта: trim + нижній регістр. Одна
    /// нормалізація з обох боків — інакше «Свобода » і «свобода» розійшлися б мовчки,
    /// і етап 2 переобрав би тему під носом у етапу 1.
    nonisolated static func themeKey(_ word: String) -> String {
        word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Провенанс этапа 1 можна заявляти тільки тоді, коли этап 2 пише про ту саму
    /// тему. Причина — чесна (обидва слова названі, нового ми не вигадуємо):
    /// не збіг = спробу відхиляємо, а не підлаштовуємо відповідь під winner.
    nonisolated static func essayThemeMismatch(
        _ returned: ThematicAnalysisResult,
        approved winner: ThematicConcept
    ) -> String? {
        guard themeKey(returned.primaryConcept.word) != themeKey(winner.word) else { return nil }
        return "етап 2 повернув тему «\(returned.primaryConcept.word)» замість схваленої етапом 1 «\(winner.word)» — провенанс етапу 1 не заявляємо"
    }

    /// Охоронець «мовчазного урізання»: бюджет ми рахуємо з реальних рядків, але якщо
    /// навіть тоді оцінка промпта разом з генерацією перевищує стелю KV (наприклад,
    /// профіль з малим `maxKVSize`), MLX обріже промпт на ротації — і єдиним слідом
    /// це має право бути цей рядок у director.log, а не тихий обрив `stop=length`.
    nonisolated static func warnIfPromptOverKVCap(
        stage: String,
        estimatedPromptTokens: Int,
        maxTokens: Int,
        kvCap: Int
    ) {
        let total = estimatedPromptTokens + maxTokens
        guard total > kvCap else { return }
        Self.log("""
            stage=\(stage): УВАГА, оцінка промпта \(estimatedPromptTokens) + генерація \(maxTokens) \
            = \(total) > стеля KV \(kvCap) — дайджест буде прорізаний ротацією, промпт не доходить до моделі цілком
            """)
    }

    /// Chars/token measured on the live two-stage run (28.10.2026, «Бійцівський
    /// клуб», український дубляж): 18 933 chars → 8 564 prompt tokens and 80 545
    /// chars → 35 921 prompt tokens, i.e. ≈2.2. The previous 3.7 came from a Latin
    /// corpus and halved every token estimate, so the "budget" shipped roughly
    /// twice as much text as the KV cache could hold. 2.0 keeps the estimate
    /// pessimistic in the safe direction: fewer characters reach the model.
    nonisolated static let approxCharsPerToken = 2.0

    /// Той самий консервативний перрахунок знаків у токени, що й бюджет: використовуємо
    /// і для оцінки готового промпта в логах, щоб «оцінка» і «бюджет» не були двома
    /// різними правдами.
    nonisolated static func estimatedTokens(of text: String) -> Int {
        Int(ceil(Double(text.count) / approxCharsPerToken))
    }

    /// Нижня межа накладних витрат промпта. Константа тут лише тому, що чат-шаблон
    /// Gemma (`<start_of_turn>`, `enable_thinking: false`) не є рядком, який ми
    /// збираємо, — його неможливо порахувати зі строки. Все решта рахується з
    /// реальних рядків; на живих промптах оцінка з рядків завжди більша за цю
    /// величину, тому вона floor, а не оцінка.
    nonisolated static let thematicChatTemplateFloorTokens = 128

    /// Токени, які промпт з'їдає на себе: інструкції + рамка користувацького
    /// промпта без дайджеста (з ремаркою повтору — найгірший випадок).
    ///
    /// Раніше це була константа `thematicPromptOverheadTokens = 1_500`, і вона
    /// майже втричі недооцінювала реальні інструкції этапа 2: живий прогін
    /// 28.10.2026 мав 11 376 prompt tokens при дайджесті 16 669 знаків, тобто
    /// ~3 800 токенів на інструкції й рамку. Разом зі стелею генерації 5 120 це
    /// 16 496 > стеля KV 16 384 — саме так спробу обрізало `stop=length`.
    /// Тепер цифра виростає разом з промптом, а не відстає від нього.
    nonisolated static func thematicPromptOverheadTokens(instructions: String, frameChars: Int) -> Int {
        max(
            thematicChatTemplateFloorTokens,
            Int(ceil(Double(instructions.count + frameChars) / approxCharsPerToken)))
    }

    /// Assumed token budget when a profile leaves KV unbounded (`maxKVSize == nil`),
    /// and the rotation cap we then hand to MLX. 40 000 was not a budget but a wish:
    /// the 35 921-token stage-2 prompt that fits inside it crashed the process on
    /// the second prefill (`mutex lock failed: Invalid argument`, mlx
    /// `transforms.cpp:15`) on this 18 GB machine with a 6.3 GB 4-bit 12B loaded.
    /// 16 384 is the same rotation point the Qwen profile declares and the region
    /// where live runs are known to survive.
    nonisolated static let unboundedKVTokenBudget = 16_384

    /// Количество коротких попыток для отбора тем на этапе 1.
    nonisolated static let stagedAttemptsPerStage = 2

    /// Этап 2 получает исходный план и две попытки, чтобы самой модели хватило
    /// пространства сохранить сильные сцены и добрать материал по актам.
    nonisolated static let essayPlanAttempts = 3

    nonisolated static func essaySceneRetryContext(
        _ moments: [SelectedMoment],
        catalogue: EssaySceneCatalogue?
    ) -> String {
        let entries = moments.prefix(EssayDurationPolicy.pool.upperBound).compactMap { moment -> String? in
            let role = moment.actRole?.promptKey ?? "role-missing"
            if let catalogue,
               let scene = catalogue.scenes.first(where: {
                   abs($0.start - moment.startTime) < 0.05 && abs($0.end - moment.endTime) < 0.05
               }) {
                return "\(scene.id)=\(role)"
            }
            return String(format: "%.0f-%.0f=%@", moment.startTime, moment.endTime, role)
        }
        return "Попередньо вибрані сцени (поверни повний список у відповіді; збережи придатні, виправ помилки та ДОДАЙ сцени з матеріалу для кожного недоукомплектованого акту; не дублюй): "
            + entries.joined(separator: ", ")
    }

    nonisolated static let thematicOverviewCharCap = 2_000

    /// Нижня межа дайджеста в токенах і в знаках: навіть на мікро-профілі KV модель
    /// повинна отримати початок і фінал фільму, а не порожній промпт. Якщо floor б'є
    /// стелю — це не мовчазне урізання: планувальник логує перевищення.
    nonisolated static let thematicMinDigestTokens = 1_024
    nonisolated static let thematicMinDigestChars = 2_000

    /// Character budget that provably fits the KV cap we hand to MLX together with
    /// the generation cap — `maxKVSize` is a rotation point, not a context window,
    /// so anything larger silently loses the head of the film (і на 18 ГБ це ще й
    /// `mutex lock failed` у процесі).
    ///
    /// `promptOverheadTokens` рахується з реальних рядків промпта
    /// (`thematicPromptOverheadTokens`), а не з константи: рамка з інструкціями
    /// з'їдає рівно стільки KV, скільки вона важить насправді.
    nonisolated static func thematicContextBudgetChars(
        maxKVSize: Int?,
        maxTokens: Int,
        promptOverheadTokens: Int
    ) -> Int {
        let kvTokens = maxKVSize ?? unboundedKVTokenBudget
        let transcriptTokens = max(
            thematicMinDigestTokens, kvTokens - maxTokens - promptOverheadTokens)
        return max(thematicMinDigestChars, Int(Double(transcriptTokens) * approxCharsPerToken))
    }

    /// Інструкції этапа 2: системний промпт Director + фокус на темі, схваленій
    /// этапом 1. Одна збірка і для генерації, і для бюджету — інакше цифра в логу
    /// описувала б інший промпт, ніж той, що пішов у модель.
    nonisolated static func essayInstructions(
        movieTitle: String,
        winner: ThematicConcept,
        approvedCandidates: [ThematicConcept],
        catalogueMode: Bool = false
    ) -> String {
        if catalogueMode {
            return DirectorStagedAnalysis.catalogueInstructions(movieTitle: movieTitle, concept: winner)
        }
        return LongformThematicService.thematicSystemPrompt(movieTitle: movieTitle)
            + "\n\n" + DirectorStagedAnalysis.stage2Focus(
                winner: winner.word,
                runnersUp: approvedCandidates.dropFirst().map(\.word))
            + "\nОбрана грань теми (збережи її сенс у тезі та відборі сцен): "
            + String(winner.philosophicalPremise.prefix(600))
    }

    /// План этапа 1: скільки знаків діалогів візьмемо і скільки токенів з'їдять
    /// інструкції. Обидві цифри — з тих самих рядків, що підуть у модель.
    nonisolated static func candidatesDigestPlan(
        movieTitle: String,
        overview: String,
        maxKVSize: Int?
    ) -> (digestChars: Int, promptOverheadTokens: Int) {
        let overhead = thematicPromptOverheadTokens(
            instructions: DirectorStagedAnalysis.candidatesInstructions(movieTitle: movieTitle),
            frameChars: DirectorStagedAnalysis.candidatesFrameChars(
                movieTitle: movieTitle, overview: overview))
        let room = thematicContextBudgetChars(
            maxKVSize: maxKVSize,
            maxTokens: DirectorStagedAnalysis.stage1MaxTokens,
            promptOverheadTokens: overhead)
        // 18 000 — власна стеля этапа 1 (саме монотонний промпт на 71 000 знаків і
        // ламав відповідь); KV-бюджет — зовнішня межа, тому бере менше з двох.
        return (min(DirectorStagedAnalysis.stage1DigestChars, room), overhead)
    }

    /// План этапа 2: весь залишок KV після реальних інструкцій і стелі генерації.
    nonisolated static func essayDigestPlan(
        movieTitle: String,
        overview: String,
        winner: ThematicConcept,
        approvedCandidates: [ThematicConcept],
        maxKVSize: Int?,
        catalogueMode: Bool = false
    ) -> (digestChars: Int, promptOverheadTokens: Int) {
        let overhead = thematicPromptOverheadTokens(
            instructions: essayInstructions(
                movieTitle: movieTitle, winner: winner, approvedCandidates: approvedCandidates,
                catalogueMode: catalogueMode),
            frameChars: catalogueMode
                ? DirectorStagedAnalysis.cataloguePrompt(movieTitle: movieTitle, overview: overview, digest: "").count
                    + DirectorStagedAnalysis.essayRetryNote.count + DirectorStagedAnalysis.evidenceFeedbackChars
                    + DirectorStagedAnalysis.essaySceneContextChars + 60
                : DirectorStagedAnalysis.essayFrameChars(
                movieTitle: movieTitle,
                overview: overview,
                theme: winner.word,
                tagline: winner.tagline))
        return (
            thematicContextBudgetChars(
                maxKVSize: maxKVSize,
                maxTokens: DirectorStagedAnalysis.stage2MaxTokens,
                promptOverheadTokens: overhead),
            overhead)
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

}
