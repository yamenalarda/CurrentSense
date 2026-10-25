import Foundation

/// Three-component vector. Magnetic field values are in microtesla (µT).
public struct Vector3: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(_ x: Double, _ y: Double, _ z: Double) {
        self.x = x; self.y = y; self.z = z
    }

    public static let zero = Vector3(0, 0, 0)

    public var squaredMagnitude: Double { x * x + y * y + z * z }
    public var magnitude: Double { squaredMagnitude.squareRoot() }
    public var isFinite: Bool { x.isFinite && y.isFinite && z.isFinite }

    public static func + (l: Vector3, r: Vector3) -> Vector3 { Vector3(l.x + r.x, l.y + r.y, l.z + r.z) }
    public static func - (l: Vector3, r: Vector3) -> Vector3 { Vector3(l.x - r.x, l.y - r.y, l.z - r.z) }
    public static func * (v: Vector3, s: Double) -> Vector3 { Vector3(v.x * s, v.y * s, v.z * s) }
    public static func / (v: Vector3, s: Double) -> Vector3 { Vector3(v.x / s, v.y / s, v.z / s) }
}

/// Unit-quaternion orientation (device attitude relative to Core Motion's arbitrary reference frame).
public struct Quaternion: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double
    public var w: Double

    public init(x: Double, y: Double, z: Double, w: Double) {
        self.x = x; self.y = y; self.z = z; self.w = w
    }

    public static let identity = Quaternion(x: 0, y: 0, z: 0, w: 1)

    public var norm: Double { (x * x + y * y + z * z + w * w).squareRoot() }

    /// Smallest rotation angle in radians (0...pi) between two orientations.
    /// A degenerate (zero-norm) quaternion yields pi, i.e. "maximally different", which is the
    /// conservative choice for baseline invalidation.
    public func angle(to other: Quaternion) -> Double {
        let n = norm * other.norm
        guard n > 1e-9, n.isFinite else { return .pi }
        let d = abs(x * other.x + y * other.y + z * other.z + w * other.w) / n
        return 2 * acos(min(1, d))
    }

    public static func axisAngle(axis: Vector3, angle: Double) -> Quaternion {
        let m = axis.magnitude
        guard m > 0 else { return .identity }
        let s = sin(angle / 2) / m
        return Quaternion(x: axis.x * s, y: axis.y * s, z: axis.z * s, w: cos(angle / 2))
    }
}

/// One magnetometer sample. `timestamp` is seconds on a monotonic clock (Core Motion: since boot).
public struct MagSample: Equatable, Sendable {
    public var timestamp: TimeInterval
    /// Field in the device frame, microtesla.
    public var field: Vector3
    /// Gyro/accelerometer-fused attitude (no magnetometer in the fusion), if available.
    public var attitude: Quaternion?
    /// Rotation rate in rad/s, if available.
    public var rotationRate: Vector3?

    public init(timestamp: TimeInterval, field: Vector3, attitude: Quaternion? = nil, rotationRate: Vector3? = nil) {
        self.timestamp = timestamp
        self.field = field
        self.attitude = attitude
        self.rotationRate = rotationRate
    }
}

public enum MeasurementMode: String, CaseIterable, Sendable, Identifiable {
    case ac, dc
    public var id: String { rawValue }
    public var title: String { self == .ac ? "AC" : "DC" }
}

public enum MeasurementPhase: Equatable, Sendable {
    case idle, acquiring, measuring, stopped
}

public enum Confidence: Int, Comparable, Sendable {
    case none = 0, low, moderate, high
    public static func < (a: Confidence, b: Confidence) -> Bool { a.rawValue < b.rawValue }
}

public enum FieldStrengthCategory: Int, Sendable {
    case none = 0, weak, moderate, strong
}

public enum PipelineIssue: Equatable, Sendable {
    case none
    case holdStill
    case environmentUnstable
    case samplingTooSlow
    case sensorStalled
    case invalidData
    case baselineStale
    case orientationChanged
    case sensorUnavailable
    case sensorError
}

public enum UnavailableReason: Equatable, Sendable {
    case notCalibrated
    case measurementInvalid
    case motion
    case baselineInvalid
    case lowSignal
    case unstable
    case outOfCalibratedRange
    case invalidGeometry
    case excessiveUncertainty
}

public enum EstimateBasis: Equatable, Sendable {
    case calibration
    case idealSingleConductor
}

public enum CurrentEstimate: Equatable, Sendable {
    case unavailable(UnavailableReason)
    case available(amps: Double, relativeUncertainty: Double, basis: EstimateBasis)
}

public enum ToneStatus: Equatable, Sendable {
    case unresolvable, absent, present
}

/// Evidence of a mains-frequency tone in the (possibly aliased) high-passed signal.
/// Supporting evidence only; it never decides presence by itself.
public struct MainsSignature: Equatable, Sendable {
    public var line50: ToneStatus
    public var line60: ToneStatus
    public init(line50: ToneStatus, line60: ToneStatus) { self.line50 = line50; self.line60 = line60 }
    public static let unresolved = MainsSignature(line50: .unresolvable, line60: .unresolvable)
    public var anyPresent: Bool { line50 == .present || line60 == .present }
}

/// Everything the UI may show. AC snapshots never carry a current estimate (`currentEstimate == nil`).
public struct MeasurementSnapshot: Equatable, Sendable {
    public var session: Int
    public var time: TimeInterval = 0
    public var mode: MeasurementMode
    public var phase: MeasurementPhase
    public var isLive = false
    public var issue: PipelineIssue = .none
    public var acquisitionProgress = 0.0
    /// 0...1, drives colour/animation/audio. 0 when there is no validated signal.
    public var level = 0.0
    public var confidence: Confidence = .none
    public var effectiveSampleRate: Double?
    public var hasOrientation = false

    // DC
    public var deltaVector: Vector3?
    public var deltaMagnitude: Double?
    public var fieldMagnitude: Double?
    public var signalToNoise: Double?
    public var relativeSpread: Double?
    public var currentEstimate: CurrentEstimate?

    // AC
    public var fieldPresent: Bool?
    public var strength: FieldStrengthCategory?
    public var acRatio: Double?
    public var mainsSignature: MainsSignature?

    public init(session: Int, mode: MeasurementMode, phase: MeasurementPhase) {
        self.session = session; self.mode = mode; self.phase = phase
    }

    public static func cleared(mode: MeasurementMode, phase: MeasurementPhase, session: Int,
                               issue: PipelineIssue = .none, progress: Double = 0) -> MeasurementSnapshot {
        var s = MeasurementSnapshot(session: session, mode: mode, phase: phase)
        s.issue = issue
        s.acquisitionProgress = progress
        return s
    }
}
