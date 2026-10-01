import Foundation

/// Word timestamp within a spoken segment (SOLID: Domain Model).
public struct WordTimestamp: Codable, Sendable, Equatable {
    public let word: String
    public let start: Double
    public let end: Double

    public init(word: String, start: Double, end: Double) {
        self.word = word
        self.start = start
        self.end = end
    }
}
