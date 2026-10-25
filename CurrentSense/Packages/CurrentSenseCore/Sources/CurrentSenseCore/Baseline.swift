import Foundation

/// Background reference captured with the target load OFF and the phone held still.
public struct Baseline: Equatable, Sendable {
    /// Median field in the device frame (µT).
    public let field: Vector3
    /// Robust per-axis noise (µT), floored at the configured quantisation guard.
    public let sigma: Vector3
    /// RMS of the high-passed vector in the quiet condition (µT). Reference for AC ratio.
    public let acNoiseFloor: Double
    public let attitude: Quaternion?
    public let acquiredAt: TimeInterval
    public let sampleCount: Int
    public let sampleRate: Double

    /// RMS magnitude of the 3-axis noise vector.
    public var sigmaMagnitude: Double { sigma.magnitude }
}

struct BaselineAcquirer {
    enum Result: Equatable {
        case inProgress(progress: Double, issue: PipelineIssue)
        case completed(Baseline)
        case failed(PipelineIssue)
    }

    private let config: PipelineConfig
    private var samples: [MagSample] = []
    private var startTime: Double?
    private var startAttitude: Quaternion?

    init(config: PipelineConfig) { self.config = config }

    mutating func restart() {
        samples.removeAll(keepingCapacity: true)
        startTime = nil
        startAttitude = nil
    }

    mutating func add(_ s: MagSample) -> Result {
        if let w = s.rotationRate, w.magnitude > config.maxAcquisitionRotationRate {
            restart()
            return .inProgress(progress: 0, issue: .holdStill)
        }
        if let a0 = startAttitude, let a1 = s.attitude, a0.angle(to: a1) > config.orientationInvalidationAngle {
            restart()
            startTime = s.timestamp
            startAttitude = s.attitude
            samples.append(s)
            return .inProgress(progress: 0, issue: .holdStill)
        }
        if startTime == nil {
            startTime = s.timestamp
            startAttitude = s.attitude
        }
        if samples.count < config.maxAcquisitionSamples { samples.append(s) }
        let elapsed = s.timestamp - (startTime ?? s.timestamp)
        if elapsed >= config.acquisitionDuration { return finalize() }
        return .inProgress(progress: min(1, elapsed / config.acquisitionDuration), issue: .none)
    }

    private func finalize() -> Result {
        guard samples.count >= config.minAcquisitionSamples,
              let first = samples.first, let last = samples.last, last.timestamp > first.timestamp
        else { return .failed(.samplingTooSlow) }

        let fs = Double(samples.count - 1) / (last.timestamp - first.timestamp)
        guard fs >= config.minSampleRate else { return .failed(.samplingTooSlow) }

        let xs = samples.map { $0.field.x }, ys = samples.map { $0.field.y }, zs = samples.map { $0.field.z }
        let med = Vector3(RobustStats.median(xs), RobustStats.median(ys), RobustStats.median(zs))
        let rawSigma = Vector3(RobustStats.robustSigma(xs), RobustStats.robustSigma(ys), RobustStats.robustSigma(zs))
        guard max(rawSigma.x, rawSigma.y, rawSigma.z) <= config.maxBaselineSigma else {
            return .failed(.environmentUnstable)
        }
        let floor = config.sigmaFloor
        let sigma = Vector3(max(rawSigma.x, floor), max(rawSigma.y, floor), max(rawSigma.z, floor))

        // Drift: first half vs second half.
        let h = samples.count / 2
        func med3(_ s: ArraySlice<MagSample>) -> Vector3 {
            Vector3(RobustStats.median(s.map { $0.field.x }),
                    RobustStats.median(s.map { $0.field.y }),
                    RobustStats.median(s.map { $0.field.z }))
        }
        let drift = (med3(samples[0..<h]) - med3(samples[h...])).magnitude
        guard drift <= config.maxBaselineDrift else { return .failed(.environmentUnstable) }

        // AC noise floor: run the same high-pass the AC detector uses.
        let fc = min(config.acHighPassHz, fs * 0.1)
        var hp = TimeAwareHighPass(cutoffHz: fc)
        var sumSq = 0.0
        var n = 0
        for s in samples {
            let y = hp.update(s.field, at: s.timestamp)
            if s.timestamp - first.timestamp >= 0.3 { sumSq += y.squaredMagnitude; n += 1 }
        }
        guard n >= 10 else { return .failed(.samplingTooSlow) }
        let acFloor = max((sumSq / Double(n)).squareRoot(), config.acNoiseFloorMin)

        return .completed(Baseline(field: med, sigma: sigma, acNoiseFloor: acFloor,
                                   attitude: samples.first?.attitude, acquiredAt: last.timestamp,
                                   sampleCount: samples.count, sampleRate: fs))
    }
}
