import Foundation

/// A 3D vector of magnetic flux density in microtesla.
struct MagneticFieldVector: Sendable {
    let x: Double
    let y: Double
    let z: Double

    var isFinite: Bool { x.isFinite && y.isFinite && z.isFinite }

    func distance(to other: MagneticFieldVector) -> Double {
        let dx = x - other.x
        let dy = y - other.y
        let dz = z - other.z
        return sqrt(dx * dx + dy * dy + dz * dz)
    }

    func subtracting(_ other: MagneticFieldVector) -> MagneticFieldVector {
        MagneticFieldVector(x: x - other.x, y: y - other.y, z: z - other.z)
    }

    func adding(_ other: MagneticFieldVector) -> MagneticFieldVector {
        MagneticFieldVector(x: x + other.x, y: y + other.y, z: z + other.z)
    }

    /// Transform a device-coordinate vector to Core Motion's reference coordinates.
    /// Core Motion's attitude rotation matrix maps reference-frame vectors to device
    /// coordinates, so the inverse transform for a rotation matrix is its transpose.
    func rotated(
        m11: Double, m12: Double, m13: Double,
        m21: Double, m22: Double, m23: Double,
        m31: Double, m32: Double, m33: Double
    ) -> MagneticFieldVector {
        MagneticFieldVector(
            x: x * m11 + y * m21 + z * m31,
            y: x * m12 + y * m22 + z * m32,
            z: x * m13 + y * m23 + z * m33
        )
    }
}


/// Estimates the phone-fixed hard-iron bias from paired raw and calibrated field vectors.
/// Call only while capturing a baseline away from the target; the median rejects isolated spikes.
struct MagneticFieldBiasEstimator {
    static func estimate(
        rawVectors: [MagneticFieldVector],
        calibratedVectors: [MagneticFieldVector],
        minimumPairs: Int = 10
    ) -> MagneticFieldVector? {
        let count = min(rawVectors.count, calibratedVectors.count)
        guard count >= max(1, minimumPairs) else { return nil }

        var dx: [Double] = []
        var dy: [Double] = []
        var dz: [Double] = []
        dx.reserveCapacity(count)
        dy.reserveCapacity(count)
        dz.reserveCapacity(count)

        for index in 0..<count {
            let raw = rawVectors[index]
            let calibrated = calibratedVectors[index]
            guard raw.isFinite, calibrated.isFinite else { continue }
            let delta = raw.subtracting(calibrated)
            guard delta.isFinite else { continue }
            dx.append(delta.x)
            dy.append(delta.y)
            dz.append(delta.z)
        }

        guard dx.count >= max(1, minimumPairs) else { return nil }
        let bias = MagneticFieldVector(
            x: MagneticAnomalyDetector.median(dx),
            y: MagneticAnomalyDetector.median(dy),
            z: MagneticAnomalyDetector.median(dz)
        )
        return bias.isFinite ? bias : nil
    }
}

/// Detects sustained changes in a stable reference-frame magnetic vector.
/// This identifies a local magnetic anomaly, not an object type or physical contact.
struct MagneticAnomalyDetector {
    private(set) var baselineVector: MagneticFieldVector?
    private(set) var noiseSigmaEstimate = 0.0
    private(set) var isDetected = false

    private let minimumDeltaMicrotesla = 2.0
    private let noiseMultiplier = 5.0
    private let samplesToTrigger = 3
    private let samplesToClear = 10
    private var aboveThresholdCount = 0
    private var belowReleaseCount = 0

    var hasBaseline: Bool { baselineVector != nil }

    mutating func setBaseline(from vectors: [MagneticFieldVector]) {
        let valid = vectors.filter(\.isFinite)
        guard !valid.isEmpty else {
            reset()
            return
        }

        // Per-axis medians resist brief outliers during the baseline window.
        let center = MagneticFieldVector(
            x: Self.median(valid.map(\.x)),
            y: Self.median(valid.map(\.y)),
            z: Self.median(valid.map(\.z))
        )
        let sigmaX = 1.4826 * Self.median(valid.map { abs($0.x - center.x) })
        let sigmaY = 1.4826 * Self.median(valid.map { abs($0.y - center.y) })
        let sigmaZ = 1.4826 * Self.median(valid.map { abs($0.z - center.z) })
        baselineVector = center
        // Estimate each component's noise with MAD, then combine the three axes.
        // The detector's hard floor avoids reacting to tiny numerical changes.
        noiseSigmaEstimate = sqrt(sigmaX * sigmaX + sigmaY * sigmaY + sigmaZ * sigmaZ)
        isDetected = false
        aboveThresholdCount = 0
        belowReleaseCount = 0
    }

    @discardableResult
    mutating func update(vector: MagneticFieldVector) -> Bool {
        guard vector.isFinite, let baselineVector else {
            isDetected = false
            aboveThresholdCount = 0
            belowReleaseCount = 0
            return false
        }

        let delta = vector.distance(to: baselineVector)
        let triggerThreshold = max(minimumDeltaMicrotesla, noiseSigmaEstimate * noiseMultiplier)
        let releaseThreshold = triggerThreshold * 0.55

        if delta >= triggerThreshold {
            aboveThresholdCount += 1
            belowReleaseCount = 0
            if aboveThresholdCount >= samplesToTrigger {
                isDetected = true
            }
        } else if delta < releaseThreshold {
            belowReleaseCount += 1
            aboveThresholdCount = 0
            if belowReleaseCount >= samplesToClear {
                isDetected = false
            }
        } else {
            // In the hysteresis band, do not accumulate evidence in either direction.
            aboveThresholdCount = 0
            belowReleaseCount = 0
        }
        return isDetected
    }

    mutating func reset() {
        baselineVector = nil
        noiseSigmaEstimate = 0
        isDetected = false
        aboveThresholdCount = 0
        belowReleaseCount = 0
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }
}


/// Median-window filter with exponential smoothing for noisy field-change readings.
/// Keeps raw samples available for diagnostics while presenting a steadier value to the UI.
struct FieldDeltaFilter {
    private var window: [Double] = []
    private var smoothedValue: Double?
    private var lastTimestamp: TimeInterval?
    private let windowSize: Int
    private let smoothingFactor: Double
    private let smoothingTimeConstant: TimeInterval

    init(
        windowSize: Int = 7,
        smoothingFactor: Double = 0.40,
        nominalSampleInterval: TimeInterval = 1.0 / 40.0
    ) {
        self.windowSize = max(1, windowSize)
        let clampedFactor = min(max(smoothingFactor, 0.01), 1.0)
        self.smoothingFactor = clampedFactor
        let nominalInterval = nominalSampleInterval.isFinite && nominalSampleInterval > 0
            ? nominalSampleInterval : 1.0 / 40.0
        // Calibrate the time constant so alpha=0.40 at the nominal 40 Hz rate.
        self.smoothingTimeConstant = clampedFactor >= 1.0
            ? 0.0
            : -nominalInterval / log(1.0 - clampedFactor)
    }

    /// If timestamps are supplied, the EMA follows elapsed time rather than assuming
    /// every delivered sensor sample arrived exactly on schedule. Timestamp-free use
    /// retains the fixed-coefficient behavior for compatibility and unit tests.
    mutating func update(_ rawValue: Double?, timestamp: TimeInterval? = nil) -> Double? {
        guard let rawValue, rawValue.isFinite, rawValue >= 0 else {
            reset()
            return nil
        }

        let alpha: Double
        if let timestamp {
            guard timestamp.isFinite else {
                reset()
                return nil
            }
            if let previousTimestamp = lastTimestamp {
                let elapsed = timestamp - previousTimestamp
                guard elapsed > 0 else {
                    reset()
                    return nil
                }
                alpha = smoothingTimeConstant == 0
                    ? 1.0
                    : min(max(1.0 - exp(-elapsed / smoothingTimeConstant), 0.0), 1.0)
            } else {
                alpha = smoothingFactor
            }
            lastTimestamp = timestamp
        } else {
            lastTimestamp = nil
            alpha = smoothingFactor
        }

        window.append(rawValue)
        if window.count > windowSize {
            window.removeFirst(window.count - windowSize)
        }

        let robustValue = MagneticAnomalyDetector.median(window)
        if let previous = smoothedValue {
            smoothedValue = previous + (robustValue - previous) * alpha
        } else {
            smoothedValue = robustValue
        }
        return smoothedValue
    }

    mutating func reset() {
        window.removeAll(keepingCapacity: true)
        smoothedValue = nil
        lastTimestamp = nil
    }
}


/// Rejects samples while the device is rotating quickly or translating abruptly.
/// Attitude compensation handles rotation mathematically, while this gate suppresses
/// transient motion/calibration artifacts. Stability returns only after several calm samples.
struct OrientationStabilityGate {
    private(set) var isStable = false
    private var consecutiveCalmSamples = 0

    private let instabilityRateRadiansPerSecond = 0.35
    private let recoveryRateRadiansPerSecond = 0.20
    // CMDeviceMotion.userAcceleration is expressed in g after gravity is removed.
    // Thresholds conservatively reject pronounced hand translation/shocks, not tiny tremor.
    private let instabilityAccelerationMagnitudeG = 0.12
    private let recoveryAccelerationMagnitudeG = 0.06
    private let calmSamplesRequired = 4

    @discardableResult
    mutating func update(
        rotationRateRadiansPerSecond rate: Double,
        userAccelerationMagnitudeG acceleration: Double = 0.0
    ) -> Bool {
        guard rate.isFinite, rate >= 0,
              acceleration.isFinite, acceleration >= 0 else {
            consecutiveCalmSamples = 0
            isStable = false
            return false
        }

        if rate >= instabilityRateRadiansPerSecond
            || acceleration >= instabilityAccelerationMagnitudeG {
            consecutiveCalmSamples = 0
            isStable = false
        } else if rate <= recoveryRateRadiansPerSecond
                    && acceleration <= recoveryAccelerationMagnitudeG {
            consecutiveCalmSamples += 1
            if consecutiveCalmSamples >= calmSamplesRequired {
                isStable = true
            }
        } else {
            // Hysteresis band: do not count a moving sample as evidence of recovery.
            consecutiveCalmSamples = 0
        }
        return isStable
    }

    mutating func reset() {
        isStable = false
        consecutiveCalmSamples = 0
    }
}
