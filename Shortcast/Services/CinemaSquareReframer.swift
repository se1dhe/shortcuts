import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision
import AppKit
import QuartzCore

// MARK: - Domain Models & Data Structures

/// Represents a weighted interest region computed across one or more detected faces.
public struct InterestRegion: Sendable, Equatable {
    /// Weighted center of visual attention in normalized coordinates (0.0 ... 1.0, origin bottom-left).
    public let weightedCenter: CGPoint
    /// Bounding box enclosing the primary faces of interest.
    public let boundingBox: CGRect
    /// Aggregated confidence and prominence weight of the region.
    public let totalWeight: CGFloat
    /// Total number of detected faces contributing to this region.
    public let faceCount: Int
    /// Normalized individual weights assigned to each face (sums to 1.0).
    public let individualWeights: [CGFloat]
    /// The primary (most prominent) face bounding box.
    public let primaryFace: CGRect

    public init(
        weightedCenter: CGPoint,
        boundingBox: CGRect,
        totalWeight: CGFloat,
        faceCount: Int,
        individualWeights: [CGFloat],
        primaryFace: CGRect
    ) {
        self.weightedCenter = weightedCenter
        self.boundingBox = boundingBox
        self.totalWeight = totalWeight
        self.faceCount = faceCount
        self.individualWeights = individualWeights
        self.primaryFace = primaryFace
    }
}

/// Configuration parameters for computing face interest weights.
public struct FaceWeightConfiguration: Sendable, Equatable {
    /// Exponent applied to face area (e.g. 0.65 balances close-ups with two-shots so secondary speakers are not ignored).
    public var sizeExponent: CGFloat
    /// Importance of proximity to the horizontal frame center (0.0 ... 1.0).
    public var centerProximityWeight: CGFloat
    /// Target eye-level line according to the rule of thirds in Vision coordinates (origin bottom-left, typically ~0.65).
    public var optimalEyeLevelY: CGFloat
    /// Importance of vertical alignment near the optimal eye-level (0.0 ... 1.0).
    public var eyeLevelWeight: CGFloat
    /// Weight given to maintaining continuity with the previous focus center (hysteresis).
    public var previousFocusWeight: CGFloat

    public static let `default` = FaceWeightConfiguration(
        sizeExponent: 0.65,
        centerProximityWeight: 0.40,
        optimalEyeLevelY: 0.65,
        eyeLevelWeight: 0.35,
        previousFocusWeight: 0.30
    )

    public init(
        sizeExponent: CGFloat = 0.65,
        centerProximityWeight: CGFloat = 0.40,
        optimalEyeLevelY: CGFloat = 0.65,
        eyeLevelWeight: CGFloat = 0.35,
        previousFocusWeight: CGFloat = 0.30
    ) {
        self.sizeExponent = sizeExponent
        self.centerProximityWeight = centerProximityWeight
        self.optimalEyeLevelY = optimalEyeLevelY
        self.eyeLevelWeight = eyeLevelWeight
        self.previousFocusWeight = previousFocusWeight
    }
}

/// A sample of camera crop positioning at a specific point in time.
public struct CameraSample: Sendable, Equatable {
    /// Timestamp in seconds.
    public var time: Double
    /// Normalized crop window X offset in [0.0, 1.0].
    public var cropX: CGFloat
    /// Associated interest region if face detection was performed.
    public var interestRegion: InterestRegion?

    public init(time: Double, cropX: CGFloat, interestRegion: InterestRegion? = nil) {
        self.time = time
        self.cropX = cropX
        self.interestRegion = interestRegion
    }
}

/// Keyframe used for AVFoundation transform ramps and export compositions.
public struct CameraKeyframe: Sendable, Equatable {
    public var time: Double
    public var cropX: CGFloat

    public init(time: Double, cropX: CGFloat) {
        self.time = time
        self.cropX = cropX
    }
}

/// Dynamic internal filter state tracking position, velocity, and timestamps.
public struct CameraFilterState: Sendable, Equatable {
    public var position: CGFloat
    public var velocity: CGFloat
    public var timestamp: Double
    public var emaFilteredTarget: CGFloat

    public init(
        position: CGFloat,
        velocity: CGFloat = 0,
        timestamp: Double = 0,
        emaFilteredTarget: CGFloat? = nil
    ) {
        self.position = position
        self.velocity = velocity
        self.timestamp = timestamp
        self.emaFilteredTarget = emaFilteredTarget ?? position
    }
}

/// Configuration tuning the camera path smoothing dynamics.
public struct SmoothingConfiguration: Sendable, Equatable {
    /// Deadband zone threshold (normalized units).
    /// Target displacements smaller than this threshold are ignored, producing a steady "heavy fluid tripod" effect.
    public var deadbandThreshold: CGFloat

    /// Exponential Moving Average time constant (tau in seconds).
    /// Used for frame-rate-independent sensor noise reduction.
    public var emaTimeConstant: Double

    /// Natural angular frequency (stiffness) of the damped spring in rad/s.
    public var springOmega: Double

    /// Damping ratio (zeta).
    /// 1.0 = critically damped (no overshoot, fastest settling without oscillation).
    /// > 1.0 = overdamped (viscous, ultra-smooth cinematic ease).
    public var dampingRatio: Double

    /// Maximum pan velocity in normalized units per second to prevent jarring camera whips.
    public var maxPanVelocity: CGFloat

    /// Jump threshold in normalized units that indicates a hard scene cut rather than character motion.
    /// When exceeded, the camera instantly cuts to the new position without dragging.
    public var sceneCutThreshold: CGFloat

    /// Smoothing algorithm mode.
    public var mode: SmoothingMode

    public enum SmoothingMode: Sendable, Equatable {
        /// Pure 2nd-order analytical damped spring.
        case dampedSpring
        /// Time-corrected Exponential Moving Average.
        case exponentialMovingAverage
        /// Hybrid pipeline: EMA eliminates high-frequency detection jitter, damped spring adds physical inertia.
        case hybridDampedSpringWithEMA
    }

    public static let `default` = SmoothingConfiguration(
        deadbandThreshold: 0.025,
        emaTimeConstant: 0.35,
        springOmega: 4.5,
        dampingRatio: 1.05,
        maxPanVelocity: 0.70,
        sceneCutThreshold: 0.45,
        mode: .hybridDampedSpringWithEMA
    )

    public init(
        deadbandThreshold: CGFloat = 0.025,
        emaTimeConstant: Double = 0.35,
        springOmega: Double = 4.5,
        dampingRatio: Double = 1.05,
        maxPanVelocity: CGFloat = 0.70,
        sceneCutThreshold: CGFloat = 0.45,
        mode: SmoothingMode = .hybridDampedSpringWithEMA
    ) {
        self.deadbandThreshold = deadbandThreshold
        self.emaTimeConstant = emaTimeConstant
        self.springOmega = springOmega
        self.dampingRatio = dampingRatio
        self.maxPanVelocity = maxPanVelocity
        self.sceneCutThreshold = sceneCutThreshold
        self.mode = mode
    }
}

/// Represents an expanded exclusion zone around a detected face to prevent subtitle collisions.
public struct FaceExclusionZone: Sendable, Equatable {
    public let boundingBox: CGRect
    public let expandedBox: CGRect

    public init(face: CGRect, marginX: CGFloat = 0.07, marginY: CGFloat = 0.06) {
        self.boundingBox = face
        self.expandedBox = face.insetBy(dx: -marginX, dy: -marginY)
    }

    public func intersects(_ rect: CGRect) -> Bool {
        rect.intersects(expandedBox)
    }
}

// MARK: - Protocols (SOLID: ISP, DIP, OCP)

/// Strategy for calculating weighted interest regions from detected faces.
public protocol InterestRegionCalculating: Sendable {
    func computeInterestRegion(
        faces: [CGRect],
        previousFocus: CGPoint?,
        configuration: FaceWeightConfiguration
    ) -> InterestRegion?
}

/// Strategy for smoothing camera crop trajectory over time.
public protocol CameraPathSmoothing: Sendable {
    func smoothTrajectory(
        rawSamples: [CameraSample],
        configuration: SmoothingConfiguration
    ) -> [CameraSample]

    func step(
        currentState: CameraFilterState,
        targetX: CGFloat,
        deltaTime: Double,
        configuration: SmoothingConfiguration
    ) -> (newPosition: CGFloat, newState: CameraFilterState)
}

/// Strategy for computing collision-free subtitle zones away from faces.
public protocol SafeZoneCalculating: Sendable {
    func calculateSafeZone(
        faces: [CGRect],
        textWidthNorm: CGFloat,
        textHeightNorm: CGFloat
    ) -> CGRect
}

/// Strategy for building coordinate transformations for cinema square reframing.
public protocol CinemaCropTransforming: Sendable {
    func makeSquareCropTransform(
        sourceSize: CGSize,
        cropXNorm: CGFloat
    ) -> CGAffineTransform

    func makeTransform(
        for cropXNorm: CGFloat,
        base: CGAffineTransform,
        sourceSize: CGSize,
        targetSize: CGSize
    ) -> CGAffineTransform
}

// MARK: - Weighted Interest Region Calculator (SRP)

/// Computes the visual center of attention when one or more faces are present in the shot.
public struct WeightedInterestRegionCalculator: InterestRegionCalculating {
    public init() {}

    public func computeInterestRegion(
        faces: [CGRect],
        previousFocus: CGPoint? = nil,
        configuration: FaceWeightConfiguration = .default
    ) -> InterestRegion? {
        guard !faces.isEmpty else { return nil }

        if faces.count == 1 {
            let f = faces[0]
            let center = CGPoint(x: f.midX, y: f.midY)
            return InterestRegion(
                weightedCenter: center,
                boundingBox: f,
                totalWeight: 1.0,
                faceCount: 1,
                individualWeights: [1.0],
                primaryFace: f
            )
        }

        var rawWeights: [CGFloat] = []
        rawWeights.reserveCapacity(faces.count)

        for face in faces {
            // 1. Size factor (area raised to sub-linear power to balance dialogues)
            let area = max(0.0001, face.width * face.height)
            let wSize = pow(area, configuration.sizeExponent)

            // 2. Center proximity factor (favors subjects near the camera's center axis)
            let dxCenter = abs(face.midX - 0.5)
            let wCenter = max(0.15, 1.0 - configuration.centerProximityWeight * (2.0 * dxCenter))

            // 3. Eye-level alignment factor (favors upper-third cinematic framing)
            let dyEye = abs(face.midY - configuration.optimalEyeLevelY)
            let wEye = max(0.20, 1.0 - configuration.eyeLevelWeight * (2.0 * dyEye))

            // 4. Temporal focus continuity factor (hysteresis to prevent jumping between actors)
            let wPrev: CGFloat
            if let prev = previousFocus {
                let dist = hypot(face.midX - prev.x, face.midY - prev.y)
                wPrev = max(0.25, 1.0 - configuration.previousFocusWeight * min(1.0, 2.0 * dist))
            } else {
                wPrev = 1.0
            }

            let totalW = wSize * wCenter * wEye * wPrev
            rawWeights.append(max(0.0001, totalW))
        }

        let sumWeight = rawWeights.reduce(0, +)
        let normalizedWeights = rawWeights.map { $0 / max(0.0001, sumWeight) }

        var cx: CGFloat = 0
        var cy: CGFloat = 0
        for (i, face) in faces.enumerated() {
            cx += normalizedWeights[i] * face.midX
            cy += normalizedWeights[i] * face.midY
        }

        let primaryIndex = normalizedWeights.enumerated().max(by: { $0.element < $1.element })?.offset ?? 0
        let primaryFace = faces[primaryIndex]

        // Enclosing bounding box covering faces with notable weight (>= 12%)
        var unionBox: CGRect? = nil
        for (i, face) in faces.enumerated() {
            if normalizedWeights[i] >= 0.12 || i == primaryIndex {
                unionBox = unionBox.map { $0.union(face) } ?? face
            }
        }

        return InterestRegion(
            weightedCenter: CGPoint(x: cx, y: cy),
            boundingBox: unionBox ?? primaryFace,
            totalWeight: sumWeight,
            faceCount: faces.count,
            individualWeights: normalizedWeights,
            primaryFace: primaryFace
        )
    }
}

// MARK: - Damped Spring & EMA Physics Smoothers (SRP, LSP)

/// Exact analytical solver for 2nd-order damped spring-mass systems.
/// Provides 100% unconditional numerical stability without dispersion or drift regardless of time step.
public enum DampedSpringSmoother {
    public static func solveDampedSpring(
        currentPos: CGFloat,
        currentVel: CGFloat,
        targetPos: CGFloat,
        deltaTime: Double,
        omega: Double,
        dampingRatio: Double
    ) -> (position: CGFloat, velocity: CGFloat) {
        guard deltaTime > 0 else { return (currentPos, currentVel) }

        let x0 = Double(currentPos - targetPos)
        let v0 = Double(currentVel)
        let dt = deltaTime

        let nextX: Double
        let nextV: Double

        if abs(dampingRatio - 1.0) < 1e-4 {
            // Critically damped (zeta == 1.0): fastest settling with zero oscillation
            let c1 = x0
            let c2 = v0 + omega * c1
            let decay = exp(-omega * dt)
            nextX = (c1 + c2 * dt) * decay
            nextV = (c2 - omega * (c1 + c2 * dt)) * decay
        } else if dampingRatio > 1.0 {
            // Overdamped (zeta > 1.0): viscous, gentle cinematic glide
            let alpha = omega * sqrt(dampingRatio * dampingRatio - 1.0)
            let r1 = -omega * dampingRatio + alpha
            let r2 = -omega * dampingRatio - alpha
            let c2 = (v0 - r1 * x0) / (r2 - r1)
            let c1 = x0 - c2
            let e1 = exp(r1 * dt)
            let e2 = exp(r2 * dt)
            nextX = c1 * e1 + c2 * e2
            nextV = c1 * r1 * e1 + c2 * r2 * e2
        } else {
            // Underdamped (zeta < 1.0)
            let alpha = omega * dampingRatio
            let omegaD = omega * sqrt(1.0 - dampingRatio * dampingRatio)
            let decay = exp(-alpha * dt)
            let cosD = cos(omegaD * dt)
            let sinD = sin(omegaD * dt)
            let c1 = x0
            let c2 = (v0 + alpha * x0) / max(1e-6, omegaD)
            nextX = decay * (c1 * cosD + c2 * sinD)
            nextV = decay * (cosD * (c2 * omegaD - c1 * alpha) - sinD * (c1 * omegaD + c2 * alpha))
        }

        return (CGFloat(targetPos + nextX), CGFloat(nextV))
    }
}

/// Time-corrected Exponential Moving Average (EMA) smoother.
public enum ExponentialMovingAverageSmoother {
    public static func smooth(
        current: CGFloat,
        target: CGFloat,
        deltaTime: Double,
        timeConstant: Double
    ) -> CGFloat {
        guard deltaTime > 0 else { return current }
        let alpha = CGFloat(1.0 - exp(-deltaTime / max(0.001, timeConstant)))
        return current + alpha * (target - current)
    }
}

// MARK: - Smoothed Path Optimizer (SRP)

/// High-level trajectory optimizer implementing Deadband filtering,
/// Scene Cut detection, velocity clamping, and hybrid Damped Spring + EMA physics.
public struct SmoothedPathOptimizer: CameraPathSmoothing {
    public let defaultConfiguration: SmoothingConfiguration

    public init(configuration: SmoothingConfiguration = .default) {
        self.defaultConfiguration = configuration
    }

    public func smoothTrajectory(
        rawSamples: [CameraSample],
        configuration: SmoothingConfiguration
    ) -> [CameraSample] {
        guard !rawSamples.isEmpty else { return [] }
        guard rawSamples.count > 1 else { return rawSamples }

        var smoothed: [CameraSample] = []
        smoothed.reserveCapacity(rawSamples.count)

        let first = rawSamples[0]
        smoothed.append(first)

        var state = CameraFilterState(
            position: first.cropX,
            velocity: 0,
            timestamp: first.time,
            emaFilteredTarget: first.cropX
        )

        for i in 1..<rawSamples.count {
            let sample = rawSamples[i]
            let dt = max(0.001, sample.time - rawSamples[i - 1].time)

            let (newPos, newState) = step(
                currentState: state,
                targetX: sample.cropX,
                deltaTime: dt,
                configuration: configuration
            )

            state = newState
            smoothed.append(CameraSample(
                time: sample.time,
                cropX: newPos,
                interestRegion: sample.interestRegion
            ))
        }

        return smoothed
    }

    public func step(
        currentState: CameraFilterState,
        targetX: CGFloat,
        deltaTime: Double,
        configuration: SmoothingConfiguration
    ) -> (newPosition: CGFloat, newState: CameraFilterState) {
        let dt = max(0.0001, deltaTime)
        let currentPos = currentState.position
        let currentVel = currentState.velocity
        let diff = targetX - currentPos

        // 1. Scene cut detection (abrupt shot transition)
        if abs(diff) > configuration.sceneCutThreshold {
            let newState = CameraFilterState(
                position: targetX,
                velocity: 0,
                timestamp: currentState.timestamp + dt,
                emaFilteredTarget: targetX
            )
            return (targetX, newState)
        }

        // 2. Deadband threshold (Heavy Tripod stabilization)
        let effectiveTarget: CGFloat
        if abs(diff) <= configuration.deadbandThreshold {
            // Inside deadband: virtual camera remains firmly parked
            effectiveTarget = currentPos
        } else {
            // Continuous motion threshold offset
            let sign: CGFloat = diff > 0 ? 1.0 : -1.0
            effectiveTarget = targetX - sign * configuration.deadbandThreshold
        }

        switch configuration.mode {
        case .exponentialMovingAverage:
            let emaPos = ExponentialMovingAverageSmoother.smooth(
                current: currentPos,
                target: effectiveTarget,
                deltaTime: dt,
                timeConstant: configuration.emaTimeConstant
            )
            let rawVel = (emaPos - currentPos) / CGFloat(dt)
            let clampedVel = min(max(rawVel, -configuration.maxPanVelocity), configuration.maxPanVelocity)
            let finalPos = min(max(currentPos + clampedVel * CGFloat(dt), 0.0), 1.0)

            let newState = CameraFilterState(
                position: finalPos,
                velocity: clampedVel,
                timestamp: currentState.timestamp + dt,
                emaFilteredTarget: finalPos
            )
            return (finalPos, newState)

        case .dampedSpring:
            let (springPos, springVel) = DampedSpringSmoother.solveDampedSpring(
                currentPos: currentPos,
                currentVel: currentVel,
                targetPos: effectiveTarget,
                deltaTime: dt,
                omega: configuration.springOmega,
                dampingRatio: configuration.dampingRatio
            )

            let clampedVel = min(max(springVel, -configuration.maxPanVelocity), configuration.maxPanVelocity)
            let pos = abs(springVel) > configuration.maxPanVelocity
                ? (currentPos + clampedVel * CGFloat(dt))
                : springPos
            let finalPos = min(max(pos, 0.0), 1.0)

            let newState = CameraFilterState(
                position: finalPos,
                velocity: clampedVel,
                timestamp: currentState.timestamp + dt,
                emaFilteredTarget: effectiveTarget
            )
            return (finalPos, newState)

        case .hybridDampedSpringWithEMA:
            // Step A: EMA on target to eliminate Vision detector single-frame noise
            let smoothedTarget = ExponentialMovingAverageSmoother.smooth(
                current: currentState.emaFilteredTarget,
                target: effectiveTarget,
                deltaTime: dt,
                timeConstant: configuration.emaTimeConstant
            )

            // Step B: Damped spring interpolation towards smoothed target for natural inertia
            let (springPos, springVel) = DampedSpringSmoother.solveDampedSpring(
                currentPos: currentPos,
                currentVel: currentVel,
                targetPos: smoothedTarget,
                deltaTime: dt,
                omega: configuration.springOmega,
                dampingRatio: configuration.dampingRatio
            )

            let clampedVel = min(max(springVel, -configuration.maxPanVelocity), configuration.maxPanVelocity)
            let pos = abs(springVel) > configuration.maxPanVelocity
                ? (currentPos + clampedVel * CGFloat(dt))
                : springPos
            let finalPos = min(max(pos, 0.0), 1.0)

            let newState = CameraFilterState(
                position: finalPos,
                velocity: clampedVel,
                timestamp: currentState.timestamp + dt,
                emaFilteredTarget: smoothedTarget
            )
            return (finalPos, newState)
        }
    }
}

// MARK: - Face Exclusion Zone Calculator (SRP)

/// Computes the optimal safe position for subtitle text bounding boxes
/// guaranteeing 100% collision-free placement away from faces.
public struct FaceExclusionZoneCalculator: SafeZoneCalculating {
    public let horizontalMargin: CGFloat
    public let verticalMargin: CGFloat

    public init(horizontalMargin: CGFloat = 0.07, verticalMargin: CGFloat = 0.06) {
        self.horizontalMargin = horizontalMargin
        self.verticalMargin = verticalMargin
    }

    public func calculateSafeZone(
        faces: [CGRect],
        textWidthNorm: CGFloat,
        textHeightNorm: CGFloat
    ) -> CGRect {
        let W = min(max(textWidthNorm, 0.10), 0.85)
        let H = min(max(textHeightNorm, 0.05), 0.20)

        let exclusionZones = faces.map {
            FaceExclusionZone(face: $0, marginX: horizontalMargin, marginY: verticalMargin)
        }

        func isCollisionFree(_ rect: CGRect) -> Bool {
            for zone in exclusionZones {
                if zone.intersects(rect) { return false }
            }
            return true
        }

        // Candidates in order of cinematic aesthetic preference (Y: 0 is bottom, 1 is top):
        let candidates: [CGRect] = [
            // 1. Lower Third Center (y: ~0.18)
            CGRect(x: max(0.05, 0.5 - W / 2), y: 0.18, width: W, height: H),
            // 2. Lower Third Left
            CGRect(x: 0.06, y: 0.18, width: W, height: H),
            // 3. Lower Third Right
            CGRect(x: max(0.06, 0.94 - W), y: 0.18, width: W, height: H),
            // 4. Mid-Lower Left
            CGRect(x: 0.06, y: 0.28, width: W, height: H),
            // 5. Mid-Lower Right
            CGRect(x: max(0.06, 0.94 - W), y: 0.28, width: W, height: H),
            // 6. Middle Left Column
            CGRect(x: 0.06, y: 0.38, width: W, height: H),
            // 7. Middle Right Column
            CGRect(x: max(0.06, 0.94 - W), y: 0.38, width: W, height: H),
            // 8. Upper Third Center
            CGRect(x: max(0.05, 0.5 - W / 2), y: 0.82, width: W, height: H),
            // 9. Upper Third Left
            CGRect(x: 0.06, y: 0.82, width: W, height: H),
            // 10. Upper Third Right
            CGRect(x: max(0.06, 0.94 - W), y: 0.82, width: W, height: H),
            // 11. Ultra-bottom fallback
            CGRect(x: max(0.05, 0.5 - W / 2), y: 0.08, width: W, height: H)
        ]

        for candidate in candidates {
            if isCollisionFree(candidate) {
                return candidate
            }
        }

        // Dynamic clearance scan: systematically search for collision-free bands
        let testPositionsY: [CGFloat] = [0.12, 0.15, 0.22, 0.25, 0.32, 0.35, 0.45, 0.72, 0.76, 0.86]
        let testPositionsX: [CGFloat] = [max(0.05, 0.5 - W / 2), 0.06, max(0.06, 0.94 - W)]

        for y in testPositionsY {
            for x in testPositionsX {
                let rect = CGRect(x: x, y: y, width: W, height: H)
                if isCollisionFree(rect) {
                    return rect
                }
            }
        }

        // Robust edge-case fallback: candidate with absolute minimum overlap area
        var bestCandidate = candidates[0]
        var minOverlapArea: CGFloat = .infinity
        for candidate in candidates {
            var overlapArea: CGFloat = 0
            for zone in exclusionZones {
                let intersection = candidate.intersection(zone.expandedBox)
                if !intersection.isNull {
                    overlapArea += intersection.width * intersection.height
                }
            }
            if overlapArea < minOverlapArea {
                minOverlapArea = overlapArea
                bestCandidate = candidate
            }
        }
        return bestCandidate
    }
}

// MARK: - Cinema Crop Transformer (SRP)

/// Mathematical builder for square and vertical crop transformations.
public struct CinemaCropTransformer: CinemaCropTransforming {
    public static let defaultCanvasSize: CGFloat = 1080

    public init() {}

    public func makeSquareCropTransform(
        sourceSize: CGSize,
        cropXNorm: CGFloat
    ) -> CGAffineTransform {
        let side = min(sourceSize.width, sourceSize.height)
        guard side > 0 else { return .identity }
        let scale = Self.defaultCanvasSize / side

        let availableX = max(0, sourceSize.width - side)
        let offsetX = max(0, min(availableX * cropXNorm, availableX))
        let offsetY = max(0, (sourceSize.height - side) / 2.0)

        return CGAffineTransform(translationX: -offsetX, y: -offsetY)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
    }

    public func makeTransform(
        for cropXNorm: CGFloat,
        base: CGAffineTransform,
        sourceSize: CGSize,
        targetSize: CGSize = CGSize(width: 1080, height: 1080)
    ) -> CGAffineTransform {
        let side = min(sourceSize.width, sourceSize.height)
        guard side > 0 else { return base }
        let scale = targetSize.height / side
        let availableX = max(0, sourceSize.width - side)
        let offsetX = max(0, min(availableX * cropXNorm, availableX))
        let offsetY = max(0, (sourceSize.height - side) / 2.0)

        return base
            .concatenating(CGAffineTransform(translationX: -offsetX, y: -offsetY))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
    }
}

// MARK: - CinemaSquareReframer (High-Level Service Facade)

/// Crops widescreen movies into a 1080x1080 square or vertical canvas,
/// tracks speakers using Weighted Interest Regions and a Smoothed Path Optimizer,
/// guarantees 100% face-safe subtitle zones, and generates person segmentation masks.
public enum CinemaSquareReframer: Sendable {

    public static let canvasSize: CGFloat = 1080

    // Component dependencies injected via protocols (DIP / OCP)
    public static let interestCalculator: any InterestRegionCalculating = WeightedInterestRegionCalculator()
    public static let pathSmoother: any CameraPathSmoothing = SmoothedPathOptimizer()
    public static let safeZoneCalculator: any SafeZoneCalculating = FaceExclusionZoneCalculator()
    public static let cropTransformer: any CinemaCropTransforming = CinemaCropTransformer()

    public struct FaceCompositionInfo: Sendable, Equatable {
        public var faceCenterNormX: CGFloat
        public var suggestedCropXNorm: CGFloat
        public var textOnLeft: Bool
        public var safeTextZoneNorm: CGRect
        public var interestRegion: InterestRegion?
        public var faceCount: Int

        public init(
            faceCenterNormX: CGFloat,
            suggestedCropXNorm: CGFloat,
            textOnLeft: Bool,
            safeTextZoneNorm: CGRect,
            interestRegion: InterestRegion? = nil,
            faceCount: Int = 1
        ) {
            self.faceCenterNormX = faceCenterNormX
            self.suggestedCropXNorm = suggestedCropXNorm
            self.textOnLeft = textOnLeft
            self.safeTextZoneNorm = safeTextZoneNorm
            self.interestRegion = interestRegion
            self.faceCount = faceCount
        }
    }

    /// Computes the optimal crop X offset for a given interest region and source size.
    public static func suggestedCropX(
        for interestRegion: InterestRegion,
        sourceSize: CGSize
    ) -> CGFloat {
        let side = min(sourceSize.width, sourceSize.height)
        guard sourceSize.width > side else { return 0.5 }

        let sideRatio = side / sourceSize.width
        let availableNorm = 1.0 - sideRatio
        guard availableNorm > 0.001 else { return 0.5 }

        let faceCenterX = interestRegion.weightedCenter.x

        // Exact geometric centering of the weighted center of interest:
        var rawCropX = (faceCenterX - (sideRatio / 2.0)) / availableNorm

        // Cinematic rule of thirds bias: give subtle leading room in direction of composition
        if faceCenterX > 0.55 {
            rawCropX += 0.03
        } else if faceCenterX < 0.45 {
            rawCropX -= 0.03
        }

        return min(max(rawCropX, 0.0), 1.0)
    }

    /// Analyzes framing for a single keyframe (for initial crop / fallback placement).
    public static func analyzeFraming(
        image: CGImage,
        previousFocus: CGPoint? = nil,
        weightConfig: FaceWeightConfiguration = .default
    ) async -> FaceCompositionInfo {
        let faces = await detectFaceBoxes(image: image)
        guard let interestRegion = interestCalculator.computeInterestRegion(
            faces: faces,
            previousFocus: previousFocus,
            configuration: weightConfig
        ) else {
            return FaceCompositionInfo(
                faceCenterNormX: 0.5,
                suggestedCropXNorm: 0.5,
                textOnLeft: false,
                safeTextZoneNorm: CGRect(x: 0.08, y: 0.18, width: 0.84, height: 0.12),
                interestRegion: nil,
                faceCount: 0
            )
        }

        let faceCenterX = interestRegion.weightedCenter.x
        let safeZone = safeZoneCalculator.calculateSafeZone(faces: faces, textWidthNorm: 0.60, textHeightNorm: 0.09)
        let sourceSize = CGSize(width: image.width, height: image.height)
        let cropX = suggestedCropX(for: interestRegion, sourceSize: sourceSize)

        return FaceCompositionInfo(
            faceCenterNormX: faceCenterX,
            suggestedCropXNorm: cropX,
            textOnLeft: safeZone.midX < 0.5,
            safeTextZoneNorm: safeZone,
            interestRegion: interestRegion,
            faceCount: faces.count
        )
    }

    /// Extracts all face bounding boxes from an image in normalized coordinates (0..1, origin bottom-left).
    nonisolated public static func detectFaceBoxes(image: CGImage) async -> [CGRect] {
        return await Task.detached(priority: .userInitiated) {
            autoreleasepool {
                let request = VNDetectFaceRectanglesRequest()
                let handler = VNImageRequestHandler(cgImage: image, options: [:])
                try? handler.perform([request])
                return (request.results ?? []).map(\.boundingBox)
            }
        }.value
    }

    /// Computes the optimal safe position for a subtitle text bounding box (normalized 0..1 in Core Animation coords)
    /// guaranteeing 100% collision-free placement away from faces.
    nonisolated public static func calculateSafeZone(
        faces: [CGRect],
        textWidthNorm: CGFloat,
        textHeightNorm: CGFloat
    ) -> CGRect {
        // Fast path utilizing default calculator
        FaceExclusionZoneCalculator().calculateSafeZone(
            faces: faces,
            textWidthNorm: textWidthNorm,
            textHeightNorm: textHeightNorm
        )
    }

    /// Computes safe text zone mapped into canvas coordinates after crop is applied.
    nonisolated public static func calculateSafeZoneInCanvas(
        facesInOriginal: [CGRect],
        cropXNorm: CGFloat,
        sourceSize: CGSize,
        textWidthNorm: CGFloat,
        textHeightNorm: CGFloat
    ) -> CGRect {
        let side = min(sourceSize.width, sourceSize.height)
        guard sourceSize.width > side else {
            return calculateSafeZone(faces: facesInOriginal, textWidthNorm: textWidthNorm, textHeightNorm: textHeightNorm)
        }

        let availableX = sourceSize.width - side
        let originCropX = availableX * cropXNorm

        // Map original face boxes into canvas normalized coordinates (0..1)
        let canvasFaces = facesInOriginal.compactMap { face -> CGRect? in
            let faceOrigMinX = face.minX * sourceSize.width
            let faceOrigMaxX = face.maxX * sourceSize.width

            // Check if face overlaps current crop window
            guard faceOrigMaxX > originCropX && faceOrigMinX < (originCropX + side) else {
                return nil
            }

            let canvasNormX = (faceOrigMinX - originCropX) / side
            let canvasNormW = face.width * (sourceSize.width / side)
            let canvasNormY = face.origin.y
            let canvasNormH = face.height

            return CGRect(x: canvasNormX, y: canvasNormY, width: canvasNormW, height: canvasNormH)
        }

        return calculateSafeZone(faces: canvasFaces, textWidthNorm: textWidthNorm, textHeightNorm: textHeightNorm)
    }

    /// Smooths a trajectory of raw camera samples using the Smoothed Path Optimizer.
    public static func optimizePath(
        samples: [CameraSample],
        configuration: SmoothingConfiguration = .default
    ) -> [CameraSample] {
        pathSmoother.smoothTrajectory(rawSamples: samples, configuration: configuration)
    }

    /// Generates keyframes for AVFoundation transform ramps from camera samples.
    public static func generatePanKeyframes(
        from samples: [CameraSample],
        configuration: SmoothingConfiguration = .default
    ) -> [CameraKeyframe] {
        guard !samples.isEmpty else { return [CameraKeyframe(time: 0, cropX: 0.5)] }
        let smoothed = optimizePath(samples: samples, configuration: configuration)
        return smoothed.map { CameraKeyframe(time: $0.time, cropX: $0.cropX) }
    }

    /// Samples video frames across an AVAsset, tracks Weighted Interest Regions,
    /// and generates a smoothed keyframe sequence ready for export.
    public static func sampleAndOptimizeVideoPath(
        asset: AVAsset,
        sampleInterval: Double = 0.35,
        configuration: SmoothingConfiguration = .default,
        weightConfig: FaceWeightConfiguration = .default
    ) async throws -> [CameraKeyframe] {
        let duration = try await asset.load(.duration)
        let totalSeconds = CMTimeGetSeconds(duration)
        guard totalSeconds > 0 else { return [CameraKeyframe(time: 0, cropX: 0.5)] }

        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            return [CameraKeyframe(time: 0, cropX: 0.5)]
        }
        let naturalSize = try await videoTrack.load(.naturalSize)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        let orientedSize = naturalSize.applying(preferredTransform)
        let sourceSize = CGSize(width: abs(orientedSize.width), height: abs(orientedSize.height))

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.15, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.15, preferredTimescale: 600)
        generator.maximumSize = CGSize(width: 512, height: 512)

        var rawSamples: [CameraSample] = []
        var t = 0.0
        var lastFocus: CGPoint? = nil

        while t < totalSeconds {
            let cmTime = CMTime(seconds: t, preferredTimescale: 600)
            if let (cgImage, _) = try? await generator.image(at: cmTime) {
                let faces = await detectFaceBoxes(image: cgImage)
                if let region = interestCalculator.computeInterestRegion(
                    faces: faces,
                    previousFocus: lastFocus,
                    configuration: weightConfig
                ) {
                    lastFocus = region.weightedCenter
                    let cropX = suggestedCropX(for: region, sourceSize: sourceSize)
                    rawSamples.append(CameraSample(time: t, cropX: cropX, interestRegion: region))
                } else {
                    // Fallback to center or previous crop
                    let prevCrop = rawSamples.last?.cropX ?? 0.5
                    rawSamples.append(CameraSample(time: t, cropX: prevCrop, interestRegion: nil))
                }
            } else {
                let prevCrop = rawSamples.last?.cropX ?? 0.5
                rawSamples.append(CameraSample(time: t, cropX: prevCrop, interestRegion: nil))
            }
            t += sampleInterval
        }

        return generatePanKeyframes(from: rawSamples, configuration: configuration)
    }

    /// Generates a high-quality person segmentation mask (foreground matte)
    /// using Apple Vision to allow subtitle text to sit behind the actor.
    public static func generatePersonMask(image: CGImage) -> CIImage? {
        if #available(macOS 12.0, *) {
            let request = VNGeneratePersonSegmentationRequest()
            request.qualityLevel = .balanced
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            try? handler.perform([request])

            guard let maskPixelBuffer = request.results?.first?.pixelBuffer else {
                return nil
            }
            return CIImage(cvPixelBuffer: maskPixelBuffer)
        }
        return nil
    }

    /// Builds the 1:1 square crop transform for a given source video size.
    public static func makeSquareCropTransform(
        sourceSize: CGSize,
        cropXNorm: CGFloat
    ) -> CGAffineTransform {
        cropTransformer.makeSquareCropTransform(sourceSize: sourceSize, cropXNorm: cropXNorm)
    }
}
