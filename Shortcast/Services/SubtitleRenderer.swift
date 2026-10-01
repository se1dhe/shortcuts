import AppKit
import AVFoundation
import CoreGraphics
import CoreMedia
import SwiftUI

/// Full appearance config for burned-in subtitles. Per-property so the user
/// can tweak colour, border, size, position, and animation.
struct SubtitleAppearance: Codable, Equatable, Sendable {
    enum FontChoice: String, Codable, CaseIterable, Identifiable, Sendable {
        case russoOne, oswald, bebasNeue, impact, montserrat, tiktokSans, helvetica, captureIt, dinCondensed, arialBlack

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .russoOne: "Russo One (Premium Cyrillic)"
            case .oswald: "Oswald Bold (Cinematic Condensed)"
            case .montserrat: "Montserrat"
            case .tiktokSans: "TikTok Sans"
            case .bebasNeue: "Bebas Neue"
            case .impact: "Impact"
            case .helvetica: "Helvetica"
            case .captureIt: "Capture It"
            case .dinCondensed: "DIN Condensed"
            case .arialBlack: "Arial Black"
            }
        }

        var preferredPostScriptNames: [String] {
            switch self {
            case .russoOne:
                ["RussoOne-Regular", "Russo One"]
            case .oswald:
                ["Oswald-Bold", "Oswald-Regular", "Oswald"]
            case .montserrat:
                ["Montserrat-Black", "Montserrat-ExtraBold", "Montserrat-Bold"]
            case .tiktokSans:
                ["TikTokSans-Bold", "TikTokSansDisplay-Bold"]
            case .bebasNeue:
                ["BebasNeue-Regular", "DINCondensed-Bold", "Impact"]
            case .impact:
                ["Impact", "Arial-Black"]
            case .helvetica:
                ["HelveticaNeue-Bold", "Helvetica-Bold", "Arial-BoldMT"]
            case .captureIt:
                ["CaptureIt"]
            case .dinCondensed:
                ["DINCondensed-Bold", "DINCondensed", "DINAlternate-Bold"]
            case .arialBlack:
                ["Arial-Black", "ArialBlack"]
            }
        }
    }

    var textColorHex:     String = "#FFFFFF"
    var textBorderColorHex: String = "#000000"
    var textBorderWidth:  Double = 2.5
    var accentColorHex:   String = "#FFE45C"
    var punchlineColorHex: String = "#E50914"
    var bgColorHex:       String = "#000000"
    var bgOpacity:        Double = 0.55
    var fontSizeScale:    Double = 0.055   // fontSize = width * scale
    var fontWeightRaw:    String = "bold"   // regular / semibold / bold / heavy
    var fontChoiceRaw:    String = FontChoice.russoOne.rawValue
    var verticalPosition: Double = 0.78     // 0.0 = top, 0.5 = middle, 1.0 = bottom
    var safeTextZoneNorm: CGRect? = nil     // If set, overrides manual placement
    var horizontalAlign:  String = "center" // left / center / right
    var animationRaw:     String = "fade"   // none / fade / slide
    var highlightModeRaw: String = "keyword" // none / keyword / firstWord
    var maxWordsPerCaption: Int = 7
    var maxWidthScale:    Double = 0.92     // subtitle width = width * scale
    var cornerRadiusScale: Double = 0.02    // radius = width * scale
    var paddingScale:     Double = 0.015    // padding = width * scale
    var moodProfile: CinematicMoodProfile? = nil

    enum CodingKeys: String, CodingKey {
        case textColorHex, textBorderColorHex, textBorderWidth, accentColorHex
        case punchlineColorHex, bgColorHex, bgOpacity, fontSizeScale, fontWeightRaw, fontChoiceRaw
        case verticalPosition, safeTextZoneNorm, horizontalAlign, animationRaw, highlightModeRaw
        case maxWordsPerCaption, maxWidthScale, cornerRadiusScale, paddingScale, moodProfile
    }

    init(
        textColorHex: String = "#FFFFFF",
        textBorderColorHex: String = "#000000",
        textBorderWidth: Double = 2.5,
        accentColorHex: String = "#FFE45C",
        punchlineColorHex: String = "#E50914",
        bgColorHex: String = "#000000",
        bgOpacity: Double = 0.0,
        fontSizeScale: Double = 0.074,
        fontWeightRaw: String = "bold",
        fontChoiceRaw: String = FontChoice.russoOne.rawValue,
        verticalPosition: Double = 0.72,
        horizontalAlign: String = "center",
        animationRaw: String = "pop",
        highlightModeRaw: String = "keyword",
        maxWordsPerCaption: Int = 7,
        maxWidthScale: Double = 0.92,
        cornerRadiusScale: Double = 0.0,
        paddingScale: Double = 0.006,
        moodProfile: CinematicMoodProfile? = nil
    ) {
        self.textColorHex = textColorHex
        self.textBorderColorHex = textBorderColorHex
        self.textBorderWidth = textBorderWidth
        self.accentColorHex = accentColorHex
        self.punchlineColorHex = punchlineColorHex
        self.bgColorHex = bgColorHex
        self.bgOpacity = bgOpacity
        self.fontSizeScale = fontSizeScale
        self.fontWeightRaw = fontWeightRaw
        self.fontChoiceRaw = fontChoiceRaw
        self.verticalPosition = verticalPosition
        self.horizontalAlign = horizontalAlign
        self.animationRaw = animationRaw
        self.highlightModeRaw = highlightModeRaw
        self.maxWordsPerCaption = maxWordsPerCaption
        self.maxWidthScale = maxWidthScale
        self.cornerRadiusScale = cornerRadiusScale
        self.paddingScale = paddingScale
        self.moodProfile = moodProfile
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.textColorHex = try c.decodeIfPresent(String.self, forKey: .textColorHex) ?? "#FFFFFF"
        self.textBorderColorHex = try c.decodeIfPresent(String.self, forKey: .textBorderColorHex) ?? "#000000"
        self.textBorderWidth = try c.decodeIfPresent(Double.self, forKey: .textBorderWidth) ?? 2.5
        self.accentColorHex = try c.decodeIfPresent(String.self, forKey: .accentColorHex) ?? "#FFE45C"
        self.punchlineColorHex = try c.decodeIfPresent(String.self, forKey: .punchlineColorHex) ?? "#E50914"
        self.bgColorHex = try c.decodeIfPresent(String.self, forKey: .bgColorHex) ?? "#000000"
        self.bgOpacity = try c.decodeIfPresent(Double.self, forKey: .bgOpacity) ?? 0.0
        self.fontSizeScale = try c.decodeIfPresent(Double.self, forKey: .fontSizeScale) ?? 0.074
        self.fontWeightRaw = try c.decodeIfPresent(String.self, forKey: .fontWeightRaw) ?? "bold"
        self.fontChoiceRaw = try c.decodeIfPresent(String.self, forKey: .fontChoiceRaw) ?? FontChoice.russoOne.rawValue
        self.verticalPosition = try c.decodeIfPresent(Double.self, forKey: .verticalPosition) ?? 0.72
        self.horizontalAlign = try c.decodeIfPresent(String.self, forKey: .horizontalAlign) ?? "center"
        self.animationRaw = try c.decodeIfPresent(String.self, forKey: .animationRaw) ?? "pop"
        self.highlightModeRaw = try c.decodeIfPresent(String.self, forKey: .highlightModeRaw) ?? "keyword"
        self.maxWordsPerCaption = try c.decodeIfPresent(Int.self, forKey: .maxWordsPerCaption) ?? 7
        self.maxWidthScale = try c.decodeIfPresent(Double.self, forKey: .maxWidthScale) ?? 0.92
        self.cornerRadiusScale = try c.decodeIfPresent(Double.self, forKey: .cornerRadiusScale) ?? 0.0
        self.paddingScale = try c.decodeIfPresent(Double.self, forKey: .paddingScale) ?? 0.006
        self.moodProfile = try c.decodeIfPresent(CinematicMoodProfile.self, forKey: .moodProfile)
    }

    // MARK: Presets

    static let tiktok = SubtitleAppearance(
        textColorHex: "#FFFFFF", textBorderColorHex: "#000000", textBorderWidth: 3.0,
        accentColorHex: "#FFE45C", bgColorHex: "#000000", bgOpacity: 0.0,
        fontSizeScale: 0.074, fontWeightRaw: "bold", fontChoiceRaw: FontChoice.montserrat.rawValue,
        verticalPosition: 0.72, horizontalAlign: "center",
        animationRaw: "pop", highlightModeRaw: "keyword", maxWordsPerCaption: 7,
        maxWidthScale: 0.92, cornerRadiusScale: 0.0, paddingScale: 0.006)

    static let creator = SubtitleAppearance(
        textColorHex: "#FFFFFF", textBorderColorHex: "#000000", textBorderWidth: 0.0,
        accentColorHex: "#FF4D6D", bgColorHex: "#000000", bgOpacity: 0.0,
        fontSizeScale: 0.082, fontWeightRaw: "heavy", fontChoiceRaw: FontChoice.bebasNeue.rawValue,
        verticalPosition: 0.70, horizontalAlign: "center",
        animationRaw: "pop", highlightModeRaw: "firstWord", maxWordsPerCaption: 5,
        maxWidthScale: 0.90, cornerRadiusScale: 0.0, paddingScale: 0.006)

    static let minimal = SubtitleAppearance(
        textColorHex: "#FFFFFF", textBorderColorHex: "#000000", textBorderWidth: 2.0,
        accentColorHex: "#FFFFFF", bgColorHex: "#000000", bgOpacity: 0.0,
        fontSizeScale: 0.055, fontWeightRaw: "bold", fontChoiceRaw: FontChoice.helvetica.rawValue,
        verticalPosition: 0.78, horizontalAlign: "center",
        animationRaw: "clean", highlightModeRaw: "none", maxWordsPerCaption: 9,
        maxWidthScale: 0.90, cornerRadiusScale: 0.0, paddingScale: 0.006)

    /// Modern karaoke look: word-by-word highlight, bright accent.
    static let karaoke = SubtitleAppearance(
        textColorHex: "#FFFFFF", textBorderColorHex: "#000000", textBorderWidth: 3.0,
        accentColorHex: "#FFE45C", bgColorHex: "#000000", bgOpacity: 0.0,
        fontSizeScale: 0.078, fontWeightRaw: "heavy", fontChoiceRaw: FontChoice.montserrat.rawValue,
        verticalPosition: 0.72, horizontalAlign: "center",
        animationRaw: "karaoke", highlightModeRaw: "keyword", maxWordsPerCaption: 5,
        maxWidthScale: 0.92, cornerRadiusScale: 0.0, paddingScale: 0.006)

    /// Neon glow look: colored halo around the text.
    static let neon = SubtitleAppearance(
        textColorHex: "#FFFFFF", textBorderColorHex: "#0A0A0A", textBorderWidth: 1.5,
        accentColorHex: "#48B7FF", bgColorHex: "#000000", bgOpacity: 0.0,
        fontSizeScale: 0.076, fontWeightRaw: "heavy", fontChoiceRaw: FontChoice.montserrat.rawValue,
        verticalPosition: 0.72, horizontalAlign: "center",
        animationRaw: "neon", highlightModeRaw: "keyword", maxWordsPerCaption: 6,
        maxWidthScale: 0.92, cornerRadiusScale: 0.0, paddingScale: 0.006)

    /// Cinema Grunge look from benchmark 1999/2008/2009/2013 edits:
    /// Ultra-fast 1-2 word kinetic snaps, thin crisp border (1.6px), rich cinema shadow,
    /// off-white (#F5F5F7) + golden-yellow (#F5D020) + blood-red punchline (#E50914),
    /// Ultra-premium viral cinematic look:
    /// High-impact typography (Avenir Next Heavy / Montserrat-Black), crisp double-pass border (3.5px),
    /// deep ambient contrast shadow, electric golden-yellow highlights (#FFDF00),
    /// vivid crimson punchline (#FF2A55), multi-line adaptive wrapping without accordion shrinking,
    /// safe margin (760px) avoiding social action buttons, and temporal face avoidance.
    static let cinemaPremium = SubtitleAppearance(
        textColorHex: "#FFFFFF", textBorderColorHex: "#000000", textBorderWidth: 4.2,
        accentColorHex: "#FFE45C", punchlineColorHex: "#FFE45C", bgColorHex: "#000000", bgOpacity: 0.0,
        fontSizeScale: 0.084, fontWeightRaw: "heavy", fontChoiceRaw: FontChoice.russoOne.rawValue,
        verticalPosition: 0.72, horizontalAlign: "center",
        animationRaw: "pop", highlightModeRaw: "keyword", maxWordsPerCaption: 4,
        maxWidthScale: 0.75, cornerRadiusScale: 0.0, paddingScale: 0.010)

    static let cinemaGrunge = cinemaPremium

    static let defaults: [String: SubtitleAppearance] = [
        "tiktok": .tiktok,
        "creator": .creator,
        "minimal": .minimal,
        "karaoke": .karaoke,
        "neon": .neon,
        "cinemaGrunge": .cinemaGrunge,
        "cinemaPremium": .cinemaPremium,
    ]

    // MARK: Helpers

    var textColor: NSColor {
        NSColor(hex: textColorHex) ?? .white
    }
    var textBorderColor: NSColor {
        NSColor(hex: textBorderColorHex) ?? .black
    }
    var bgColor: NSColor {
        NSColor(hex: bgColorHex) ?? .black
    }
    var accentColor: NSColor {
        NSColor(hex: accentColorHex) ?? NSColor(hex: "#F5D020") ?? .yellow
    }
    var punchlineColor: NSColor {
        NSColor(hex: punchlineColorHex) ?? NSColor(hex: "#E50914") ?? .red
    }
    var fontChoice: FontChoice {
        FontChoice(rawValue: fontChoiceRaw) ?? .montserrat
    }
    var fontWeight: NSFont.Weight {
        switch fontWeightRaw.lowercased() {
        case "regular":   return .regular
        case "medium":    return .medium
        case "semibold":  return .semibold
        case "bold":      return .bold
        case "heavy":     return .heavy
        default:          return .bold
        }
    }
    func subtitleFont(size: CGFloat) -> NSFont {
        for name in fontChoice.preferredPostScriptNames {
            if let font = NSFont(name: name, size: size) {
                return font
            }
        }
        return NSFont.systemFont(ofSize: size, weight: fontWeight)
    }
    var horizontalAlignmentMode: CATextLayerAlignmentMode {
        switch horizontalAlign.lowercased() {
        case "left":   return .left
        case "right":  return .right
        default:       return .center
        }
    }

    var normalized: SubtitleAppearance {
        var copy = self
        copy.textBorderWidth = copy.textBorderWidth.clamped(to: 0...8)
        copy.bgOpacity = copy.bgOpacity.clamped(to: 0...1)
        copy.fontSizeScale = copy.fontSizeScale.clamped(to: 0.032...0.115)
        copy.verticalPosition = copy.verticalPosition.clamped(to: 0.12...0.90)
        copy.maxWidthScale = copy.maxWidthScale.clamped(to: 0.55...0.94)
        copy.cornerRadiusScale = copy.cornerRadiusScale.clamped(to: 0...0.05)
        copy.paddingScale = copy.paddingScale.clamped(to: 0.006...0.04)
        if !["left", "center", "right"].contains(copy.horizontalAlign.lowercased()) {
            copy.horizontalAlign = "center"
        }
        if !["none", "fade", "clean", "slide", "pop", "bounce", "neon", "karaoke"].contains(copy.animationRaw.lowercased()) {
            copy.animationRaw = "pop"
        }
        if !["none", "keyword", "firstword"].contains(copy.highlightModeRaw.lowercased()) {
            copy.highlightModeRaw = "keyword"
        }
        if !["regular", "medium", "semibold", "bold", "heavy"].contains(copy.fontWeightRaw.lowercased()) {
            copy.fontWeightRaw = "bold"
        }
        if FontChoice(rawValue: copy.fontChoiceRaw) == nil {
            copy.fontChoiceRaw = FontChoice.russoOne.rawValue
        }
        copy.maxWordsPerCaption = copy.maxWordsPerCaption.clamped(to: 3...12)
        return copy
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

extension NSColor {
    convenience init?(hex: String) {
        let c = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard c.count == 6, let v = UInt64(c, radix: 16) else { return nil }
        self.init(
            red: CGFloat((v >> 16) & 0xFF) / 255,
            green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255,
            alpha: 1)
    }
}

/// One segment to burn, with timestamps in seconds relative to the clip start.
struct SubtitleSegment: Sendable {
    let start: Double
    let end: Double
    let text: String
    let words: [WordTimestamp]

    init(start: Double, end: Double, text: String, words: [WordTimestamp] = []) {
        self.start = start
        self.end = end
        self.text = text.cleanedTranscriptText
        self.words = words
    }
}

/// Burns subtitle segments into a video using Core Animation overlay.
enum SubtitleRenderer {

    enum SubtitleError: LocalizedError {
        case compositionFailed, exportFailed, trackNotFound
        var errorDescription: String? {
            switch self {
            case .compositionFailed: return "Couldn't build the subtitle composition."
            case .exportFailed:      return "Couldn't export the subtitled video."
            case .trackNotFound:     return "Video track not found."
            }
        }
    }

    // MARK: - Public

    static func burn(
        videoURL: URL,
        segments: [SubtitleSegment],
        appearance: SubtitleAppearance,
        watermarkText: String? = nil,
        watermarkAppearance: WatermarkAppearance = .default,
        promoCode: String? = nil,
        promoHoldSeconds: Double = 0,
        outputURL: URL
    ) async throws {
        let asset = AVURLAsset(url: videoURL)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw SubtitleError.trackNotFound
        }
        let duration = try await asset.load(.duration)
        let naturalSize = try await videoTrack.load(.naturalSize)
        let preferredTransform = try await videoTrack.load(.preferredTransform)

        let oriented = naturalSize.applying(preferredTransform)
        let natural = CGSize(width: abs(oriented.width), height: abs(oriented.height))
        // ≥1080 short side so burned-in subtitles + promo/watermark stay sharp even when
        // the source clip is low-res; the video is upscaled to fill.
        let (renderTarget, renderUpscale) = PromoOverlayRenderer.targetRenderSize(natural)
        let renderW = renderTarget.width
        let renderH = renderTarget.height

        let composition = AVMutableComposition()
        
        // INSERT THE ENTIRE ASSET TO PRESERVE EXACT TIMING (EDTS / B-FRAMES)
        try await composition.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: asset, at: .zero)
        
        guard let compositionTrack = try await composition.loadTracks(withMediaType: .video).first else {
            throw SubtitleError.compositionFailed
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = CGSize(width: renderW, height: renderH)
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compositionTrack)
        layerInstruction.setTransform(
            renderUpscale > 1 ? preferredTransform.concatenating(CGAffineTransform(scaleX: renderUpscale, y: renderUpscale)) : preferredTransform,
            at: .zero)
        instruction.layerInstructions = [layerInstruction]
        videoComposition.instructions = [instruction]

        let subtitleContainer = await makeSubtitleLayer(
            asset: asset,
            segments: segments, appearance: appearance,
            videoSize: CGSize(width: renderW, height: renderH),
            totalDuration: CMTimeGetSeconds(duration))

        let parentLayer = CALayer()
        let videoLayer = CALayer()

        do {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }

            parentLayer.frame = CGRect(origin: .zero, size: CGSize(width: renderW, height: renderH))

            videoLayer.frame = parentLayer.frame
            parentLayer.addSublayer(videoLayer)

            parentLayer.addSublayer(subtitleContainer)

            if let watermarkText, !watermarkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                WatermarkRenderer.addWatermark(
                    to: parentLayer,
                    text: watermarkText,
                    appearance: watermarkAppearance,
                    renderSize: CGSize(width: renderW, height: renderH),
                    totalDuration: CMTimeGetSeconds(duration))
            }
            if let promoCode, PromoOverlayConfig(promoCode: promoCode).isValid {
                PromoOverlayRenderer.addBanner(
                    to: parentLayer,
                    promoCode: promoCode,
                    renderSize: CGSize(width: renderW, height: renderH),
                    total: CMTimeGetSeconds(duration),
                    holdSeconds: promoHoldSeconds)
            }

            videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
                postProcessingAsVideoLayer: videoLayer, in: parentLayer)
        }

        try await export(composition, videoComposition: videoComposition, to: outputURL)
    }

    // MARK: - Ultra-Kinetic Typography Engine (1-2 Words Per Snap, Per-Shot Face Avoidance)

    // KineticWord is defined in SubtitleLayoutEngine.swift as a domain model.

    struct KineticSnap: Sendable {
        let words: [KineticWord] // Strictly 1 or 2 words!
        let start: Double
        let end: Double
        let isPunchline: Bool
        var safeZoneNorm: CGRect?
        
        var displayText: String {
            words.map(\.cleanText).joined(separator: " ")
        }
        var hasYellow: Bool { words.contains { $0.isYellow } }
        var hasRed: Bool { words.contains { $0.isRed } }
    }

    private static let minorWords: Set<String> = [
        "А", "И", "В", "НА", "С", "У", "К", "О", "ОБ", "ОТ", "ДО", "ИЗ", "ПО", "ЗА", "НО",
        "НЕ", "ЧТО", "КАК", "ТО", "ЖЕ", "ТЫ", "Я", "ОН", "ОНА", "ОНО", "МЫ", "ВЫ", "ОНИ",
        "ЭТО", "ТУТ", "ТАМ", "ВОТ", "БЫ", "ЛИ", "ДА", "НЕТ", "ГДЕ", "КТО", "ЧЕМ", "ТАК",
        "УЖЕ", "ВСЕ", "ЕГО", "ЕЕ", "ИХ", "ТЕБЕ", "МНЕ", "НАС", "ВАС", "ИМ"
    ]

    private static func parseKineticWords(from rawText: String) -> [KineticWord] {
        let scanner = Scanner(string: rawText)
        scanner.charactersToBeSkipped = nil
        
        var words: [KineticWord] = []
        var currentYellow = false
        var currentRed = false
        
        while !scanner.isAtEnd {
            if let textChunk = scanner.scanUpToString("<") {
                let tokens = textChunk.split(whereSeparator: \.isWhitespace).map(String.init)
                for token in tokens {
                    let cleaned = token.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !cleaned.isEmpty else { continue }
                    let upper = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: ".")).uppercased()
                    guard !upper.isEmpty else { continue }
                    let isMinor = minorWords.contains(upper.trimmingCharacters(in: CharacterSet.punctuationCharacters))
                    let weight = max(Double(cleaned.count), 2.0)
                    words.append(KineticWord(
                        cleanText: upper,
                        isYellow: currentYellow,
                        isRed: currentRed,
                        charWeight: weight,
                        isMinor: isMinor
                    ))
                }
            }
            if scanner.isAtEnd { break }
            
            if scanner.scanString("<yellow>") != nil {
                currentYellow = true
            } else if scanner.scanString("</yellow>") != nil {
                currentYellow = false
            } else if scanner.scanString("<red>") != nil {
                currentRed = true
            } else if scanner.scanString("</red>") != nil {
                currentRed = false
            } else {
                if let str = scanner.scanString("<") {
                    let tokens = str.split(whereSeparator: \.isWhitespace).map(String.init)
                    for token in tokens {
                        let cleaned = token.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !cleaned.isEmpty else { continue }
                        let upper = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: ".")).uppercased()
                        guard !upper.isEmpty else { continue }
                        let isMinor = minorWords.contains(upper.trimmingCharacters(in: CharacterSet.punctuationCharacters))
                        words.append(KineticWord(
                            cleanText: upper,
                            isYellow: currentYellow,
                            isRed: currentRed,
                            charWeight: max(Double(cleaned.count), 2.0),
                            isMinor: isMinor
                        ))
                    }
                }
            }
        }

        // Automatic Dynamic Highlighting:
        // When Whisper transcript has no XML tags, dynamically colorize the most impactful words
        let hasCustomColors = words.contains { $0.isYellow || $0.isRed }
        if !hasCustomColors && !words.isEmpty {
            // Find impactful words (nouns/verbs/numbers with >= 4 letters that are not minor words)
            var bestIdx = -1
            var bestWeight = -1.0
            for (idx, w) in words.enumerated() {
                let stripped = w.cleanText.trimmingCharacters(in: CharacterSet.punctuationCharacters)
                if !w.isMinor && Double(stripped.count) > bestWeight {
                    bestWeight = Double(stripped.count)
                    bestIdx = idx
                }
            }
            if bestIdx >= 0 {
                let old = words[bestIdx]
                words[bestIdx] = KineticWord(
                    cleanText: old.cleanText,
                    isYellow: true,
                    isRed: false,
                    charWeight: old.charWeight * 1.5,
                    isMinor: false
                )
            }
        }
        return words
    }

    /// Dynamic partition based on maxWords (Dialogue Mode support)
    private static func partitionIntoSnaps(words: [KineticWord], maxWords: Int) -> [[KineticWord]] {
        var snaps: [[KineticWord]] = []
        var currentSnap: [KineticWord] = []
        
        for word in words {
            currentSnap.append(word)
            
            let hasPunctuation = word.cleanText.hasSuffix("!") || word.cleanText.hasSuffix("?") || word.cleanText.hasSuffix(".")
            let isFull = currentSnap.count >= maxWords
            
            // Break snap if we reached max words, OR if there's terminal punctuation
            if isFull || hasPunctuation {
                snaps.append(currentSnap)
                currentSnap = []
            }
        }
        
        if !currentSnap.isEmpty {
            snaps.append(currentSnap)
        }
        
        return snaps
    }

    private static func buildKineticSnaps(segments: [SubtitleSegment], maxWords: Int) -> [KineticSnap] {
        let sorted = segments
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.start < $1.start }
        guard !sorted.isEmpty else { return [] }
        
        var snaps: [KineticSnap] = []
        
        for seg in sorted {
            let segDuration = max(seg.end - seg.start, 0.3)
            let words = parseKineticWords(from: seg.text)
            guard !words.isEmpty else { continue }
            
            let groupedWords = partitionIntoSnaps(words: words, maxWords: maxWords)
            let totalWeight = words.reduce(0.0) { $0 + $1.charWeight }
            
            let actualSpeechStart = seg.words.first?.start ?? seg.start
            let hasWordTimestamps = !seg.words.isEmpty
            var wordIndex = 0
            var accumulatedTime = actualSpeechStart
            
            for (idx, snapWords) in groupedWords.enumerated() {
                let snapStart: Double
                let snapEnd: Double
                
                if hasWordTimestamps && wordIndex < seg.words.count {
                    let wStart = seg.words[wordIndex].start
                    let endIdx = min(wordIndex + snapWords.count - 1, seg.words.count - 1)
                    let wEnd = seg.words[endIdx].end
                    snapStart = max(actualSpeechStart, wStart)
                    let rawEnd = max(snapStart + 0.22, wEnd)
                    let isLastInSeg = (idx == groupedWords.count - 1)
                    snapEnd = isLastInSeg ? max(rawEnd, seg.end) : rawEnd
                    wordIndex += snapWords.count
                } else {
                    let snapWeight = snapWords.reduce(0.0) { $0 + $1.charWeight }
                    let snapDuration = max(0.22, (snapWeight / max(totalWeight, 1.0)) * segDuration)
                    snapStart = accumulatedTime
                    let isLastInSeg = (idx == groupedWords.count - 1)
                    snapEnd = isLastInSeg ? max(snapStart + 0.22, seg.end) : (snapStart + snapDuration)
                    accumulatedTime = snapEnd
                }
                
                // Clean punchline flag: only if word itself is flagged, without turning the whole snap red
                let isPunchline = snapWords.contains(where: { $0.isRed })
                
                snaps.append(KineticSnap(
                    words: snapWords,
                    start: snapStart,
                    end: snapEnd,
                    isPunchline: isPunchline,
                    safeZoneNorm: nil
                ))
            }
        }
        
        return snaps
    }

    private static func resolveFont(name: String, size: CGFloat, fallback: NSFont.Weight = .heavy) -> NSFont {
        FontDownloadService.shared.registerBundledFonts()
        
        // 1. Try exact PostScript name match
        if let f = NSFont(name: name, size: size) {
            return f
        }
        
        // 2. Variable font support: try family name + bold trait via NSFontDescriptor.
        //    Variable fonts (e.g. Oswald) register under family "Oswald" but
        //    NSFont(name: "Oswald-Bold") fails because CoreText doesn't synthesize
        //    PostScript names for individual variation instances.
        let oswaldFamilies = ["Oswald", "Anton"]
        for family in oswaldFamilies {
            let descriptor = NSFontDescriptor(fontAttributes: [
                .family: family,
                .traits: [NSFontDescriptor.TraitKey.weight: NSFont.Weight.bold.rawValue]
            ])
            let matched = descriptor.matchingFontDescriptor(withMandatoryKeys: [.family])
            if let matched {
                if let font = NSFont(descriptor: matched, size: size) {
                    // Apply bold weight via font manager for variable fonts
                    let boldFont = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
                    return boldFont
                }
            }
        }
        
        // 3. Impact (system font, always available on macOS)
        if let f = NSFont(name: "Impact", size: size) {
            return f
        }
        
        // 4. Montserrat fallback (bundled static fonts)
        if let f = NSFont(name: "Montserrat-Black", size: size) ?? NSFont(name: "Montserrat-ExtraBold", size: size) {
            return f
        }
        if let f = NSFont(name: "Arial-Black", size: size) {
            return f
        }
        
        // 5. System Font Black (San Francisco Black)
        return NSFont.systemFont(ofSize: size, weight: .black)
    }

    private static func createStyledSnap(
        snap: KineticSnap,
        appearance: SubtitleAppearance,
        baseFontSize: CGFloat,
        usableW: CGFloat
    ) -> (attrStr: NSAttributedString, width: CGFloat, height: CGFloat) {
        let whiteColor = NSColor(hex: appearance.textColorHex) ?? .white
        let yellowColor = NSColor(hex: appearance.accentColorHex) ?? NSColor(hex: "#FFE45C") ?? .yellow
        let minorColor = NSColor(hex: "#E0E0E0") ?? .lightGray
        
        let fontName = appearance.fontChoice.preferredPostScriptNames.first ?? "Anton-Regular"
        let effectiveFont = resolveFont(name: fontName, size: baseFontSize)
        let safeW = min(usableW, SubtitleLayoutEngine.defaultSafeWidth)
        
        let layoutResult = SubtitleLayoutEngine.shared.layoutSnap(
            text: snap.words.map(\.cleanText).joined(separator: " "),
            words: snap.words,
            font: effectiveFont,
            maxSafeWidth: safeW,
            minFontSize: 46.0,
            maxFontSize: baseFontSize
        )
        
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = 4.0
        
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.98)
        shadow.shadowBlurRadius = layoutResult.fontSize * 0.28
        shadow.shadowOffset = CGSize(width: 0, height: -(layoutResult.fontSize * 0.12))
        
        let fontForRender = resolveFont(name: fontName, size: layoutResult.fontSize)
        let result = NSMutableAttributedString()
        
        for (lineIdx, line) in layoutResult.lines.enumerated() {
            let lineWords = line.split(separator: " ").map(String.init)
            for (wIdx, lWord) in lineWords.enumerated() {
                let cleanLWord = lWord.trimmingCharacters(in: CharacterSet.punctuationCharacters).uppercased()
                let matchingWord = snap.words.first {
                    let wClean = $0.cleanText.trimmingCharacters(in: CharacterSet.punctuationCharacters).uppercased()
                    return wClean == cleanLWord || $0.cleanText.caseInsensitiveCompare(lWord) == .orderedSame
                }
                
                // Pure viral kinetic aesthetic:
                // Base text is always pure snow white.
                // Highlighted keyword is electric golden-yellow (#FFE45C).
                // Red is NEVER mixed into a snap alongside yellow!
                let isHighlight = matchingWord?.isYellow == true
                let isRedWord = matchingWord?.isRed == true && !snap.hasYellow
                
                let textColor: NSColor
                if isHighlight || isRedWord {
                    textColor = yellowColor
                } else if matchingWord?.isMinor == true && lineWords.count > 2 {
                    textColor = minorColor
                } else {
                    textColor = whiteColor
                }
                
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: fontForRender,
                    .foregroundColor: textColor,
                    .strokeColor: NSColor.black,
                    .strokeWidth: -4.2, // High-contrast crisp border without clipping
                    .paragraphStyle: paragraph,
                    .shadow: shadow,
                    .kern: 1.5 // Tight, compact cinematic tracking
                ]
                
                let suffix = (wIdx == lineWords.count - 1) ? "" : " "
                result.append(NSAttributedString(string: lWord + suffix, attributes: attrs))
            }
            if lineIdx < layoutResult.lines.count - 1 {
                result.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: paragraph]))
            }
        }
        
        let measured = result.boundingRect(
            with: CGSize(width: layoutResult.bounds.width + 80.0, height: 500.0),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        // Extra vertical padding prevents CoreGraphics from clipping ascenders/top of letters
        let extraTopPadding = ceil(layoutResult.fontSize * 0.40)
        return (result, ceil(measured.width) + 48.0, ceil(measured.height) + extraTopPadding + 36.0)
    }

    private static func renderSnapImage(_ text: NSAttributedString, size: CGSize) -> CGImage? {
        let scale: CGFloat = 3.0
        let pxW = max(1, Int(ceil(size.width * scale)))
        let pxH = max(1, Int(ceil(size.height * scale)))
        
        guard let ctx = CGContext(
            data: nil,
            width: pxW,
            height: pxH,
            bitsPerComponent: 8,
            bytesPerRow: pxW * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        
        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx
        ctx.scaleBy(x: scale, y: scale)
        
        let drawRect = CGRect(x: 20.0, y: 16.0, width: size.width - 40.0, height: size.height - 32.0)
        text.draw(with: drawRect, options: [.usesLineFragmentOrigin, .usesFontLeading])
        
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    private static func buildKineticSubtitleLayer(
        asset: AVAsset? = nil,
        segments: [SubtitleSegment],
        appearance: SubtitleAppearance,
        videoSize: CGSize,
        totalDuration: Double
    ) async -> CALayer {
        let W = videoSize.width
        let H = videoSize.height
        var snaps = buildKineticSnaps(segments: segments, maxWords: appearance.normalized.maxWordsPerCaption)
        guard !snaps.isEmpty else {
            let emptyContainer = CALayer()
            emptyContainer.frame = CGRect(origin: .zero, size: videoSize)
            emptyContainer.backgroundColor = CGColor(gray: 0, alpha: 0)
            return emptyContainer
        }
        
        // Phase 3 & 4: Per-Shot Dynamic Face Detection with Temporal Hysteresis
        if let asset {
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 512, height: 512)
            generator.requestedTimeToleranceBefore = CMTime(seconds: 0.15, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.15, preferredTimescale: 600)
            
            var lastDecision: SubtitlePlacementDecision?
            for i in 0..<snaps.count {
                let sampleSec = max(0, snaps[i].start + 0.04)
                let time = CMTime(seconds: sampleSec, preferredTimescale: 600)
                var faceBoxes: [CGRect] = []
                if let frameImg = try? await generator.image(at: time).image {
                    faceBoxes = await CinemaSquareReframer.detectFaceBoxes(image: frameImg)
                }
                
                let decision = SubtitlePlacementStrategy.shared.calculateSafeZone(
                    faceBoxes: faceBoxes,
                    videoSize: CGSize(width: W, height: H),
                    currentTime: sampleSec,
                    lastPlacement: lastDecision
                )
                lastDecision = decision
                
                // Convert normalized Y (where 0.0 is top, 1.0 is bottom) to CoreAnimation coordinates (0.0 bottom, 1.0 top)
                let caNormY = 1.0 - decision.verticalNormalizedY
                snaps[i].safeZoneNorm = CGRect(
                    x: (1.0 - decision.safeWidth / W) / 2.0,
                    y: max(0.08, caNormY - 0.08),
                    width: decision.safeWidth / W,
                    height: 0.16
                )
            }
        }
        
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let container = CALayer()
        container.frame = CGRect(origin: .zero, size: videoSize)
        container.backgroundColor = CGColor(gray: 0, alpha: 0)

        let baseFontSize = W * appearance.normalized.fontSizeScale
        let usableW = min(W - 80.0, SubtitleLayoutEngine.defaultSafeWidth)
        
        for snap in snaps {
            let (attrStr, snapW, snapH) = createStyledSnap(
                snap: snap,
                appearance: appearance,
                baseFontSize: baseFontSize,
                usableW: usableW
            )
            
            // Safe zone coordinates in Core Animation (Y=0 is bottom, Y=H is top)
            let safe = snap.safeZoneNorm ?? CGRect(x: 0.15, y: 0.16, width: 0.70, height: 0.14)
            let safeOriginX = safe.origin.x * W
            let safeOriginY = safe.origin.y * H
            let safeWidth = safe.width * W
            let safeHeight = safe.height * H
            
            // Center the snap inside its safe zone
            let snapX = (safeOriginX + (safeWidth - snapW) / 2.0).clamped(to: 40.0...(W - 40.0 - snapW))
            let rawSnapY = (safeOriginY + (safeHeight - snapH) / 2.0).clamped(to: 40.0...(H - 40.0 - snapH))
            
            let snapY = rawSnapY

            let snapLayer = CALayer()
            snapLayer.frame = CGRect(x: snapX, y: snapY, width: snapW, height: snapH)
            snapLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            snapLayer.position = CGPoint(x: snapX + snapW / 2.0, y: snapY + snapH / 2.0)
            snapLayer.contentsScale = 3.0
            snapLayer.contentsGravity = .resizeAspect
            snapLayer.contents = renderSnapImage(attrStr, size: CGSize(width: snapW, height: snapH))
            
            // Hard Cut timed opacity (strictly visible only from snap.start to snap.end)
            let total = max(totalDuration, 0.001)
            let visStart = max(0, snap.start)
            let visEnd = min(total, max(visStart, snap.end))
            
            let opacityAnim = CAKeyframeAnimation(keyPath: "opacity")
            if visStart <= 0.0001 {
                let kEnd = visEnd / total
                let kFadeOutStart = max(0.0, kEnd - 0.0001)
                let kFadeOutEnd = min(1.0, kEnd)
                if kFadeOutEnd < 1.0 {
                    opacityAnim.values = [1, 1, 0, 0]
                    opacityAnim.keyTimes = [
                        NSNumber(value: 0.0),
                        NSNumber(value: kFadeOutStart),
                        NSNumber(value: kFadeOutEnd),
                        NSNumber(value: 1.0)
                    ]
                } else {
                    opacityAnim.values = [1, 1]
                    opacityAnim.keyTimes = [NSNumber(value: 0.0), NSNumber(value: 1.0)]
                }
            } else {
                let kStart = visStart / total
                let kEnd = visEnd / total
                let kFadeInStart = max(0.0, kStart - 0.0001)
                let kFadeInEnd = kStart
                let kFadeOutStart = kEnd
                let kFadeOutEnd = min(1.0, kEnd + 0.0001)
                
                opacityAnim.values = [0, 0, 1, 1, 0, 0]
                opacityAnim.keyTimes = [
                    NSNumber(value: 0.0),
                    NSNumber(value: kFadeInStart),
                    NSNumber(value: kFadeInEnd),
                    NSNumber(value: kFadeOutStart),
                    NSNumber(value: kFadeOutEnd),
                    NSNumber(value: 1.0)
                ]
            }
            opacityAnim.duration = total
            opacityAnim.beginTime = AVCoreAnimationBeginTimeAtZero
            opacityAnim.fillMode = .both
            opacityAnim.isRemovedOnCompletion = false
            snapLayer.add(opacityAnim, forKey: "snapOpacity")
            snapLayer.opacity = 0
            
            // Kinetic "BAM" micro-scale snap (1.14 -> 0.98 -> 1.0 in 0.08s)
            let punchAnim = CAKeyframeAnimation(keyPath: "transform.scale")
            punchAnim.values = [1.14, 0.98, 1.0]
            punchAnim.duration = 0.08
            punchAnim.keyTimes = [0.0, 0.55, 1.0]
            punchAnim.beginTime = AVCoreAnimationBeginTimeAtZero + visStart
            punchAnim.fillMode = .forwards
            punchAnim.isRemovedOnCompletion = false
            snapLayer.add(punchAnim, forKey: "snapPunch")
            
            container.addSublayer(snapLayer)
        }
        
        return container
    }

    // MARK: - Layer builder

    private static func makeSubtitleLayer(
        asset: AVAsset? = nil,
        segments: [SubtitleSegment],
        appearance: SubtitleAppearance,
        videoSize: CGSize,
        totalDuration: Double
    ) async -> CALayer {
        return await buildKineticSubtitleLayer(
            asset: asset,
            segments: segments,
            appearance: appearance,
            videoSize: videoSize,
            totalDuration: totalDuration)
    }

    private static func chunk(
        segment: SubtitleSegment,
        appearance: SubtitleAppearance
    ) -> [(start: Double, end: Double, text: String)] {
        let words = segment.text
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard words.count > appearance.maxWordsPerCaption else {
            return [(segment.start, segment.end, segment.text)]
        }

        let duration = max(segment.end - segment.start, 0.3)
        let groupCount = Int(ceil(Double(words.count) / Double(appearance.maxWordsPerCaption)))
        let groupDuration = duration / Double(groupCount)
        var chunks: [(Double, Double, String)] = []

        for index in 0..<groupCount {
            let wordStart = index * appearance.maxWordsPerCaption
            let wordEnd = min(wordStart + appearance.maxWordsPerCaption, words.count)
            let start = segment.start + Double(index) * groupDuration
            let end = index == groupCount - 1 ? segment.end : start + groupDuration
            chunks.append((start, end, words[wordStart..<wordEnd].joined(separator: " ")))
        }
        return chunks
    }

    private static func makeTextLayer(
        text: String,
        appearance rawAppearance: SubtitleAppearance,
        start: Double,
        duration: Double,
        videoSize: CGSize,
        totalDuration: Double,
        karaokeWord: String? = nil
    ) -> CALayer {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let appearance = rawAppearance.normalized
        let w = videoSize.width
        let h = videoSize.height
        let maxW = w * appearance.maxWidthScale
        let pad = w * appearance.paddingScale
        let fontSize = w * appearance.fontSizeScale
        let font = appearance.subtitleFont(size: fontSize)
        let outerMarginX = w * 0.04
        let outerMarginTop = h * 0.08
        let outerMarginBottom = h * 0.12
        let usableW = min(maxW, w - outerMarginX * 2)

        // Measure text height for the container.
        let nsText = text as NSString
        let textBounds = nsText.boundingRect(
            with: CGSize(width: usableW - pad * 2, height: h * 0.32),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font], context: nil)
        let containerH = min(h * 0.32, ceil(textBounds.height) + pad * 2)

        let container = CALayer()
        container.bounds = CGRect(x: 0, y: 0, width: usableW, height: containerH)
        container.anchorPoint = CGPoint(x: 0.5, y: 0.5)

        // Core Animation video layers use a bottom-left origin. The app setting
        // is user-facing (0 = top, 1 = bottom), so invert it for the export.
        let finalXPos: CGFloat
        let finalYPos: CGFloat
        if let safeZone = appearance.safeTextZoneNorm {
            // safeZone is in normalized coordinates (0..1)
            // It represents the box where we can put text safely.
            let safeX = safeZone.minX * w
            let safeY = safeZone.minY * h
            let safeW = safeZone.width * w
            let safeH = safeZone.height * h
            
            // Center the container inside the safe zone horizontally
            finalXPos = safeX + (safeW / 2)
            // Center the container vertically in the safe zone
            let yCenter = safeY + (safeH / 2)
            finalYPos = yCenter
        } else {
            let minY = outerMarginBottom + containerH / 2
            let maxY = h - outerMarginTop - containerH / 2
            // appearance.verticalPosition: 0.0 is top, 1.0 is bottom in UI
            // Core Animation is bottom-left, so we invert
            finalYPos = (h * (1.0 - appearance.verticalPosition)).clamped(to: minY...max(minY, maxY))
            
            switch appearance.horizontalAlign.lowercased() {
            case "left":
                finalXPos = outerMarginX + usableW / 2
            case "right":
                finalXPos = w - outerMarginX - usableW / 2
            default:
                finalXPos = w / 2
            }
        }
        container.position = CGPoint(x: finalXPos, y: finalYPos)

        // Background.
        let bg = appearance.bgColor
        container.backgroundColor = NSColor(
            red: bg.redComponent, green: bg.greenComponent,
            blue: bg.blueComponent, alpha: appearance.bgOpacity).cgColor
        container.cornerRadius = w * appearance.cornerRadiusScale
        container.isOpaque = false
        // Neon needs its glow to spill outside the container, so don't clip it.
        container.masksToBounds = appearance.animationRaw.lowercased() != "neon"

        // AVFoundation's offline Core Animation renderer can drop CATextLayer
        // text entirely. Rasterize the styled string first, then burn that image.
        let textSize = CGSize(width: usableW - pad * 2, height: containerH - pad * 2)
        let textLayer = CALayer()
        textLayer.contentsScale = 3.0
        textLayer.contentsGravity = .resize
        textLayer.frame = CGRect(origin: CGPoint(x: pad, y: pad), size: textSize)
        textLayer.contents = renderSubtitleImage(
            attributedSubtitle(text, appearance: appearance, font: font, highlightWord: karaokeWord, moodProfile: appearance.moodProfile ?? .default),
            size: textSize,
            alignment: appearance.horizontalAlign)

        container.addSublayer(textLayer)

        // Neon: colored halo around the glyphs (glow spills past the container,
        // which is why masksToBounds is disabled above for this style).
        if appearance.animationRaw.lowercased() == "neon" {
            textLayer.shadowColor = appearance.accentColor.cgColor
            textLayer.shadowRadius = fontSize * 0.28
            textLayer.shadowOpacity = 1.0
            textLayer.shadowOffset = .zero
            textLayer.masksToBounds = false
        }

        // Entrance / exit animation.
        switch appearance.animationRaw.lowercased() {
        case "none":
            addTimedOpacity(to: container, start: start, duration: duration, totalDuration: totalDuration)
        case "clean", "fade", "neon":
            addTimedOpacity(to: container, start: start, duration: duration, totalDuration: totalDuration)
        case "pop":
            addTimedOpacity(to: container, start: start, duration: duration, totalDuration: totalDuration)

            let scale = CAKeyframeAnimation(keyPath: "transform.scale")
            scale.values = [0.92, 1.08, 1.0]
            scale.keyTimes = [0, 0.45, 1]
            scale.beginTime = AVCoreAnimationBeginTimeAtZero + start
            scale.duration = 0.18
            scale.fillMode = .forwards
            scale.isRemovedOnCompletion = false

            container.add(scale, forKey: nil)
        case "bounce":
            addTimedOpacity(to: container, start: start, duration: duration, totalDuration: totalDuration)

            let scale = CAKeyframeAnimation(keyPath: "transform.scale")
            scale.values = [0.7, 1.15, 0.95, 1.0]
            scale.keyTimes = [0, 0.5, 0.78, 1]
            scale.timingFunctions = [
                CAMediaTimingFunction(name: .easeOut),
                CAMediaTimingFunction(name: .easeInEaseOut),
                CAMediaTimingFunction(name: .easeInEaseOut),
            ]
            scale.beginTime = AVCoreAnimationBeginTimeAtZero + start
            scale.duration = 0.28
            scale.fillMode = .forwards
            scale.isRemovedOnCompletion = false

            container.add(scale, forKey: nil)
        case "slide":
            addTimedOpacity(to: container, start: start, duration: duration, totalDuration: totalDuration)

            let slideUp = CABasicAnimation(keyPath: "position.y")
            slideUp.fromValue = finalYPos + fontSize * 1.5
            slideUp.toValue = finalYPos
            slideUp.beginTime = AVCoreAnimationBeginTimeAtZero + start
            slideUp.duration = 0.25
            slideUp.fillMode = .forwards
            slideUp.isRemovedOnCompletion = false

            container.add(slideUp, forKey: nil)
        default:
            addTimedOpacity(to: container, start: start, duration: duration, totalDuration: totalDuration)
        }

        return container
    }

    private static func addTimedOpacity(
        to layer: CALayer,
        start: Double,
        duration: Double,
        totalDuration: Double
    ) {
        let total = max(totalDuration, 0.001)
        let fade = min(0.08, max(0, duration) * 0.25)
        let visibleStart = max(0, start)
        let visibleEnd = min(total, max(visibleStart, start + duration))
        let fadeInEnd = min(visibleEnd, visibleStart + fade)
        let fadeOutStart = max(fadeInEnd, visibleEnd - fade)

        let anim = CAKeyframeAnimation(keyPath: "opacity")
        anim.values = [0, 0, 1, 1, 0, 0]
        anim.keyTimes = [
            0,
            NSNumber(value: visibleStart / total),
            NSNumber(value: fadeInEnd / total),
            NSNumber(value: fadeOutStart / total),
            NSNumber(value: visibleEnd / total),
            1,
        ]
        anim.duration = total
        anim.beginTime = AVCoreAnimationBeginTimeAtZero
        anim.fillMode = .both
        anim.isRemovedOnCompletion = false
        layer.add(anim, forKey: "subtitleOpacity")
        layer.opacity = 0
    }

    private static func attributedSubtitle(
        _ text: String,
        appearance: SubtitleAppearance,
        font: NSFont,
        highlightWord: String? = nil,
        moodProfile: CinematicMoodProfile = .default
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        switch appearance.horizontalAlign.lowercased() {
        case "left": paragraph.alignment = .left
        case "right": paragraph.alignment = .right
        default: paragraph.alignment = .center
        }

        let baseAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(hex: moodProfile.primaryColorHex) ?? appearance.textColor,
            .strokeColor: appearance.textBorderColor,
            .strokeWidth: -appearance.textBorderWidth,
            .paragraphStyle: paragraph
        ]

        let result = NSMutableAttributedString(string: "", attributes: baseAttributes)
        
        // Parse <red> and <yellow> tags
        let scanner = Scanner(string: text)
        scanner.charactersToBeSkipped = nil
        
        let redColor = NSColor(hex: moodProfile.punchlineColorHex) ?? NSColor.red
        let yellowColor = NSColor(hex: moodProfile.verbColorHex) ?? NSColor.yellow
        
        while !scanner.isAtEnd {
            if let textBeforeTag = scanner.scanUpToString("<") {
                result.append(NSAttributedString(string: textBeforeTag, attributes: baseAttributes))
            }
            if scanner.isAtEnd { break }
            
            if scanner.scanString("<red>") != nil {
                if let insideText = scanner.scanUpToString("</red>") {
                    var attrs = baseAttributes
                    attrs[.foregroundColor] = redColor
                    result.append(NSAttributedString(string: insideText, attributes: attrs))
                }
                _ = scanner.scanString("</red>")
            } else if scanner.scanString("<yellow>") != nil {
                if let insideText = scanner.scanUpToString("</yellow>") {
                    var attrs = baseAttributes
                    attrs[.foregroundColor] = yellowColor
                    result.append(NSAttributedString(string: insideText, attributes: attrs))
                }
                _ = scanner.scanString("</yellow>")
            } else {
                // Not a known tag, just append
                if let bracket = scanner.scanString("<") {
                    result.append(NSAttributedString(string: bracket, attributes: baseAttributes))
                }
            }
        }

        // Apply ALL CAPS for cinematic
        let finalString = result.string.uppercased()
        let upperResult = NSMutableAttributedString(string: finalString)
        result.enumerateAttributes(in: NSRange(location: 0, length: result.length), options: []) { attrs, range, _ in
            upperResult.addAttributes(attrs, range: range)
        }

        let hasTags = text.contains("<red>") || text.contains("<yellow>")
        
        if let hw = highlightWord {
            let ns = upperResult.string as NSString
            let range = ns.range(of: hw.uppercased())
            if range.location != NSNotFound {
                upperResult.addAttribute(.foregroundColor, value: yellowColor, range: range)
            }
        } else if !hasTags {
            let mode = appearance.highlightModeRaw.lowercased()
            let ns = upperResult.string as NSString
            let words = upperResult.string.split(whereSeparator: \.isWhitespace).map(String.init)
            
            if mode == "keyword" && !words.isEmpty {
                let targetVerb = words.max { $0.count < $1.count } ?? words[0]
                let verbRange = ns.range(of: targetVerb)
                if verbRange.location != NSNotFound {
                    upperResult.addAttribute(.foregroundColor, value: yellowColor, range: verbRange)
                }
                
                if words.count > 1 {
                    let targetPunchline = words.last!
                    let punchlineRange = ns.range(of: targetPunchline, options: .backwards)
                    if punchlineRange.location != NSNotFound {
                        upperResult.addAttribute(.foregroundColor, value: redColor, range: punchlineRange)
                    }
                }
            } else if mode == "firstword" && !words.isEmpty {
                let range = ns.range(of: words[0])
                if range.location != NSNotFound {
                    upperResult.addAttribute(.foregroundColor, value: yellowColor, range: range)
                }
            }
        }

        return upperResult
    }

    private static func renderSubtitleImage(
        _ text: NSAttributedString,
        size: CGSize,
        alignment: String
    ) -> CGImage? {
        let scale: CGFloat = 3
        let pxW = max(1, Int(ceil(size.width * scale)))
        let pxH = max(1, Int(ceil(size.height * scale)))
        guard let ctx = CGContext(
            data: nil, width: pxW, height: pxH, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }

        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx
        ctx.scaleBy(x: scale, y: scale)

        let bounds = text.boundingRect(
            with: CGSize(width: size.width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        let drawHeight = min(size.height, ceil(bounds.height))
        let y = max(0, (size.height - drawHeight) / 2)
        let x: CGFloat
        let drawWidth = min(size.width, ceil(bounds.width))
        switch alignment.lowercased() {
        case "left":
            x = 0
        case "right":
            x = max(0, size.width - drawWidth)
        default:
            x = max(0, (size.width - drawWidth) / 2)
        }

        text.draw(
            with: CGRect(x: x, y: y, width: min(size.width, max(drawWidth, 1)), height: drawHeight),
            options: [.usesLineFragmentOrigin, .usesFontLeading])

        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    private static func highlightRange(in text: String, mode: String) -> NSRange? {
        guard mode.lowercased() != "none" else { return nil }
        let ns = text as NSString
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return nil }
        let target: String
        if mode.lowercased() == "firstword" {
            target = words[0]
        } else {
            target = words.max { $0.cleanedForHighlight.count < $1.cleanedForHighlight.count } ?? words[0]
        }
        let range = ns.range(of: target)
        return range.location == NSNotFound ? nil : range
    }

    // MARK: - Export

    private static func export(
        _ asset: sending AVAsset,
        videoComposition: sending AVVideoComposition,
        to outputURL: URL
    ) async throws {
        try await HighBitrateExporter.export(
            asset: asset, videoComposition: videoComposition, to: outputURL)
    }
}
