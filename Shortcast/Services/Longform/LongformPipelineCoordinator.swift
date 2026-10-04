import AVFoundation
import CoreMedia
import Foundation

/// Реализация координатора сборки длинных видео Shortcast Cinema (SOLID)
final class LongformPipelineCoordinator: LongformPipelineCoordinating, Sendable {

    private let director: any LongformNarrativeDirecting
    private let audioMastering: any LongformAudioMasteringProtocol
    private let subtitleRenderer: any LongformSubtitleRenderingProtocol

    init(
        director: any LongformNarrativeDirecting = LongformNarrativeDirector(),
        audioMastering: any LongformAudioMasteringProtocol = LongformAudioMasteringService(),
        subtitleRenderer: any LongformSubtitleRenderingProtocol = LongformSubtitleRenderer()
    ) {
        self.director = director
        self.audioMastering = audioMastering
        self.subtitleRenderer = subtitleRenderer
    }

    func buildLongformVideo(
        sourceURL: URL,
        movieTitle: String,
        transcript: Transcript,
        concept: ThematicConcept,
        backgroundMusicURL: URL? = nil,
        musicVolume: Float = 0.28,
        duckingEnabled: Bool = true,
        progressHandler: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> LongformBuildResult {

        // 1. Построение 4-актной драматургической арки
        progressHandler?(0.10, "Режиссура 4-актной арки «\(concept.word)»...")
        let arc = try await director.buildArc(
            from: transcript,
            concept: concept,
            movieTitle: movieTitle,
            targetDuration: 380.0
        )

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

        var insertTime = CMTime.zero
        var speechIntervals: [TimeSegment] = []
        var timedPhrases: [TimedSubtitlePhrase] = []

        // Вставляем нарезанные сцены фильма
        for segment in segments {
            let startCM = CMTime(seconds: segment.start, preferredTimescale: 600)
            let durationCM = CMTime(seconds: segment.duration, preferredTimescale: 600)
            let timeRange = CMTimeRange(start: startCM, duration: durationCM)

            try compVideoTrack.insertTimeRange(timeRange, of: sourceVideoTrack, at: insertTime)

            if let sourceAudioTrack {
                try compSpeechTrack.insertTimeRange(timeRange, of: sourceAudioTrack, at: insertTime)
            }

            let insertedStart = insertTime.seconds
            let insertedEnd = insertedStart + segment.duration
            speechIntervals.append(TimeSegment(start: insertedStart, end: insertedEnd))

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

        let totalDuration = insertTime.seconds

        // 3. Подключение фонового саундтрека
        progressHandler?(0.50, "Мастеринг непрерывного саундтрека...")
        var audioMix: AVAudioMix? = nil

        let musicURL: URL? = backgroundMusicURL
        if let musicURL,
           let compMusicTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let musicAsset = AVURLAsset(url: musicURL)
            if let sourceMusicTrack = (try? await musicAsset.loadTracks(withMediaType: .audio))?.first {
                let musicDuration = try await musicAsset.load(.duration)

                var musicInsertTime = CMTime.zero
                while musicInsertTime < insertTime {
                    let remaining = CMTimeSubtract(insertTime, musicInsertTime)
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
                    totalDuration: totalDuration,
                    baseMusicVolume: musicVolume,
                    duckingEnabled: duckingEnabled
                )
            }
        }

        // 4. Отрисовка фирменных кинематографических оверлеев Shortcast Cinema (1920x1080)
        progressHandler?(0.70, "Рендеринг титров и анимации...")
        let renderSize = CGSize(width: 1920, height: 1080)
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: insertTime)

        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compVideoTrack)
        
        // Масштабируем и центрируем видео под 1920x1080 16:9
        let naturalSize = try await sourceVideoTrack.load(.naturalSize)
        let scaleX = renderSize.width / max(naturalSize.width, 1.0)
        let scaleY = renderSize.height / max(naturalSize.height, 1.0)
        let scale = max(scaleX, scaleY)
        
        var transform = CGAffineTransform(scaleX: scale, y: scale)
        let tx = (renderSize.width - naturalSize.width * scale) / 2.0
        let ty = (renderSize.height - naturalSize.height * scale) / 2.0
        transform = transform.concatenating(CGAffineTransform(translationX: tx, y: ty))
        layerInstruction.setTransform(transform, at: .zero)

        // Плавное затухание видео в черный цвет (Fade to Black) в последние 2.5 секунды
        if totalDuration > 3.0 {
            let fadeDuration = 2.5
            let fadeStartTime = CMTime(seconds: totalDuration - fadeDuration, preferredTimescale: 600)
            let fadeDurationTime = CMTime(seconds: fadeDuration, preferredTimescale: 600)
            layerInstruction.setOpacityRamp(
                fromStartOpacity: 1.0,
                toEndOpacity: 0.0,
                timeRange: CMTimeRange(start: fadeStartTime, duration: fadeDurationTime)
            )
        }

        instruction.layerInstructions = [layerInstruction]
        videoComposition.instructions = [instruction]

        // Накладываем оверлей Shortcast Cinema (титульная карточка темы, кинетические субтитры 1-2 слова, маркеры актов)
        let overlayLayer = await subtitleRenderer.makeOverlayLayer(
            renderSize: renderSize,
            concept: concept,
            timedPhrases: timedPhrases,
            acts: arc.acts,
            totalDuration: totalDuration
        )

        let videoLayer = CALayer()
        videoLayer.frame = CGRect(origin: .zero, size: renderSize)

        let outputParentLayer = CALayer()
        outputParentLayer.frame = CGRect(origin: .zero, size: renderSize)
        outputParentLayer.addSublayer(videoLayer)
        outputParentLayer.addSublayer(overlayLayer)

        videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer,
            in: outputParentLayer
        )

        // 5. Экспорт в файл
        progressHandler?(0.85, "Экспорт видео в 1080p...")
        let exportDir = FileManager.default.temporaryDirectory.appendingPathComponent("LongformExports", isDirectory: true)
        try? FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
        let outputURL = exportDir.appendingPathComponent("longform_\(concept.word.lowercased())_\(UUID().uuidString.prefix(6)).mp4")

        guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPreset1920x1080) else {
            throw NSError(domain: "LongformPipeline", code: -4, userInfo: [NSLocalizedDescriptionKey: "Не удалось создать AVAssetExportSession."])
        }

        exportSession.outputURL = outputURL
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

        // 6. Формирование вирусных метаданных
        progressHandler?(0.98, "Генерация упаковки YouTube...")
        let metadata = LongformMetadataGenerator.generate(
            movieTitle: movieTitle,
            concept: concept,
            arc: arc
        )

        progressHandler?(1.0, "Готово!")

        return LongformBuildResult(
            outputURL: outputURL,
            arc: arc,
            metadata: metadata,
            duration: totalDuration
        )
    }
}
