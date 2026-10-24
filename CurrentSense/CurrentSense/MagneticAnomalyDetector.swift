import Foundation

/// A 3D vector of magnetic flux density in microtesla.
struct MagneticFieldVector {
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
