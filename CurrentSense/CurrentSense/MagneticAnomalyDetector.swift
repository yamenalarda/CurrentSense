import Foundation

/// A small, deterministic detector for sustained changes in magnetic-field magnitude.
/// It detects a magnetic anomaly, not an object type or physical contact.
struct MagneticAnomalyDetector {
    private(set) var baselineMagnitude: Double?
    private(set) var noiseSigmaEstimate = 0.0
    private(set) var isDetected = false

    private let minimumDeltaMicrotesla = 2.0
    private let noiseMultiplier = 5.0
    private let samplesToTrigger = 3
    private let samplesToClear = 10
    private var aboveThresholdCount = 0
    private var belowReleaseCount = 0

    var hasBaseline: Bool { baselineMagnitude != nil }

    mutating func setBaseline(from magnitudes: [Double]) {
        let valid = magnitudes.filter { $0.isFinite }
        guard !valid.isEmpty else {
            reset()
            return
        }

        let center = Self.median(valid)
        let absoluteDeviations = valid.map { abs($0 - center) }
        // 1.4826 * MAD estimates standard deviation for approximately normal noise
        // while remaining robust against isolated spikes during baseline capture.
        baselineMagnitude = center
        noiseSigmaEstimate = 1.4826 * Self.median(absoluteDeviations)
        isDetected = false
        aboveThresholdCount = 0
        belowReleaseCount = 0
    }

    @discardableResult
    mutating func update(magnitude: Double) -> Bool {
        guard magnitude.isFinite, let baselineMagnitude else {
            isDetected = false
            aboveThresholdCount = 0
            belowReleaseCount = 0
            return false
        }

        let delta = abs(magnitude - baselineMagnitude)
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
        baselineMagnitude = nil
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
