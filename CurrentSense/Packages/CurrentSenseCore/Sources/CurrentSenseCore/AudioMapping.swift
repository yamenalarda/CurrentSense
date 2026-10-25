import Foundation

public struct ToneTarget: Equatable, Sendable {
    public var frequencyHz: Double
    public var amplitude: Double
}

/// Maps the validated 0...1 signal level to a tone: log-frequency (monotonic), deadband (no jitter),
/// slew-rate limit (no jumps). The audio renderer additionally ramps per sample to avoid clicks.
public struct AudioToneMapper: Sendable {
    public var minFrequency = 220.0
    public var octaves = 2.0                  // 220 Hz ... 880 Hz
    public var maxAmplitude = 0.15            // default volume (linear, conservative)
    public var deadband = 0.03
    public var maxOctavesPerSecond = 1.5

    private var heldLevel = 0.0
    private var currentOctaves = 0.0
    private var current = ToneTarget(frequencyHz: 220, amplitude: 0)

    public init() {}

    public static func frequency(forLevel level: Double, minFrequency: Double = 220, octaves: Double = 2) -> Double {
        minFrequency * pow(2, octaves * min(1, max(0, level)))
    }

    public mutating func reset() {
        heldLevel = 0; currentOctaves = 0
        current = ToneTarget(frequencyHz: minFrequency, amplitude: 0)
    }

    public mutating func update(level: Double, active: Bool, dt: Double) -> ToneTarget {
        guard active, level > 0 else {
            heldLevel = 0
            current.amplitude = 0
            return current
        }
        if abs(level - heldLevel) > deadband || heldLevel == 0 { heldLevel = level }
        let targetOct = octaves * min(1, max(0, heldLevel))
        let step = maxOctavesPerSecond * max(0, dt)
        if current.amplitude == 0 { currentOctaves = targetOct }   // start at the right pitch, no glide from silence
        else { currentOctaves += min(step, max(-step, targetOct - currentOctaves)) }
        current.frequencyHz = minFrequency * pow(2, currentOctaves)
        current.amplitude = maxAmplitude
        return current
    }
}
