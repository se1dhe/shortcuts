import Foundation

/// Represents a continuous cut within a multi-segment cinema edit.
struct TimeSegment: Codable, Sendable, Equatable {
    var start: Double
    var end: Double

    init(start: Double, end: Double) {
        self.start = start
        self.end = end
    }

    var duration: Double { max(end - start, 0) }
}
