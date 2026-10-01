import Foundation
import AppKit

/// Represents a single styled word for kinetic/subtitles rendering and layout.
public struct KineticWord: Sendable {
    public let cleanText: String
    public let isYellow: Bool
    public let isRed: Bool
    public let charWeight: Double
    public let isMinor: Bool

    public init(
        cleanText: String,
        isYellow: Bool = false,
        isRed: Bool = false,
        charWeight: Double = 1.0,
        isMinor: Bool = false
    ) {
        self.cleanText = cleanText
        self.isYellow = isYellow
        self.isRed = isRed
        self.charWeight = charWeight
        self.isMinor = isMinor
    }
}

/// Protocol for subtitle layout and typography calculation (SOLID: SRP/DIP).
public protocol SubtitleLayoutEngineProtocol: Sendable {
    func layoutSnap(
        text: String,
        words: [KineticWord],
        font: NSFont,
        maxSafeWidth: CGFloat,
        minFontSize: CGFloat,
        maxFontSize: CGFloat
    ) -> SubtitleLayoutResult
}

public struct SubtitleLayoutResult: Sendable {
    public let lines: [String]
    public let fontSize: CGFloat
    public let bounds: CGSize
    public let wordLayouts: [WordLayoutInfo]

    public init(lines: [String], fontSize: CGFloat, bounds: CGSize, wordLayouts: [WordLayoutInfo]) {
        self.lines = lines
        self.fontSize = fontSize
        self.bounds = bounds
        self.wordLayouts = wordLayouts
    }
}

public struct WordLayoutInfo: Sendable {
    public let text: String
    public let lineIndex: Int
    public let rect: CGRect
    public let isYellow: Bool
    public let isRed: Bool

    public init(text: String, lineIndex: Int, rect: CGRect, isYellow: Bool, isRed: Bool) {
        self.text = text
        self.lineIndex = lineIndex
        self.rect = rect
        self.isYellow = isYellow
        self.isRed = isRed
    }
}

/// Layout engine providing premium multi-line word wrapping and stable font sizing without "accordion" shrinking.
public final class SubtitleLayoutEngine: SubtitleLayoutEngineProtocol, @unchecked Sendable {
    public static let shared = SubtitleLayoutEngine()

    /// Recommended safe width for vertical 9:16 / 1:1 mobile players (leaves 160px margin on right for action buttons).
    public static let defaultSafeWidth: CGFloat = 760.0

    public init() {}

    public func layoutSnap(
        text: String,
        words: [KineticWord],
        font: NSFont,
        maxSafeWidth: CGFloat = defaultSafeWidth,
        minFontSize: CGFloat = 46.0,
        maxFontSize: CGFloat = 62.0
    ) -> SubtitleLayoutResult {
        let cleanWords = words.filter { !$0.cleanText.isEmpty }
        guard !cleanWords.isEmpty else {
            return SubtitleLayoutResult(lines: [], fontSize: minFontSize, bounds: .zero, wordLayouts: [])
        }

        // Try single line first
        var chosenFontSize = maxFontSize
        var lines: [String] = []

        // If there are more than 3 words or combined characters > 22, prefer 2 lines
        let totalChars = cleanWords.reduce(0) { $0 + $1.cleanText.count }
        if cleanWords.count > 3 || totalChars > 20 {
            lines = splitIntoTwoBalancedLines(cleanWords.map { $0.cleanText })
            chosenFontSize = min(maxFontSize, 54.0)
        } else {
            lines = [cleanWords.map { $0.cleanText }.joined(separator: " ")]
            chosenFontSize = maxFontSize
        }

        // Measure and ensure text fits within maxSafeWidth
        while chosenFontSize > minFontSize {
            let candidateFont = NSFont(name: font.fontName, size: chosenFontSize) ?? NSFont.boldSystemFont(ofSize: chosenFontSize)
            let maxMeasuredWidth = lines.reduce(CGFloat.zero) { currentMax, line in
                let attr = NSAttributedString(string: line, attributes: [.font: candidateFont])
                return max(currentMax, attr.size().width)
            }

            if maxMeasuredWidth <= maxSafeWidth {
                break
            }
            chosenFontSize -= 2.0
        }

        let effectiveFont = NSFont(name: font.fontName, size: chosenFontSize) ?? NSFont.boldSystemFont(ofSize: chosenFontSize)

        // Measure line heights and bounds
        let lineHeight = effectiveFont.pointSize * 1.25
        let totalHeight: CGFloat = CGFloat(lines.count) * lineHeight
        var maxLineWidth: CGFloat = 0

        for line in lines {
            let attr = NSAttributedString(string: line, attributes: [.font: effectiveFont])
            maxLineWidth = max(maxLineWidth, attr.size().width)
        }

        let bounds = CGSize(width: maxLineWidth + 40.0, height: totalHeight + 20.0)

        // Calculate layout coordinates for each word
        var wordLayouts: [WordLayoutInfo] = []
        var wordIndex = 0

        for (lineIdx, line) in lines.enumerated() {
            let lineAttr = NSAttributedString(string: line, attributes: [.font: effectiveFont])
            let lineWidth = lineAttr.size().width
            var currentX = (bounds.width - lineWidth) / 2.0
            let currentY = CGFloat(lines.count - 1 - lineIdx) * lineHeight + 10.0

            let lineWords = line.split(separator: " ").map(String.init)
            for lWord in lineWords {
                guard wordIndex < cleanWords.count else { break }
                let kWord = cleanWords[wordIndex]
                let wAttr = NSAttributedString(string: lWord, attributes: [.font: effectiveFont])
                let wSize = wAttr.size()
                let wRect = CGRect(x: currentX, y: currentY, width: wSize.width, height: wSize.height)

                wordLayouts.append(WordLayoutInfo(
                    text: kWord.cleanText,
                    lineIndex: lineIdx,
                    rect: wRect,
                    isYellow: kWord.isYellow,
                    isRed: kWord.isRed
                ))

                let spaceAttr = NSAttributedString(string: " ", attributes: [.font: effectiveFont])
                currentX += wSize.width + spaceAttr.size().width
                wordIndex += 1
            }
        }

        return SubtitleLayoutResult(
            lines: lines,
            fontSize: chosenFontSize,
            bounds: bounds,
            wordLayouts: wordLayouts
        )
    }

    private func splitIntoTwoBalancedLines(_ wordStrings: [String]) -> [String] {
        guard wordStrings.count > 1 else { return [wordStrings.joined(separator: " ")] }

        let totalLen = wordStrings.reduce(0) { $0 + $1.count }
        let targetHalf = totalLen / 2

        var bestSplitIdx = 1
        var currentAcc = 0
        var minDiff = Int.max

        for i in 0..<(wordStrings.count - 1) {
            currentAcc += wordStrings[i].count
            let diff = abs(currentAcc - targetHalf)
            if diff < minDiff {
                minDiff = diff
                bestSplitIdx = i + 1
            }
        }

        let line1 = wordStrings[0..<bestSplitIdx].joined(separator: " ")
        let line2 = wordStrings[bestSplitIdx..<wordStrings.count].joined(separator: " ")
        return [line1, line2]
    }
}
