import Foundation

struct DCReading: Equatable {
    var delta: Vector3          // smoothed (sample - baseline), device frame, µT
    var deltaMagnitude: Double
    var fieldMagnitude: Double  // |baseline + smoothed delta|
    var snr: Double
    var spread: Double?         // relative std of |delta| over the last second
}

/// Vector baseline subtraction + time-aware smoothing. Magnitudes are computed AFTER the vector
/// subtraction (never as a difference of scalar magnitudes).
struct DCProcessor {
    private var lowpass: TimeAwareLowPass
    private var magnitudes: TimeWindow<Double>
    private let config: PipelineConfig

    init(config: PipelineConfig) {
        self.config = config
        lowpass = TimeAwareLowPass(tau: config.dcSmoothingTau)
        magnitudes = TimeWindow<Double>(duration: config.spreadWindow)
    }

    mutating func reset() {
        lowpass.reset()
        magnitudes.removeAll()
    }

    mutating func process(_ s: MagSample, baseline: Baseline) {
        let smoothed = lowpass.update(s.field - baseline.field, at: s.timestamp)
        magnitudes.append(smoothed.magnitude, at: s.timestamp)
    }

    func reading(baseline: Baseline, sampleRate: Double) -> DCReading? {
        guard let d = lowpass.value, sampleRate > 0 else { return nil }
        let gain = TimeAwareLowPass.noiseGain(dt: 1 / sampleRate, tau: config.dcSmoothingTau)
        let noise = max(baseline.sigmaMagnitude * gain, 1e-9)
        var spread: Double?
        if magnitudes.span >= config.minSpreadSpan, let m = magnitudes.mean, let sd = magnitudes.standardDeviation, m > 1e-9 {
            spread = sd / m
        }
        return DCReading(delta: d, deltaMagnitude: d.magnitude,
                         fieldMagnitude: (baseline.field + d).magnitude,
                         snr: d.magnitude / noise, spread: spread)
    }
}
