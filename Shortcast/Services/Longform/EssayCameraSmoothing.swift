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
