import Foundation
import AVFoundation
import CoreGraphics
import CoreImage
import os.log
import Darwin

// MARK: - Presets Enum

/// Optional image and sound treatments. Archive raw values remain stable.
public enum AntiCopyrightPreset: String, CaseIterable, Identifiable, Codable, Sendable {
    case off = "off"
    case subtle = "subtle"
    case cinemaShield = "cinemaShield"
    case tikTokShield = "tikTokShield"
    case moderate = "moderate"
    case aggressive = "aggressive"
    case custom = "custom"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .off: return "Отключено"
        case .subtle: return "Мягкая (Subtle)"
        case .cinemaShield: return "Кинематографическая обработка"
        case .tikTokShield: return "Обработка вертикального видео"
        case .moderate: return "Стандартная (Moderate)"
        case .aggressive: return "Максимальная (Aggressive)"
        case .custom: return "Пользовательская (Custom)"
        }
    }

    public var config: AntiCopyrightConfig {
        switch self {
        case .off: return .off
        case .subtle: return .subtle
        case .cinemaShield: return .cinemaShield
        case .tikTokShield: return .tikTokShield
        case .moderate: return .moderate
        case .aggressive: return .aggressive
        case .custom: return .cinemaShield
        }
    }
}

// MARK: - Configuration

/// Configuration options for the Anti-Copyright transformation pipeline.
///
/// Encapsulates optional visual and auditory changes. These settings do not
/// establish permission to use material or predict platform claim decisions.
public struct AntiCopyrightConfig: Codable, Sendable, Equatable, Hashable {

    /// Whether to mirror the video horizontally (flip X axis).
    public var enableMirror: Bool

    /// Micro-zoom scale factor (e.g. 1.02 - 1.06). 1.0 means no zoom.
    public var zoomScale: Double

    /// Contrast adjustment delta (e.g. +0.03 = +3% contrast). 0.0 means unchanged.
    public var contrastDelta: Double

    /// Saturation adjustment delta (e.g. +0.03 = +3% saturation). 0.0 means unchanged.
    public var saturationDelta: Double

    /// 35mm dynamic cinematic micro-grain intensity (0.0 = off, 0.25 = subtle, 0.45 = moderate).
    /// Breaks block-level DCT hashes while giving film-like organic texture.
    public var filmGrainIntensity: Double

    /// Audio playback speed multiplier (e.g. 1.015 = +1.5% faster). 1.0 means normal speed.
    public var audioSpeedMultiplier: Double

    /// Audio pitch shift in cents (100 cents = 1 semitone). E.g. +8.0 to +22.0 cents.
    /// Alters acoustic constellation peaks to bypass audio fingerprint matching.
    public var audioPitchShiftCents: Double

    /// Subtle presence/warmth EQ curve to shift spectral energy away from studio master.
    public var enableAudioWarmthEQ: Bool

    /// Optional dynamic framing drift amplitude as a fraction of available zoom margin (0.0 ... 1.0).
    public var driftIntensity: Double

    /// Strip container and stream metadata tags to remove ripper/studio footprints.
    public var stripMetadata: Bool

    // MARK: - Initialization

    public init(
        enableMirror: Bool = true,
        zoomScale: Double = 1.035,
        contrastDelta: Double = 0.04,
        saturationDelta: Double = 0.03,
        filmGrainIntensity: Double = 0.25,
        audioSpeedMultiplier: Double = 1.015,
        audioPitchShiftCents: Double = 14.0,
        enableAudioWarmthEQ: Bool = true,
        driftIntensity: Double = 0.35,
        stripMetadata: Bool = true
    ) {
        self.enableMirror = enableMirror
        self.zoomScale = zoomScale
        self.contrastDelta = contrastDelta
        self.saturationDelta = saturationDelta
        self.filmGrainIntensity = filmGrainIntensity
        self.audioSpeedMultiplier = audioSpeedMultiplier
        self.audioPitchShiftCents = audioPitchShiftCents
        self.enableAudioWarmthEQ = enableAudioWarmthEQ
        self.driftIntensity = driftIntensity
        self.stripMetadata = stripMetadata
    }

    // MARK: - Presets

    /// Protection disabled (identity transform).
    public static let off = AntiCopyrightConfig(
        enableMirror: false,
        zoomScale: 1.0,
        contrastDelta: 0.0,
        saturationDelta: 0.0,
        filmGrainIntensity: 0.0,
        audioSpeedMultiplier: 1.0,
        audioPitchShiftCents: 0.0,
        enableAudioWarmthEQ: false,
        driftIntensity: 0.0,
        stripMetadata: false
    )

    /// Subtle protection: light visual/audio adjustments.
    public static let subtle = AntiCopyrightConfig(
        enableMirror: true,
        zoomScale: 1.025,
        contrastDelta: 0.03,
        saturationDelta: 0.02,
        filmGrainIntensity: 0.15,
        audioSpeedMultiplier: 1.0,
        audioPitchShiftCents: 8.0,
        enableAudioWarmthEQ: true,
        driftIntensity: 0.2,
        stripMetadata: true
    )

    /// YouTube Cinema Shield: Оптимизировано специально для 16:9 кино-эссе и длинных видео на YouTube.
    /// Сохраняет оригинальную геометрию (без зеркалирования, чтобы не переворачивать текст и актёров),
    /// применяет 3.5% микро-зум, 35мм кино-зерно, сдвиг питча (+12¢) и эквализацию, очищая метаданные.
    public static let cinemaShield = AntiCopyrightConfig(
        enableMirror: false,
        zoomScale: 1.035,
        contrastDelta: 0.04,
        saturationDelta: 0.03,
        filmGrainIntensity: 0.20,
        audioSpeedMultiplier: 1.0,
        audioPitchShiftCents: 12.0,
        enableAudioWarmthEQ: true,
        driftIntensity: 0.25,
        stripMetadata: true
    )

    /// TikTok / Reels Shield (RECOMMENDED): Alternative audiovisual treatment for vertical video; effectiveness against recognition is unverified.
    public static let tikTokShield = AntiCopyrightConfig(
        enableMirror: true,
        zoomScale: 1.035,
        contrastDelta: 0.04,
        saturationDelta: 0.03,
        filmGrainIntensity: 0.25,
        audioSpeedMultiplier: 1.015,
        audioPitchShiftCents: 14.0,
        enableAudioWarmthEQ: true,
        driftIntensity: 0.35,
        stripMetadata: true
    )

    /// Moderate protection: recommended standard for cinematic shorts and viral clips.
    public static let moderate = AntiCopyrightConfig(
        enableMirror: true,
        zoomScale: 1.04,
        contrastDelta: 0.05,
        saturationDelta: 0.04,
        filmGrainIntensity: 0.30,
        audioSpeedMultiplier: 1.02,
        audioPitchShiftCents: 15.0,
        enableAudioWarmthEQ: true,
        driftIntensity: 0.4,
        stripMetadata: true
    )

    /// Aggressive protection: higher modulation for strict content identification systems.
    public static let aggressive = AntiCopyrightConfig(
        enableMirror: true,
        zoomScale: 1.06,
        contrastDelta: 0.07,
        saturationDelta: 0.05,
        filmGrainIntensity: 0.45,
        audioSpeedMultiplier: 1.03,
        audioPitchShiftCents: 22.0,
        enableAudioWarmthEQ: true,
        driftIntensity: 0.6,
        stripMetadata: true
    )

    // MARK: - Computed Properties

    /// Whether any visual or auditory modification is active.
    public var isActive: Bool {
        enableMirror ||
        abs(zoomScale - 1.0) > 0.0001 ||
        abs(contrastDelta) > 0.0001 ||
        abs(saturationDelta) > 0.0001 ||
        filmGrainIntensity > 0.01 ||
        abs(audioSpeedMultiplier - 1.0) > 0.0001 ||
        abs(audioPitchShiftCents) > 0.0001 ||
        enableAudioWarmthEQ ||
        stripMetadata
    }

    /// Whether visual video stream transformations are active.
    public var hasVideoTransforms: Bool {
        enableMirror ||
        abs(zoomScale - 1.0) > 0.0001 ||
        abs(contrastDelta) > 0.0001 ||
        abs(saturationDelta) > 0.0001 ||
        filmGrainIntensity > 0.01
    }

    /// Whether audio stream transformations are active.
    public var hasAudioTransforms: Bool {
        abs(audioSpeedMultiplier - 1.0) > 0.0001 ||
        abs(audioPitchShiftCents) > 0.0001 ||
        enableAudioWarmthEQ
    }

    /// Frequency scale ratio derived from cents: `2^(cents / 1200)`.
    public var pitchScaleRatio: Double {
        pow(2.0, audioPitchShiftCents / 1200.0)
    }

    /// Returns a clamped, safe copy of this configuration.
    public func clamped() -> AntiCopyrightConfig {
        var copy = self
        copy.zoomScale = max(1.0, min(1.20, zoomScale))
        copy.contrastDelta = max(-0.30, min(0.30, contrastDelta))
        copy.saturationDelta = max(-0.30, min(0.30, saturationDelta))
        copy.filmGrainIntensity = max(0.0, min(1.0, filmGrainIntensity))
        copy.audioSpeedMultiplier = max(0.5, min(2.0, audioSpeedMultiplier))
        copy.audioPitchShiftCents = max(-200.0, min(200.0, audioPitchShiftCents))
        copy.driftIntensity = max(0.0, min(1.0, driftIntensity))
        return copy
    }
}

// MARK: - FFmpeg Audio Pitch Method

/// Strategy for modifying audio pitch and tempo in FFmpeg.
public enum FFmpegAudioPitchMethod: String, Sendable, CaseIterable {
    /// High-quality time-stretch and pitch-shift using `librubberband`.
    case rubberband
    /// Universal resampling filter chain (`asetrate` -> `aresample` -> `atempo`) without external libraries.
    case asetrate
    /// Tempo modification only via `atempo` (keeps original pitch).
    case atempoOnly
}

// MARK: - Errors

/// Errors that can occur during anti-copyright processing.
public enum AntiCopyrightError: LocalizedError, Sendable {
    case invalidRenderSize(CGSize)
    case missingVideoTrack
    case exportFailed(String)
    case ffmpegNotFound
    case processingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRenderSize(let size):
            return String(localized: "Invalid render size for anti-copyright transform: \(size.width)x\(size.height)")
        case .missingVideoTrack:
            return String(localized: "No video track found for anti-copyright transformation.")
        case .exportFailed(let reason):
            return String(localized: "Anti-copyright export failed: \(reason)")
        case .ffmpegNotFound:
            return String(localized: "FFmpeg binary not found.")
        case .processingFailed(let reason):
            return String(localized: "Anti-copyright processing failed: \(reason)")
        }
    }
}

// MARK: - Segregated Protocols (SOLID: Interface Segregation & Dependency Inversion)

/// Contract for video geometry and color adjustments.
public protocol AntiCopyrightVideoTransforming: Sendable {
    /// Calculates the 2D affine transform (mirror + centered zoom scale + base transform).
    func calculateTransform(
        renderSize: CGSize,
        baseTransform: CGAffineTransform,
        driftOffset: CGPoint
    ) -> CGAffineTransform

    /// Applies the anti-copyright transform to an AVFoundation layer instruction.
    func applyVideoTransform(
        to layerInstruction: AVMutableVideoCompositionLayerInstruction,
        renderSize: CGSize,
        at time: CMTime,
        baseTransform: CGAffineTransform,
        driftOffset: CGPoint
    )

    /// Applies an anti-copyright transform ramp across a time range (supporting drift or pan transitions).
    func applyVideoTransformRamp(
        to layerInstruction: AVMutableVideoCompositionLayerInstruction,
        renderSize: CGSize,
        timeRange: CMTimeRange,
        startBaseTransform: CGAffineTransform,
        endBaseTransform: CGAffineTransform,
        startDriftOffset: CGPoint,
        endDriftOffset: CGPoint
    )

    /// Applies color grading (contrast & saturation deltas) to a Core Image frame.
    func applyColorGrading(to image: CIImage) -> CIImage

    /// Creates a Core Image filter configured with contrast & saturation deltas.
    func makeColorControlsFilter() -> CIFilter?
}

/// Contract for audio time-pitch and volume mix adjustments.
public protocol AntiCopyrightAudioTransforming: Sendable {
    /// Computes duration scaled by the configured audio speed multiplier.
    func calculateScaledDuration(for duration: CMTime) -> CMTime

    /// Scales the time range of an AVFoundation composition track to adjust tempo.
    func applyAudioTimeStretch(
        to compositionTrack: AVMutableCompositionTrack,
        timeRange: CMTimeRange
    )

    /// Configures audio mix input parameters (e.g. audioTimePitchAlgorithm) for an audio track.
    func configureAudioMixParameters(
        for track: AVCompositionTrack,
        into audioMix: AVMutableAudioMix
    )

    /// Builds a configured `AVAudioMix` for an `AVComposition`.
    func createAudioMix(for composition: AVComposition) -> AVAudioMix
}

/// Contract for generating FFmpeg command line filters and parameters.
public protocol AntiCopyrightFFmpegGenerating: Sendable {
    /// Builds the list of FFmpeg video filter tokens (`hflip`, `scale`, `eq`).
    func buildFFmpegVideoFilters(renderSize: CGSize?) -> [String]

    /// Combines video filters into an FFmpeg `-vf` filter graph string.
    func buildFFmpegVideoFilterString(renderSize: CGSize?) -> String

    /// Builds the list of FFmpeg audio filter tokens (`rubberband`, `asetrate`, `atempo`).
    func buildFFmpegAudioFilters(method: FFmpegAudioPitchMethod, sampleRate: Int) -> [String]

    /// Combines audio filters into an FFmpeg `-af` filter graph string.
    func buildFFmpegAudioFilterString(method: FFmpegAudioPitchMethod, sampleRate: Int) -> String

    /// Generates complete FFmpeg argument array including `-vf` and `-af` flags.
    func buildFFmpegArguments(
        renderSize: CGSize?,
        audioPitchMethod: FFmpegAudioPitchMethod,
        sampleRate: Int
    ) -> [String]
}

/// Unified protocol combining video, audio, and FFmpeg anti-copyright capabilities.
public protocol AntiCopyrightTransforming: AntiCopyrightVideoTransforming,
                                          AntiCopyrightAudioTransforming,
                                          AntiCopyrightFFmpegGenerating,
                                          Sendable {
    /// Active configuration.
    var config: AntiCopyrightConfig { get }

    /// Applies the anti-copyright transformations to an AVFoundation composition and video composition.
    func apply(
        to composition: AVMutableComposition,
        videoComposition: AVMutableVideoComposition,
        audioMix: AVMutableAudioMix,
        renderSize: CGSize
    ) async throws

    /// Processes a video file end-to-end and writes transformed output.
    func process(
        videoURL: URL,
        outputURL: URL?,
        workingDirectory: URL?
    ) async throws -> URL
}

// MARK: - Protocol Extension Defaults

public extension AntiCopyrightVideoTransforming {
    func calculateTransform(
        renderSize: CGSize,
        baseTransform: CGAffineTransform = .identity
    ) -> CGAffineTransform {
        calculateTransform(renderSize: renderSize, baseTransform: baseTransform, driftOffset: .zero)
    }

    func applyVideoTransform(
        to layerInstruction: AVMutableVideoCompositionLayerInstruction,
        renderSize: CGSize,
        at time: CMTime = .zero,
        baseTransform: CGAffineTransform = .identity
    ) {
        applyVideoTransform(
            to: layerInstruction,
            renderSize: renderSize,
            at: time,
            baseTransform: baseTransform,
            driftOffset: .zero
        )
    }

    func applyVideoTransformRamp(
        to layerInstruction: AVMutableVideoCompositionLayerInstruction,
        renderSize: CGSize,
        timeRange: CMTimeRange,
        startBaseTransform: CGAffineTransform = .identity,
        endBaseTransform: CGAffineTransform = .identity
    ) {
        applyVideoTransformRamp(
            to: layerInstruction,
            renderSize: renderSize,
            timeRange: timeRange,
            startBaseTransform: startBaseTransform,
            endBaseTransform: endBaseTransform,
            startDriftOffset: .zero,
            endDriftOffset: .zero
        )
    }
}

public extension AntiCopyrightFFmpegGenerating {
    func buildFFmpegVideoFilters() -> [String] {
        buildFFmpegVideoFilters(renderSize: nil)
    }

    func buildFFmpegVideoFilterString() -> String {
        buildFFmpegVideoFilterString(renderSize: nil)
    }

    func buildFFmpegAudioFilters() -> [String] {
        buildFFmpegAudioFilters(method: .rubberband, sampleRate: 44100)
    }

    func buildFFmpegAudioFilterString() -> String {
        buildFFmpegAudioFilterString(method: .rubberband, sampleRate: 44100)
    }

    func buildFFmpegArguments() -> [String] {
        buildFFmpegArguments(renderSize: nil, audioPitchMethod: .rubberband, sampleRate: 44100)
    }
}

// MARK: - Specialized Single-Responsibility Components (SOLID: Single Responsibility)

/// Isolated component responsible for video geometry transformation math.
public struct AntiCopyrightGeometryTransformer: Sendable {
    public let config: AntiCopyrightConfig

    public init(config: AntiCopyrightConfig) {
        self.config = config.clamped()
    }

    /// Computes the combined affine transform for horizontal flip and centered zoom.
    ///
    /// Transformation pipeline order:
    /// 1. `baseTransform`: aligns source track to upright `renderSize` coordinates `[0, w] x [0, h]`.
    /// 2. `mirrorTransform`: flips horizontally along the vertical axis at `w / 2`.
    /// 3. `zoomTransform`: expands frame by `zoomScale` relative to center `(w / 2, h / 2)`,
    ///    plus optional drift offset within the safe crop margin.
    public func transform(
        renderSize: CGSize,
        baseTransform: CGAffineTransform = .identity,
        driftOffset: CGPoint = .zero
    ) -> CGAffineTransform {
        guard renderSize.width > 0, renderSize.height > 0 else {
            return baseTransform
        }

        let w = renderSize.width
        let h = renderSize.height

        // 1. Horizontal mirror
        let mirrorTransform: CGAffineTransform
        if config.enableMirror {
            // [x' = w - x, y' = y]
            mirrorTransform = CGAffineTransform(translationX: w, y: 0)
                .scaledBy(x: -1.0, y: 1.0)
        } else {
            mirrorTransform = .identity
        }

        // 2. Centered zoom scale + drift
        let zoomTransform: CGAffineTransform
        let s = config.zoomScale
        if s > 0 && abs(s - 1.0) > 0.0001 {
            // Maximum safe drift margin that does not expose black borders
            let maxMarginX = (s - 1.0) * (w / 2.0)
            let maxMarginY = (s - 1.0) * (h / 2.0)
            let clampedDriftX = max(-maxMarginX, min(maxMarginX, driftOffset.x))
            let clampedDriftY = max(-maxMarginY, min(maxMarginY, driftOffset.y))

            let tx = (1.0 - s) * (w / 2.0) + clampedDriftX
            let ty = (1.0 - s) * (h / 2.0) + clampedDriftY
            zoomTransform = CGAffineTransform(translationX: tx, y: ty)
                .scaledBy(x: s, y: s)
        } else {
            zoomTransform = .identity
        }

        return baseTransform
            .concatenating(mirrorTransform)
            .concatenating(zoomTransform)
    }

    /// Computes recommended drift endpoints (start and end offsets) for a given duration.
    public func driftEndpoints(renderSize: CGSize) -> (start: CGPoint, end: CGPoint) {
        guard config.driftIntensity > 0, config.zoomScale > 1.0 else {
            return (.zero, .zero)
        }
        let maxMarginX = (config.zoomScale - 1.0) * (renderSize.width / 2.0) * config.driftIntensity
        let start = CGPoint(x: -maxMarginX * 0.5, y: 0)
        let end = CGPoint(x: maxMarginX * 0.5, y: 0)
        return (start, end)
    }
}

/// Isolated component responsible for color adjustments.
public struct AntiCopyrightColorTransformer: Sendable {
    public let config: AntiCopyrightConfig

    public init(config: AntiCopyrightConfig) {
        self.config = config.clamped()
    }

    public func makeColorControlsFilter() -> CIFilter? {
        guard abs(config.contrastDelta) > 0.0001 || abs(config.saturationDelta) > 0.0001 else {
            return nil
        }
        let filter = CIFilter(name: "CIColorControls")
        filter?.setValue(Float(1.0 + config.contrastDelta), forKey: kCIInputContrastKey)
        filter?.setValue(Float(1.0 + config.saturationDelta), forKey: kCIInputSaturationKey)
        return filter
    }

    public func apply(to image: CIImage) -> CIImage {
        guard let filter = makeColorControlsFilter() else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        return filter.outputImage ?? image
    }
}

/// Isolated component responsible for audio mix and time manipulation.
public struct AntiCopyrightAudioMixer: Sendable {
    public let config: AntiCopyrightConfig

    public init(config: AntiCopyrightConfig) {
        self.config = config.clamped()
    }

    public func calculateScaledDuration(for duration: CMTime) -> CMTime {
        guard config.audioSpeedMultiplier > 0, abs(config.audioSpeedMultiplier - 1.0) > 0.0001 else {
            return duration
        }
        let scaledSeconds = duration.seconds / config.audioSpeedMultiplier
        return CMTime(seconds: scaledSeconds, preferredTimescale: duration.timescale > 0 ? duration.timescale : 600)
    }

    public func applyAudioTimeStretch(
        to compositionTrack: AVMutableCompositionTrack,
        timeRange: CMTimeRange
    ) {
        guard config.audioSpeedMultiplier > 0, abs(config.audioSpeedMultiplier - 1.0) > 0.0001 else {
            return
        }
        let targetDuration = calculateScaledDuration(for: timeRange.duration)
        compositionTrack.scaleTimeRange(timeRange, toDuration: targetDuration)
    }

    public func configureAudioMixParameters(
        for track: AVCompositionTrack,
        into audioMix: AVMutableAudioMix
    ) {
        let params = AVMutableAudioMixInputParameters(track: track)
        if abs(config.audioPitchShiftCents) > 0.0001 {
            params.audioTimePitchAlgorithm = .varispeed
        } else {
            params.audioTimePitchAlgorithm = .spectral
        }

        var list = audioMix.inputParameters
        if let idx = list.firstIndex(where: { $0.trackID == track.trackID }) {
            if let mutable = list[idx] as? AVMutableAudioMixInputParameters {
                mutable.audioTimePitchAlgorithm = params.audioTimePitchAlgorithm
            }
        } else {
            list.append(params)
            audioMix.inputParameters = list
        }
    }

    public func createAudioMix(for composition: AVComposition) -> AVAudioMix {
        let audioMix = AVMutableAudioMix()
        var paramsList: [AVMutableAudioMixInputParameters] = []
        for track in composition.tracks(withMediaType: .audio) {
            let params = AVMutableAudioMixInputParameters(track: track)
            if abs(config.audioPitchShiftCents) > 0.0001 {
                params.audioTimePitchAlgorithm = .varispeed
            } else {
                params.audioTimePitchAlgorithm = .spectral
            }
            paramsList.append(params)
        }
        audioMix.inputParameters = paramsList
        return audioMix
    }
}

/// Isolated component responsible for FFmpeg argument and filter string construction.
public struct AntiCopyrightFFmpegBuilder: Sendable {
    public let config: AntiCopyrightConfig

    public init(config: AntiCopyrightConfig) {
        self.config = config.clamped()
    }

    public func buildVideoFilters(renderSize: CGSize? = nil) -> [String] {
        var filters: [String] = []

        // 1. Horizontal mirror
        if config.enableMirror {
            filters.append("hflip")
        }

        // 2. Zoom / Scale & Crop
        if config.zoomScale > 1.0 {
            let z = fmt(config.zoomScale)
            if let size = renderSize, size.width > 0, size.height > 0 {
                let outW = Int(size.width.rounded())
                let outH = Int(size.height.rounded())
                let drift = config.driftIntensity > 0 ? ":x='(iw-ow)/2*(1+\(fmt(config.driftIntensity))*sin(t*0.2))':y='(ih-oh)/2'" : ""
                filters.append("crop=trunc(iw/\(z)/2)*2:trunc(ih/\(z)/2)*2" + drift + ",scale=\(outW):\(outH)")
            } else {
                filters.append("scale=ceil(iw*\(z)/2)*2:ceil(ih*\(z)/2)*2,crop=trunc(iw/\(z)/2)*2:trunc(ih/\(z)/2)*2")
            }
        }

        // 3. Contrast & Saturation micro-modulation
        if abs(config.contrastDelta) > 0.0001 || abs(config.saturationDelta) > 0.0001 {
            let c = fmt(1.0 + config.contrastDelta)
            let s = fmt(1.0 + config.saturationDelta)
            filters.append("eq=contrast=\(c):saturation=\(s)")
        }

        // 4. Temporal film grain. No recognition-avoidance guarantee is implied.
        if config.filmGrainIntensity > 0.01 {
            let strength = max(1, min(6, Int(round(config.filmGrainIntensity * 10.0))))
            filters.append("noise=c0s=\(strength):c0f=t+u")
        }

        // 5. Video tempo synchronization with audio tempo
        if abs(config.audioSpeedMultiplier - 1.0) > 0.0001 {
            let ptsFactor = fmt(1.0 / config.audioSpeedMultiplier)
            filters.append("setpts=\(ptsFactor)*PTS")
        }

        return filters
    }

    public func buildAudioFilters(
        method: FFmpegAudioPitchMethod = .rubberband,
        sampleRate: Int = 44100
    ) -> [String] {
        var filters: [String] = []
        let hasSpeed = abs(config.audioSpeedMultiplier - 1.0) > 0.0001
        let hasPitch = abs(config.audioPitchShiftCents) > 0.0001
        let hasEQ = config.enableAudioWarmthEQ

        guard hasSpeed || hasPitch || hasEQ else {
            return filters
        }

        switch method {
        case .rubberband:
            let tempo = fmt(config.audioSpeedMultiplier)
            let pitch = fmt(config.pitchScaleRatio)
            filters.append("rubberband=tempo=\(tempo):pitch=\(pitch)")

        case .asetrate:
            if hasPitch {
                let pitchRatio = config.pitchScaleRatio
                let baseRate = max(8000, sampleRate)
                let shiftedRate = max(8000, Int(round(Double(baseRate) * pitchRatio)))
                let speedCompensation = config.audioSpeedMultiplier / pitchRatio
                filters.append("asetrate=\(shiftedRate)")
                filters.append("aresample=\(baseRate)")
                if abs(speedCompensation - 1.0) > 0.0001 {
                    let tempo = fmt(speedCompensation)
                    filters.append("atempo=\(tempo)")
                }
            } else if hasSpeed {
                let tempo = fmt(config.audioSpeedMultiplier)
                filters.append("atempo=\(tempo)")
            }

        case .atempoOnly:
            if hasSpeed {
                let tempo = fmt(config.audioSpeedMultiplier)
                filters.append("atempo=\(tempo)")
            }
        }

        // 6. Spectral EQ warmth & presence shift
        if config.enableAudioWarmthEQ {
            filters.append("equalizer=f=1200:t=q:w=1.5:g=1.2,equalizer=f=350:t=q:w=1.2:g=-0.8")
        }

        return filters
    }

    private func fmt(_ value: Double, places: Int = 4) -> String {
        String(format: "%.\(places)f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}

// MARK: - Main Service Implementation (AntiCopyrightService)

/// Primary service implementing `AntiCopyrightTransforming`.
///
/// Follows SOLID principles:
/// - Single Responsibility: orchestrates video, audio, and FFmpeg anti-copyright modules.
/// - Open/Closed: extensible via `AntiCopyrightConfig` and protocol conformance.
/// - Liskov Substitution: full conformance to `AntiCopyrightTransforming`.
/// - Interface Segregation: protocol split into focused video, audio, and FFmpeg aspects.
/// - Dependency Inversion: consumers rely on `AntiCopyrightTransforming`.
public struct AntiCopyrightService: AntiCopyrightTransforming, Sendable {

    private static let logger = Logger(subsystem: "app.shortcast", category: "AntiCopyrightService")

    public static func log(_ message: String) {
        logger.notice("🛡️ [AntiCopyright] \(message, privacy: .public)")
    }

    public let config: AntiCopyrightConfig
    private let pictureRegion: CGRect?
    private let activeDuration: Double?

    private let geometryTransformer: AntiCopyrightGeometryTransformer
    private let colorTransformer: AntiCopyrightColorTransformer
    private let audioMixer: AntiCopyrightAudioMixer
    private let ffmpegBuilder: AntiCopyrightFFmpegBuilder

    // MARK: - Initializers

    public init(config: AntiCopyrightConfig = .tikTokShield, pictureRegion: CGRect? = nil,
                activeDuration: Double? = nil, preserveTimeline: Bool = false) {
        var clampedConfig = config.clamped()
        if preserveTimeline { clampedConfig.audioSpeedMultiplier = 1 }
        self.pictureRegion = pictureRegion
        self.activeDuration = activeDuration
        self.config = clampedConfig
        self.geometryTransformer = AntiCopyrightGeometryTransformer(config: clampedConfig)
        self.colorTransformer = AntiCopyrightColorTransformer(config: clampedConfig)
        self.audioMixer = AntiCopyrightAudioMixer(config: clampedConfig)
        self.ffmpegBuilder = AntiCopyrightFFmpegBuilder(config: clampedConfig)
    }

    // MARK: - Standard Instances

    public static let subtle = AntiCopyrightService(config: .subtle)
    public static let cinemaShield = AntiCopyrightService(config: .cinemaShield)
    public static let tikTokShield = AntiCopyrightService(config: .tikTokShield)
    public static let moderate = AntiCopyrightService(config: .moderate)
    public static let aggressive = AntiCopyrightService(config: .aggressive)
    public static let off = AntiCopyrightService(config: .off)

    // MARK: - AntiCopyrightVideoTransforming Conformance

    public func calculateTransform(
        renderSize: CGSize,
        baseTransform: CGAffineTransform = .identity,
        driftOffset: CGPoint = .zero
    ) -> CGAffineTransform {
        geometryTransformer.transform(
            renderSize: renderSize,
            baseTransform: baseTransform,
            driftOffset: driftOffset
        )
    }

    public func applyVideoTransform(
        to layerInstruction: AVMutableVideoCompositionLayerInstruction,
        renderSize: CGSize,
        at time: CMTime = .zero,
        baseTransform: CGAffineTransform = .identity,
        driftOffset: CGPoint = .zero
    ) {
        let t = calculateTransform(
            renderSize: renderSize,
            baseTransform: baseTransform,
            driftOffset: driftOffset
        )
        layerInstruction.setTransform(t, at: time)
    }

    public func applyVideoTransformRamp(
        to layerInstruction: AVMutableVideoCompositionLayerInstruction,
        renderSize: CGSize,
        timeRange: CMTimeRange,
        startBaseTransform: CGAffineTransform = .identity,
        endBaseTransform: CGAffineTransform = .identity,
        startDriftOffset: CGPoint = .zero,
        endDriftOffset: CGPoint = .zero
    ) {
        let startT = calculateTransform(
            renderSize: renderSize,
            baseTransform: startBaseTransform,
            driftOffset: startDriftOffset
        )
        let endT = calculateTransform(
            renderSize: renderSize,
            baseTransform: endBaseTransform,
            driftOffset: endDriftOffset
        )
        layerInstruction.setTransformRamp(fromStart: startT, toEnd: endT, timeRange: timeRange)
    }

    public func applyColorGrading(to image: CIImage) -> CIImage {
        colorTransformer.apply(to: image)
    }

    public func makeColorControlsFilter() -> CIFilter? {
        colorTransformer.makeColorControlsFilter()
    }

    // MARK: - AntiCopyrightAudioTransforming Conformance

    public func calculateScaledDuration(for duration: CMTime) -> CMTime {
        audioMixer.calculateScaledDuration(for: duration)
    }

    public func applyAudioTimeStretch(
        to compositionTrack: AVMutableCompositionTrack,
        timeRange: CMTimeRange
    ) {
        audioMixer.applyAudioTimeStretch(to: compositionTrack, timeRange: timeRange)
    }

    public func configureAudioMixParameters(
        for track: AVCompositionTrack,
        into audioMix: AVMutableAudioMix
    ) {
        audioMixer.configureAudioMixParameters(for: track, into: audioMix)
    }

    public func createAudioMix(for composition: AVComposition) -> AVAudioMix {
        audioMixer.createAudioMix(for: composition)
    }

    // MARK: - AntiCopyrightFFmpegGenerating Conformance

    public func buildFFmpegVideoFilters(renderSize: CGSize? = nil) -> [String] {
        ffmpegBuilder.buildVideoFilters(renderSize: renderSize)
    }

    public func buildFFmpegVideoFilterString(renderSize: CGSize? = nil) -> String {
        buildFFmpegVideoFilters(renderSize: renderSize).joined(separator: ",")
    }

    public func buildFFmpegAudioFilters(
        method: FFmpegAudioPitchMethod = .rubberband,
        sampleRate: Int = 44100
    ) -> [String] {
        ffmpegBuilder.buildAudioFilters(method: method, sampleRate: sampleRate)
    }

    public func buildFFmpegAudioFilterString(
        method: FFmpegAudioPitchMethod = .rubberband,
        sampleRate: Int = 44100
    ) -> String {
        buildFFmpegAudioFilters(method: method, sampleRate: sampleRate).joined(separator: ",")
    }

    public func buildFFmpegArguments(
        renderSize: CGSize? = nil,
        audioPitchMethod: FFmpegAudioPitchMethod = .rubberband,
        sampleRate: Int = 44100
    ) -> [String] {
        var args: [String] = []
        let vf = buildFFmpegVideoFilterString(renderSize: renderSize)
        if !vf.isEmpty {
            args.append(contentsOf: ["-vf", vf])
        }
        let af = buildFFmpegAudioFilterString(method: audioPitchMethod, sampleRate: sampleRate)
        if !af.isEmpty {
            args.append(contentsOf: ["-af", af])
        }
        return args
    }

    // MARK: - Full AVFoundation Pipeline Integration

    public func apply(
        to composition: AVMutableComposition,
        videoComposition: AVMutableVideoComposition,
        audioMix: AVMutableAudioMix,
        renderSize: CGSize
    ) async throws {
        guard config.isActive else { return }

        Self.log("Applying native AVFoundation anti-copyright pipeline...")

        // 1. Audio and Video synchronous time stretch (if speed multiplier is modified)
        if abs(config.audioSpeedMultiplier - 1.0) > 0.0001 {
            let duration = composition.duration
            let fullRange = CMTimeRange(start: .zero, duration: duration)
            for track in composition.tracks(withMediaType: .audio) {
                applyAudioTimeStretch(to: track, timeRange: fullRange)
            }
            let scaledDuration = calculateScaledDuration(for: duration)
            for track in composition.tracks(withMediaType: .video) {
                track.scaleTimeRange(fullRange, toDuration: scaledDuration)
            }
        }

        // 2. Audio mix parameters (pitch algorithm / varispeed)
        for track in composition.tracks(withMediaType: .audio) {
            configureAudioMixParameters(for: track, into: audioMix)
        }

        // 3. Video transform layer instruction
        if config.hasVideoTransforms {
            let drift = geometryTransformer.driftEndpoints(renderSize: renderSize)
            for instruction in videoComposition.instructions {
                guard let videoInstruction = instruction as? AVMutableVideoCompositionInstruction else {
                    continue
                }
                for layerInstruction in videoInstruction.layerInstructions {
                    guard let mutableLayer = layerInstruction as? AVMutableVideoCompositionLayerInstruction else {
                        continue
                    }
                    if config.driftIntensity > 0 {
                        applyVideoTransformRamp(
                            to: mutableLayer,
                            renderSize: renderSize,
                            timeRange: videoInstruction.timeRange,
                            startDriftOffset: drift.start,
                            endDriftOffset: drift.end
                        )
                    } else {
                        applyVideoTransform(
                            to: mutableLayer,
                            renderSize: renderSize,
                            at: videoInstruction.timeRange.start
                        )
                    }
                }
            }
        }
    }

    // MARK: - End-to-End Processing

    public func process(
        videoURL: URL,
        outputURL: URL? = nil,
        workingDirectory: URL? = nil
    ) async throws -> URL {
        guard config.isActive else {
            return videoURL
        }

        let destination = outputURL ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("shortcast-anticopyright-\(UUID().uuidString).mp4")
        // Always encode beside the destination. Never delete a usable export,
        // especially when the caller requests in-place processing.
        let staged = destination.deletingLastPathComponent()
            .appendingPathComponent(".shield-" + UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: staged) }
        guard let ffmpegBin = BinaryDownloadService.resolveBinary("ffmpeg", workingDirectory: workingDirectory) else {
            throw AntiCopyrightError.processingFailed("FFmpeg недоступен. Shield не применён; исходный файл сохранён.")
        }
        try Task.checkCancellation()
        try await processWithFFmpeg(videoURL: videoURL, outputURL: staged, ffmpegBinary: ffmpegBin)
        try await validateProcessedVideo(source: videoURL, output: staged)
        try Task.checkCancellation()
        let status = staged.path.withCString { from in
            destination.path.withCString { to in Darwin.rename(from, to) }
        }
        guard status == 0 else {
            throw AntiCopyrightError.processingFailed("Не удалось атомарно сохранить результат Shield: " + String(cString: strerror(errno)))
        }
        Self.log("Shield completed and validated: " + destination.lastPathComponent)
        return destination
    }

    private func validateProcessedVideo(source: URL, output: URL) async throws {
        let original = AVURLAsset(url: source), rendered = AVURLAsset(url: output)
        let expected = try await original.load(.duration).seconds / config.audioSpeedMultiplier
        let actual = try await rendered.load(.duration).seconds
        guard expected.isFinite, actual.isFinite, actual > 0, abs(expected - actual) < 0.2,
              let originalTrack = try await original.loadTracks(withMediaType: .video).first,
              let outputTrack = try await rendered.loadTracks(withMediaType: .video).first else {
            throw AntiCopyrightError.processingFailed("Shield: не совпал хронометраж или отсутствует видеодорожка.")
        }
        let originalSize = try await originalTrack.load(.naturalSize)
        let outputSize = try await outputTrack.load(.naturalSize)
        guard originalSize == outputSize else {
            throw AntiCopyrightError.processingFailed("Shield изменил разрешение видео.")
        }
        let hadAudio = try await !original.loadTracks(withMediaType: .audio).isEmpty
        let hasAudio = try await !rendered.loadTracks(withMediaType: .audio).isEmpty
        if hadAudio && !hasAudio {
            throw AntiCopyrightError.processingFailed("Shield потерял звуковую дорожку.")
        }
        let frames = AVAssetImageGenerator(asset: rendered)
        frames.maximumSize = CGSize(width: 320, height: 320)
        for seconds in [min(0.5, actual / 2), max(0, actual - 0.5)] {
            _ = try await frames.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
        }
    }

    // MARK: - Private Processing Helpers

    private func processWithFFmpeg(
        videoURL: URL,
        outputURL: URL,
        ffmpegBinary: URL
    ) async throws {
        Self.log("Executing FFmpeg anti-copyright pass...")

        let asset = AVURLAsset(url: videoURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let renderSize: CGSize?
        if let firstVideo = videoTracks.first {
            let naturalSize = try await firstVideo.load(.naturalSize)
            let prefTransform = try await firstVideo.load(.preferredTransform)
            let oriented = naturalSize.applying(prefTransform)
            renderSize = CGSize(width: abs(oriented.width), height: abs(oriented.height))
        } else {
            renderSize = nil
        }

        var failures: [String] = []
        // Hardware encoding is preferred, but an unavailable VideoToolbox
        // session must not degrade the requested filters to a partial native pass.
        let attempts: [(FFmpegAudioPitchMethod, String)] = [(.rubberband, "h264_videotoolbox"),
            (.asetrate, "h264_videotoolbox"), (.asetrate, "libx264")]
        for (pitch, encoder) in attempts {
            try Task.checkCancellation()
            var arguments = ["-hide_banner", "-nostdin", "-y", "-i", videoURL.path]
            if let region = pictureRegion {
                guard let size = renderSize, region.width > 0, region.height > 0,
                      region.minX >= 0, region.minY >= 0, region.maxX <= size.width, region.maxY <= size.height else {
                    throw AntiCopyrightError.processingFailed("Shield: область кадра выходит за границы видео.")
                }
                let crop = "crop=\(Int(region.width)):\(Int(region.height)):\(Int(region.minX)):\(Int(region.minY))"
                let filters = buildFFmpegVideoFilterString(renderSize: region.size)
                let chain = filters.isEmpty ? crop : crop + "," + filters
                let enable = activeDuration.map { ":enable='lt(t,\($0))'" } ?? ""
                arguments += ["-filter_complex", "[0:v]split=2[base][movie];[movie]" + chain
                    + "[treated];[base][treated]overlay=\(Int(region.minX)):\(Int(region.minY))" + enable + "[v]", "-map", "[v]", "-map", "0:a:0?"]
                let af = buildFFmpegAudioFilterString(method: pitch, sampleRate: 48000)
                if !af.isEmpty { arguments += ["-af", af] }
            } else {
                arguments += ["-map", "0:v:0", "-map", "0:a:0?"]
                arguments += buildFFmpegArguments(renderSize: renderSize, audioPitchMethod: pitch, sampleRate: 48000)
            }
            arguments += ["-c:v", encoder]
            if encoder == "libx264" { arguments += ["-preset", "veryfast", "-crf", "18"] }
            else { arguments += ["-b:v", "14M", "-maxrate", "20M", "-bufsize", "28M"] }
            arguments += ["-pix_fmt", "yuv420p", "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709",
                "-c:a", "aac", "-b:a", "256k", "-ar", "48000", "-profile:a", "aac_low", "-aac_tns", "0"]
            if config.stripMetadata { arguments += ["-map_metadata", "-1"] }
            arguments += ["-movflags", "+faststart", outputURL.path]
            do {
                _ = try await ProcessRunner.shared.run(executableURL: ffmpegBinary, arguments: arguments)
                return
            } catch {
                try Task.checkCancellation()
                failures.append(encoder + ": " + String(error.localizedDescription.suffix(1800)))
                Self.log("Shield encoding attempt failed: " + encoder)
            }
        }
        throw AntiCopyrightError.processingFailed(failures.joined(separator: " | "))
    }

    private func processWithAVFoundation(
        videoURL: URL,
        outputURL: URL
    ) async throws {
        Self.log("Executing AVFoundation anti-copyright pass...")

        let asset = AVURLAsset(url: videoURL)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw AntiCopyrightError.missingVideoTrack
        }

        let naturalSize = try await videoTrack.load(.naturalSize)
        let prefTransform = try await videoTrack.load(.preferredTransform)
        let oriented = naturalSize.applying(prefTransform)
        let renderSize = CGSize(width: abs(oriented.width), height: abs(oriented.height))
        let duration = try await asset.load(.duration)
        let fullRange = CMTimeRange(start: .zero, duration: duration)

        let composition = AVMutableComposition()
        guard let compVideo = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw AntiCopyrightError.exportFailed("Could not create video composition track.")
        }
        try compVideo.insertTimeRange(fullRange, of: videoTrack, at: .zero)

        if let audioTrack = try await asset.loadTracks(withMediaType: .audio).first,
           let compAudio = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            try compAudio.insertTimeRange(fullRange, of: audioTrack, at: .zero)
            if abs(config.audioSpeedMultiplier - 1.0) > 0.0001 {
                applyAudioTimeStretch(to: compAudio, timeRange: fullRange)
                let scaledDuration = calculateScaledDuration(for: duration)
                compVideo.scaleTimeRange(fullRange, toDuration: scaledDuration)
            }
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        let nominalFPS = try await videoTrack.load(.nominalFrameRate)
        let fps = nominalFPS > 0 ? Int32(nominalFPS.rounded()) : 30
        videoComposition.frameDuration = CMTime(value: 1, timescale: fps)

        let finalDuration = abs(config.audioSpeedMultiplier - 1.0) > 0.0001
            ? calculateScaledDuration(for: duration)
            : duration
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: finalDuration)

        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compVideo)
        applyVideoTransform(
            to: layerInstruction,
            renderSize: renderSize,
            at: .zero,
            baseTransform: prefTransform
        )
        instruction.layerInstructions = [layerInstruction]
        videoComposition.instructions = [instruction]

        let audioMix = createAudioMix(for: composition)

        guard let exportSession = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHEVCHighestQuality
        ) ?? AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw AntiCopyrightError.exportFailed("Export session unavailable.")
        }

        exportSession.videoComposition = videoComposition
        exportSession.audioMix = audioMix

        do {
            try await exportSession.export(to: outputURL, as: .mp4)
        } catch {
            throw AntiCopyrightError.exportFailed(error.localizedDescription)
        }
    }
}
