import Foundation

/// Single-point calibration against a reference current at a fixed, repeatable phone position.
public struct Calibration: Codable, Equatable, Sendable {
    /// Magnitude of the baseline-subtracted field per ampere, µT/A, at the calibrated position.
    public var sensitivityMicroteslaPerAmp: Double
    public var referenceCurrentAmps: Double
    public var relativeUncertainty: Double
    public var createdAt: Date

    public init(sensitivityMicroteslaPerAmp: Double, referenceCurrentAmps: Double,
                relativeUncertainty: Double, createdAt: Date = Date()) {
        self.sensitivityMicroteslaPerAmp = sensitivityMicroteslaPerAmp
        self.referenceCurrentAmps = referenceCurrentAmps
        self.relativeUncertainty = relativeUncertainty
        self.createdAt = createdAt
    }
}

public enum GeometryModel: Equatable, Sendable {
    /// No model: no current estimate is produced.
    case none
    case calibrated(Calibration)
    /// Idealised infinitely long single straight conductor at a user-declared distance.
    case idealSingleConductor(distanceMeters: Double, distanceRelativeUncertainty: Double)
}

public enum CurrentEstimator {
    /// Permeability of free space, H/m.
    public static let mu0 = 4e-7 * Double.pi

    /// I = 2*pi*r*B / mu0, with B in µT and r in metres. Returns amperes.
    public static func idealSingleConductorCurrent(fieldMicrotesla: Double, distanceMeters r: Double) -> Double {
        2 * Double.pi * r * (fieldMicrotesla * 1e-6) / mu0
    }

    /// B = mu0*I / (2*pi*r), result in µT.
    public static func idealSingleConductorField(amps: Double, distanceMeters r: Double) -> Double {
        mu0 * amps / (2 * Double.pi * r) * 1e6
    }

    static func estimate(deltaMagnitude: Double?, snr: Double?, spread: Double?,
                         issue: PipelineIssue, model: GeometryModel, config: PipelineConfig) -> CurrentEstimate {
        switch issue {
        case .none: break
        case .holdStill: return .unavailable(.motion)
        case .orientationChanged, .baselineStale: return .unavailable(.baselineInvalid)
        default: return .unavailable(.measurementInvalid)
        }
        if case .none = model { return .unavailable(.notCalibrated) }
        guard let delta = deltaMagnitude, let snr = snr, snr >= config.dcCurrentMinSNR else {
            return .unavailable(.lowSignal)
        }
        guard let spread = spread, spread <= config.dcMaxSpread else { return .unavailable(.unstable) }

        let amps: Double
        let rel: Double
        let basis: EstimateBasis
        switch model {
        case .none:
            return .unavailable(.notCalibrated)
        case .calibrated(let cal):
            guard cal.sensitivityMicroteslaPerAmp > 0, cal.referenceCurrentAmps > 0 else {
                return .unavailable(.notCalibrated)
            }
            amps = delta / cal.sensitivityMicroteslaPerAmp
            if amps > cal.referenceCurrentAmps * config.extrapolationFactor {
                return .unavailable(.outOfCalibratedRange)
            }
            rel = (cal.relativeUncertainty * cal.relativeUncertainty + 1 / (snr * snr)).squareRoot()
            basis = .calibration
        case .idealSingleConductor(let r, let rRel):
            guard r >= config.minIdealDistance, r <= config.maxIdealDistance else {
                return .unavailable(.invalidGeometry)
            }
            amps = idealSingleConductorCurrent(fieldMicrotesla: delta, distanceMeters: r)
            let m = config.idealModelMinUncertainty
            rel = (rRel * rRel + m * m + 1 / (snr * snr)).squareRoot()
            basis = .idealSingleConductor
        }
        guard rel <= config.maxCurrentUncertainty else { return .unavailable(.excessiveUncertainty) }
        return .available(amps: amps, relativeUncertainty: rel, basis: basis)
    }
}

/// Signal-quality classification. "Quality" describes the measurement, NOT accuracy and NOT proof
/// that the signal belongs to the target conductor.
public enum QualityAssessor {
    static func dcConfidence(snr: Double, spread: Double?, hasOrientation: Bool, config: PipelineConfig) -> Confidence {
        guard snr >= config.dcDetectSNR, let sp = spread else { return .low }
        var c: Confidence
        if snr >= config.dcHighConfidenceSNR && sp <= config.dcHighConfidenceSpread { c = .high }
        else if snr >= config.dcCurrentMinSNR && sp <= config.dcMaxSpread { c = .moderate }
        else { c = .low }
        if !hasOrientation && c > .moderate { c = .moderate }
        return c
    }

    static func dcLevel(snr: Double, config: PipelineConfig) -> Double {
        guard snr >= config.dcDetectSNR else { return 0 }
        let top = 1000.0
        return min(1, max(0, log(snr / config.dcDetectSNR) / log(top / config.dcDetectSNR)))
    }

    static func acLevel(ratio: Double, present: Bool, config: PipelineConfig) -> Double {
        guard present else { return 0 }
        let v = log(max(ratio, config.acEnterRatio) / config.acEnterRatio) / log(100 / config.acEnterRatio)
        return min(1, max(0.1, v))
    }

    static func acConfidence(ratio: Double, present: Bool, mains: MainsSignature?, config: PipelineConfig) -> Confidence {
        if !present { return ratio <= 1.2 ? .moderate : .low }
        let tone = mains?.anyPresent ?? false
        if ratio >= config.acEnterRatio * 1.5 && (tone || ratio >= 6) { return .high }
        if ratio >= config.acEnterRatio * 1.25 { return .moderate }
        return .low
    }
}

/// Records snapshots while a known reference current flows and builds a `Calibration`.
public struct CalibrationRecorder {
    public enum Status: Equatable, Sendable {
        case inProgress(Double)
        case succeeded(Calibration)
    }

    public static let referenceInstrumentUncertainty = 0.03
    public static let minimumUncertainty = 0.05

    private let reference: Double
    private let duration: Double
    private let config: PipelineConfig
    private var values: [Double] = []
    private var startTime: Double?

    public init(referenceAmps: Double, duration: Double = 3.0, config: PipelineConfig = .default) {
        self.reference = referenceAmps
        self.duration = duration
        self.config = config
    }

    public mutating func add(_ s: MeasurementSnapshot, now: Date = Date()) -> Status {
        guard reference > 0, s.mode == .dc, s.isLive, s.phase == .measuring, s.issue == .none,
              let d = s.deltaMagnitude, let snr = s.signalToNoise, let sp = s.relativeSpread,
              snr >= config.dcCurrentMinSNR, sp <= config.dcMaxSpread
        else {
            values.removeAll(); startTime = nil
            return .inProgress(0)
        }
        if startTime == nil { startTime = s.time }
        values.append(d)
        let elapsed = s.time - (startTime ?? s.time)
        guard elapsed >= duration, values.count >= 5 else { return .inProgress(min(1, elapsed / duration)) }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count - 1)
        let relStd = mean > 0 ? variance.squareRoot() / mean : 1
        let rel = max(Self.minimumUncertainty,
                      (relStd * relStd + Self.referenceInstrumentUncertainty * Self.referenceInstrumentUncertainty).squareRoot())
        return .succeeded(Calibration(sensitivityMicroteslaPerAmp: mean / reference,
                                      referenceCurrentAmps: reference, relativeUncertainty: rel, createdAt: now))
    }
}
