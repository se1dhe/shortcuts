import AVFoundation
import CoreMedia
import Foundation
import OSLog

/// Реализация координатора сборки длинных видео Shortcast Cinema (SOLID)
final class LongformPipelineCoordinator: LongformPipelineCoordinating, Sendable {

    private static let logger = Logger(subsystem: "app.shortcast", category: "LongformPipelineCoordinator")

    private let director: any LongformNarrativeDirecting
    private let audioMastering: any LongformAudioMasteringProtocol
    private let subtitleRenderer: any LongformSubtitleRenderingProtocol
    private let thumbnailGenerator: any LongformThumbnailGeneratingProtocol
    private let audioLooper: any SeamlessAudioLooping
    private let loudnessNormalizer: any LongformLoudnessNormalizing
    private let actTitling: any LongformActTitling
    private let editorialReview: LongformEditorialReview
    private let discussionURL: String?
    private let support: EssaySupport?
    private let modelManager: ModelManager?

    init(
        director: any LongformNarrativeDirecting = LongformNarrativeDirector(),
        audioMastering: any LongformAudioMasteringProtocol = LongformAudioMasteringService(),
        subtitleRenderer: any LongformSubtitleRenderingProtocol = LongformSubtitleRenderer(),
        thumbnailGenerator: any LongformThumbnailGeneratingProtocol = LongformThumbnailGenerator(),
        audioLooper: any SeamlessAudioLooping = SeamlessAudioLoopService.shared,
        loudnessNormalizer: any LongformLoudnessNormalizing = LongformLoudnessService(),
        actTitling: any LongformActTitling = LongformActTitleService(),
        editorialReview: LongformEditorialReview = LongformEditorialReview(model: nil),
        discussionURL: String? = nil,
        support: EssaySupport? = nil,
        modelManager: ModelManager? = nil
    ) {
        self.director = director
        self.audioMastering = audioMastering
        self.subtitleRenderer = subtitleRenderer
        self.thumbnailGenerator = thumbnailGenerator
        self.audioLooper = audioLooper
        self.loudnessNormalizer = loudnessNormalizer
        self.actTitling = actTitling
        self.editorialReview = editorialReview
        self.discussionURL = discussionURL
        self.support = support
        self.modelManager = modelManager
    }

    func buildLongformVideo(
        sourceURL: URL,
        movieTitle: String,
        transcript: Transcript,
        concept: ThematicConcept,
        selectedMoments: [SelectedMoment] = [],
        essayPlan: EssayPlan? = nil,
        audioSettings: LongformAudioSettings,
        existingArc: LongformNarrativeArc? = nil,
        allowUserApprovedScenes: Bool = false,
        workingDirectory: URL? = nil,
        channelLogoEnabled: Bool,
        progressHandler: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> LongformBuildResult {
        let audioSettings = existingArc?.musicSettings ?? audioSettings
        if concept.source == .llm, concept.publicationWord == nil,
           let issue = await MainActor.run(body: { UkrainianTextReview.themeSpellingIssue(concept.displayWord) }) {
            throw NSError(domain: "EssayThemeSpelling", code: 1,
                userInfo: [NSLocalizedDescriptionKey: issue])
        }

        // 1. Построение арки: аналитическая 5-актная или прежняя 4-актная
        var arc: LongformNarrativeArc
        if let existing = existingArc {
            progressHandler?(0.10, "Использование утвержденного монтажа «\(concept.word)»...")
            arc = existing
        } else {
            progressHandler?(0.10, "Режиссура 4-актной арки «\(concept.word)»...")
            let built = try await director.buildArc(
                from: transcript,
                concept: concept,
                selectedMoments: selectedMoments,
                movieTitle: movieTitle,
                targetDuration: essayPlan?.effectiveTargetDuration ?? EssayDurationPolicy.defaultRenderedTarget,
                essayPlan: essayPlan,
                sourceMovieURL: sourceURL
            )
            
            // Режиссёрское ревью арки (опциональный второй LLM-проход)
            progressHandler?(0.12, "Редакторская проверка сцен и соседних реплик...")
            let reviewedArc = await editorialReview.review(
                arc: built, transcript: transcript, coldOpenEnabled: audioSettings.coldOpenEnabled)
            try Task.checkCancellation()
            
            // Второй LLM-проход: названия актов из РЕАЛЬНОГО диалога, вошедшего в каждый акт.
            // Выполняется ровно один раз и до stagedArc, иначе LongformAct.id меняется под
            // открытым редактором и правки сцен осиротевают.
            let outcome = await actTitling.applyTitles(
                to: reviewedArc,
                transcript: transcript,
                movieTitle: movieTitle,
                progress: { step in progressHandler?(0.15, step) }
            )
            arc = outcome.arc
        }

        arc.viewerPromise = arc.viewerPromise ?? arc.thesis ?? concept.philosophicalPremise
        arc.discussionURL = discussionURL ?? arc.discussionURL
        arc.support = arc.support ?? support
        arc.musicSettings = MusicBedMixing.resolvedSettings(arc.musicSettings ?? audioSettings,
            for: arc, coldOpenEnabled: audioSettings.coldOpenEnabled)
        if let issue = arc.support?.validationIssue {
            throw NSError(domain: "EssaySupport", code: 1, userInfo: [NSLocalizedDescriptionKey: issue])
        }
        if !selectedMoments.isEmpty, selectedMoments.allSatisfy({ $0.evidenceQuote != nil }) {
            try EssaySceneEvidence.validateArc(
                arc, selectedMoments: selectedMoments, coldOpenEnabled: audioSettings.coldOpenEnabled,
                allowApprovedTrim: existingArc != nil,
                allowUserApprovedScenes: allowUserApprovedScenes)
        }
        let segments = arc.segments
        guard !segments.isEmpty else {
            throw NSError(domain: "LongformPipeline", code: -1, userInfo: [NSLocalizedDescriptionKey: "Не удалось выделить сегменты для ролика."])
        }

        // 2. Подготовка AVComposition
        progressHandler?(0.25, "Сборка видеокомпозиции 1920x1080...")
        let composition = AVMutableComposition()

        guard let compVideoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let compSpeechTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else {
            throw NSError(domain: "LongformPipeline", code: -2, userInfo: [NSLocalizedDescriptionKey: "Ошибка создания дорожек AVComposition."])
        }

        let sourceAsset = AVURLAsset(url: sourceURL)
        let sourceVideoTracks = try await sourceAsset.loadTracks(withMediaType: .video)
        let sourceAudioTracks = try await sourceAsset.loadTracks(withMediaType: .audio)

        guard let sourceVideoTrack = sourceVideoTracks.first else {
            throw NSError(domain: "LongformPipeline", code: -3, userInfo: [NSLocalizedDescriptionKey: "В исходном видео не найдена дорожка видео."])
        }

        let sourceAudioTrack = sourceAudioTracks.first

        // 2. Кинематографический Cold Open (нарастание саундтрека в затемнении)
        arc.editorialNotes = LongformEditorialSupport.refreshedNotes(for: arc, transcript: transcript)
        let timeline = LongformTimeline(arc: arc, coldOpenEnabled: audioSettings.coldOpenEnabled)
        let introPadding = timeline.introDuration
        var insertTime = CMTime(seconds: introPadding, preferredTimescale: 600)
        var timedPhrases: [TimedSubtitlePhrase] = []
        let qualityGate = TranscriptQualityGate(segments: transcript.segments)
        var sceneCutPoints: [Double] = [introPadding]
        var cutTransitions: [LongformCutTransition] = []
        let interActGap = LongformTimeline.interActGap
        let intraActGap = LongformTimeline.intraActGap
        let captionSegments = LongformEditorialSupport.captions(transcript.segments, edits: arc.captionEdits)
        // An archive can predate language checks. Validate only the subtitles
        // actually selected for this Ukrainian essay, after approved edits.
        let captionLanguage = transcript.contentLanguage == "uk" || transcript.language == "uk" ? "uk" : transcript.language
        try TranscriptionService.validateRenderedCaptions(captionSegments, ranges: arc.segments,
            requestedLanguage: captionLanguage)


        // Вставляем нарезанные сцены фильма по актам с кинематографическим разделением
        for (actIndex, act) in arc.acts.enumerated() {
            // Пауза-«дыхание» имеет смысл только между двумя содержательными актами:
            // пустой акт ничего не вставляет, и щель рядом с ним была бы мёртвым чёрным
            // экраном, который при этом засчитывается в хронометраж.
            if actIndex > 0,
               !act.segments.isEmpty,
               timeline.placements.contains(where: { $0.actIndex == actIndex && $0.isInterAct }) {
                let prevEnd = insertTime.seconds
                // Добавляем меж-актовую паузу (черный экран, где звучит только фоновая музыка)
                insertTime = CMTimeAdd(insertTime, CMTime(seconds: interActGap, preferredTimescale: 600))
                let nextStart = insertTime.seconds
                cutTransitions.append(LongformCutTransition(
                    sceneEndTime: prevEnd,
                    nextSceneStartTime: nextStart,
                    isInterAct: true
                ))
                sceneCutPoints.append(nextStart)
            }
            for (segIndex, segment) in act.segments.enumerated() {
                if segIndex > 0 {
                    let prevEnd = insertTime.seconds
                    // Пауза между сценами внутри одного акта (мягкий переход)
                    insertTime = CMTimeAdd(insertTime, CMTime(seconds: intraActGap, preferredTimescale: 600))
                    let nextStart = insertTime.seconds
                    cutTransitions.append(LongformCutTransition(
                        sceneEndTime: prevEnd,
                        nextSceneStartTime: nextStart,
                        isInterAct: false
                    ))
                    sceneCutPoints.append(nextStart)
                }

                let startCM = CMTime(seconds: segment.start, preferredTimescale: 600)
                let durationCM = CMTime(seconds: segment.duration, preferredTimescale: 600)
                let timeRange = CMTimeRange(start: startCM, duration: durationCM)

                try compVideoTrack.insertTimeRange(timeRange, of: sourceVideoTrack, at: insertTime)

                if let sourceAudioTrack {
                    try compSpeechTrack.insertTimeRange(timeRange, of: sourceAudioTrack, at: insertTime)
                }

                let insertedStart = insertTime.seconds
                let insertedEnd = insertedStart + segment.duration

                // Сопоставляем фразы из транскрипта с новым таймлайном
                let matchingSegments = transcript.segments.filter {
                    $0.end > segment.start && $0.start < segment.end && qualityGate.isUsable($0)
                }
                for s in matchingSegments {
                    let phraseStart = max(insertedStart, insertedStart + (s.start - segment.start))
                    let phraseEnd = min(insertedEnd, insertedStart + (s.end - segment.start))
                    if phraseEnd > phraseStart {
                        let caption = captionSegments.first { $0.start == s.start && $0.end == s.end }?.text ?? s.text
                        timedPhrases.append(TimedSubtitlePhrase(start: phraseStart, end: phraseEnd, text: caption))
                    }
                }

                insertTime = CMTimeAdd(insertTime, durationCM)
            }
        }

        // Кинематографический хвост послевкусия (Outro Tail): 4.0 секунды черного экрана
        // после завершения речи, во время которых фоновая музыка солирует и плавно затухает
        let speechFinishTime = insertTime.seconds
        let outroPadding = timeline.outroDuration
        let totalDuration = speechFinishTime + outroPadding
        let totalDurationCM = CMTime(seconds: totalDuration, preferredTimescale: 600)
        // Empty ranges alone are trimmed by the exporter without a music bed.
        // Carry the CTA tail on silent video samples from the last approved
        // clip. The video layer is explicitly invisible from speechFinishTime,
        // so these samples only keep the black CTA canvas alive.
        if outroPadding > 0, let last = segments.last, last.duration > 0 {
            var remaining = outroPadding
            var tailCursor = insertTime
            while remaining > 0.001 {
                let chunk = min(last.duration, remaining)
                let duration = CMTime(seconds: chunk, preferredTimescale: 600)
                try compVideoTrack.insertTimeRange(CMTimeRange(
                    start: CMTime(seconds: last.start, preferredTimescale: 600), duration: duration),
                    of: sourceVideoTrack, at: tailCursor)
                tailCursor = CMTimeAdd(tailCursor, duration)
                remaining -= chunk
            }
        }

        // Формируем интервалы реальной речи из Whisper для сайдчейн-дакинга музыки
        let speechIntervals: [TimeSegment] = timedPhrases.map { TimeSegment(start: $0.start, end: $0.end) }

        // 3. Подключение фонового саундтрека с бесшовным мягким зацикливанием
        progressHandler?(0.50, "Мастеринг непрерывного саундтрека...")
        var audioMix: AVAudioMix? = nil
        let musicURL: URL? = audioSettings.backgroundMusicURL
        if arc.musicSettings == nil, let rawMusicURL = musicURL,
           FileManager.default.isReadableFile(atPath: rawMusicURL.path) {
            // Не создаём пустой audio track для удалённого/недоступного файла.
            // AVAssetExportSession может завершиться общим -12123 даже когда
            // этот track так и не получил ни одного sample. Исходный звук фильма
            // остаётся в композиции и экспорт продолжается без фоновой музыки.
            // Если видео длиннее саундтрека, бесшовно зацикливаем его с мягким психоакустическим кроссфейдом
            let effectiveMusicURL: URL
            if totalDuration > 0 {
                effectiveMusicURL = (try? await audioLooper.createSeamlessLoop(
                    sourceURL: rawMusicURL,
                    targetDuration: totalDuration + 5.0,
                    crossfadeDuration: 4.0
                )) ?? rawMusicURL
            } else {
                effectiveMusicURL = rawMusicURL
            }

            let musicAsset = AVURLAsset(url: effectiveMusicURL)
            if let sourceMusicTrack = (try? await musicAsset.loadTracks(withMediaType: .audio))?.first,
               let musicDuration = try? await musicAsset.load(.duration),
               musicDuration.seconds.isFinite, musicDuration.seconds > 0,
               let compMusicTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {

                var musicInsertTime = CMTime.zero
                while musicInsertTime < totalDurationCM {
                    let remaining = CMTimeSubtract(totalDurationCM, musicInsertTime)
                    let chunk = CMTimeMinimum(remaining, musicDuration)
                    let range = CMTimeRange(start: .zero, duration: chunk)
                    try compMusicTrack.insertTimeRange(range, of: sourceMusicTrack, at: musicInsertTime)
                    musicInsertTime = CMTimeAdd(musicInsertTime, chunk)
                }

                audioMix = audioMastering.buildAudioMixParameters(
                    composition: composition,
                    musicTrack: compMusicTrack,
                    speechTrack: compSpeechTrack,
                    speechIntervals: speechIntervals,
                    sceneCutPoints: sceneCutPoints,
                    cutTransitions: cutTransitions,
                    totalDuration: totalDuration,
                    baseMusicVolume: audioSettings.musicVolume,
                    duckingEnabled: audioSettings.duckingEnabled,
                    dialogueFocusEnabled: audioSettings.dialogueFocusEnabled,
                    originalMusicDucking: audioSettings.originalMusicDucking
                )
            } else {
                OperationJournal.shared.append("Configured background music has no readable audio track; exporting with source audio only", level: .warning)
                Self.logger.warning("Configured background music has no readable audio track; exporting with source audio only")
            }
        } else if arc.musicSettings == nil, let musicURL {
            OperationJournal.shared.append("Configured background music is unavailable (\(musicURL.lastPathComponent)); exporting with source audio only", level: .warning)
            Self.logger.warning("Configured background music is unavailable (\(musicURL.lastPathComponent, privacy: .public)); exporting with source audio only")
            progressHandler?(0.50, "Фоновая музыка не найдена — продолжаю с оригинальным звуком фильма...")
        }

        if let musicSettings = arc.musicSettings {
            if let params = try await MusicBedMixing.add(to: composition, settings: musicSettings,
                                                         duration: totalDuration, speech: speechIntervals),
               let track = composition.track(withTrackID: params.trackID) {
                let mastered = audioMastering.buildAudioMixParameters(composition: composition, musicTrack: track,
                    speechTrack: compSpeechTrack, speechIntervals: speechIntervals, sceneCutPoints: sceneCutPoints,
                    cutTransitions: cutTransitions, totalDuration: totalDuration, baseMusicVolume: musicSettings.musicVolume,
                    duckingEnabled: false, dialogueFocusEnabled: musicSettings.dialogueFocusEnabled,
                    originalMusicDucking: musicSettings.originalMusicDucking)
                let mix = AVMutableAudioMix()
                mix.inputParameters = mastered.inputParameters.filter { $0.trackID != params.trackID } + [params]
                audioMix = mix
            } else { audioMix = nil }
        }

        // 4. Отрисовка фирменных кинематографических оверлеев Shortcast Cinema (1920x1080)
        progressHandler?(0.70, "Рендеринг титров и анимации...")
        let renderSize = CGSize(width: 1920, height: 1080)
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        videoComposition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        videoComposition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: totalDurationCM)
        instruction.backgroundColor = CGColor(gray: 0.0, alpha: 1.0)

        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compVideoTrack)
        
        // Кинематографический леттербоксинг (aspect-fit) под 1920x1080 16:9 без обрезания краев 2.35:1
        let naturalSize = try await sourceVideoTrack.load(.naturalSize)
        let scaleX = renderSize.width / max(naturalSize.width, 1.0)
        let scaleY = renderSize.height / max(naturalSize.height, 1.0)
        let scale = min(scaleX, scaleY)
        
        var transform = CGAffineTransform(scaleX: scale, y: scale)
        let tx = (renderSize.width - naturalSize.width * scale) / 2.0
        let ty = (renderSize.height - naturalSize.height * scale) / 2.0
        transform = transform.concatenating(CGAffineTransform(translationX: tx, y: ty))
        layerInstruction.setTransform(transform, at: .zero)

        // Затемнения на ВСЕХ монтажных склейках, включая сцены внутри акта.
        // План ограничивает рампы концом видео и исключает их пересечения.
        let opacityRamps = LongformTransitionPlan.ramps(
            intro: introPadding, speechEnd: speechFinishTime, cuts: cutTransitions)
        layerInstruction.setOpacity(0, at: .zero)
        for ramp in opacityRamps {
            layerInstruction.setOpacityRamp(
                fromStartOpacity: ramp.from, toEndOpacity: ramp.to,
                timeRange: CMTimeRange(
                    start: CMTime(seconds: ramp.start, preferredTimescale: 600),
                    duration: CMTime(seconds: ramp.end - ramp.start, preferredTimescale: 600)))
        }
        layerInstruction.setOpacity(0, at: CMTime(seconds: speechFinishTime, preferredTimescale: 600))

        instruction.layerInstructions = [layerInstruction]
        videoComposition.instructions = [instruction]

        // Накладываем оверлей Shortcast Cinema (титульная карточка темы, ритмичные субтитры)
        let overlayLayout = LongformOverlayLayout(
            bottomBarHeight: ty > 0.5 ? ceil(ty) + 2 : 0,
            channelLogo: channelLogoEnabled ? .essay : nil
        )
        let overlayLayer = await subtitleRenderer.makeOverlayLayer(
            renderSize: renderSize,
            concept: concept,
            timedPhrases: timedPhrases,
            totalDuration: totalDuration,
            layout: overlayLayout,
            hookText: arc.hookText,
            ctaText: LongformEditorialSupport.finalCard(for: arc)
        )

        if let support = arc.support, support.showsCredits {
            progressHandler?(0.72, "Финальная карточка: благодарности \(support.nicknames.count) донатерам…")
            let finalText = LongformEditorialSupport.finalCard(for: arc)
            let card = DonorCreditsRenderer.makeLayer(support: support, ctaText: finalText,
                theme: concept.displayWord, start: speechFinishTime, duration: outroPadding, canvas: renderSize)
            if channelLogoEnabled, let logo = overlayLayer.sublayers?.last {
                overlayLayer.insertSublayer(card, below: logo)
            } else {
                overlayLayer.addSublayer(card)
            }
        }

        // Подложка глубокого чёрного цвета (YUV Black Fix — предотвращает появление зелёных полос)
        let blackBackgroundLayer = CALayer()
        blackBackgroundLayer.frame = CGRect(origin: .zero, size: renderSize)
        blackBackgroundLayer.backgroundColor = CGColor(gray: 0.0, alpha: 1.0)
        blackBackgroundLayer.isOpaque = true

        let videoLayer = CALayer()
        videoLayer.frame = CGRect(origin: .zero, size: renderSize)
        videoLayer.backgroundColor = CGColor(gray: 0.0, alpha: 1.0)
        videoLayer.isOpaque = true

        let outputParentLayer = CALayer()
        outputParentLayer.frame = CGRect(origin: .zero, size: renderSize)
        outputParentLayer.backgroundColor = CGColor(gray: 0.0, alpha: 1.0)
        outputParentLayer.isOpaque = true

        outputParentLayer.addSublayer(blackBackgroundLayer)
        outputParentLayer.addSublayer(videoLayer)

        // Кинематографические матовые черные полосы леттербоксинга (Hardware Matte Letterbox Fix)
        // Физически перекрывают верх и низ кадра чистым матовым черным цветом (YUV 16,128,128)
        if ty > 0.5 {
            let bottomBar = CALayer()
            bottomBar.frame = CGRect(x: 0, y: 0, width: renderSize.width, height: ceil(ty) + 2.0)
            bottomBar.backgroundColor = CGColor(gray: 0.0, alpha: 1.0)
            bottomBar.isOpaque = true
            outputParentLayer.addSublayer(bottomBar)

            let topBar = CALayer()
            topBar.frame = CGRect(x: 0, y: floor(renderSize.height - ty) - 2.0, width: renderSize.width, height: ceil(ty) + 4.0)
            topBar.backgroundColor = CGColor(gray: 0.0, alpha: 1.0)
            topBar.isOpaque = true
            outputParentLayer.addSublayer(topBar)
        }

        outputParentLayer.addSublayer(overlayLayer)

        // Плавное растворение в глубокий черный экран в финале (Cinematic Outro Fade to Black)
        // Рендерится через CoreAnimation поверх всех слоев, гарантируя 100% отсутствие зеленых YUV-полос
        if totalDuration > 4.0 {
            let fadeDuration = 2.5
            let fadeStartTime = totalDuration - fadeDuration
            let fadeOutLayer = CALayer()
            fadeOutLayer.frame = CGRect(origin: .zero, size: renderSize)
            fadeOutLayer.backgroundColor = CGColor(gray: 0.0, alpha: 1.0)
            fadeOutLayer.opacity = 0.0

            let anim = CAKeyframeAnimation(keyPath: "opacity")
            anim.values = [0.0, 0.0, 1.0]
            anim.keyTimes = [
                0.0,
                NSNumber(value: fadeStartTime / totalDuration),
                1.0
            ]
            anim.duration = totalDuration
            anim.beginTime = AVCoreAnimationBeginTimeAtZero
            anim.fillMode = .both
            anim.isRemovedOnCompletion = false
            fadeOutLayer.add(anim, forKey: "fadeToBlackAnimation")
            outputParentLayer.addSublayer(fadeOutLayer)
        }

        videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer,
            in: outputParentLayer
        )

        // 5. Экспорт в файл (строго в папку Exports/<Название Фильма>/ рабочего каталога)
        progressHandler?(0.85, "Экспорт видео в 1080p...")
        let filmDir = try ExportLayout.filmDirectory(workingDirectory: workingDirectory, movieTitle: movieTitle)

        let isAntiCopyrightActive = audioSettings.antiCopyrightEnabled && audioSettings.antiCopyrightPreset != .off
        let cleanOutputURL = ExportLayout.artifact(in: filmDir, kind: .longformVideo, base: concept.word, ext: "mp4")
        let intermediateURL = isAntiCopyrightActive
            ? ExportLayout.artifact(in: filmDir, kind: .rawRender, base: concept.word, ext: "mp4")
            : cleanOutputURL

        try await exportComposition(
            composition,
            videoComposition: videoComposition,
            audioMix: audioMix,
            to: intermediateURL
        )

        var finalVideoURL = cleanOutputURL
        if isAntiCopyrightActive {
            progressHandler?(0.90, "Обработка изображения и звука...")
            let antiCopyrightService = AntiCopyrightService(config: audioSettings.antiCopyrightPreset.config, preserveTimeline: true)
            do {
                let protectedURL = try await antiCopyrightService.process(
                    videoURL: intermediateURL,
                    outputURL: cleanOutputURL,
                    workingDirectory: workingDirectory
                )
                finalVideoURL = protectedURL
                if protectedURL != intermediateURL {
                    try? FileManager.default.removeItem(at: intermediateURL)
                }
            } catch {
                OperationJournal.shared.append("Shield failed; original render retained: \(error.localizedDescription)", level: .error)
                Self.logger.error("Shield failed; original render retained: \(error.localizedDescription)")
                throw AntiCopyrightError.processingFailed("Обработка эффектов не завершена; исходный рендер сохранён: " + error.localizedDescription)
            }
        }

        // 5.5. Пост-экспортная нормализация по общим целям CinemaAudioMasteringService.
        // Это ПОСЛЕДНЯЯ аудио-операция конвейера: после обработки эффектов и до обложки,
        // поэтому её результат уже никем не перекодируется. Имя файла и расширение сохраняются,
        // их читают генератор обложки и LongformResultsView. Этап не фатален: без ffmpeg,
        // без свободного места или при ошибке прохода остается предыдущий рендер.
        if audioSettings.loudnessNormalizationEnabled {
            let loudnessTarget = String(format: "%.0f", CinemaAudioMasteringService.targetLUFS)
            progressHandler?(0.92, "Нормализация громкости до \(loudnessTarget) LUFS...")
            do {
                finalVideoURL = try await loudnessNormalizer.normalize(
                    videoURL: finalVideoURL,
                    outputURL: finalVideoURL,
                    workingDirectory: workingDirectory
                )
            } catch {
                OperationJournal.shared.append("Loudness pass failed, keeping pre-normalized render: \(error.localizedDescription)", level: .warning)
                Self.logger.warning("Loudness pass failed, keeping pre-normalized render: \(error.localizedDescription)")
            }
        }

        // 5.6. Пост-рендер валидация: громкость, длительность, наличие треков
        progressHandler?(0.93, "Валидация рендера...")
        let validationService = RenderValidationService()
        let validationResult = await validationService.validateLongform(
            outputURL: finalVideoURL,
            expectedDurationRange: allowUserApprovedScenes ? 0.1...Double.greatestFiniteMagnitude
                : EssayDurationPolicy.rendered.lowerBound...(EssayDurationPolicy.rendered.upperBound + timeline.supportExtraDuration),
            workingDirectory: workingDirectory
        )
        if validationResult.hasIssues {
            let report = validationResult.issues.map { $0.description }.joined(separator: ", ")
            OperationJournal.shared.append("Longform render rejected by validation: \(report)", level: .error)
            Self.logger.error("Longform render rejected by validation: \(report)")
            throw NSError(
                domain: "LongformPipeline",
                code: -4,
                userInfo: [NSLocalizedDescriptionKey:
                    "Рендер отклонён проверкой: \(report)."])
        }

        // 6. Генерация кинематографической обложки YouTube Thumbnail (1920x1080)
        progressHandler?(0.95, "Создание обложки YouTube 1080p...")
        let thumbOutputURL = ExportLayout.artifact(in: filmDir, kind: .cover, base: concept.word, ext: "jpg")
        var thumbnail: ReviewedThumbnail?
        var packagingWarning: String?
        do {
            var coverConcept = arc.concept
            coverConcept.coverText = arc.coverText ?? arc.concept.coverText
            if let title = arc.publicationTitle, !title.trimmed.isEmpty { coverConcept.suggestedTitle = title }
            thumbnail = try await thumbnailGenerator.generateReviewedThumbnail(sourceAsset: sourceAsset,
                segments: segments, concept: coverConcept, movieTitle: movieTitle, outputURL: thumbOutputURL)
        } catch is CancellationError { throw CancellationError() }
        catch {
            packagingWarning = error.localizedDescription
            OperationJournal.shared.append("Cover not created: \(error.localizedDescription)", level: .warning)
            Self.logger.warning("Cover not created: \(error.localizedDescription)")
        }

        // 7. Формирование вирусных метаданных
        progressHandler?(0.98, "Генерация упаковки YouTube...")
        if let collection = CompilationManifest.load(for: sourceURL) {
            arc.sourceAttributions = collection.sources.map(\.title)
        }
        let metadata = LongformMetadataGenerator.generate(
            movieTitle: movieTitle,
            concept: concept,
            arc: arc,
            timeline: timeline
        )

        progressHandler?(1.0, "Готово!")

        return LongformBuildResult(
            outputURL: finalVideoURL,
            arc: arc,
            metadata: metadata,
            duration: totalDuration,
            thumbnailURL: thumbnail?.url,
            validationResult: validationResult,
            audioSettings: audioSettings,
            thumbnailSubject: thumbnail?.subject,
            packagingWarning: packagingWarning
        )
    }

    /// Exports the final composition with a compatible retry path. Some long HEVC
    /// sources make the fixed 1080p preset stop in VideoToolbox even though the
    /// composition itself is valid. `HighestQuality` still honours the 1920×1080
    /// video composition, but uses a different export path on macOS.
    private func exportComposition(
        _ composition: AVComposition,
        videoComposition: AVVideoComposition,
        audioMix: AVAudioMix?,
        to outputURL: URL
    ) async throws {
        let presets = [
            AVAssetExportPreset1920x1080,
            AVAssetExportPresetHighestQuality
        ]
        var failures: [String] = []

        for preset in presets {
            try Task.checkCancellation()
            try? FileManager.default.removeItem(at: outputURL)

            guard let exportSession = AVAssetExportSession(asset: composition, presetName: preset) else {
                failures.append("\(preset): не удалось создать сессию экспорта")
                continue
            }

            exportSession.videoComposition = videoComposition
            exportSession.audioMix = audioMix

            do {
                try await exportSession.export(to: outputURL, as: .mp4)
                guard exportSession.status == .completed else {
                    throw exportFailure(for: exportSession, preset: preset)
                }
                Self.logger.notice("Longform export completed with preset \(preset, privacy: .public)")
                return
            } catch is CancellationError {
                exportSession.cancelExport()
                throw CancellationError()
            } catch {
                if Task.isCancelled {
                    exportSession.cancelExport()
                    throw CancellationError()
                }

                let detail = exportFailureDescription(for: exportSession, fallback: error)
                failures.append("\(preset): \(detail)")
                OperationJournal.shared.append("Longform export failed with preset \(preset): \(detail)", level: .warning)
                Self.logger.warning("Longform export failed with preset \(preset, privacy: .public): \(detail, privacy: .public)")
            }
        }

        let detail = failures.joined(separator: " | ")
        throw NSError(
            domain: "LongformPipeline",
            code: -5,
            userInfo: [
                NSLocalizedDescriptionKey: "Экспорт не удался после всех совместимых попыток. \(detail)",
                NSLocalizedFailureReasonErrorKey: detail
            ]
        )
    }

    private func exportFailure(for session: AVAssetExportSession, preset: String) -> NSError {
        NSError(
            domain: "LongformPipeline",
            code: -5,
            userInfo: [
                NSLocalizedDescriptionKey: "\(preset): \(exportFailureDescription(for: session, fallback: nil))"
            ]
        )
    }

    private func exportFailureDescription(for session: AVAssetExportSession, fallback: Error?) -> String {
        let primary = session.error ?? fallback
        guard let primary else {
            return "статус экспорта: \(session.status.rawValue)"
        }

        let nsError = primary as NSError
        let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        let underlyingDescription = underlying.map { " [\($0.domain) \($0.code): \($0.localizedDescription)]" } ?? ""
        return "\(nsError.domain) \(nsError.code): \(nsError.localizedDescription)\(underlyingDescription)"
    }
}
