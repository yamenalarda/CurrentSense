import XCTest
@testable import CurrentSenseCore

struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

/// Deterministic synthetic magnetometer. Change the public vars between segments to simulate events.
struct Synth {
    var rng: SplitMix64
    var rate = 100.0
    var background = Vector3(20, -5, -40)   // Earth-like field incl. phone offset, µT
    var noise = 0.1                          // per-axis white noise sigma, µT
    var jitter = 0.0                         // uniform timing jitter, fraction of one sample period
    var dropout = 0.0                        // probability of a missing sample
    var attitude: Quaternion? = .identity
    var rotationRate: Vector3? = .zero

    init(seed: UInt64 = 42) { rng = SplitMix64(state: seed) }

    mutating func gauss() -> Double {
        let u1 = max(Double.random(in: 0..<1, using: &rng), 1e-12)
        let u2 = Double.random(in: 0..<1, using: &rng)
        return (-2 * log(u1)).squareRoot() * cos(2 * Double.pi * u2)
    }

    mutating func samples(from t0: Double, duration: Double,
                          extra: (Double) -> Vector3 = { _ in .zero }) -> [MagSample] {
        var out: [MagSample] = []
        let n = Int(duration * rate)
        for i in 0..<n {
            if dropout > 0, Double.random(in: 0..<1, using: &rng) < dropout { continue }
            let jit = jitter > 0 ? Double.random(in: -jitter...jitter, using: &rng) / rate : 0
            let t = t0 + Double(i) / rate + jit
            let noiseVec = Vector3(gauss() * noise, gauss() * noise, gauss() * noise)
            out.append(MagSample(timestamp: t, field: background + extra(t) + noiseVec,
                                 attitude: attitude, rotationRate: rotationRate))
        }
        return out
    }
}

@discardableResult
func feed(_ p: MeasurementPipeline, _ samples: [MagSample]) -> [MeasurementSnapshot] {
    var out: [MeasurementSnapshot] = []
    for s in samples { if let snap = p.ingest(s) { out.append(snap) } }
    return out
}

func makePipeline(_ mode: MeasurementMode, geometry: GeometryModel = .none) -> MeasurementPipeline {
    let p = MeasurementPipeline()
    p.start(mode: mode, session: 1, geometry: geometry, now: 0)
    return p
}

func tone(_ f: Double, amplitude: Double, phase: Double = 0, axis: Int = 0) -> (Double) -> Vector3 {
    { t in
        let v = amplitude * sin(2 * Double.pi * f * t + phase)
        return axis == 0 ? Vector3(v, 0, 0) : (axis == 1 ? Vector3(0, v, 0) : Vector3(0, 0, v))
    }
}
