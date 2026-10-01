import AVFoundation
import CoreImage
import Vision
import QuartzCore

/// Reframes a horizontal (16:9) clip into a vertical 9:16 short, the way
/// short-form editors do it: it follows the speaker with a smoothed "virtual
/// camera" (Apple Vision face detection → a panning crop window), and falls back
/// to a blurred-background letterbox when there's no clear single face.
///
/// Everything is on-device and native — no Python, MediaPipe, YOLO or FFmpeg.
/// The pan is expressed as `setTransformRamp` keyframes on a layer instruction,
/// so AVFoundation interpolates the motion on the GPU in a single export pass,
/// and the optional text hook is burned in the same pass (reusing
/// `VideoOverlayRenderer`'s band helpers).
@MainActor
enum VerticalReframer {

    /// 1080×1080 — the cinematic square canvas (1:1).
    private static let outW: CGFloat = 1080
    private static let outH: CGFloat = 1080

    // MARK: - Public

    /// True when the video is wider than it is tall (so reframing to 9:16 makes
    /// sense). Used by the pipeline to decide whether to offer the per-clip
    /// "Convert to vertical" toggle.
    static func isLandscape(url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let size = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform)
        else { return false }
        let oriented = size.applying(transform)
        return abs(oriented.width) > abs(oriented.height)
    }

    /// Produces the file to upload for a clip. Returns `nil` when there's nothing
    /// to do (no reframe and no overlay) — the caller then uploads the original.
    ///
    /// - `reframe`: convert 16:9 → 9:16 (caller already checked it's landscape).
    /// - `overlayText`: burn this text hook into the first seconds (nil = none).
    static func process(clipURL: URL, reframe: Bool, overlayText: String?, promoCode: String? = nil,
                        promoHoldSeconds: Double = 0,
                        hookAppearance: HookAppearance = .default) async throws -> URL? {
        let hook = overlayText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let wantOverlay = !(hook?.isEmpty ?? true)
        let cleanPromoCode = promoCode?.trimmingCharacters(in: .whitespacesAndNewlines)
        let wantPromo = !(cleanPromoCode?.isEmpty ?? true)

        // No reframe → keep the existing overlay-only path untouched.
        guard reframe else {
            if wantOverlay || wantPromo {
                return try await VideoOverlayRenderer.render(
                    clipURL: clipURL, text: hook,
                    promoCode: cleanPromoCode,
                    promoHoldSeconds: promoHoldSeconds,
                    appearance: hookAppearance)
            }
            return nil
        }

        let asset = AVURLAsset(url: clipURL)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw MediaExtractorError.noVideoTrack
        }
        let duration = try await asset.load(.duration)
        let naturalSize = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        let oriented = naturalSize.applying(transform)
        let orientedSize = CGSize(width: abs(oriented.width), height: abs(oriented.height))

        // Sample faces across the clip using the Smoothed Path Optimizer
        var keyframes: [Keyframe] = []
        var trackable = false
        
        if let cinemaKeyframes = try? await CinemaSquareReframer.sampleAndOptimizeVideoPath(asset: asset),
           !cinemaKeyframes.isEmpty {
            let scale = outH / orientedSize.height
            let scaledW = orientedSize.width * scale
            let cropMaxX = max(0, scaledW - outW)
            keyframes = cinemaKeyframes.map { ck in
                let targetX = min(max(ck.cropX * cropMaxX, 0), cropMaxX)
                return Keyframe(time: ck.time, cropX: targetX)
            }
            trackable = true
        }

        if trackable {
            return try await renderTracking(
                asset: asset, videoTrack: videoTrack, duration: duration,
                transform: transform, keyframes: keyframes,
                overlayText: wantOverlay ? hook! : nil,
                promoCode: cleanPromoCode,
                promoHoldSeconds: promoHoldSeconds,
                hookAppearance: hookAppearance)
        } else {
            let reframed = try await renderBlurred(asset: asset)
            guard wantOverlay || wantPromo else { return reframed }
            // B-roll fallback only: one additional pass for the visual layers.
            let withHook = try await VideoOverlayRenderer.render(
                clipURL: reframed, text: hook,
                promoCode: cleanPromoCode,
                promoHoldSeconds: promoHoldSeconds,
                appearance: hookAppearance)
            try? FileManager.default.removeItem(at: reframed)
            return withHook
        }
    }

    // MARK: - Face sampling (Vision)

    private struct Sample { let time: Double; let midX: CGFloat? }

    /// Detects the largest face every ~0.5 s. `midX` is the face's horizontal
    /// centre in 0…1 of the oriented frame; nil when no face is found. Runs off
    /// the main actor (Vision is CPU-heavy) and only takes the URL so no
    /// non-Sendable AVFoundation object crosses isolation.
    nonisolated private static func sampleFaces(clipURL: URL, duration: Double) async -> [Sample] {
        let asset = AVURLAsset(url: clipURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true   // upright frames
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.25, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.25, preferredTimescale: 600)
        generator.maximumSize = CGSize(width: 512, height: 512)  // plenty for detection

        var samples: [Sample] = []
        var t = 0.0
        let step = 0.5
        while t < max(step, duration) {
            let time = CMTime(seconds: t, preferredTimescale: 600)
            if let (cgImage, _) = try? await generator.image(at: time) {
                samples.append(Sample(time: t, midX: largestFaceMidX(in: cgImage)))
            } else {
                samples.append(Sample(time: t, midX: nil))
            }
            t += step
        }
        return samples
    }

    nonisolated private static func largestFaceMidX(in cgImage: CGImage) -> CGFloat? {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        guard (try? handler.perform([request])) != nil,
              let faces = request.results, !faces.isEmpty else { return nil }
        // Largest face by area wins (the speaker, not background extras).
        let biggest = faces.max { a, b in
            (a.boundingBox.width * a.boundingBox.height) < (b.boundingBox.width * b.boundingBox.height)
        }
        return biggest?.boundingBox.midX
    }

    // MARK: - Pan path (the "virtual camera")

    private struct Keyframe { let time: Double; let cropX: CGFloat }

    /// Turns face samples into a smoothed sequence of crop-window centres, in the
    /// scaled render space. "Heavy tripod": the camera only pans when the subject
    /// leaves a safe zone, and never faster than a capped speed — no jitter.
    private static func panPath(from samples: [Sample], orientedSize: CGSize) -> [Keyframe] {
        let scale = outH / orientedSize.height
        let scaledW = orientedSize.width * scale
        let cropMaxX = max(0, scaledW - outW)
        let center = cropMaxX / 2

        let facePositions = samples.compactMap { $0.midX }
        guard !facePositions.isEmpty else { return [Keyframe(time: 0, cropX: center)] }
        
        let avgX = facePositions.reduce(0, +) / CGFloat(facePositions.count)
        let targetX = min(max(avgX * scaledW - outW / 2, 0), cropMaxX)
        
        // Return a single static keyframe so the camera never floats.
        return [Keyframe(time: 0, cropX: targetX)]
    }

    /// Maps the oriented video into the 1080×1920 canvas with the crop window at
    /// `cropX`: orient → scale-to-height → translate horizontally.
    private static func transform(for cropX: CGFloat, base: CGAffineTransform,
                                  orientedSize: CGSize, zoom: CGFloat = 1.0) -> CGAffineTransform {
        let scale = (outH / orientedSize.height) * zoom
        let adjustedCropX = (cropX + (outW / 2.0)) * zoom - (outW / 2.0)
        let adjustedCropY = (outH / 2.0) * zoom - (outH / 2.0)
        
        return base
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: -adjustedCropX, y: -adjustedCropY))
    }

    // MARK: - Tracking composition (transform ramps)

    /// Builds the 9:16 tracking composition (pan ramps, no overlay) — shared by
    /// the export path and the live preview.
    private static func buildTracking(
        asset: AVAsset, videoTrack: AVAssetTrack, duration: CMTime,
        transform base: CGAffineTransform, keyframes: [Keyframe]
    ) async throws -> (composition: AVMutableComposition, videoComposition: AVMutableVideoComposition) {
        let oriented = try await videoTrack.load(.naturalSize).applying(base)
        let orientedSize = CGSize(width: abs(oriented.width), height: abs(oriented.height))

        let composition = AVMutableComposition()
        let full = CMTimeRange(start: .zero, duration: duration)
        // INSERT THE ENTIRE ASSET TO PRESERVE EXACT TIMING (EDTS / B-FRAMES)
        try await composition.insertTimeRange(full, of: asset, at: .zero)
        
        guard let compVideo = composition.tracks(withMediaType: .video).first else {
            throw MediaExtractorError.clipExportFailed("no video track")
        }

        let renderSize = CGSize(width: outW, height: outH)
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = full
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compVideo)

        // Pan as a chain of linear transform ramps between sampled keyframes.
        let frames = keyframes.isEmpty
            ? [Keyframe(time: 0, cropX: max(0, orientedSize.width * (outH / orientedSize.height) - outW) / 2)]
            : keyframes
            
        let totalDuration = duration.seconds
        layerInstruction.setTransform(
            transform(for: frames[0].cropX, base: base, orientedSize: orientedSize, zoom: 1.0), at: .zero)
            
        for i in 0..<frames.count - 1 where frames.count > 1 {
            let startT = CMTime(seconds: frames[i].time, preferredTimescale: 600)
            let endT = CMTime(seconds: frames[i + 1].time, preferredTimescale: 600)
            
            // Slow Cinematic Zoom (0 to 5% over the entire clip)
            let zoomStart = 1.0 + (0.05 * (startT.seconds / totalDuration))
            let zoomEnd = 1.0 + (0.05 * (endT.seconds / totalDuration))
            
            layerInstruction.setTransformRamp(
                fromStart: transform(for: frames[i].cropX, base: base, orientedSize: orientedSize, zoom: zoomStart),
                toEnd: transform(for: frames[i + 1].cropX, base: base, orientedSize: orientedSize, zoom: zoomEnd),
                timeRange: CMTimeRange(start: startT, end: endT))
        }
        instruction.layerInstructions = [layerInstruction]
        videoComposition.instructions = [instruction]

        return (composition, videoComposition)
    }

    /// Export path: tracking reframe + optional burned-in hook, one pass.
    private static func renderTracking(
        asset: AVAsset, videoTrack: AVAssetTrack, duration: CMTime,
        transform base: CGAffineTransform, keyframes: [Keyframe],
        overlayText: String?, promoCode: String? = nil,
        promoHoldSeconds: Double = 0,
        hookAppearance: HookAppearance = .default
    ) async throws -> URL {
        let (composition, videoComposition) = try await buildTracking(
            asset: asset, videoTrack: videoTrack, duration: duration,
            transform: base, keyframes: keyframes)

        if overlayText != nil || promoCode != nil {
            let renderSize = videoComposition.renderSize
            let parentLayer = CALayer()
            let videoLayer = CALayer()
            parentLayer.frame = CGRect(origin: .zero, size: renderSize)
            videoLayer.frame = parentLayer.frame
            parentLayer.addSublayer(videoLayer)

            let total = CMTimeGetSeconds(duration)
            if let overlayText {
                let band = VideoOverlayRenderer.makeHookBand(
                    text: overlayText, renderSize: renderSize, hasPromo: promoCode != nil, appearance: hookAppearance)
                VideoOverlayRenderer.addOpacityAnimation(to: band, total: total, hold: 3)
                VideoOverlayRenderer.addStyleAnimation(to: band, style: hookAppearance.normalized.style, total: total)
                parentLayer.addSublayer(band)
            }
            if let promoCode {
                PromoOverlayRenderer.addBanner(to: parentLayer, promoCode: promoCode,
                                                renderSize: renderSize, total: total,
                                                holdSeconds: promoHoldSeconds)
            }

            videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
                postProcessingAsVideoLayer: videoLayer, in: parentLayer)
        }

        return try await export(composition, videoComposition: videoComposition)
    }

    // MARK: - Blurred-background fallback (Core Image)

    /// Builds the blurred-letterbox CI composition — shared by export and preview.
    private static func buildBlurred(asset: AVAsset) async throws -> AVMutableVideoComposition {
        let w = outW
        let h = outH
        let canvas = CGRect(x: 0, y: 0, width: w, height: h)
        let handler: @Sendable (AVAsynchronousCIImageFilteringRequest) -> Void = { request in
            let src = request.sourceImage
            let s = src.extent
            guard s.width > 0, s.height > 0 else { request.finish(with: src, context: nil); return }
            // Normalize origin to (0,0).
            let normalized = src.transformed(
                by: CGAffineTransform(translationX: -s.minX, y: -s.minY))

            // Background: scale to fill, centre, blur, crop to canvas.
            let bgScale = max(w / s.width, h / s.height)
            let bg = normalized
                .transformed(by: CGAffineTransform(scaleX: bgScale, y: bgScale))
                .transformed(by: CGAffineTransform(
                    translationX: (w - s.width * bgScale) / 2,
                    y: (h - s.height * bgScale) / 2))
                .clampedToExtent()
                .applyingGaussianBlur(sigma: 28)
                .cropped(to: canvas)

            // Foreground: scale to width, centre vertically.
            let fgScale = w / s.width
            let fg = normalized
                .transformed(by: CGAffineTransform(scaleX: fgScale, y: fgScale))
                .transformed(by: CGAffineTransform(
                    translationX: 0, y: (h - s.height * fgScale) / 2))

            let out = fg.composited(over: bg).cropped(to: canvas)
            request.finish(with: out, context: nil)
        }

        let videoComposition: AVMutableVideoComposition
        nonisolated(unsafe) let safeAsset = asset
        if #available(macOS 15.0, iOS 18.0, tvOS 18.0, visionOS 2.0, *) {
            videoComposition = try await AVMutableVideoComposition.videoComposition(with: safeAsset, applyingCIFiltersWithHandler: handler)
        } else {
            videoComposition = AVMutableVideoComposition(asset: safeAsset, applyingCIFiltersWithHandler: handler)
        }
        videoComposition.renderSize = canvas.size
        return videoComposition
    }

    private static func renderBlurred(asset: AVAsset) async throws -> URL {
        try await export(asset, videoComposition: try await buildBlurred(asset: asset))
    }

    // MARK: - Live preview (reframe applied via videoComposition, no export)

    /// An `AVPlayerItem` that plays the clip already reframed to 9:16 — so the
    /// in-app "Play with sound" preview matches the downloaded/published file.
    /// The burned-in text hook is export-only and is intentionally not shown
    /// here. Returns nil when the clip isn't being reframed (play the raw clip).
    @MainActor
    static func previewItem(clipURL: URL, reframe: Bool) async -> AVPlayerItem? {
        guard reframe else { return nil }
        let asset = AVURLAsset(url: clipURL)
        guard let videoTrack = try? await asset.loadTracks(withMediaType: .video).first,
              let duration = try? await asset.load(.duration),
              let naturalSize = try? await videoTrack.load(.naturalSize),
              let transform = try? await videoTrack.load(.preferredTransform)
        else { return nil }

        let oriented = naturalSize.applying(transform)
        let orientedSize = CGSize(width: abs(oriented.width), height: abs(oriented.height))

        var keyframes: [Keyframe] = []
        var trackable = false
        if let cinemaKeyframes = try? await CinemaSquareReframer.sampleAndOptimizeVideoPath(asset: asset),
           !cinemaKeyframes.isEmpty {
            let scale = outH / orientedSize.height
            let scaledW = orientedSize.width * scale
            let cropMaxX = max(0, scaledW - outW)
            keyframes = cinemaKeyframes.map { ck in
                let targetX = min(max(ck.cropX * cropMaxX, 0), cropMaxX)
                return Keyframe(time: ck.time, cropX: targetX)
            }
            trackable = true
        }

        if trackable {
            guard let (composition, vc) = try? await buildTracking(
                asset: asset, videoTrack: videoTrack, duration: duration,
                transform: transform, keyframes: keyframes) else { return nil }
            let item = AVPlayerItem(asset: composition)
            item.videoComposition = vc
            return item
        } else {
            let item = AVPlayerItem(asset: asset)
            item.videoComposition = try? await buildBlurred(asset: asset)
            return item
        }
    }

    // MARK: - Export

    private static func export(_ asset: sending AVAsset,
                               videoComposition: sending AVVideoComposition) async throws -> URL {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("shortcast-clip-vertical-\(UUID().uuidString).mp4")
        try await HighBitrateExporter.export(
            asset: asset, videoComposition: videoComposition, to: outputURL)
        return outputURL
    }
}
