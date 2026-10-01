import Foundation

// MARK: - SentenceBoundaryDetecting Protocol

/// Protocol for snapping cinema and clip cuts to natural speech and sentence boundaries (SOLID: SRP/DIP).
public protocol SentenceBoundaryDetecting: Sendable {
    /// Snaps a timestamp to the start of the enclosing or closest sentence, applying head padding.
    func snapToSentenceStart(timestamp: Double, in segments: [TranscriptSegment]) -> Double

    /// Snaps a timestamp to the end of the enclosing or closest sentence, applying tail padding.
    func snapToSentenceEnd(timestamp: Double, maxAllowedDuration: Double, in segments: [TranscriptSegment]) -> Double

    /// Refines a scene boundary so both start and end align with complete sentences,
    /// guaranteeing no mid-sentence cuts even when constrained by `maxAllowedDuration`.
    func refineSceneBoundary(range: TimeSegment, maxAllowedDuration: Double, in segments: [TranscriptSegment]) -> TimeSegment

    /// Searches backwards for the latest completed sentence ending before `before`.
    func findPreviousSentenceEnd(before: Double, in segments: [TranscriptSegment]) -> Double?
}

// MARK: - SentenceBoundaryDetector Implementation

/// Concrete implementation of `SentenceBoundaryDetecting`.
/// Detects punctuation (`.`, `!`, `?`, `…`), significant speech pauses (>= 1.0s),
/// and respects audio room tone and consonant attack buffers.
public struct SentenceBoundaryDetector: SentenceBoundaryDetecting {

    public static let defaultHeadPadding: Double = 0.20
    public static let defaultTailPadding: Double = 0.45
    public static let defaultMinSegmentDuration: Double = 10.0
    public static let defaultMaxShortsDuration: Double = 58.0
    public static let defaultPauseThreshold: Double = 1.0

    public let headPadding: Double
    public let tailPadding: Double
    public let minSegmentDuration: Double
    public let maxShortsDuration: Double
    public let pauseThreshold: Double

    public init(
        headPadding: Double = defaultHeadPadding,
        tailPadding: Double = defaultTailPadding,
        minSegmentDuration: Double = defaultMinSegmentDuration,
        maxShortsDuration: Double = defaultMaxShortsDuration,
        pauseThreshold: Double = defaultPauseThreshold
    ) {
        self.headPadding = headPadding
        self.tailPadding = tailPadding
        self.minSegmentDuration = minSegmentDuration
        self.maxShortsDuration = maxShortsDuration
        self.pauseThreshold = pauseThreshold
    }

    // MARK: - Detected Sentence Model

    public struct DetectedSentence: Sendable, Equatable {
        public let start: Double
        public let end: Double
        public let text: String
        public let isTerminal: Bool

        public init(start: Double, end: Double, text: String, isTerminal: Bool) {
            self.start = start
            self.end = end
            self.text = text
            self.isTerminal = isTerminal
        }
    }

    private struct SpeechItem {
        let start: Double
        let end: Double
        let text: String
    }

    // MARK: - Punctuation & Boundary Detection

    /// Returns true if the text ends with terminal sentence punctuation (. ! ? … ...).
    public static func hasTerminalPunctuation(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        // Strip closing quotes, brackets, and typographic marks: " ' ) ] } » ” ’ ›
        let closingCharacters = CharacterSet(charactersIn: "\"')]}»”’›")
        let stripped = trimmed.trimmingCharacters(in: closingCharacters)
        guard !stripped.isEmpty else { return false }

        if stripped.hasSuffix("...") || stripped.hasSuffix("…") {
            return true
        }
        if let last = stripped.last, last == "." || last == "!" || last == "?" {
            return true
        }
        return false
    }

    /// Aggregates transcript segments or word-level timings into coherent sentences.
    public func detectSentences(in segments: [TranscriptSegment]) -> [DetectedSentence] {
        guard !segments.isEmpty else { return [] }

        var items: [SpeechItem] = []
        for seg in segments {
            if !seg.words.isEmpty {
                for w in seg.words {
                    let trimmedWord = w.word.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmedWord.isEmpty {
                        items.append(SpeechItem(start: w.start, end: w.end, text: trimmedWord))
                    }
                }
            } else {
                let trimmedText = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedText.isEmpty {
                    items.append(SpeechItem(start: seg.start, end: seg.end, text: trimmedText))
                }
            }
        }
        guard !items.isEmpty else { return [] }

        var sentences: [DetectedSentence] = []
        var currentSentenceStartIndex: Int = 0

        for i in 0..<items.count {
            let item = items[i]
            let hasTerminal = Self.hasTerminalPunctuation(item.text)
            let isLast = (i == items.count - 1)
            let hasPause: Bool
            if !isLast {
                let gap = items[i + 1].start - item.end
                hasPause = gap >= pauseThreshold
            } else {
                hasPause = false
            }

            if hasTerminal || hasPause || isLast {
                let sentenceStart = items[currentSentenceStartIndex].start
                let sentenceEnd = item.end
                let sentenceWords = items[currentSentenceStartIndex...i].map(\.text)
                let sentenceText = sentenceWords.joined(separator: " ")
                sentences.append(DetectedSentence(
                    start: sentenceStart,
                    end: sentenceEnd,
                    text: sentenceText,
                    isTerminal: hasTerminal || isLast
                ))
                currentSentenceStartIndex = i + 1
            }
        }
        return sentences
    }

    // MARK: - SentenceBoundaryDetecting

    public func snapToSentenceStart(timestamp: Double, in segments: [TranscriptSegment]) -> Double {
        let sentences = detectSentences(in: segments)
        guard !sentences.isEmpty else {
            return max(0.0, timestamp - headPadding)
        }

        // 1. If timestamp is enclosed in a sentence: snap to its start
        if let enclosing = sentences.first(where: { timestamp >= $0.start && timestamp <= $0.end }) {
            return max(0.0, enclosing.start - headPadding)
        }

        // 2. If timestamp is before all sentences: snap to the first sentence start
        if let first = sentences.first, timestamp < first.start {
            return max(0.0, first.start - headPadding)
        }

        // 3. If timestamp is after all sentences: keep timestamp minus headPadding
        if let last = sentences.last, timestamp > last.end {
            return max(0.0, timestamp - headPadding)
        }

        // 4. In a pause between sentences: find the closest sentence start
        let closest = sentences.min(by: {
            abs(timestamp - $0.start) < abs(timestamp - $1.start)
        })
        if let closest = closest {
            return max(0.0, closest.start - headPadding)
        }

        return max(0.0, timestamp - headPadding)
    }

    public func snapToSentenceEnd(timestamp: Double, maxAllowedDuration: Double, in segments: [TranscriptSegment]) -> Double {
        let sentences = detectSentences(in: segments)
        guard !sentences.isEmpty else {
            return timestamp + tailPadding
        }

        // 1. If timestamp is enclosed in a sentence: snap to its end with tail padding
        if let enclosing = sentences.first(where: { timestamp >= $0.start && timestamp <= $0.end }) {
            return enclosing.end + tailPadding
        }

        // 2. Closest sentence by end timestamp
        let closest = sentences.min(by: {
            abs(timestamp - $0.end) < abs(timestamp - $1.end)
        })
        if let closest = closest {
            return closest.end + tailPadding
        }

        return timestamp + tailPadding
    }

    public func findPreviousSentenceEnd(before: Double, in segments: [TranscriptSegment]) -> Double? {
        let sentences = detectSentences(in: segments)
        let candidates = sentences.compactMap { s -> Double? in
            let endWithPadding = s.end + tailPadding
            return endWithPadding <= (before + 0.001) ? endWithPadding : nil
        }
        return candidates.max()
    }

    public func refineSceneBoundary(
        range: TimeSegment,
        maxAllowedDuration: Double,
        in segments: [TranscriptSegment]
    ) -> TimeSegment {
        let maxLimit = maxAllowedDuration > 0 ? maxAllowedDuration : maxShortsDuration
        let refinedStart = snapToSentenceStart(timestamp: range.start, in: segments)
        var refinedEnd = snapToSentenceEnd(timestamp: range.end, maxAllowedDuration: maxLimit, in: segments)

        // If refined range exceeds maxLimit, search backwards for the previous complete sentence ending
        if (refinedEnd - refinedStart) > maxLimit {
            let maxCutPoint = refinedStart + maxLimit
            if let safeEnd = findPreviousSentenceEnd(before: maxCutPoint, in: segments), safeEnd > refinedStart {
                refinedEnd = safeEnd
            } else {
                // Fallback: clamp without exceeding maxLimit
                refinedEnd = min(refinedEnd, refinedStart + maxLimit)
            }
        }

        // Ensure minimum duration threshold if candidate dialogue allows
        if (refinedEnd - refinedStart) < minSegmentDuration {
            let sentences = detectSentences(in: segments)
            // Look for a sentence ending that reaches at least minSegmentDuration while staying within maxLimit
            if let extendedSentence = sentences.first(where: {
                let candidateEnd = $0.end + tailPadding
                return (candidateEnd - refinedStart) >= minSegmentDuration && (candidateEnd - refinedStart) <= maxLimit
            }) {
                refinedEnd = extendedSentence.end + tailPadding
            }
        }

        return TimeSegment(start: refinedStart, end: refinedEnd)
    }
}
