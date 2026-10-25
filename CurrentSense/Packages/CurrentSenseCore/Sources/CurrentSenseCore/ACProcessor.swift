import Foundation

enum SpectralTone {
    /// Frequency (Hz) at which a tone of `f` Hz appears after sampling at `fs` Hz.
    static func aliasedFrequency(_ f: Double, sampleRate fs: Double) -> Double {
        abs(f - (f / fs).rounded() * fs)
    }

    /// Single-frequency projection using the real timestamps (valid for irregular sampling).
    /// For a uniformly sampled sinusoid with whole cycles in the window, narrow == total.
    static func narrowband(times: [Double], values: [Double], frequency f: Double) -> (narrow: Double, total: Double) {
        let n = values.count
        guard n > 0, times.count == n else { return (0, 0) }
        let w = 2 * Double.pi * f
        let t0 = times[0]
        var c = 0.0, s = 0.0, p = 0.0
        for i in 0..<n {
            let ph = w * (times[i] - t0)
            c += values[i] * cos(ph)
            s += values[i] * sin(ph)
            p += values[i] * values[i]
        }
        let nd = Double(n)
        return (2 * (c * c + s * s) / (nd * nd), p / nd)
    }
}

enum MainsAnalyzer {
    static func isResolvable(alias: Double, sampleRate fs: Double, config: PipelineConfig) -> Bool {
        alias >= config.mainsMinAliasHz && alias <= fs / 2 - config.mainsNyquistGuardHz
    }

    static func analyze(times: [Double], x: [Double], y: [Double], z: [Double],
                        sampleRate fs: Double, config: PipelineConfig) -> MainsSignature {
        guard fs > 0, times.count >= 16 else { return .unresolved }
        let a50 = SpectralTone.aliasedFrequency(50, sampleRate: fs)
        let a60 = SpectralTone.aliasedFrequency(60, sampleRate: fs)
        let r50 = isResolvable(alias: a50, sampleRate: fs, config: config)
        let r60 = isResolvable(alias: a60, sampleRate: fs, config: config)

        func fraction(at alias: Double) -> Double {
            var best = 0.0
            var df = -config.mainsScanHz
            while df <= config.mainsScanHz + 1e-9 {
                let f = alias + df
                if f > 0 {
                    let a = SpectralTone.narrowband(times: times, values: x, frequency: f)
                    let b = SpectralTone.narrowband(times: times, values: y, frequency: f)
                    let c = SpectralTone.narrowband(times: times, values: z, frequency: f)
                    let total = a.total + b.total + c.total
                    if total > 0 { best = max(best, (a.narrow + b.narrow + c.narrow) / total) }
                }
                df += config.mainsScanStep
            }
            return best
        }

        var s50 = ToneStatus.unresolvable, s60 = ToneStatus.unresolvable
        if r50 { s50 = fraction(at: a50) >= config.mainsToneFraction ? .present : .absent }
        if r60 { s60 = fraction(at: a60) >= config.mainsToneFraction ? .present : .absent }
        return MainsSignature(line50: s50, line60: s60)
    }
}

struct ACReading: Equatable {
    var rms: Double?
    var ratio: Double?
    var present: Bool
    var strength: FieldStrengthCategory
    var mains: MainsSignature?
}

/// Dedicated AC-band pipeline: high-pass -> windowed RMS -> ratio to the quiet-baseline noise floor
/// -> hysteresis. It detects AC-band magnetic ACTIVITY (anything above ~8 Hz), not a specific voltage.
struct ACProcessor {
    private var hp: TimeAwareHighPass
    private var power: TimeWindow<Double>
    private var spectrum: TimeWindow<Vector3>
    private var detector: HysteresisDetector
    private var strength: FieldStrengthCategory = .none
    private let config: PipelineConfig

    init(config: PipelineConfig, sampleRate: Double) {
        self.config = config
        hp = TimeAwareHighPass(cutoffHz: min(config.acHighPassHz, max(sampleRate, 1) * 0.1))
        power = TimeWindow<Double>(duration: config.acRMSWindow)
        spectrum = TimeWindow<Vector3>(duration: config.spectrumWindow)
        detector = HysteresisDetector(enter: config.acEnterRatio, exit: config.acExitRatio,
                                      enterDwell: config.acEnterDwell, exitDwell: config.acExitDwell)
    }

    mutating func reset() {
        hp.reset(); power.removeAll(); spectrum.removeAll(); detector.reset(); strength = .none
    }

    mutating func process(_ s: MagSample) {
        let y = hp.update(s.field, at: s.timestamp)
        power.append(y.squaredMagnitude, at: s.timestamp)
        spectrum.append(y, at: s.timestamp)
    }

    static func category(ratio: Double, previous: FieldStrengthCategory, config: PipelineConfig) -> FieldStrengthCategory {
        let b1 = config.acModerateRatio, b2 = config.acStrongRatio, m = config.acCategoryHysteresis
        var c = previous
        if c == .none { return ratio >= b2 ? .strong : (ratio >= b1 ? .moderate : .weak) }
        switch c {
        case .weak:
            if ratio >= b2 * (1 + m) { c = .strong } else if ratio >= b1 * (1 + m) { c = .moderate }
        case .moderate:
            if ratio >= b2 * (1 + m) { c = .strong } else if ratio < b1 * (1 - m) { c = .weak }
        case .strong:
            if ratio < b2 * (1 - m) { c = ratio >= b1 * (1 - m) ? .moderate : .weak }
        case .none:
            break
        }
        return c
    }

    mutating func evaluate(at t: Double, noiseFloor: Double, sampleRate: Double?, suppress: Bool) -> ACReading {
        guard !suppress else {
            detector.reset(); strength = .none
            return ACReading(rms: nil, ratio: nil, present: false, strength: .none, mains: nil)
        }
        guard power.span >= config.acMinSpan, let meanPower = power.mean, noiseFloor > 0 else {
            return ACReading(rms: nil, ratio: nil, present: false, strength: .none, mains: nil)
        }
        let rms = meanPower.squareRoot()
        let ratio = rms / noiseFloor
        let present = detector.update(ratio, at: t)
        strength = present ? Self.category(ratio: ratio, previous: strength, config: config) : .none

        var mains: MainsSignature?
        if present, let fs = sampleRate, spectrum.count >= 16 {
            var ts: [Double] = [], xs: [Double] = [], ys: [Double] = [], zs: [Double] = []
            spectrum.forEach { time, v in ts.append(time); xs.append(v.x); ys.append(v.y); zs.append(v.z) }
            mains = MainsAnalyzer.analyze(times: ts, x: xs, y: ys, z: zs, sampleRate: fs, config: config)
        }
        return ACReading(rms: rms, ratio: ratio, present: present, strength: strength, mains: mains)
    }
}
