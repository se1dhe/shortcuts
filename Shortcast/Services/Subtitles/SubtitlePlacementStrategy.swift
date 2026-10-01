import Foundation
import CoreGraphics

/// Protocol for subtitle placement and face collision avoidance (SOLID: SRP/DIP).
public protocol SubtitlePlacementStrategyProtocol: Sendable {
    func calculateSafeZone(
        faceBoxes: [CGRect],
        videoSize: CGSize,
        currentTime: Double,
        lastPlacement: SubtitlePlacementDecision?
    ) -> SubtitlePlacementDecision
}

public struct SubtitlePlacementDecision: Sendable, Equatable {
    public let verticalNormalizedY: CGFloat // 0.0 (top) to 1.0 (bottom)
    public let horizontalAlign: String // "center", "left", "right"
    public let decisionTime: Double
    public let safeWidth: CGFloat

    public init(
        verticalNormalizedY: CGFloat,
        horizontalAlign: String = "center",
        decisionTime: Double,
        safeWidth: CGFloat = 760.0
    ) {
        self.verticalNormalizedY = verticalNormalizedY
        self.horizontalAlign = horizontalAlign
        self.decisionTime = decisionTime
        self.safeWidth = safeWidth
    }
}

/// Robust placement strategy with temporal hysteresis (no jarring leaps) and strict face protection.
public final class SubtitlePlacementStrategy: SubtitlePlacementStrategyProtocol, @unchecked Sendable {
    public static let shared = SubtitlePlacementStrategy()

    /// Minimum time in seconds to hold a vertical position before allowing a reposition jump.
    public let minimumHoldDuration: Double = 4.0

    /// Default vertical position in the lower safe third (safely below face, above bottom UI).
    public let defaultLowerY: CGFloat = 0.72

    public init() {}

    public func calculateSafeZone(
        faceBoxes: [CGRect],
        videoSize: CGSize,
        currentTime: Double,
        lastPlacement: SubtitlePlacementDecision?
    ) -> SubtitlePlacementDecision {
        // If we recently changed position within minimumHoldDuration, hold the previous decision
        if let last = lastPlacement, (currentTime - last.decisionTime) < minimumHoldDuration {
            return SubtitlePlacementDecision(
                verticalNormalizedY: last.verticalNormalizedY,
                horizontalAlign: last.horizontalAlign,
                decisionTime: last.decisionTime,
                safeWidth: last.safeWidth
            )
        }

        // Check if faces occupy the lower or upper area
        // In Vision coordinates, y=0 is bottom, y=1 is top.
        // We convert to normalized video display coordinates (y=0 top, y=1 bottom).
        var hasFaceInLowerThird = false
        var hasFaceInUpperArea = false

        for box in faceBoxes {
            // box is in Vision coordinates: origin at bottom-left
            let displayY = 1.0 - (box.origin.y + box.height) // top edge of face in display coords
            let displayBottom = 1.0 - box.origin.y // bottom edge of face in display coords

            if displayBottom > 0.65 {
                hasFaceInLowerThird = true
            }
            if displayY < 0.55 {
                hasFaceInUpperArea = true
            }
        }

        // Rule 1: Never place subtitles on top of a face in the upper half!
        // If there's an upper face (like Judge Palmer talking), ALWAYS keep subtitles at default lower third
        if hasFaceInUpperArea && !hasFaceInLowerThird {
            return SubtitlePlacementDecision(
                verticalNormalizedY: defaultLowerY,
                horizontalAlign: "center",
                decisionTime: currentTime,
                safeWidth: 760.0
            )
        }

        // Rule 2: If face is in lower third but upper third is completely clear, place at top safe zone
        if hasFaceInLowerThird && !hasFaceInUpperArea {
            return SubtitlePlacementDecision(
                verticalNormalizedY: 0.18,
                horizontalAlign: "center",
                decisionTime: currentTime,
                safeWidth: 760.0
            )
        }

        // Default: Stable lower-third position
        return SubtitlePlacementDecision(
            verticalNormalizedY: defaultLowerY,
            horizontalAlign: "center",
            decisionTime: currentTime,
            safeWidth: 760.0
        )
    }
}
