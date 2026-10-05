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

    init(
        director: any LongformNarrativeDirecting = LongformNarrativeDirector(),
        audioMastering: any LongformAudioMasteringProtocol = LongformAudioMasteringService(),
        subtitleRenderer: any LongformSubtitleRenderingProtocol = LongformSubtitleRenderer(),
        thumbnailGenerator: any LongformThumbnailGeneratingProtocol = LongformThumbnailGenerator(),
        audioLooper: any SeamlessAudioLooping = SeamlessAudioLoopService.shared
    ) {
        self.director = director
        self.audioMastering = audioMastering
        self.subtitleRenderer = subtitleRenderer
        self.thumbnailGenerator = thumbnailGenerator
        self.audioLooper = audioLooper
    }

    func buildLongformVideo(
        sourceURL: URL,
        movieTitle: String,
        transcript: Transcript,
        concept: ThematicConcept,
        audioSettings: LongformAudioSettings,
        existingArc: LongformNarrativeArc? = nil,
        workingDirectory: URL? = nil,
        progressHandler: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> LongformBuildResult {

        // 1. Построение или переиспользование 4-актной драматургической арки
        let arc: LongformNarrativeArc
        if let existing = existingArc {
            progressHandler?(0.10, "Использование утвержденного монтажа «\(concept.word)»...")
            arc = existing
        } else {
            progressHandler?(0.10, "Режиссура 4-актной арки «\(concept.word)»...")
            arc = try await director.buildArc(
                from: transcript,
                concept: concept,
                movieTitle: movieTitle,
                targetDuration: 520.0
            )
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
        let introPadding: Double = audioSettings.coldOpenEnabled ? 2.5 : 0.0
        var insertTime = CMTime(seconds: introPadding, preferredTimescale: 600)
        var timedPhrases: [TimedSubtitlePhrase] = []
        var sceneCutPoints: [Double] = [introPadding]
        var cutTransitions: [LongformCutTransition] = []
        var actStartTimes: [Double] = []
        let interActGap: Double = 0.8 // Мягкая кинематографическая пауза (дыхание) между актами
        let intraActGap: Double = 0.5 // Мягкая кинематографическая пауза между сценами внутри акта

        // Вставляем нарезанные сцены фильма по актам с кинематографическим разделением
        for (actIndex, act) in arc.acts.enumerated() {
            if actIndex > 0 {
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
            let actStartSec = insertTime.seconds
            actStartTimes.append(actStartSec)

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
                    $0.end > segment.start && $0.start < segment.end
                }
                for s in matchingSegments {
                    let phraseStart = max(insertedStart, insertedStart + (s.start - segment.start))
                    let phraseEnd = min(insertedEnd, insertedStart + (s.end - segment.start))
                    if phraseEnd > phraseStart {
                        timedPhrases.append(TimedSubtitlePhrase(start: phraseStart, end: phraseEnd, text: s.text))
                    }
                }

                insertTime = CMTimeAdd(insertTime, durationCM)
            }
        }

        // Кинематографический хвост послевкусия (Outro Tail): 4.0 секунды черного экрана
        // после завершения речи, во время которых фоновая музыка солирует и плавно затухает
        let speechFinishTime = insertTime.seconds
        let outroPadding: Double = 4.0
        let totalDuration = speechFinishTime + outroPadding
        let totalDurationCM = CMTime(seconds: totalDuration, preferredTimescale: 600)

        // Формируем интервалы реальной речи из Whisper для сайдчейн-дакинга музыки
        let speechIntervals: [TimeSegment] = timedPhrases.map { TimeSegment(start: $0.start, end: $0.end) }

        // 3. Подключение фонового саундтрека с бесшовным мягким зацикливанием
        progressHandler?(0.50, "Мастеринг непрерывного саундтрека...")
        var audioMix: AVAudioMix? = nil

        let musicURL: URL? = audioSettings.backgroundMusicURL
        if let rawMusicURL = musicURL,
           let compMusicTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            
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
            if let sourceMusicTrack = (try? await musicAsset.loadTracks(withMediaType: .audio))?.first {
                let musicDuration = try await musicAsset.load(.duration)

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
            }
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

        // Плавный выход первого кадра фильма из затемнения (Cold Open Fade-In)
        if introPadding > 0 {
            layerInstruction.setOpacity(0.0, at: .zero)
            layerInstruction.setOpacityRamp(
                fromStartOpacity: 0.0,
                toEndOpacity: 1.0,
                timeRange: CMTimeRange(
                    start: CMTime(seconds: introPadding, preferredTimescale: 600),
                    duration: CMTime(seconds: 1.5, preferredTimescale: 600)
                )
            )
        } else {
            layerInstruction.setOpacityRamp(
                fromStartOpacity: 0.0,
                toEndOpacity: 1.0,
                timeRange: CMTimeRange(
                    start: .zero,
                    duration: CMTime(seconds: 1.2, preferredTimescale: 600)
                )
            )
        }

        // Мягкие кинематографические затемнения (Dip to Black) на всех склейках сцен и актов
        for cut in cutTransitions {
            let fadeOutDuration: Double = cut.isInterAct ? 0.35 : 0.28
            let fadeInDuration: Double = cut.isInterAct ? 0.45 : 0.32
            let fadeOutStart = max(introPadding + 0.5, cut.sceneEndTime - fadeOutDuration)

            layerInstruction.setOpacityRamp(
                fromStartOpacity: 1.0,
                toEndOpacity: 0.0,
                timeRange: CMTimeRange(
                    start: CMTime(seconds: fadeOutStart, preferredTimescale: 600),
                    duration: CMTime(seconds: fadeOutDuration, preferredTimescale: 600)
                )
            )
            layerInstruction.setOpacityRamp(
                fromStartOpacity: 0.0,
                toEndOpacity: 1.0,
                timeRange: CMTimeRange(
                    start: CMTime(seconds: cut.nextSceneStartTime, preferredTimescale: 600),
                    duration: CMTime(seconds: fadeInDuration, preferredTimescale: 600)
                )
            )
        }

        // Финальное кинематографическое затухание в темноту (Outro Fade to Black)
        let finalFadeStart = max(introPadding + 2.0, speechFinishTime - 1.2)
        layerInstruction.setOpacityRamp(
            fromStartOpacity: 1.0,
            toEndOpacity: 0.0,
            timeRange: CMTimeRange(
                start: CMTime(seconds: finalFadeStart, preferredTimescale: 600),
                duration: CMTime(seconds: 1.2, preferredTimescale: 600)
            )
        )
        layerInstruction.setOpacity(0.0, at: CMTime(seconds: speechFinishTime, preferredTimescale: 600))

        instruction.layerInstructions = [layerInstruction]
        videoComposition.instructions = [instruction]

        // Накладываем оверлей Shortcast Cinema (титульная карточка темы, ритмичные субтитры, карточки актов)
        let overlayLayer = await subtitleRenderer.makeOverlayLayer(
            renderSize: renderSize,
            concept: concept,
            timedPhrases: timedPhrases,
            acts: arc.acts,
            actStartTimes: actStartTimes,
            totalDuration: totalDuration
        )

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

        // 5. Экспорт в файл (строго в папку Exports рабочего каталога проекта)
        progressHandler?(0.85, "Экспорт видео в 1080p...")
        let exportDir: URL
        if let workingDirectory {
            exportDir = workingDirectory.appendingPathComponent("Exports", isDirectory: true)
        } else {
            exportDir = FileManager.default.temporaryDirectory.appendingPathComponent("LongformExports", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)

        let isAntiCopyrightActive = audioSettings.antiCopyrightEnabled && audioSettings.antiCopyrightPreset != .off
        let cleanOutputURL = exportDir.appendingPathComponent("longform_\(concept.word.lowercased())_\(UUID().uuidString.prefix(6)).mp4")
        let intermediateURL = isAntiCopyrightActive
            ? exportDir.appendingPathComponent("raw_render_\(concept.word.lowercased())_\(UUID().uuidString.prefix(6)).mp4")
            : cleanOutputURL

        guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPreset1920x1080) else {
            throw NSError(domain: "LongformPipeline", code: -4, userInfo: [NSLocalizedDescriptionKey: "Не удалось создать AVAssetExportSession."])
        }

        exportSession.outputURL = intermediateURL
        exportSession.outputFileType = .mp4
        exportSession.videoComposition = videoComposition
        if let audioMix {
            exportSession.audioMix = audioMix
        }

        await exportSession.export()

        if exportSession.status != .completed {
            let errorMsg = exportSession.error?.localizedDescription ?? "Неизвестная ошибка экспорта"
            throw NSError(domain: "LongformPipeline", code: -5, userInfo: [NSLocalizedDescriptionKey: "Экспорт не удался: \(errorMsg)"])
        }

        var finalVideoURL = cleanOutputURL
        if isAntiCopyrightActive {
            progressHandler?(0.90, "Применение защиты YouTube Shield (Anti-Copyright)...")
            let antiCopyrightService = AntiCopyrightService(config: audioSettings.antiCopyrightPreset.config)
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
                Self.logger.warning("AntiCopyright pass failed, fallback to raw render: \(error.localizedDescription)")
                finalVideoURL = intermediateURL
            }
        }

        // 6. Генерация кинематографической обложки YouTube Thumbnail (1920x1080)
        progressHandler?(0.95, "Создание обложки YouTube 1080p...")
        let thumbOutputURL = exportDir.appendingPathComponent("thumbnail_\(concept.word.lowercased())_\(UUID().uuidString.prefix(6)).jpg")
        let thumbnailURL = try? await thumbnailGenerator.generateThumbnail(
            sourceAsset: sourceAsset,
            segments: segments,
            concept: concept,
            movieTitle: movieTitle,
            outputURL: thumbOutputURL
        )

        // 7. Формирование вирусных метаданных
        progressHandler?(0.98, "Генерация упаковки YouTube...")
        let metadata = LongformMetadataGenerator.generate(
            movieTitle: movieTitle,
            concept: concept,
            arc: arc
        )

        progressHandler?(1.0, "Готово!")

        return LongformBuildResult(
            outputURL: finalVideoURL,
            arc: arc,
            metadata: metadata,
            duration: totalDuration,
            thumbnailURL: thumbnailURL
        )
    }
}
