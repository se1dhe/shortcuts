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
    static func addMatte(to root: CALayer) {
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
                diagnosticsDirectory: URL? = nil) async throws -> EssayShort {
        let output = directory.appendingPathComponent("essay_\(short.id)_\(UUID().uuidString.prefix(6)).mp4")
        let cover = output.deletingPathExtension().appendingPathExtension("jpg")
        var completed = false
        defer {
            if !completed {
                try? FileManager.default.removeItem(at: output)
                try? FileManager.default.removeItem(at: cover)
            }
        }
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
        Self.addMatte(to: root)
        let essayCaptions = LongformEditorialSupport.captions(transcript.segments, edits: result.arc.captionEdits)
        let captions = LongformEditorialSupport.captions(essayCaptions, edits: short.captionEdits)
        var cursor = 0.0
        let total = short.duration
        var cameraDiagnostics: [EssayCameraPath.Segment] = []
        for range in short.segments {
            try Task.checkCancellation()
            let start = CMTime(seconds: cursor, preferredTimescale: 600)
            let duration = CMTime(seconds: range.duration, preferredTimescale: 600)
            let sourceRange = CMTimeRange(start: CMTime(seconds: range.start, preferredTimescale: 600), duration: duration)
            try video.insertTimeRange(sourceRange, of: sourceVideo, at: start)
            try speech.insertTimeRange(sourceRange, of: sourceAudio, at: start)
            // A large square picture band within the vertical canvas; preserve
            // the speaker with Vision framing rather than a blind centre crop.
            let scale = max(Self.pictureBand.width / sourceSize.width, Self.pictureBand.height / sourceSize.height)
            let width = sourceSize.width * scale
            func transform(_ point: EssayCameraPath.Keyframe) -> CGAffineTransform {
                preferred.concatenating(CGAffineTransform(scaleX: scale, y: scale))
                    .concatenating(CGAffineTransform(translationX: -point.cropX, y: Self.pictureBand.minY))
            }
            // Reset at both editorial cuts and strong source shot changes.
            // Detect them at export cadence, not from the face's displacement:
            // an actor moving quickly within a shot must still pan smoothly.
            let scenes = try await SceneDetectionService.detectScenes(in: sourceURL, threshold: 0.65,
                sampleRate: 30, range: range, spatialThreshold: 0.10)
            let shots = scenes.isEmpty ? [range] : scenes.map { TimeSegment(start: $0.start, end: $0.end) }
            for shot in shots {
                let samples = try await faceCentres(source: source, range: shot)
                let path = EssayCameraPath.make(samples: samples, duration: shot.duration,
                    scaledWidth: width, viewportWidth: Self.pictureBand.width)
                cameraDiagnostics.append(.init(source: shot, samples: samples, path: path))
                let offset = cursor + shot.start - range.start
                if let first = path.first {
                    instruction.setTransform(transform(first), at: CMTime(seconds: offset, preferredTimescale: 600))
                }
                for (from, to) in zip(path, path.dropFirst()) {
                    instruction.setTransformRamp(fromStart: transform(from), toEnd: transform(to),
                        timeRange: CMTimeRange(start: CMTime(seconds: offset + from.time, preferredTimescale: 600),
                            end: CMTime(seconds: offset + to.time, preferredTimescale: 600)))
                }
            }
            let fade = min(0.12, range.duration / 4)
            instruction.setOpacityRamp(fromStartOpacity: 0, toEndOpacity: 1,
                timeRange: CMTimeRange(start: start, duration: CMTime(seconds: fade, preferredTimescale: 600)))
            instruction.setOpacityRamp(fromStartOpacity: 1, toEndOpacity: 0,
                timeRange: CMTimeRange(start: CMTime(seconds: cursor + range.duration - fade, preferredTimescale: 600),
                    duration: CMTime(seconds: fade, preferredTimescale: 600)))
            speechMix.setVolumeRamp(fromStartVolume: 0, toEndVolume: 1,
                timeRange: CMTimeRange(start: start, duration: CMTime(seconds: 0.035, preferredTimescale: 600)))
            speechMix.setVolumeRamp(fromStartVolume: 1, toEndVolume: 0,
                timeRange: CMTimeRange(start: CMTime(seconds: cursor + range.duration - 0.035, preferredTimescale: 600),
                    duration: CMTime(seconds: 0.035, preferredTimescale: 600)))
            let phrases = captions.filter { $0.start >= range.start && $0.end <= range.end }.map {
                TimedSubtitlePhrase(start: cursor + $0.start - range.start, end: cursor + $0.end - range.start, text: $0.text)
            }
            for phrase in LongformSubtitleRenderer.chunkTimedPhrases(phrases) {
                let layer = Self.text(phrase.text.uppercased(), frame: CGRect(x: 70, y: 355, width: 940, height: 170),
                    font: 48, color: Self.gold)
                Self.visible(layer, from: phrase.start, until: phrase.end, total: total)
                root.addSublayer(layer)
            }
            cursor += range.duration
        }
        // Trailing empty composition time is not exported by all AVFoundation
        // presets. A hidden real video span keeps the complete CTA on the clock.
        if let last = short.segments.last {
            try video.insertTimeRange(CMTimeRange(
                start: CMTime(seconds: last.end - 3, preferredTimescale: 600), duration: CMTime(seconds: 3, preferredTimescale: 600)),
                of: sourceVideo, at: CMTime(seconds: cursor, preferredTimescale: 600))
        }
        instruction.setOpacity(0, at: CMTime(seconds: cursor, preferredTimescale: 600))
        let title = Self.text(result.arc.movieTitle.uppercased(), frame: CGRect(x: 70, y: 1810, width: 940, height: 70), font: 34, color: Self.gold)
        root.addSublayer(title)
        root.addSublayer(Self.text(short.hook, frame: CGRect(x: 80, y: 1600, width: 920, height: 200), font: 56, color: .white))
        root.addSublayer(Self.text("КАДР & СЕНС", frame: CGRect(x: 70, y: 225, width: 940, height: 60), font: 32, color: Self.gold))
        let handle = telegramURL.flatMap { URL(string: $0)?.lastPathComponent }.map { "\nОбговорення: @" + $0 } ?? ""
        root.addSublayer(Self.text("Повне есе — на YouTube «Кадр & Сенс»" + handle,
            frame: CGRect(x: 80, y: 100, width: 920, height: 110), font: 30, color: .white))
        let endCard = CALayer(); endCard.frame = root.bounds
        endCard.backgroundColor = NSColor(calibratedWhite: 0.025, alpha: 1).cgColor
        endCard.addSublayer(Self.text("ПОВНЕ КІНОЕСЕ", frame: CGRect(x: 80, y: 1220, width: 920, height: 100), font: 60, color: Self.gold))
        endCard.addSublayer(Self.text(result.arc.movieTitle + "\nYouTube: Кадр & Сенс" + handle,
            frame: CGRect(x: 80, y: 800, width: 920, height: 340), font: 48, color: .white))
        Self.visible(endCard, from: cursor, until: total, total: total); root.addSublayer(endCard)
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = Self.size
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        let main = AVMutableVideoCompositionInstruction()
        main.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: total, preferredTimescale: 600))
        main.backgroundColor = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1); main.layerInstructions = [instruction]
        videoComposition.instructions = [main]
        videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: videoLayer, in: root)
        let audio = AVMutableAudioMix(); audio.inputParameters = [speechMix]
        if let diagnosticsDirectory {
            try FileManager.default.createDirectory(at: diagnosticsDirectory, withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(cameraDiagnostics).write(to: diagnosticsDirectory.appendingPathComponent(short.id + "-camera.json"), options: .atomic)
        }
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw EssayReleaseError.invalid("Не удалось создать экспорт шортса.")
        }
        exporter.videoComposition = videoComposition; exporter.audioMix = audio
        try await exporter.export(to: output, as: .mp4)
        try Task.checkCancellation()
        _ = try await LongformLoudnessService().normalize(videoURL: output, outputURL: output, workingDirectory: directory)
        let validation = await RenderValidationService().validateShort(outputURL: output, workingDirectory: directory)
        guard !validation.hasIssues else { throw EssayReleaseError.invalid("Шортс не прошёл проверку: " + validation.issues.map(\.description).joined(separator: ", ")) }
        let image = AVAssetImageGenerator(asset: AVURLAsset(url: output))
        image.appliesPreferredTrackTransform = true
        let frame = try await image.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image
        guard let data = NSBitmapImageRep(cgImage: frame).representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else {
            throw EssayReleaseError.invalid("Не удалось сохранить обложку шортса.")
        }
        try data.write(to: cover, options: .atomic)
        var rendered = short; rendered.outputURL = output; rendered.coverURL = cover
        completed = true
        return rendered
    }

    private static let gold = NSColor(calibratedRed: 0.83, green: 0.69, blue: 0.22, alpha: 1)
    private static func text(_ text: String, frame: CGRect, font: CGFloat, color: NSColor) -> CALayer {
        let layer = CALayer(); layer.frame = frame; layer.contentsScale = 2
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
        var pointSize = font
        var attributed: NSAttributedString
        repeat {
            attributed = NSAttributedString(string: text, attributes: [.font: NSFont(name: "AvenirNext-DemiBold", size: pointSize) ?? NSFont.boldSystemFont(ofSize: pointSize),
                .foregroundColor: color, .paragraphStyle: paragraph])
            let measured = attributed.boundingRect(with: CGSize(width: frame.width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading])
            if measured.height <= frame.height || pointSize <= font * 0.65 { break }
            pointSize -= 2
        } while true
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
            let request = VNDetectFaceRectanglesRequest()
            try VNImageRequestHandler(cgImage: frame).perform([request])
            let face = EssayCameraPath.selectFace((request.results ?? []).map(\.boundingBox), previous: previousFace)
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
