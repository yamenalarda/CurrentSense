import Foundation

public struct ReadingRow: Equatable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var value: String
}

public struct ReadingsPresentation: Equatable, Sendable {
    public var header: String
    public var rows: [ReadingRow]
    public var status: String
    public var disclaimer: String?
    public var isLive: Bool
}

/// Turns a snapshot into user-facing text. AC presentations never contain a current row.
public enum ReadingsPresenter {
    public static let acDisclaimer = "Detects AC magnetic activity only. Not a voltage tester."
    static let dash = "\u{2014}"

    public static func present(_ s: MeasurementSnapshot) -> ReadingsPresentation {
        ReadingsPresentation(header: header(s), rows: rows(s), status: status(s),
                             disclaimer: s.mode == .ac ? acDisclaimer : nil, isLive: s.isLive && s.phase == .measuring)
    }

    static func header(_ s: MeasurementSnapshot) -> String {
        switch s.phase {
        case .idle: return "Ready"
        case .acquiring: return "Taking baseline"
        case .measuring: return s.isLive ? "Live" : "Signal lost"
        case .stopped: return hasValues(s) ? "Last result" : "Stopped"
        }
    }

    static func hasValues(_ s: MeasurementSnapshot) -> Bool {
        s.deltaMagnitude != nil || s.fieldPresent != nil
    }

    public static func formatMicrotesla(_ v: Double) -> String {
        v < 10 ? String(format: "%.2f \u{00B5}T", v) : String(format: "%.1f \u{00B5}T", v)
    }

    public static func formatCurrent(amps: Double, relativeUncertainty: Double) -> String {
        let digits = amps < 1 ? "%.2f" : (amps < 10 ? "%.1f" : "%.0f")
        let value = String(format: digits, amps)
        let pct = Int((relativeUncertainty * 100 / 5).rounded() * 5)
        return "\u{2248} \(value) A \u{00B1}\(pct)%"
    }

    static func confidenceText(_ c: Confidence) -> String {
        switch c {
        case .none: return dash
        case .low: return "Low"
        case .moderate: return "Moderate"
        case .high: return "High"
        }
    }

    static func rows(_ s: MeasurementSnapshot) -> [ReadingRow] {
        switch s.mode {
        case .dc:
            let change = s.deltaMagnitude.map(formatMicrotesla) ?? dash
            var current = dash
            if let e = s.currentEstimate {
                switch e {
                case .available(let a, let u, _): current = formatCurrent(amps: a, relativeUncertainty: u)
                case .unavailable: current = s.phase == .idle ? dash : "Unavailable"
                }
            }
            return [ReadingRow(id: "change", label: "Field change", value: change),
                    ReadingRow(id: "current", label: "Current", value: current),
                    ReadingRow(id: "quality", label: "Signal quality", value: confidenceText(s.confidence))]
        case .ac:
            var field = dash
            if let p = s.fieldPresent { field = p ? "Detected" : "Not detected" }
            var strength = dash
            if let c = s.strength {
                switch c {
                case .none: strength = dash
                case .weak: strength = "Weak"
                case .moderate: strength = "Moderate"
                case .strong: strength = "Strong"
                }
            }
            return [ReadingRow(id: "field", label: "Field", value: field),
                    ReadingRow(id: "strength", label: "Strength", value: strength),
                    ReadingRow(id: "quality", label: "Signal quality", value: confidenceText(s.confidence))]
        }
    }

    static func status(_ s: MeasurementSnapshot) -> String {
        switch s.issue {
        case .sensorUnavailable: return "The magnetometer is not available on this device."
        case .sensorError: return "The sensor reported an error. Stop and try again."
        case .sensorStalled: return "The sensor stopped delivering data."
        case .invalidData: return "The sensor returned invalid data."
        case .environmentUnstable: return "The magnetic background is unstable. Move away from magnets and metal, then try again."
        case .samplingTooSlow: return "The sensor data rate is too low for a reliable result."
        case .holdStill: return "Movement detected. Hold the phone still."
        case .orientationChanged: return "The phone moved since the baseline. Stop and start again with the load off."
        case .baselineStale: return "The baseline is old. Stop and start again."
        case .none: break
        }
        switch s.phase {
        case .idle:
            return s.mode == .dc ? "Tap the circle with the load switched off to take a baseline."
                                 : "Tap the circle, then hold the phone near the cable."
        case .acquiring:
            return s.mode == .dc ? "Hold the phone still. Keep the load switched off."
                                 : "Hold the phone still while the background is measured."
        case .measuring:
            if s.mode == .ac {
                guard let p = s.fieldPresent else { return "Measuring the AC background." }
                return p ? "AC magnetic activity detected. This does not test voltage."
                         : "No AC magnetic activity detected. This does not prove a conductor is safe."
            }
            switch s.currentEstimate {
            case .available: return "Estimate assumes the selected calibration or geometry."
            case .unavailable(let r)?:
                switch r {
                case .notCalibrated: return "Switch the load on. A current needs a calibration or geometry model."
                case .lowSignal: return "Signal too weak for a current. Switch the load on or move closer."
                case .unstable: return "The signal is changing. Hold the phone steady."
                case .outOfCalibratedRange: return "Outside the calibrated range."
                case .invalidGeometry: return "Check the distance setting."
                case .excessiveUncertainty: return "Uncertainty is too large to show a current."
                case .motion, .baselineInvalid, .measurementInvalid: return "Measurement paused."
                }
            case nil: return "Measuring."
            }
        case .stopped:
            return hasValues(s) ? "Stopped. Showing the last result." : "Stopped."
        }
    }
}
