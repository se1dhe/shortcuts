import Testing
import Foundation
@testable import Shortcast

@Suite("DirectorPromptBudget Tests")
struct DirectorPromptBudgetTests {

    @Test("Text within budget passes through unchanged")
    func smallTextUnchanged() {
        let text = "первая строка\nвторая строка\nтретья строка"
        #expect(DirectorPromptBudget.downsample(text) == text)
    }

    @Test("Oversized text is downsampled within the prefill budget, keeping head and tail")
    func oversizedTextFitsBudget() {
        var lines: [String] = []
        for i in 0..<2000 {
            lines.append(String(format: "[%02d:%02d] Реплика персонажа номер %04d с несколькими словами про смысл жизни и судьбу.", i / 60, i % 60, i))
        }
        let big = lines.joined(separator: "\n")
        #expect(big.count > DirectorPromptBudget.maxPromptChars)

        let result = DirectorPromptBudget.downsample(big)
        #expect(result.count <= DirectorPromptBudget.maxPromptChars)
        #expect(result.contains(lines.first!))

        let sourceLast = lastTimecodeSeconds(in: big)
        let resultLast = lastTimecodeSeconds(in: result)
        #expect(resultLast >= sourceLast * 0.9, "downsample must keep chronology tail coverage")
    }

    @Test("Single huge line without newlines is hard-truncated to budget")
    func singleLineTruncated() {
        let text = String(repeating: "а", count: 25_000)
        let result = DirectorPromptBudget.downsample(text)
        #expect(result.count == DirectorPromptBudget.maxPromptChars)
    }

    @Test("Budget leaves KV-window headroom: 6000 prompt + system + output fits 8192")
    func budgetLeavesKVHeadroom() {
        #expect(DirectorPromptBudget.maxPromptTokens == 6000)
        #expect(DirectorPromptBudget.maxPromptChars == 18_000)
    }

    private func lastTimecodeSeconds(in text: String) -> Double {
        guard let regex = try? NSRegularExpression(pattern: #"\[(\d{1,2}):(\d{2})"#) else { return 0 }
        let ns = NSRange(text.startIndex..<text.endIndex, in: text)
        var last: Double = 0
        regex.enumerateMatches(in: text, range: ns) { match, _, _ in
            guard let match,
                  let minR = Range(match.range(at: 1), in: text),
                  let secR = Range(match.range(at: 2), in: text),
                  let m = Double(text[minR]), let s = Double(text[secR]) else { return }
            last = max(last, m * 60 + s)
        }
        return last
    }
}
