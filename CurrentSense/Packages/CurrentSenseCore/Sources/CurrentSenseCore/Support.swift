import Foundation

enum RobustStats {
    static func median(_ v: [Double]) -> Double {
        guard !v.isEmpty else { return .nan }
        let s = v.sorted()
        let n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }

    /// Gaussian-consistent sigma from the median absolute deviation.
    static func robustSigma(_ v: [Double]) -> Double {
        let m = median(v)
        return 1.4826 * median(v.map { abs($0 - m) })
    }
}

/// Bounded sliding window keyed by sample time.
struct TimeWindow<Element> {
    private(set) var times: [Double] = []
    private(set) var items: [Element] = []
    private var head = 0
    let duration: Double
    let capacity: Int

    init(duration: Double, capacity: Int = 1024) {
        self.duration = duration
        self.capacity = capacity
    }

    var count: Int { times.count - head }
    var span: Double { count >= 2 ? times[times.count - 1] - times[head] : 0 }

    mutating func append(_ e: Element, at t: Double) {
        times.append(t)
        items.append(e)
        while head < times.count - 1 && t - times[head] > duration { head += 1 }
        while times.count - head > capacity { head += 1 }
        if head >= 512 {
            times.removeFirst(head)
            items.removeFirst(head)
            head = 0
        }
    }

    mutating func removeAll() {
        times.removeAll(keepingCapacity: true)
        items.removeAll(keepingCapacity: true)
        head = 0
    }

    func forEach(_ body: (Double, Element) -> Void) {
        var i = head
        while i < times.count { body(times[i], items[i]); i += 1 }
    }
}

extension TimeWindow where Element == Double {
    var mean: Double? {
        guard count > 0 else { return nil }
        var s = 0.0
        var i = head
        while i < items.count { s += items[i]; i += 1 }
        return s / Double(count)
    }

    var standardDeviation: Double? {
        guard count >= 2, let m = mean else { return nil }
        var s = 0.0
        var i = head
        while i < items.count { let d = items[i] - m; s += d * d; i += 1 }
        return (s / Double(count - 1)).squareRoot()
    }
}

/// Time-aware exponential smoother (correct for irregular sampling).
struct TimeAwareLowPass {
    let tau: Double
    private(set) var value: Vector3?
    private var lastTime: Double?

    init(tau: Double) {
        precondition(tau > 0)
        self.tau = tau
    }

    mutating func reset() { value = nil; lastTime = nil }

    @discardableResult
    mutating func update(_ v: Vector3, at t: Double) -> Vector3 {
        guard let s = value, let lt = lastTime else {
            value = v; lastTime = t
            return v
        }
        let dt = max(0, t - lt)
        let a = 1 - exp(-dt / tau)
        let n = s + (v - s) * a
        value = n; lastTime = t
        return n
    }

    /// Output-noise standard-deviation factor of the filter for white input noise.
    static func noiseGain(dt: Double, tau: Double) -> Double {
        let a = 1 - exp(-dt / tau)
        return (a / (2 - a)).squareRoot()
    }
}

/// Second-order high-pass (two cascaded first-order stages, x - lowpass(x)). Stronger rejection of
/// hand-sway frequencies than a single stage; passes anything well above `cutoffHz`.
struct TimeAwareHighPass {
    private var lp1: TimeAwareLowPass
    private var lp2: TimeAwareLowPass

    init(cutoffHz: Double) {
        precondition(cutoffHz > 0)
        let tau = 1 / (2 * Double.pi * cutoffHz)
        lp1 = TimeAwareLowPass(tau: tau)
        lp2 = TimeAwareLowPass(tau: tau)
    }

    mutating func reset() { lp1.reset(); lp2.reset() }

    mutating func update(_ v: Vector3, at t: Double) -> Vector3 {
        let y1 = v - lp1.update(v, at: t)
        return y1 - lp2.update(y1, at: t)
    }
}

/// Schmitt trigger with dwell times: prevents rapid field-present / field-absent flipping.
struct HysteresisDetector {
    let enter: Double
    let exit: Double
    let enterDwell: Double
    let exitDwell: Double
    private(set) var state = false
    private var candidateSince: Double?

    init(enter: Double, exit: Double, enterDwell: Double, exitDwell: Double) {
        precondition(exit < enter)
        self.enter = enter; self.exit = exit
        self.enterDwell = enterDwell; self.exitDwell = exitDwell
    }

    mutating func reset() { state = false; candidateSince = nil }

    @discardableResult
    mutating func update(_ v: Double, at t: Double) -> Bool {
        if !state {
            if v >= enter {
                if candidateSince == nil { candidateSince = t }
                if let c = candidateSince, t - c >= enterDwell { state = true; candidateSince = nil }
            } else { candidateSince = nil }
        } else {
            if v <= exit {
                if candidateSince == nil { candidateSince = t }
                if let c = candidateSince, t - c >= exitDwell { state = false; candidateSince = nil }
            } else { candidateSince = nil }
        }
        return state
    }
}

enum SampleValidity: Equatable { case valid, nonFinite, implausible, nonMonotonic }

struct SampleValidator {
    let maxMagnitude: Double
    private var last: Double?

    init(maxMagnitude: Double) { self.maxMagnitude = maxMagnitude }
    mutating func reset() { last = nil }

    mutating func validate(_ s: MagSample) -> SampleValidity {
        guard s.timestamp.isFinite, s.field.isFinite else { return .nonFinite }
        let m = s.field.magnitude
        guard m > 0, m <= maxMagnitude else { return .implausible }   // exactly zero = dead sensor
        if let l = last, s.timestamp <= l { return .nonMonotonic }
        last = s.timestamp
        return .valid
    }
}

/// Effective sample rate from the median of recent inter-sample intervals (robust to dropouts).
struct RateEstimator {
    private var dts: [Double] = []
    private var index = 0
    private var last: Double?
    private let capacity = 64

    mutating func reset() { dts.removeAll(keepingCapacity: true); index = 0; last = nil }

    mutating func add(_ t: Double) {
        defer { last = t }
        guard let l = last else { return }
        let dt = t - l
        guard dt > 0 else { return }
        if dts.count < capacity { dts.append(dt) } else { dts[index] = dt; index = (index + 1) % capacity }
    }

    var rate: Double? {
        guard dts.count >= 10 else { return nil }
        let m = RobustStats.median(dts)
        return m > 0 ? 1 / m : nil
    }
}

/// Rotation-based motion rejection with hold-off. Translation is not observable (accelerometer unused).
struct MotionGate {
    private var holdUntil = -Double.infinity
    private(set) var hasRotationData = false

    mutating func reset() { holdUntil = -.infinity }

    mutating func update(_ s: MagSample, limit: Double, holdoff: Double) -> Bool {
        if let w = s.rotationRate {
            hasRotationData = true
            if w.magnitude > limit { holdUntil = s.timestamp + holdoff }
        }
        return s.timestamp < holdUntil
    }
}
