import AppKit
import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import os.log

/// Внутренние ошибки однопроходного экспорта клипов.
enum SinglePassError: LocalizedError {
    case compositionFailed
    case cannotCreateExportSession
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .compositionFailed:
            return "Не удалось создать видео-дорожку для композиции."
        case .cannotCreateExportSession:
            return "Не удалось инициализировать сессию экспорта AVAssetExportSession."
        case .exportFailed(let reason):
            return "Экспорт клипа завершился с ошибкой: \(reason)"
        }
    }
}

/// Протокол однопроходного рендеринга шортсов (SOLID: Interface Segregation).
protocol SinglePassClipCompositing: Sendable {
    func renderClip(
        clip: ShortClip,
        workingDirectory: URL?,
        customMusicDirectory: URL?,
        outputURL: URL
    ) async throws -> URL
}

/// Высокопроизводительный однопроходный компоновщик шортсов (SOLID: Single Responsibility).
/// Объединяет тримминг, центрирование/рефрейминг 1:1 или 9:16, субтитры, хук, водяной знак,
/// промокод и сведение фоновой музыки в ЕДИНЫЙ проход AVFoundation без промежуточных MP4-файлов на диске.
@MainActor
final class SinglePassClipCompositor: SinglePassClipCompositing {

    static let shared = SinglePassClipCompositor()

    private static let logger = Logger(subsystem: "app.shortcast", category: "SinglePassClipCompositor")

    init() {}

    func renderClip(
        clip: ShortClip,
        workingDirectory: URL?,
        customMusicDirectory: URL? = nil,
        outputURL: URL
    ) async throws -> URL {
        guard let clipJob = clip.clipJob else {
            throw MomentFinderError.notReady
        }

        let asset = AVURLAsset(url: clipJob.url)
        guard let sourceVideoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw MediaExtractorError.noVideoTrack
        }

        let fullDuration = try await asset.load(.duration)
        let naturalSize = try await sourceVideoTrack.load(.naturalSize)
        let preferredTransform = try await sourceVideoTrack.load(.preferredTransform)
        let orientedSize = naturalSize.applying(preferredTransform)
        let naturalW = abs(orientedSize.width)
        let naturalH = abs(orientedSize.height)

        // 1. Определение временного диапазона клипа (тримминг)
        let startSec = max(0, clip.trimStartSeconds)
        let rawEndSec = clip.trimEndSeconds > 0 ? clip.trimEndSeconds : fullDuration.seconds
        let endSec = min(fullDuration.seconds, max(startSec + 0.5, rawEndSec))
        let clipDurationSec = endSec - startSec
        let clipTimeRange = CMTimeRange(
            start: CMTime(seconds: startSec, preferredTimescale: 600),
            duration: CMTime(seconds: clipDurationSec, preferredTimescale: 600)
        )

        Self.logger.notice("Single-Pass Render: \(clip.displayTitle) duration=\(clipDurationSec)s")

        // 2. Сборка единой AVMutableComposition
        let composition = AVMutableComposition()
        guard let compVideoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw SinglePassError.compositionFailed
        }

        try compVideoTrack.insertTimeRange(clipTimeRange, of: sourceVideoTrack, at: .zero)

        // Речевой аудио-трек из исходного видео
        var compSpeechTrack: AVMutableCompositionTrack?
        if let sourceAudioTrack = (try? await asset.loadTracks(withMediaType: .audio))?.first {
            compSpeechTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            try? compSpeechTrack?.insertTimeRange(clipTimeRange, of: sourceAudioTrack, at: .zero)
        }

        // 3. Фоновая музыка (если назначена или включена)
        var compMusicTrack: AVMutableCompositionTrack?
        var musicURL = clip.selectedMusicURL
        if musicURL == nil && clip.backgroundMusicEnabled {
            let mood = clip.candidate.mood?.mood.rawValue ?? clip.detectedMovieTitle
            musicURL = await BackgroundMusicSelector.selectBestTrack(from: customMusicDirectory, mood: mood)
        }

        if let musicURL, FileManager.default.fileExists(atPath: musicURL.path) {
            let musicAsset = AVURLAsset(url: musicURL)
            let audioTracks = try? await musicAsset.loadTracks(withMediaType: AVMediaType.audio)
            if let sourceMusicAudioTrack = audioTracks?.first {
                compMusicTrack = composition.addMutableTrack(withMediaType: AVMediaType.audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                let musicDur = try? await musicAsset.load(.duration)
                let musicDurSec = musicDur?.seconds ?? clipDurationSec

                // Зацикливание или подрезка музыки под длительность клипа
                var currentInsertTime: Double = 0
                while currentInsertTime < clipDurationSec {
                    let chunkDuration = min(musicDurSec, clipDurationSec - currentInsertTime)
                    let insertRange = CMTimeRange(
                        start: .zero,
                        duration: CMTime(seconds: chunkDuration, preferredTimescale: 600)
                    )
                    try? compMusicTrack?.insertTimeRange(
                        insertRange,
                        of: sourceMusicAudioTrack,
                        at: CMTime(seconds: currentInsertTime, preferredTimescale: 600)
                    )
                    currentInsertTime += chunkDuration
                }
            }
        }

        // 4. Определение разрешения вывода и рефрейминг
        let isVertical = clip.isCinemaMode ? false : (clip.reframeEnabled && clip.isLandscape)
        let isCinemaSquare = clip.isCinemaMode && clip.isLandscape
        let renderSize: CGSize
        let wantReframe: Bool

        if isCinemaSquare {
            renderSize = CGSize(width: 1080, height: 1080)
            wantReframe = true
        } else if isVertical {
            renderSize = CGSize(width: 1080, height: 1920)
            wantReframe = true
        } else {
            // Оригинальное соотношение
            let targetShortSide: CGFloat = 1080
            let shortSide = min(naturalW, naturalH)
            let scale = shortSide > 0 ? max(1.0, targetShortSide / shortSide) : 1.0
            renderSize = CGSize(width: round(naturalW * scale / 2) * 2, height: round(naturalH * scale / 2) * 2)
            wantReframe = false
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: clipDurationSec, preferredTimescale: 600))

        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compVideoTrack)

        if wantReframe {
            // Центрируем или используем трекинг лиц из CinemaSquareReframer
            let scale = renderSize.height / naturalH
            let scaledW = naturalW * scale
            let defaultTx = (renderSize.width - scaledW) / 2.0
            var defaultTransform = preferredTransform.concatenating(CGAffineTransform(scaleX: scale, y: scale))
            defaultTransform = defaultTransform.concatenating(CGAffineTransform(translationX: defaultTx, y: 0))

            let cropTransformer = CinemaCropTransformer()
            if let keyframes = try? await CinemaSquareReframer.sampleAndOptimizeVideoPath(asset: asset),
               keyframes.count > 1 {
                for i in 0..<(keyframes.count - 1) {
                    let kf1 = keyframes[i]
                    let kf2 = keyframes[i + 1]
                    let t1 = max(0, kf1.time - startSec)
                    let t2 = max(t1, kf2.time - startSec)
                    if t1 >= clipDurationSec { break }
                    let clampedT2 = min(clipDurationSec, t2)
                    let timeRange = CMTimeRange(
                        start: CMTime(seconds: t1, preferredTimescale: 600),
                        duration: CMTime(seconds: clampedT2 - t1, preferredTimescale: 600)
                    )

                    let trans1 = cropTransformer.makeTransform(
                        for: kf1.cropX,
                        base: preferredTransform,
                        sourceSize: CGSize(width: naturalW, height: naturalH),
                        targetSize: renderSize
                    )
                    let trans2 = cropTransformer.makeTransform(
                        for: kf2.cropX,
                        base: preferredTransform,
                        sourceSize: CGSize(width: naturalW, height: naturalH),
                        targetSize: renderSize
                    )

                    layerInstruction.setTransformRamp(fromStart: trans1, toEnd: trans2, timeRange: timeRange)
                }
            } else {
                layerInstruction.setTransform(defaultTransform, at: .zero)
            }
        } else {
            let scaleX = renderSize.width / naturalW
            let scaleY = renderSize.height / naturalH
            let scale = min(scaleX, scaleY)
            var transform = preferredTransform.concatenating(CGAffineTransform(scaleX: scale, y: scale))
            let tx = (renderSize.width - naturalW * scale) / 2.0
            let ty = (renderSize.height - naturalH * scale) / 2.0
            transform = transform.concatenating(CGAffineTransform(translationX: tx, y: ty))
            layerInstruction.setTransform(transform, at: .zero)
        }

        instruction.layerInstructions = [layerInstruction]
        videoComposition.instructions = [instruction]

        // 5. Оверлеи CoreAnimation: субтитры + хук + водяной знак + промокод
        let parentLayer = CALayer()
        parentLayer.frame = CGRect(origin: .zero, size: renderSize)

        let videoLayer = CALayer()
        videoLayer.frame = parentLayer.frame
        parentLayer.addSublayer(videoLayer)

        // Субтитры (с учетом смещения тримминга startSec)
        let wantSubtitles = clip.isCinemaMode ? !clip.subtitleSegments.isEmpty : (clip.burnSubtitles && !clip.subtitleSegments.isEmpty)
        if wantSubtitles {
            let shiftedSegments = clip.subtitleSegments.compactMap { seg -> SubtitleSegment? in
                let segStart = seg.start - startSec
                let segEnd = seg.end - startSec
                guard segEnd > 0 && segStart < clipDurationSec else { return nil }
                return SubtitleSegment(
                    start: max(0, segStart),
                    end: min(clipDurationSec, segEnd),
                    text: seg.text,
                    words: seg.words.map {
                        WordTimestamp(
                            word: $0.word,
                            start: max(0, $0.start - startSec),
                            end: min(clipDurationSec, $0.end - startSec)
                        )
                    }
                )
            }

            let subtitleContainer = await SubtitleRenderer.buildKineticSubtitleLayer(
                asset: asset,
                segments: shiftedSegments,
                appearance: clip.subtitleAppearance,
                videoSize: renderSize,
                totalDuration: clipDurationSec
            )
            parentLayer.addSublayer(subtitleContainer)
        }

        // Водяной знак
        if clip.watermarkEnabled && !clip.watermarkText.isEmpty {
            WatermarkRenderer.addWatermark(
                to: parentLayer,
                text: clip.watermarkText,
                appearance: clip.watermarkAppearance,
                renderSize: renderSize,
                totalDuration: clipDurationSec
            )
        }

        // Баннер промокода / соцсети
        if clip.promoOverlayEnabled && !clip.promoCode.isEmpty {
            PromoOverlayRenderer.addBanner(
                to: parentLayer,
                promoCode: clip.promoCode,
                renderSize: renderSize,
                total: clipDurationSec,
                holdSeconds: clip.promoDurationSeconds
            )
        }

        // Оверлей хука (если включен)
        if clip.overlayEnabled && !clip.overlayText.isEmpty {
            let hookBand = VideoOverlayRenderer.makeHookBand(
                text: clip.overlayText,
                renderSize: renderSize,
                hasPromo: clip.promoOverlayEnabled && !clip.promoCode.isEmpty,
                appearance: clip.hookAppearance
            )
            VideoOverlayRenderer.addOpacityAnimation(
                to: hookBand,
                total: clipDurationSec,
                hold: 3.0
            )
            VideoOverlayRenderer.addStyleAnimation(
                to: hookBand,
                style: clip.hookAppearance.normalized.style,
                total: clipDurationSec
            )
            parentLayer.addSublayer(hookBand)
        }

        videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer,
            in: parentLayer
        )

        // 6. Аудио-микс: баланс голоса и саундтрека
        let audioMix = AVMutableAudioMix()
        var inputParams: [AVAudioMixInputParameters] = []

        if let compSpeechTrack {
            let speechParam = AVMutableAudioMixInputParameters(track: compSpeechTrack)
            let vol = Float(clip.isOriginalAudioMuted ? 0.0 : max(0.0, clip.originalAudioVolume))
            speechParam.setVolume(vol, at: .zero)
            inputParams.append(speechParam)
        }

        if let compMusicTrack {
            let musicParam = AVMutableAudioMixInputParameters(track: compMusicTrack)
            let baseVol = Float(max(0.0, clip.musicVolume))

            if !clip.musicDuckingEnabled {
                musicParam.setVolume(baseVol, at: .zero)
            } else {
                // Применяем дакинг под реплики
                let duckingFactor = Float(pow(10.0, -14.0 / 20.0))
                let duckedVol = baseVol * duckingFactor
                musicParam.setVolume(baseVol, at: .zero)

                for seg in clip.subtitleSegments {
                    let sStart = max(0, seg.start - startSec)
                    let sEnd = min(clipDurationSec, seg.end - startSec)
                    guard sEnd > sStart else { continue }

                    let attackRange = CMTimeRange(
                        start: CMTime(seconds: max(0, sStart - 0.1), preferredTimescale: 600),
                        duration: CMTime(seconds: 0.1, preferredTimescale: 600)
                    )
                    musicParam.setVolumeRamp(fromStartVolume: baseVol, toEndVolume: duckedVol, timeRange: attackRange)

                    let releaseRange = CMTimeRange(
                        start: CMTime(seconds: sEnd, preferredTimescale: 600),
                        duration: CMTime(seconds: 0.4, preferredTimescale: 600)
                    )
                    musicParam.setVolumeRamp(fromStartVolume: duckedVol, toEndVolume: baseVol, timeRange: releaseRange)
                }
            }

            // Плавное затухание в конце
            if clipDurationSec > 1.0 {
                let fadeOutRange = CMTimeRange(
                    start: CMTime(seconds: clipDurationSec - 0.8, preferredTimescale: 600),
                    duration: CMTime(seconds: 0.8, preferredTimescale: 600)
                )
                musicParam.setVolumeRamp(fromStartVolume: baseVol, toEndVolume: 0.0, timeRange: fadeOutRange)
            }

            inputParams.append(musicParam)
        }

        audioMix.inputParameters = inputParams

        // 7. Экспорт в файл
        try? FileManager.default.removeItem(at: outputURL)

        guard let exportSession = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw SinglePassError.cannotCreateExportSession
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mp4
        exportSession.videoComposition = videoComposition
        exportSession.audioMix = audioMix

        await exportSession.export()

        if exportSession.status != .completed {
            let errorMsg = exportSession.error?.localizedDescription ?? "Неизвестная ошибка экспорта"
            throw SinglePassError.exportFailed(errorMsg)
        }

        Self.logger.notice("Single-Pass Render completed in 1 pass: \(outputURL.path)")
        return outputURL
    }
}
