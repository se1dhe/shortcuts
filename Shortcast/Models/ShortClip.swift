import Foundation
import Observation

/// One short being produced from a long video: the moment the Director picked,
/// the cut clip, its editable captions, and its own publish state. One
/// observable instance per card so each updates and publishes independently.
@MainActor
@Observable
final class ShortClip: Identifiable {

    let id = UUID()
    var candidate: ClipCandidate
    /// What's actually said in this clip's range — grounds the captioning.
    let transcriptSlice: String
    /// Transcript segments with timestamps for this clip's time range, used
    /// for burning subtitle overlays.
    var subtitleSegments: [SubtitleSegment]
    /// Original source metadata, e.g. the YouTube title/URL before download.
    let sourceMetadata: VideoSourceMetadata?

    /// The cut clip (url + duration); nil until cutting finishes.
    var clipJob: VideoJob?
    /// The three platform posts, edited in place by the card.
    var variants: [PostVariant] = []
    var detectedLanguage: String?

    /// Cinema metadata entered or detected by the user, persisted across card reopens.
    var detectedMovieTitle: String = ""
    var detectedMovieYear: String = ""
    var imdbRating: String?
    var rottenTomatoesScore: String?
    var posterURL: URL?
    /// Whether the generated description describes the scene (from the transcript)
    /// or the movie (its synopsis). Chosen in the editor, persisted across reopens.
    var descriptionMode: CinemaContentGenerator.DescriptionMode = .movie

    enum Stage: Equatable {
        case pending, cutting, captioning, ready
        case failed(String)
    }
    var stage: Stage = .pending

    /// Whether this clip is included in "Publish all approved".
    var isApproved = true

    /// Manual trim (in seconds, relative to the cut clip). `trimEndSeconds <= 0`
    /// means "until the end". Applied as the first render step so it stacks with
    /// reframe / subtitles / watermark.
    var trimStartSeconds: Double = 0
    var trimEndSeconds: Double = 0

    /// True when the user narrowed the clip beyond its natural bounds.
    var hasCustomTrim: Bool {
        let fullDuration = clipJob?.durationSeconds ?? 0
        let end = trimEndSeconds > 0 ? trimEndSeconds : fullDuration
        if trimStartSeconds > 0.05 { return true }
        if fullDuration > 0, end < fullDuration - 0.05 { return true }
        return false
    }

    /// Whether this clip was generated from a movie/cinema pipeline.
    /// In cinema mode, layout is strictly 1080x1080 square canvas, subtitles
    /// are strictly cinemaGrunge with AI moodProfile, and user app settings
    /// are not allowed to override the model's choices.
    var isCinemaMode: Bool {
        !detectedMovieTitle.isEmpty || candidate.mood != nil
    }

    /// Editable on-screen hook text, burned into the first seconds of the clip
    /// at publish time when `overlayEnabled` is on.
    var overlayText: String
    /// Per-clip switch for the burned-in text hook.
    var overlayEnabled: Bool
    /// Style + size of the burned-in hook (pill / pop / typewriter / neon / minimal).
    var hookAppearance: HookAppearance = .default

    /// Per-clip switch for reframing a horizontal clip to vertical 9:16 at
    /// publish time. Only takes effect when the cut clip is `isLandscape`.
    var reframeEnabled: Bool
    /// Whether the cut clip is wider than tall. Set by the pipeline after cutting;
    /// gates both the reframe and the per-clip toggle's visibility.
    var isLandscape = false

    /// Per-clip switch for burning transcript subtitles into the clip.
    var burnSubtitles: Bool
    /// Subtitle appearance override. Defaults to the global setting.
    var subtitleAppearance: SubtitleAppearance

    /// Per-clip switch for the burned-in watermark (typewriter / fade / static).
    var watermarkEnabled: Bool
    /// Watermark text (synced from global settings before publish).
    var watermarkText: String
    /// Watermark appearance (synced from global settings before publish).
    var watermarkAppearance: WatermarkAppearance

    /// Per-clip switch for the RedQueen bot promo banner at the top.
    var promoOverlayEnabled: Bool
    /// Promo code burned into the banner when `promoOverlayEnabled` is on.
    var promoCode: String
    /// Seconds the promo banner stays before it retracts. 0 = half the video.
    var promoDurationSeconds: Double
    // MARK: - Video enhancement (per-clip)

    /// Enhancement preset applied before export / publish.
    var videoEnhancementPreset: VideoEnhancementPreset
    /// Target FPS for RIFE interpolation (ultraHD4K only).
    var videoEnhancementRifeFPS: Int
    /// Real-ESRGAN upscaling factor.
    var videoEnhancementScale: Int
    /// FFmpeg unsharp mask strength.
    var videoEnhancementSharpness: Double
    /// FFmpeg eq contrast.
    var videoEnhancementContrast: Double
    /// FFmpeg eq saturation.
    var videoEnhancementSaturation: Double
    /// Output bitrate for HEVC pass (Mbps).
    var videoEnhancementBitrate: Int

    // MARK: - Background music & sound mastering
    /// Volume multiplier for the original video/speech track (0.0 = Muted, 1.0 = 100%, 2.0 = 200%).
    var originalAudioVolume: Double = 1.0
    /// Whether the original video audio track is muted completely.
    var isOriginalAudioMuted: Bool = false
    /// Whether background music is mixed into the short. Default true for cinema mode.
    var backgroundMusicEnabled: Bool = true
    /// User selected music track URL (if manually picked or imported).
    var selectedMusicURL: URL? = nil
    /// Master volume of overlaid background music across the entire short (0.0 to 1.5, default 0.70 = 70%).
    var musicVolume: Double = 0.70
    /// Trim/start offset for the background music (in seconds).
    var musicStartOffsetSeconds: Double = 0.0
    /// Total duration of the selected background music track (in seconds).
    var musicTrackDurationSeconds: Double = 0.0
    /// Whether voice ducking is enabled. When false, background music volume stays constant across the entire short.
    var musicDuckingEnabled: Bool = true
    /// Background music volume during speech (default -14.0 dB for optimal ducking).
    var musicDuckingDB: Float = -14.0
    /// Smooth fade-in duration for music (seconds).
    var musicFadeInDuration: Double = 0.30
    /// Smooth fade-out duration for music at the tail of the short (seconds).
    var musicFadeOutDuration: Double = 0.80

    // MARK: - Anti-Copyright Protection & TikTok Shield
    /// Whether anti-copyright protection transforms are enabled for this clip.
    var antiCopyrightEnabled: Bool = true
    /// User-selected anti-copyright protection preset.
    var antiCopyrightPreset: AntiCopyrightPreset = .tikTokShield
    /// Custom or active anti-copyright configuration.
    var antiCopyrightConfig: AntiCopyrightConfig = .tikTokShield

    private(set) var isPublishing = false
    private(set) var publishReport: UploadPostClient.PublishReport?
    var publishError: String?
    /// Last local TikTok risk assessment. It is informational for policy/IP
    /// risks, but blocks publishing when the prepared video is unreadable.
    private(set) var tiktokPreflightReport: TikTokPreflightService.Report?
    /// Set when the clip was published as a scheduled post (future date).
    private(set) var scheduledDate: Date?

    init(candidate: ClipCandidate, transcriptSlice: String,
         subtitleSegments: [SubtitleSegment],
         sourceMetadata: VideoSourceMetadata? = nil,
         overlayEnabled: Bool, reframeEnabled: Bool,
         burnSubtitles: Bool, subtitleAppearance: SubtitleAppearance,
         watermarkEnabled: Bool = false, watermarkText: String = "",
         watermarkAppearance: WatermarkAppearance = .default,
          promoOverlayEnabled: Bool = false, promoCode: String = PromoOverlayConfig.default.promoCode,
         promoDurationSeconds: Double = 0,
         videoEnhancementPreset: VideoEnhancementPreset = .off,
         videoEnhancementRifeFPS: Int = 60,
         videoEnhancementScale: Int = 2,
         videoEnhancementSharpness: Double = 1.5,
         videoEnhancementContrast: Double = 1.1,
         videoEnhancementSaturation: Double = 1.1,
         videoEnhancementBitrate: Int = 40) {
        self.candidate = candidate
        self.transcriptSlice = transcriptSlice
        self.subtitleSegments = subtitleSegments
        self.sourceMetadata = sourceMetadata
        self.overlayText = candidate.overlay
        self.overlayEnabled = overlayEnabled
        self.reframeEnabled = reframeEnabled
        self.burnSubtitles = burnSubtitles
        self.subtitleAppearance = subtitleAppearance
        self.watermarkEnabled = watermarkEnabled
        self.watermarkText = watermarkText
        self.watermarkAppearance = watermarkAppearance
        self.promoOverlayEnabled = promoOverlayEnabled
        self.promoCode = promoCode
        self.promoDurationSeconds = promoDurationSeconds
        self.videoEnhancementPreset = videoEnhancementPreset
        self.videoEnhancementRifeFPS = videoEnhancementRifeFPS
        self.videoEnhancementScale = videoEnhancementScale
        self.videoEnhancementSharpness = videoEnhancementSharpness
        self.videoEnhancementContrast = videoEnhancementContrast
        self.videoEnhancementSaturation = videoEnhancementSaturation
        self.videoEnhancementBitrate = videoEnhancementBitrate
    }

    var isReadyToPublish: Bool {
        if case .ready = stage { return !variants.isEmpty }
        return false
    }

    var displayTitle: String {
        if !detectedMovieTitle.trimmed.isEmpty {
            let yearPart = detectedMovieYear.trimmed.isEmpty ? "" : " (\(detectedMovieYear.trimmed))"
            return "🎬 \(detectedMovieTitle.trimmed)\(yearPart)"
        }
        let candidateHook = candidate.hook.trimmed
        if !candidateHook.isEmpty { return candidateHook }
        if let tikTokHook = variants.first(where: { $0.platform == .tiktok })?.hook.trimmed,
           !tikTokHook.isEmpty {
            return tikTokHook
        }
        if let firstHook = variants.map(\.hook).first(where: { !$0.trimmed.isEmpty })?.trimmed {
            return firstHook
        }
        return "Untitled short"
    }

    /// Whether this clip will be rendered (reframed and/or overlaid) before it's
    /// uploaded or downloaded — i.e. the published file differs from the raw cut.
    var isRendered: Bool {
        let wantReframe = reframeEnabled && isLandscape
        let wantOverlay = overlayEnabled && !overlayText.trimmed.isEmpty
        let wantSubtitles = burnSubtitles && !subtitleSegments.isEmpty
        let wantWatermark = watermarkEnabled && !watermarkText.isEmpty
        let wantPromo = promoOverlayEnabled && PromoOverlayConfig(promoCode: promoCode, holdSeconds: promoDurationSeconds).isValid
        let wantAudio = backgroundMusicEnabled || originalAudioVolume != 1.0 || isOriginalAudioMuted || musicStartOffsetSeconds > 0
        return wantReframe || wantOverlay || wantSubtitles || wantWatermark || wantPromo || wantAudio
    }

    /// Builds the file to upload or download: applies the vertical reframe and/or
    /// the burned-in text hook when enabled, otherwise returns the raw cut clip.
    /// `isTemporary` says whether the caller must delete the returned file.
    func makeRenderedFile(
        workingDirectory: URL? = nil,
        customMusicDirectory: URL? = nil,
        enhancementOptions: VideoEnhancementOptions? = nil
    ) async throws -> (url: URL, isTemporary: Bool) {
        guard let clipJob else { throw MomentFinderError.notReady }
        
        let hook = overlayText.trimmed
        let wantReframe = isCinemaMode ? isLandscape : (reframeEnabled && isLandscape)
        let wantOverlay = isCinemaMode ? false : (overlayEnabled && !hook.isEmpty)
        let wantSubtitles = isCinemaMode ? !subtitleSegments.isEmpty : (burnSubtitles && !subtitleSegments.isEmpty)
        let wantPromo = isCinemaMode ? false : (promoOverlayEnabled && PromoOverlayConfig(promoCode: promoCode, holdSeconds: promoDurationSeconds).isValid)
        let wantWatermark = watermarkEnabled && !watermarkText.isEmpty
        let wantsEnhancement = enhancementOptions?.preset != .off
        let wantAudio = backgroundMusicEnabled || originalAudioVolume != 1.0 || isOriginalAudioMuted || musicStartOffsetSeconds > 0
        let wantAntiCopyright = (isCinemaMode || antiCopyrightEnabled) && antiCopyrightConfig.isActive
        let needsRenderBase = isCinemaMode || hasCustomTrim || wantReframe || wantOverlay
        let needsRenderExtras = wantSubtitles || wantWatermark || wantPromo || wantsEnhancement || wantAudio || wantAntiCopyright
        let needsRender = needsRenderBase || needsRenderExtras
        let cacheKey = renderCacheKey(enhancementOptions: enhancementOptions)

        Self.log("render: burnSubtitles=\(burnSubtitles) segments=\(subtitleSegments.count) wantSubtitles=\(wantSubtitles)")
        Self.log("render: watermarkEnabled=\(watermarkEnabled) watermarkText='\(watermarkText)' wantWatermark=\(wantWatermark)")
        Self.log("render: overlayEnabled=\(overlayEnabled) hook='\(hook)' wantOverlay=\(wantOverlay)")
        Self.log("render: antiCopyrightEnabled=\(antiCopyrightEnabled) preset=\(antiCopyrightPreset.rawValue) wantAntiCopyright=\(wantAntiCopyright)")
        Self.log("render: needsRender=\(needsRender)")

        if needsRender,
           let cached = RenderedVideoCache.existingFile(for: cacheKey, workingDirectory: workingDirectory) {
            Self.log("render: returning CACHED file → \(cached.lastPathComponent)")
            return (cached, false)
        }

        var currentURL = clipJob.url
        var isTemp = false
        let tmp = workingDirectory ?? FileManager.default.temporaryDirectory

        // Step 0: manual trim (in/out from the timeline editor).
        if hasCustomTrim {
            let trimmed = try await VideoTrimmer.trim(
                videoURL: currentURL,
                startSeconds: trimStartSeconds,
                endSeconds: trimEndSeconds)
            if trimmed != currentURL {
                currentURL = trimmed
                isTemp = true
            }
        }

        // Step 0.5: Anti-Copyright Protection & TikTok Shield
        if wantAntiCopyright {
            Self.log("render: step 0.5 — anti-copyright protection (\(antiCopyrightPreset.rawValue))")
            let antiOut = tmp.appendingPathComponent("shortcast-anticopyright-\(id.uuidString).mp4")
            do {
                let service = AntiCopyrightService(config: antiCopyrightConfig)
                let protectedURL = try await service.process(
                    videoURL: currentURL,
                    outputURL: antiOut,
                    workingDirectory: workingDirectory)
                if isTemp && currentURL != clipJob.url {
                    try? FileManager.default.removeItem(at: currentURL)
                }
                currentURL = protectedURL
                isTemp = true

                // Scale subtitle timestamps if audioSpeedMultiplier changed video duration
                if abs(antiCopyrightConfig.audioSpeedMultiplier - 1.0) > 0.0001 {
                    let speedFactor = 1.0 / antiCopyrightConfig.audioSpeedMultiplier
                    subtitleSegments = subtitleSegments.map { $0.scaled(by: speedFactor) }
                    Self.log("render: adjusted subtitle timestamps by speed factor \(speedFactor)")
                }

                Self.log("render: step 0.5 — anti-copyright protection OK")
            } catch {
                Self.log("anti-copyright protection fallback: \(error.localizedDescription)")
            }
        }

        // Step 1: reframe + overlay hook.
        if wantReframe || wantOverlay {
            Self.log("render: step 1 — reframe=\(wantReframe) overlay=\(wantOverlay)")
            if let url = try await VerticalReframer.process(
                  clipURL: currentURL,
                  reframe: wantReframe,
                  overlayText: wantOverlay ? hook : nil,
                  promoCode: wantPromo ? promoCode : nil,
                  promoHoldSeconds: promoDurationSeconds,
                  hookAppearance: hookAppearance) {
                currentURL = url
                isTemp = true
            }
        }

        // Step 2: burn subtitles.
        if wantSubtitles {
            Self.log("render: step 2 — burning \(subtitleSegments.count) subtitle segments")
            let subOut = tmp
                .appendingPathComponent("shortcast-subtitles-\(id.uuidString).mp4")
            try await SubtitleRenderer.burn(
                videoURL: currentURL,
                segments: subtitleSegments,
                appearance: subtitleAppearance,
                watermarkText: wantWatermark ? watermarkText : nil,
                watermarkAppearance: watermarkAppearance,
                promoCode: wantPromo ? promoCode : nil,
                promoHoldSeconds: promoDurationSeconds,
                outputURL: subOut)
            if isTemp && currentURL != clipJob.url {
                try? FileManager.default.removeItem(at: currentURL)
            }
            currentURL = subOut
            isTemp = true
            Self.log("render: step 2 — subtitles burned OK")
        } else {
            Self.log("render: step 2 — SKIPPED (burnSubtitles=\(burnSubtitles), segments=\(subtitleSegments.count))")
        }

        // Step 3: watermark. When subtitles are enabled it was composed in
        // their export above, so there is no second full-video encode.
        if wantWatermark && !wantSubtitles {
            Self.log("render: step 3 — watermark standalone")
            let wmURL = try await WatermarkRenderer.render(
                videoURL: currentURL,
                text: watermarkText,
                appearance: watermarkAppearance)
            if isTemp && currentURL != clipJob.url {
                try? FileManager.default.removeItem(at: currentURL)
            }
            currentURL = wmURL
            isTemp = true
        } else if wantWatermark && wantSubtitles {
            Self.log("render: step 3 — watermark already included in subtitle pass")
        } else {
            Self.log("render: step 3 — SKIPPED (watermarkEnabled=\(watermarkEnabled), watermarkText='\(watermarkText)')")
        }

        // Step 4: partner promo banner at the top.
        let promoConfig = PromoOverlayConfig(promoCode: promoCode, holdSeconds: promoDurationSeconds).sanitized
        // When a hook or reframe was rendered, the promo was included in that
        // same pass. Render it separately only when it is the sole visual layer.
        if promoOverlayEnabled && promoConfig.isValid && !(wantReframe || wantOverlay || wantSubtitles) {
            let promoURL = try await PromoOverlayRenderer.render(
                videoURL: currentURL,
                config: promoConfig)
            if isTemp && currentURL != clipJob.url {
                try? FileManager.default.removeItem(at: currentURL)
            }
            currentURL = promoURL
            isTemp = true
        }

        // Step 5: optional cinematic / 4K enhancement (applied last).
        if let options = enhancementOptions, options.preset != .off {
            let enhanced = try await VideoEnhancementService.enhance(
                videoURL: currentURL,
                options: options,
                workingDirectory: workingDirectory)
            if isTemp {
                try? FileManager.default.removeItem(at: currentURL)
            }
            currentURL = enhanced
            isTemp = true
        }

        // Step 6: Audio Mastering (-14 LUFS + original volume control + background music trimming & ducking)
        if isCinemaMode || wantAudio {
            Self.log("render: step 6 — audio mastering (-14 LUFS, music=\(backgroundMusicEnabled), origVol=\(originalAudioVolume), muted=\(isOriginalAudioMuted))")
            let masteredOut = tmp.appendingPathComponent("shortcast-mastered-\(id.uuidString).mp4")
            let speechTimes = subtitleSegments.map { (start: $0.start, end: $0.end) }
            do {
                let bgMusic: URL?
                if backgroundMusicEnabled {
                    if let customSelected = selectedMusicURL {
                        bgMusic = customSelected
                    } else {
                        let mood = candidate.mood?.mood.rawValue ?? detectedMovieTitle
                        bgMusic = await BackgroundMusicSelector.selectBestTrack(from: customMusicDirectory, mood: mood)
                    }
                } else {
                    bgMusic = nil
                }

                let effectiveOriginalVol = isOriginalAudioMuted ? 0.0 : Float(originalAudioVolume)
                let mixConfig = CinemaAudioMasteringService.AudioMixConfig(
                    musicURL: bgMusic,
                    originalAudioVolume: effectiveOriginalVol,
                    dialogueBoostDB: isOriginalAudioMuted ? -100.0 : 2.0,
                    musicVolume: Float(musicVolume),
                    musicStartOffsetSeconds: musicStartOffsetSeconds,
                    musicDuckingEnabled: musicDuckingEnabled,
                    musicDuckingDB: musicDuckingDB,
                    musicRestingDB: -6.0,
                    musicFadeInDuration: musicFadeInDuration,
                    musicFadeOutDuration: musicFadeOutDuration
                )

                try await CinemaAudioMasteringService.applyMastering(
                    videoURL: currentURL,
                    speechSegments: speechTimes,
                    backgroundMusicURL: bgMusic,
                    outputURL: masteredOut,
                    config: mixConfig)
                if isTemp && currentURL != clipJob.url {
                    try? FileManager.default.removeItem(at: currentURL)
                }
                currentURL = masteredOut
                isTemp = true
                Self.log("render: step 6 — audio mastering OK (-14 LUFS with music: \(bgMusic?.lastPathComponent ?? "none"))")
            } catch {
                Self.log("audio mastering fallback: \(error.localizedDescription)")
            }
        }


        if needsRender,
           let cachedURL = try RenderedVideoCache.store(
                currentURL, key: cacheKey, workingDirectory: workingDirectory) {
            if isTemp && currentURL != clipJob.url {
                try? FileManager.default.removeItem(at: currentURL)
            }
            Self.log("render: stored to cache → \(cachedURL.lastPathComponent)")
            return (cachedURL, false)
        }

        Self.log("render: done → \(currentURL.lastPathComponent)")
        return (currentURL, isTemp)
    }

    func makePreviewFile(workingDirectory: URL? = nil,
                         customMusicDirectory: URL? = nil,
                         enhancementOptions: VideoEnhancementOptions? = nil) async throws -> (url: URL, isTemporary: Bool) {
        try await makeRenderedFile(workingDirectory: workingDirectory,
                                   customMusicDirectory: customMusicDirectory,
                                   enhancementOptions: enhancementOptions)
    }

    func makeExportReadyFile(workingDirectory: URL? = nil,
                             customMusicDirectory: URL? = nil,
                             enhancementOptions: VideoEnhancementOptions? = nil) async throws -> (url: URL, isTemporary: Bool) {
        try await makeRenderedFile(workingDirectory: workingDirectory,
                                   customMusicDirectory: customMusicDirectory,
                                   enhancementOptions: enhancementOptions)
    }

    func applyGeneratedCopy(_ result: GenerationResult, detectedLanguage: String?) {
        variants = result.variants
        self.detectedLanguage = detectedLanguage

        guard overlayText.trimmed.isEmpty else { return }
        let generatedHook = result.variant(for: .tiktok)?.hook.trimmed
            ?? result.variants.map(\.hook).first(where: { !$0.trimmed.isEmpty })?.trimmed
        if let generatedHook, !generatedHook.isEmpty {
            overlayText = generatedHook.truncatingToHook(limit: 50)
        }

        generatePinnedComments()
    }

    /// Fills the `pinnedComment` field on every variant with a 1win promo
    /// template when the promo overlay is enabled. Can be called again to
    /// regenerate or left alone for manual edits.
    func generatePinnedComments() {
        guard promoOverlayEnabled else { return }
        let text = PinnedCommentGenerator.generate(promoCode: promoCode)
        for index in variants.indices {
            guard variants[index].pinnedComment.trimmed.isEmpty else { continue }
            variants[index].pinnedComment = text
        }
    }

    // MARK: - Publishing

    func publish(
        settings: AppSettings,
        selectedPlatforms: Set<SocialPlatform>? = nil,
        scheduledDate: Date? = nil
    ) async {
        guard clipJob != nil, !isPublishing else { return }
        publishError = nil
        publishReport = nil
        isPublishing = true
        defer { isPublishing = false }

        // Reframe + overlay + subtitles. Clean up temp files after upload.
        let uploadURL: URL
        let isTemporary: Bool
        do {
            let enhance = VideoEnhancementOptions(
                preset: videoEnhancementPreset,
                rifeFrameRate: videoEnhancementRifeFPS,
                realesrganScale: videoEnhancementScale,
                sharpness: videoEnhancementSharpness,
                contrast: videoEnhancementContrast,
                saturation: videoEnhancementSaturation,
                bitrateMbps: videoEnhancementBitrate)
            (uploadURL, isTemporary) = try await makeRenderedFile(
                workingDirectory: settings.workingDirectory,
                customMusicDirectory: settings.customMusicDirectory,
                enhancementOptions: enhance)
        } catch {
            publishError = "Couldn't prepare the clip for publishing: \(error.localizedDescription)"
            return
        }
        defer { if isTemporary { try? FileManager.default.removeItem(at: uploadURL) } }

        let tiktok = variants.first(where: { $0.platform == .tiktok })
        let preflight = await TikTokPreflightService.check(
            videoURL: uploadURL,
            sourceMetadata: sourceMetadata,
            tiktokVariant: tiktok,
            promoEnabled: promoOverlayEnabled,
            antiCopyrightEnabled: antiCopyrightEnabled,
            antiCopyrightConfig: antiCopyrightConfig)
        tiktokPreflightReport = preflight
        if preflight.blocksUpload {
            publishError = "TikTok preflight found a technical blocker: \(preflight.findings.first(where: { $0.severity == .error })?.detail ?? "inspect the final video and try again.")"
            return
        }

        let client = UploadPostClient(
            apiKey: settings.apiKey,
            profileName: settings.profileName)
        do {
            publishReport = try await client.publish(
                videoURL: uploadURL,
                variants: variants,
                tiktokAsDraft: settings.tiktokAsDraft,
                selectedPlatforms: selectedPlatforms,
                scheduledDate: scheduledDate)
            self.scheduledDate = scheduledDate
        } catch {
            publishError = error.localizedDescription
        }
    }

    // MARK: - Telegram Publishing

    var isPublishingToTelegram = false
    var telegramPostURL: String?
    var telegramPublishError: String?

    func publishToTelegram(
        settings: AppSettings,
        service: TelegramPublishingProtocol = TelegramPublishingService.shared
    ) async {
        guard !isPublishingToTelegram else { return }
        isPublishingToTelegram = true
        telegramPublishError = nil
        defer { isPublishingToTelegram = false }

        do {
            let msgId = try await service.publishMoviePost(
                clip: self,
                botToken: settings.telegramBotToken,
                channelId: settings.telegramChannelId
            )
            let channelClean = settings.telegramChannelId.trimmingCharacters(in: CharacterSet(charactersIn: "@"))
            self.telegramPostURL = "https://t.me/\(channelClean)/\(msgId)"
        } catch {
            self.telegramPublishError = error.localizedDescription
        }
    }

    // MARK: - Download

    private(set) var isExporting = false
    var exportError: String?

    /// Renders the publish-ready file (reframe + overlay + subtitles) and copies it to
    /// `destination`. Used by the "Download" action on each clip.
    func export(to destination: URL, workingDirectory: URL? = nil,
                customMusicDirectory: URL? = nil,
                enhancementOptions: VideoEnhancementOptions? = nil) async {
        guard clipJob != nil, !isExporting else { return }
        exportError = nil
        isExporting = true
        defer { isExporting = false }

        do {
            let (url, isTemporary) = try await makeRenderedFile(
                workingDirectory: workingDirectory,
                customMusicDirectory: customMusicDirectory,
                enhancementOptions: enhancementOptions)
            defer { if isTemporary { try? FileManager.default.removeItem(at: url) } }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: url, to: destination)
        } catch {
            exportError = error.localizedDescription
        }
    }

    /// Suggested filename for a download, derived from the hook.
    var suggestedFileName: String {
        var rawText = displayTitle
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        
        // Fix merged pronouns/prepositions (e.g., "тыразбил" -> "ты разбил", "былидеальным" -> "был идеальным")
        let splitPatterns = [
            #"(?i)\b(ты|я|мы|вы|он|она|они|был|была|были|не|в|на|с|со|по|за|к|из|от|до)(разбил|был|была|были|идеальным|знаешь|стоишь|сбивал|защищал|хотел|нанял|вел|делал)\b"#: "$1 $2"
        ]
        for (pattern, template) in splitPatterns {
            rawText = rawText.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }

        var base = rawText
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9а-яё]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        
        if base.count > 50 {
            let prefix = String(base.prefix(50))
            if let lastHyphen = prefix.lastIndex(of: "-"), lastHyphen > prefix.index(prefix.startIndex, offsetBy: 20) {
                base = String(prefix[..<lastHyphen])
            } else {
                base = prefix
            }
        }
        base = base.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return (base.isEmpty ? "short" : base) + ".mp4"
    }

    func dismissPublishResult() {
        publishReport = nil
        publishError = nil
    }

    /// Runs the same local assessment used directly before upload, against the
    /// latest prepared clip available on disk. Final render settings are checked
    /// again when Publish is pressed.
    func runTikTokPreflight() async {
        guard let clipJob else { return }
        let tiktok = variants.first(where: { $0.platform == .tiktok })
        tiktokPreflightReport = await TikTokPreflightService.check(
            videoURL: clipJob.url,
            sourceMetadata: sourceMetadata,
            tiktokVariant: tiktok,
            promoEnabled: promoOverlayEnabled,
            antiCopyrightEnabled: antiCopyrightEnabled,
            antiCopyrightConfig: antiCopyrightConfig)
    }

    func applySubtitleDefaults(_ appearance: SubtitleAppearance, burnSubtitles: Bool) {
        self.subtitleAppearance = appearance
        self.burnSubtitles = burnSubtitles
    }

    func applyWatermarkDefaults(enabled: Bool, text: String, appearance: WatermarkAppearance) {
        self.watermarkEnabled = enabled
        self.watermarkText = text
        self.watermarkAppearance = appearance
    }

    func applyPromoDefaults(enabled: Bool, promoCode: String, durationSeconds: Double = 0) {
        self.promoOverlayEnabled = enabled
        self.promoCode = promoCode
        self.promoDurationSeconds = durationSeconds
    }

    private func renderCacheKey(enhancementOptions: VideoEnhancementOptions?) -> String {
        let sourceValues = try? clipJob?.url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let subtitles = subtitleSegments.map { "\($0.start)|\($0.end)|\($0.text)" }.joined(separator: "\n")
        let payload = [
            clipJob?.url.path ?? "",
            String(sourceValues?.fileSize ?? 0),
            String(sourceValues?.contentModificationDate?.timeIntervalSince1970 ?? 0),
            String(trimStartSeconds), String(trimEndSeconds),
            String(reframeEnabled), String(isLandscape),
            String(overlayEnabled), overlayText, String(describing: hookAppearance),
            detectedMovieTitle, detectedMovieYear,
            String(burnSubtitles), subtitles, String(describing: subtitleAppearance),
            String(watermarkEnabled), watermarkText, String(describing: watermarkAppearance),
            String(promoOverlayEnabled), promoCode, String(promoDurationSeconds),
            String(enhancementOptions?.preset.rawValue ?? "off"),
            String(enhancementOptions?.rifeFrameRate ?? 0),
            String(enhancementOptions?.realesrganScale ?? 0),
            String(enhancementOptions?.sharpness ?? 0),
            String(enhancementOptions?.contrast ?? 0),
            String(enhancementOptions?.saturation ?? 0),
            String(enhancementOptions?.bitrateMbps ?? 0),
            String(originalAudioVolume), String(isOriginalAudioMuted),
            String(backgroundMusicEnabled), selectedMusicURL?.absoluteString ?? "",
            String(musicVolume), String(musicStartOffsetSeconds),
            String(musicDuckingEnabled), String(musicDuckingDB),
            String(musicFadeInDuration), String(musicFadeOutDuration),
            String(antiCopyrightEnabled), antiCopyrightPreset.rawValue, String(antiCopyrightConfig.hashValue),
        ].joined(separator: "\u{1F}")
        return RenderedVideoCache.key(for: payload)
    }

    nonisolated static func log(_ message: String) {
        FileHandle.standardError.write(Data("[shortcast/clip] \(message)\n".utf8))
    }
}
