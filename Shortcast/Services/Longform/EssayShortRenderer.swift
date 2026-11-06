import AppKit
import AVFoundation
import Vision

/// Dedicated 9:16 essay trailer renderer. Never enters the legacy square cinema
/// pipeline or asks an unrelated copywriter to rewrite the approved argument.
@MainActor
struct EssayShortRenderer {
    static let size = CGSize(width: 1080, height: 1920)
    static let pictureBand = CGRect(x: 0, y: 360, width: 1080, height: 1000)

    /// Cover the compositor's unused pixels independently of video opacity.
    /// AVCoreAnimationTool can expose green YUV padding during opacity ramps;
    /// an opaque matte above the video must stay in place for every frame.
    static func addMatte(to root: CALayer, pictureBand: CGRect = Self.pictureBand) {
        let black = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        root.backgroundColor = black
        root.isOpaque = true
        // Video composition transforms use a top-left image origin; Core
        // Animation uses a bottom-left origin. Convert the band boundaries.
        for frame in [
            CGRect(x: 0, y: 0, width: size.width, height: size.height - pictureBand.maxY),
            CGRect(x: 0, y: size.height - pictureBand.minY, width: size.width, height: pictureBand.minY)
        ] {
            let matte = CALayer()
            matte.frame = frame
            matte.backgroundColor = black
            matte.isOpaque = true
            root.addSublayer(matte)
        }
    }

    func render(_ short: EssayShort, sourceURL: URL, result: LongformBuildResult,
                transcript: Transcript, telegramURL: String?, directory: URL,
                diagnosticsDirectory: URL? = nil,
                report: @escaping (Int, String) -> Void = { _, _ in }) async throws -> EssayShort {
        let pictureBand = short.isMontage ? CGRect(origin: .zero, size: Self.size) : Self.pictureBand
        let output = directory.appendingPathComponent("essay_\(short.id)_\(UUID().uuidString.prefix(6)).mp4")
        let cover = output.deletingPathExtension().appendingPathExtension("jpg")
        var completed = false
        defer {
            if !completed {
                try? FileManager.default.removeItem(at: output)
                try? FileManager.default.removeItem(at: cover)
            }
        }
        report(0, "Проверяю видео и украинскую звуковую дорожку")
        FontDownloadService.shared.registerBundledFonts()
        let source = AVURLAsset(url: sourceURL)
        guard let sourceVideo = try await source.loadTracks(withMediaType: .video).first,
              let sourceAudio = try await source.loadTracks(withMediaType: .audio).first else {
            throw EssayReleaseError.invalid("В источнике шортса отсутствует видео или украинская аудиодорожка.")
        }
        let natural = try await sourceVideo.load(.naturalSize)
        let preferred = try await sourceVideo.load(.preferredTransform)
        let oriented = natural.applying(preferred)
        let sourceSize = CGSize(width: abs(oriented.width), height: abs(oriented.height))
        let composition = AVMutableComposition()
        let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
        let speech = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
        let instruction = AVMutableVideoCompositionLayerInstruction(assetTrack: video)
        let speechMix = AVMutableAudioMixInputParameters(track: speech)
        let root = CALayer(); root.frame = CGRect(origin: .zero, size: Self.size)
        let videoLayer = CALayer(); videoLayer.frame = root.bounds
        videoLayer.backgroundColor = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        videoLayer.isOpaque = true
        root.addSublayer(videoLayer)
        Self.addMatte(to: root, pictureBand: pictureBand)
        let brand = CALayer(); brand.frame = root.bounds
        if short.isMontage {
            let title = Self.text(short.hook, frame: CGRect(x: 64, y: 220, width: 952, height: 180), font: 64, color: ShortBrandArtwork.ivory)
            brand.addSublayer(title)
        } else { brand.contents = try ShortBrandArtwork.hookHeader(short: short, result: result) }
        Self.visible(brand, from: 0, until: min(short.isMontage ? 2 : 4, short.duration), total: short.duration)
        root.addSublayer(brand)
        if let logo = ChannelLogo.makeLayer(frame: CGRect(x: 28, y: 590, width: 112, height: 112),
            renderSize: Self.size, opacity: ChannelLogoStyle.essay.opacity) { root.addSublayer(logo) }
        let essayCaptions = LongformEditorialSupport.captions(transcript.segments, edits: result.arc.captionEdits)
        let captions = LongformEditorialSupport.captions(essayCaptions, edits: short.captionEdits)
        if short.showsSubtitles {
            try TranscriptionService.validateRenderedCaptions(captions, ranges: short.segments, requestedLanguage: "uk")
        }

        var cursor = 0.0
        let total = short.duration
        var cameraDiagnostics: [EssayCameraPath.Segment] = []
        for (sceneIndex, range) in short.segments.enumerated() {
            report(1, "Кадрирование и склейки · сцена \(sceneIndex + 1) из \(short.segments.count)")
            try Task.checkCancellation()
            let start = CMTime(seconds: cursor, preferredTimescale: 600)
            let duration = CMTime(seconds: range.duration, preferredTimescale: 600)
            let sourceRange = CMTimeRange(start: CMTime(seconds: range.start, preferredTimescale: 600), duration: duration)
            try video.insertTimeRange(sourceRange, of: sourceVideo, at: start)
            try speech.insertTimeRange(sourceRange, of: sourceAudio, at: start)
            // A large square picture band within the vertical canvas; preserve
            // the speaker with Vision framing rather than a blind centre crop.
            let scale = max(pictureBand.width / sourceSize.width, pictureBand.height / sourceSize.height)
            let width = sourceSize.width * scale
            func transform(_ point: EssayCameraPath.Keyframe, zoom: Double = 1) -> CGAffineTransform {
                preferred.concatenating(CGAffineTransform(scaleX: scale * zoom, y: scale * zoom))
                    .concatenating(CGAffineTransform(translationX: -point.cropX * zoom - pictureBand.width * (zoom - 1) / 2,
                        y: pictureBand.minY - pictureBand.height * (zoom - 1) / 2))
            }
            // Reset at both editorial cuts and strong source shot changes.
            // Detect them at export cadence, not from the face's displacement:
            // an actor moving quickly within a shot must still pan smoothly.
            let scenes = try await SceneDetectionService.detectScenes(in: sourceURL, threshold: 0.65,
                sampleRate: 30, range: range, spatialThreshold: 0.10)
            let shots = scenes.isEmpty ? [range] : scenes.map { TimeSegment(start: $0.start, end: $0.end) }
            // Accents follow real shot boundaries, rather than flashing at a
            // fixed interval during an uninterrupted performance.
            for (index, shot) in shots.enumerated() where index > 0 {
                let cut = cursor + shot.start - range.start
                guard cut > 0.1, cut < total - 0.1 else { continue }
                let accent = min(0.06, shots[index - 1].duration / 4, shot.duration / 4)
                switch short.editPlan?.transition ?? .cut {
                case .cut: break
                case .dip:
                    instruction.setOpacityRamp(fromStartOpacity: 1, toEndOpacity: 0.35,
                        timeRange: CMTimeRange(start: CMTime(seconds: cut - accent, preferredTimescale: 600), duration: CMTime(seconds: accent, preferredTimescale: 600)))
                    instruction.setOpacityRamp(fromStartOpacity: 0.35, toEndOpacity: 1,
                        timeRange: CMTimeRange(start: CMTime(seconds: cut, preferredTimescale: 600), duration: CMTime(seconds: accent, preferredTimescale: 600)))
                case .softFlash:
                    let flash = CALayer()
                    flash.frame = CGRect(x: pictureBand.minX, y: Self.size.height - pictureBand.maxY,
                        width: pictureBand.width, height: pictureBand.height)
                    flash.backgroundColor = NSColor.white.withAlphaComponent(0.16).cgColor
                    Self.visible(flash, from: cut, until: min(total, cut + 0.08), total: total)
                    root.addSublayer(flash)
                }
            }
            for shot in shots {
                let samples = try await faceCentres(source: source, range: shot)
                let path = EssayCameraPath.make(samples: samples, duration: shot.duration,
                    scaledWidth: width, viewportWidth: pictureBand.width)
                cameraDiagnostics.append(.init(source: shot, samples: samples, path: path))
                let offset = cursor + shot.start - range.start
                if let first = path.first {
                    instruction.setTransform(transform(first), at: CMTime(seconds: offset, preferredTimescale: 600))
                }
                for (from, to) in zip(path, path.dropFirst()) {
                    let z1 = short.isMontage ? 1 + 0.045 * from.time / max(0.1, shot.duration) : 1
                    let z2 = short.isMontage ? 1 + 0.045 * to.time / max(0.1, shot.duration) : 1
                    instruction.setTransformRamp(fromStart: transform(from, zoom: z1), toEnd: transform(to, zoom: z2),
                        timeRange: CMTimeRange(start: CMTime(seconds: offset + from.time, preferredTimescale: 600),
                            end: CMTime(seconds: offset + to.time, preferredTimescale: 600)))
                }
            }
            let fade = min(0.12, range.duration / 4)
            if !short.isMontage {
            instruction.setOpacityRamp(fromStartOpacity: 0, toEndOpacity: 1,
                timeRange: CMTimeRange(start: start, duration: CMTime(seconds: fade, preferredTimescale: 600)))
            instruction.setOpacityRamp(fromStartOpacity: 1, toEndOpacity: 0,
                timeRange: CMTimeRange(start: CMTime(seconds: cursor + range.duration - fade, preferredTimescale: 600),
                    duration: CMTime(seconds: fade, preferredTimescale: 600)))
            } else {
                instruction.setOpacity(1, at: start)
                if sceneIndex > 0, sceneIndex % 4 == 0, short.editPlan?.transition == .softFlash {
                    let flash = CALayer(); flash.frame = root.bounds
                    flash.backgroundColor = NSColor.white.withAlphaComponent(0.16).cgColor
                    Self.visible(flash, from: cursor, until: min(total, cursor + 0.09), total: total)
                    root.addSublayer(flash)
                } else if sceneIndex > 0, sceneIndex % 4 == 0, short.editPlan?.transition == .dip {
                    instruction.setOpacityRamp(fromStartOpacity: 0.35, toEndOpacity: 1,
                        timeRange: CMTimeRange(start: start, duration: CMTime(seconds: 0.09, preferredTimescale: 600)))
                }
            }
            speechMix.setVolumeRamp(fromStartVolume: 0, toEndVolume: short.isMontage ? 0 : 1,
                timeRange: CMTimeRange(start: start, duration: CMTime(seconds: 0.035, preferredTimescale: 600)))
            speechMix.setVolumeRamp(fromStartVolume: short.isMontage ? 0 : 1, toEndVolume: 0,
                timeRange: CMTimeRange(start: CMTime(seconds: cursor + range.duration - 0.035, preferredTimescale: 600),
                    duration: CMTime(seconds: 0.035, preferredTimescale: 600)))
            let phrases = captions.filter { $0.start >= range.start && $0.end <= range.end }.map {
                TimedSubtitlePhrase(start: cursor + $0.start - range.start, end: cursor + $0.end - range.start, text: $0.text)
            }
            for phrase in LongformSubtitleRenderer.chunkTimedPhrases(short.showsSubtitles ? phrases : []) {
                let layer = Self.text(phrase.text, frame: CGRect(x: 78, y: 368, width: 924, height: 145),
                    font: 49, color: ShortBrandArtwork.ivory)
                Self.visible(layer, from: phrase.start, until: phrase.end, total: total)
                root.addSublayer(layer)
            }
            cursor += range.duration
        }
        report(2, "Собираю субтитры, фирменную графику и музыкальную подложку")
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = Self.size
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        let main = AVMutableVideoCompositionInstruction()
        main.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: total, preferredTimescale: 600))
        main.backgroundColor = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1); main.layerInstructions = [instruction]
        videoComposition.instructions = [main]
        videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: videoLayer, in: root)
        let audio = AVMutableAudioMix(); audio.inputParameters = [speechMix]
        if let settings = short.musicSettings {
            var spoken: [TimeSegment] = []
            var position = 0.0
            for scene in short.segments {
                spoken += captions.filter { $0.end > scene.start && $0.start < scene.end }.map {
                    TimeSegment(start: position + max(0, $0.start - scene.start),
                                end: position + min(scene.duration, $0.end - scene.start))
                }
                position += scene.duration
            }
            if let music = try await MusicBedMixing.add(to: composition, settings: settings, duration: total, speech: spoken) {
                audio.inputParameters += [music]
            }
        }
        if let diagnosticsDirectory {
            try FileManager.default.createDirectory(at: diagnosticsDirectory, withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(cameraDiagnostics).write(to: diagnosticsDirectory.appendingPathComponent(short.id + "-camera.json"), options: .atomic)
        }
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw EssayReleaseError.invalid("Не удалось создать экспорт шортса.")
        }
        exporter.videoComposition = videoComposition; exporter.audioMix = audio
        report(3, "Кодирую вертикальное видео 1080 × 1920 · 30 кадров/с")
        let exportProgress = Task { @MainActor in
            while !Task.isCancelled {
                report(3, "Экспорт 1080 × 1920 · \(Int(exporter.progress * 100))%")
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        do { try await exporter.export(to: output, as: .mp4) }
        catch { exportProgress.cancel(); throw error }
        exportProgress.cancel()
        try Task.checkCancellation()
        if let plan = short.editPlan {
            report(4, "Цветокоррекция · " + plan.grade.rawValue)
            try await EssayShortLook.apply(plan.grade, to: output, directory: directory, pictureBand: pictureBand)
        }
        if result.audioSettings?.antiCopyrightEnabled ?? true {
            let preset = result.audioSettings?.antiCopyrightPreset ?? .cinemaShield
            if preset != .off {
                report(4, "Shield · обработка кинокадра и звука с сохранением титров и таймингов")
                _ = try await AntiCopyrightService(config: preset.config, pictureRegion: pictureBand,
                    activeDuration: cursor, preserveTimeline: true).process(videoURL: output, outputURL: output, workingDirectory: directory)
            }
        }
        report(5, "Выравниваю громкость и проверяю готовый файл")
        _ = try await LongformLoudnessService().normalize(videoURL: output, outputURL: output, workingDirectory: directory)
        let validation = await RenderValidationService().validateShort(outputURL: output, expectedDurationRange: (total - 0.2)...(total + 0.2), workingDirectory: directory)
        guard !validation.hasIssues else { throw EssayReleaseError.invalid("Шортс не прошёл проверку: " + validation.issues.map(\.description).joined(separator: ", ")) }
        report(6, "Создаю обложку и сохраняю готовую версию")
        let candidate = try await ShortBrandArtwork.coverCandidate(source: source, ranges: short.segments)
        let poster = try ShortBrandArtwork.cover(short: short, result: result, candidate: candidate)
        _ = try LongformThumbnailExporter().export(image: poster, to: cover)
        var rendered = short; rendered.outputURL = output; rendered.coverURL = cover; rendered.renderStyleVersion = EssayShort.currentRenderStyle
        completed = true
        return rendered
    }

    private static let gold = NSColor(calibratedRed: 0.83, green: 0.69, blue: 0.22, alpha: 1)
    private static func text(_ text: String, frame: CGRect, font: CGFloat, color: NSColor) -> CALayer {
        let layer = CALayer(); layer.frame = frame; layer.contentsScale = 2
        let fitted = LongformThumbnailComposer.fittedText(text, in: CGRect(origin: .zero, size: frame.size),
            maxSize: font, minSize: font * 0.65, serif: false)
        let attributed = NSMutableAttributedString(attributedString: fitted)
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
        paragraph.lineBreakMode = .byClipping
        attributed.addAttributes([.foregroundColor: color, .paragraphStyle: paragraph], range: NSRange(location: 0, length: attributed.length))
        // Rasterised AppKit text is reliable in AVCoreAnimationTool; native
        // CATextLayer attributed strings can disappear in an offscreen export.
        let width = max(1, Int(ceil(frame.width * 2))), height = max(1, Int(ceil(frame.height * 2)))
        if let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            context.scaleBy(x: 2, y: 2)
            attributed.draw(with: CGRect(origin: .zero, size: frame.size), options: [.usesLineFragmentOrigin, .usesFontLeading])
            NSGraphicsContext.restoreGraphicsState()
            layer.contents = context.makeImage()
        }
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = 0.9; layer.shadowRadius = 4; layer.shadowOffset = CGSize(width: 0, height: -1)
        return layer
    }
    private static func visible(_ layer: CALayer, from: Double, until: Double, total: Double) {
        layer.opacity = 0
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = [0, 0, 1, 1, 0, 0]
        let fade = min(0.08, (until - from) / 4)
        animation.keyTimes = [0, NSNumber(value: max(0, from / total)), NSNumber(value: (from + fade) / total),
            NSNumber(value: (until - fade) / total), NSNumber(value: min(1, until / total)), 1]
        animation.duration = total; animation.beginTime = AVCoreAnimationBeginTimeAtZero
        animation.fillMode = .both; animation.isRemovedOnCompletion = false
        layer.add(animation, forKey: "visibility")
    }
    private func faceCentres(source: AVURLAsset, range: TimeSegment) async throws -> [EssayCameraPath.Sample] {
        let generator = AVAssetImageGenerator(asset: source); generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 360)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        var centres: [EssayCameraPath.Sample] = []
        var previousFace: CGRect?
        for offset in stride(from: 0.0, to: range.duration, by: 0.2) {
            try Task.checkCancellation()
            // A cut timestamp rounded to the 600 Hz edit clock may fall a
            // fraction before the new source frame. Sample one output frame
            // into the shot so its opening never tracks the previous hero.
            let probe = min(offset + 1.0 / 30, max(0, range.duration - 0.001))
            guard let frame = try? await generator.image(at: CMTime(seconds: range.start + probe, preferredTimescale: 600)).image else {
                centres.append(.init(time: offset, centre: nil)); continue
            }
            let face = EssayCameraPath.selectFace(try ShortBrandArtwork.faces(in: frame).map(\.boundingBox), previous: previousFace)
            if let face {
                previousFace = face
            }
            centres.append(.init(time: offset, centre: face?.midX))
        }
        return centres
    }
}

/// A heavy, steady virtual camera: keep the chosen face, ignore sensor jitter,
/// and limit both velocity and acceleration. Positions are expressed in output
/// pixels; detector dropouts hold the last target instead of recentring.
enum EssayCameraPath {
    struct Sample: Codable, Sendable { let time: Double; let centre: CGFloat? }
    struct Keyframe: Codable, Sendable { let time: Double; let cropX: CGFloat }
    struct Segment: Codable, Sendable { let source: TimeSegment; let samples: [Sample]; let path: [Keyframe] }
    static let maximumSpeed: CGFloat = 180
    static let maximumAcceleration: CGFloat = 360
    static let deadZone: CGFloat = 42

    static func selectFace(_ faces: [CGRect], previous: CGRect?) -> CGRect? {
        guard let previous else {
            return faces.max { $0.width * $0.height < $1.width * $1.height }
        }
        // A slightly larger second face must not steal focus on each sample.
        return faces.min { a, b in
            func score(_ face: CGRect) -> CGFloat {
                let distance = hypot(face.midX - previous.midX, face.midY - previous.midY)
                let area = max(0.0001, face.width * face.height)
                let sizeChange = abs(log(area / max(0.0001, previous.width * previous.height)))
                return distance + 0.08 * sizeChange
            }
            return score(a) < score(b)
        }
    }

    static func make(samples: [Sample], duration: Double, scaledWidth: CGFloat,
                     viewportWidth: CGFloat) -> [Keyframe] {
        guard duration > 0 else { return [] }
        let travel = max(0, scaledWidth - viewportWidth)
        guard travel > 0 else { return [.init(time: 0, cropX: 0), .init(time: duration, cropX: 0)] }
        func crop(_ centre: CGFloat) -> CGFloat {
            min(1, max(0, (centre * scaledWidth - viewportWidth / 2) / travel))
        }
        let observations = samples.filter { $0.time.isFinite && $0.time >= 0 && $0.time <= duration }
            .sorted { $0.time < $1.time }
        // Seed from the first readable face near the opening, avoiding a pan
        // out of a blind centre crop while the first image becomes visible.
        let first = observations.first { $0.time <= 0.4 && $0.centre?.isFinite == true }?.centre ?? 0.5
        var target = crop(first)
        var state = CameraFilterState(position: target, velocity: 0, timestamp: 0, emaFilteredTarget: target)
        let config = SmoothingConfiguration(deadbandThreshold: deadZone / travel,
            emaTimeConstant: 0.24, springOmega: 5, dampingRatio: 1.05,
            maxPanVelocity: maximumSpeed / travel, sceneCutThreshold: 2,
            mode: .hybridDampedSpringWithEMA)
        let optimizer = SmoothedPathOptimizer(configuration: config)
        var result = [Keyframe(time: 0, cropX: target * travel)]
        var sampleIndex = 0
        for frame in 1...max(1, Int(ceil(duration * 30))) {
            let time = min(duration, Double(frame) / 30)
            let dt = time - state.timestamp
            guard dt > 0 else { continue }
            while sampleIndex < observations.count && observations[sampleIndex].time <= time {
                if let centre = observations[sampleIndex].centre, centre.isFinite { target = crop(centre) }
                sampleIndex += 1
            }
            let (_, filtered) = optimizer.step(currentState: state, targetX: target, deltaTime: dt, configuration: config)
            let acceleration = maximumAcceleration / travel * CGFloat(dt)
            let velocity = min(state.velocity + acceleration, max(state.velocity - acceleration, filtered.velocity))
            let next = min(1, max(0, state.position + (state.velocity + velocity) / 2 * CGFloat(dt)))
            state = CameraFilterState(position: next, velocity: next == 0 || next == 1 ? 0 : velocity,
                timestamp: time, emaFilteredTarget: filtered.emaFilteredTarget)
            result.append(.init(time: time, cropX: next * travel))
        }
        return result
    }
}

/// Artwork for the vertical release: one typography and colour system, with
/// separate compositions for the moving picture, its poster, and the end card.
@MainActor
enum ShortBrandArtwork {
    static let ivory = NSColor(srgbRed: 0.98, green: 0.97, blue: 0.95, alpha: 1)
    static let gold = NSColor(srgbRed: 0.85, green: 0.71, blue: 0.44, alpha: 1)
    static let ink = NSColor(srgbRed: 0.035, green: 0.043, blue: 0.052, alpha: 1)
    private static var cpuDetector = false
    private static let canvas = CGSize(width: 1080, height: 1920)

    static func faces(in frame: CGImage) throws -> [VNFaceObservation] {
        let request = VNDetectFaceRectanglesRequest()
        if cpuDetector { request.revision = VNDetectFaceRectanglesRequestRevision1; request.usesCPUOnly = true }
        do { try VNImageRequestHandler(cgImage: frame).perform([request]) }
        catch {
            // The current GPU detector can be unavailable in offscreen export
            // hosts. Retry the supported CPU revision before failing a render.
            cpuDetector = true
            request.revision = VNDetectFaceRectanglesRequestRevision1; request.usesCPUOnly = true
            try VNImageRequestHandler(cgImage: frame).perform([request])
        }
        return request.results ?? []
    }

    /// A brief film identity card; the rest of the picture has only the channel logo.
    static func openingCard(result: LongformBuildResult) throws -> CGImage {
        try draw { ctx in
            let panel = CGRect(x: 60, y: 790, width: 960, height: 340)
            ctx.setFillColor(ink.withAlphaComponent(0.92).cgColor)
            ctx.fill(panel)
            line(ctx, x: 108, y: 1060, width: 96)
            text("КАДР & СЕНС", rect: CGRect(x: 108, y: 990, width: 864, height: 42), size: 24, color: gold)
            text(result.arc.movieTitle, rect: CGRect(x: 108, y: 838, width: 864, height: 128), size: 62, color: ivory, serif: true)
        }
    }

    static func overlay(short: EssayShort, result: LongformBuildResult) throws -> CGImage {
        try hookHeader(short: short, result: result)
    }

    /// The hook occupies the upper matte; the scene and faces remain visible from frame zero.
    static func hookHeader(short: EssayShort, result: LongformBuildResult) throws -> CGImage {
        try draw { ctx in
            brand(in: ctx, y: 1818)
            text(short.hook, rect: CGRect(x: 72, y: 1630, width: 936, height: 160), size: 52, color: ivory, serif: true)
            text(result.arc.movieTitle, rect: CGRect(x: 72, y: 1570, width: 936, height: 44), size: 30, color: gold)
        }
    }

    static func endCard(result: LongformBuildResult, telegramURL: String?) throws -> CGImage {
        try draw { ctx in
            ctx.setFillColor(ink.cgColor); ctx.fill(CGRect(origin: .zero, size: canvas))
            brand(in: ctx, y: 1818)
            text("ЦЕ ЛИШЕ ОДИН ПОГЛЯД", rect: CGRect(x: 72, y: 1650, width: 936, height: 40), size: 24, color: gold)
            text("Погляньте\nглибше.", rect: CGRect(x: 72, y: 1300, width: 936, height: 310), size: 126, color: ivory, serif: true)
            line(ctx, x: 72, y: 1250, width: 140)
            text(result.arc.movieTitle, rect: CGRect(x: 72, y: 1148, width: 936, height: 70), size: 42, color: gold, serif: true)
            if let url = result.thumbnailURL, let source = CGImageSourceCreateWithURL(url as CFURL, nil),
               let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                ctx.draw(image, in: CGRect(x: 72, y: 584, width: 936, height: 526.5))
                corners(in: ctx, rect: CGRect(x: 60, y: 572, width: 960, height: 550), length: 28)
            }
            text("ДИВІТЬСЯ ПОВНЕ ЕСЕ", rect: CGRect(x: 72, y: 390, width: 936, height: 58), size: 42, color: ivory)
            text("YouTube · Кадр & Сенс", rect: CGRect(x: 72, y: 326, width: 936, height: 44), size: 30, color: gold)
            if let handle = telegramURL.flatMap({ URL(string: $0)?.lastPathComponent }), !handle.isEmpty {
                text("Обговорення · @" + handle, rect: CGRect(x: 72, y: 196, width: 936, height: 40), size: 24, color: ivory.withAlphaComponent(0.6))
            }
            line(ctx, x: 72, y: 130, width: 936, alpha: 0.25)
        }
    }

    static func cover(short: EssayShort, result: LongformBuildResult, candidate: ThumbnailCandidateFrame) throws -> CGImage {
        try draw { ctx in
            ctx.setFillColor(ink.cgColor); ctx.fill(CGRect(origin: .zero, size: canvas))
            let image = candidate.image
            // Preserve the face in a generous upper photo pane. Scaling a
            // widescreen frame to the full 9:16 height produces a giant face.
            let pane = CGRect(x: 0, y: 660, width: 1080, height: 1104)
            let scale = max(pane.width / CGFloat(image.width), pane.height / CGFloat(image.height))
            let width = CGFloat(image.width) * scale, height = CGFloat(image.height) * scale
            let face = candidate.faceBox ?? CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.3)
            let x = min(pane.minX, max(pane.maxX - width, canvas.width * 0.60 - face.midX * width))
            let y = min(pane.minY, max(pane.maxY - height, 1320 - face.midY * height))
            ctx.saveGState(); ctx.clip(to: pane)
            ctx.draw(image, in: CGRect(x: x, y: y, width: width, height: height))
            ctx.restoreGState()
            let space = CGColorSpaceCreateDeviceRGB()
            if let gradient = CGGradient(colorsSpace: space, colors: [ink.cgColor, ink.withAlphaComponent(0.97).cgColor,
                ink.withAlphaComponent(0.35).cgColor, ink.withAlphaComponent(0.08).cgColor] as CFArray, locations: [0, 0.26, 0.63, 1]) {
                ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: 1920), options: [])
            }
            ctx.setFillColor(ink.withAlphaComponent(0.78).cgColor)
            ctx.fill(CGRect(x: 0, y: 1764, width: 1080, height: 156))
            brand(in: ctx, y: 1818)
            let tag = short.id == "short2" ? "02 / СЦЕНА З ФІЛЬМУ" : "01 / СЦЕНА З ФІЛЬМУ"
            text(tag, rect: CGRect(x: 72, y: 1030, width: 936, height: 42), size: 24, color: gold)
            text(short.title, rect: CGRect(x: 72, y: 490, width: 872, height: 496), size: 108, color: ivory, serif: true)
            line(ctx, x: 72, y: 402, width: 140)
            text(result.arc.movieTitle.uppercased(), rect: CGRect(x: 72, y: 286, width: 872, height: 74), size: 36, color: gold)
            text("СЦЕНА З ФІЛЬМУ", rect: CGRect(x: 72, y: 148, width: 872, height: 40), size: 22, color: ivory.withAlphaComponent(0.6))
            corners(in: ctx, rect: CGRect(x: 34, y: 90, width: 1012, height: 1770), length: 32)
        }
    }

    static func coverCandidate(source: AVURLAsset, ranges: [TimeSegment]) async throws -> ThumbnailCandidateFrame {
        let generator = AVAssetImageGenerator(asset: source)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1920, height: 1080)
        var best: ThumbnailCandidateFrame?
        // The opening scene establishes this short's subject. A later,
        // larger reaction face must not displace its protagonist on the cover.
        for range in ranges.prefix(1) {
            for fraction in [0.22, 0.5, 0.78] {
                try Task.checkCancellation()
                let time = range.start + range.duration * fraction
                guard let image = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image else { continue }
                let boxes = try faces(in: image)
                let face = boxes.max { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }
                let box = face?.boundingBox
                let score = (box.map { Double($0.width * $0.height) } ?? 0) + (face == nil ? 0 : 1)
                let candidate = ThumbnailCandidateFrame(time: time, image: image, faceBox: box, score: score,
                    averageLuminance: 0.3, faceCount: boxes.count)
                if best == nil || candidate.score > best!.score { best = candidate }
            }
        }
        guard let best else { throw EssayReleaseError.invalid("Не удалось получить кадр для обложки шортса.") }
        return best
    }

    static func draw(_ content: (CGContext) -> Void) throws -> CGImage {
        guard let ctx = CGContext(data: nil, width: 1080, height: 1920, bitsPerComponent: 8, bytesPerRow: 4320,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw EssayReleaseError.invalid("Не удалось подготовить фирменное оформление.")
        }
        ctx.interpolationQuality = .high
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        defer { NSGraphicsContext.restoreGraphicsState() }
        content(ctx)
        guard let image = ctx.makeImage() else { throw EssayReleaseError.invalid("Не удалось отрисовать оформление.") }
        return image
    }

    static func text(_ value: String, rect: CGRect, size: CGFloat, color: NSColor, serif: Bool = false) {
        let fitted = LongformThumbnailComposer.fittedText(value, in: rect, maxSize: size, minSize: size * 0.5, serif: serif)
        let text = NSMutableAttributedString(attributedString: fitted)
        text.addAttribute(.foregroundColor, value: color, range: NSRange(location: 0, length: text.length))
        let height = ceil(text.boundingRect(with: CGSize(width: rect.width, height: 10_000), options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
        text.draw(with: CGRect(x: rect.minX, y: rect.maxY - height - 2, width: rect.width, height: height + 2), options: [.usesLineFragmentOrigin, .usesFontLeading])
    }

    private static func brand(in ctx: CGContext, y: CGFloat) {
        corners(in: ctx, rect: CGRect(x: 72, y: y + 4, width: 30, height: 30), length: 10)
        text("КАДР & СЕНС", rect: CGRect(x: 126, y: y - 2, width: 580, height: 46), size: 34, color: ivory, serif: true)
    }
    private static func line(_ ctx: CGContext, x: CGFloat, y: CGFloat, width: CGFloat, alpha: CGFloat = 1) {
        ctx.setFillColor(gold.withAlphaComponent(alpha).cgColor)
        ctx.fill(CGRect(x: x, y: y, width: width, height: 2))
    }
    private static func corners(in ctx: CGContext, rect: CGRect, length: CGFloat) {
        ctx.setStrokeColor(gold.withAlphaComponent(0.6).cgColor); ctx.setLineWidth(2)
        for point in [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)] {
            let dx: CGFloat = point.x == rect.minX ? 1 : -1
            let dy: CGFloat = point.y == rect.minY ? 1 : -1
            ctx.strokeLineSegments(between: [CGPoint(x: point.x, y: point.y + dy * length), point, point, CGPoint(x: point.x + dx * length, y: point.y)])
        }
    }
}
