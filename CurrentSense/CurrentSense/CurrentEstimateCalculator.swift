import Foundation

enum ConductorConfiguration: String, CaseIterable, Identifiable {
    case singleConductor
    case completeCable

    var id: String { rawValue }

    var title: String {
        switch self {
        case .singleConductor: return "Single isolated conductor"
        case .completeCable: return "Complete insulated cable"
        }
    }
}

enum ReferenceSelection: String, CaseIterable, Identifiable {
    case knownDistance
    case knownCurrent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .knownDistance: return "I know distance"
        case .knownCurrent: return "I know current"
        }
    }
}

enum EstimationReference {
    case knownDistanceCentimeters(Double)
    case knownCurrentAmperes(Double)
    case empiricalMicroteslaPerAmp(Double)
    case missing
    case invalid
}

struct CurrentEstimate {
    let currentAmperes: Double?
    let distanceCentimeters: Double?
    let currentDetail: String
    let distanceDetail: String
    let caution: String?

    static func unavailable(
        currentDetail: String,
        distanceDetail: String,
        caution: String? = nil
    ) -> CurrentEstimate {
        CurrentEstimate(
            currentAmperes: nil,
            distanceCentimeters: nil,
            currentDetail: currentDetail,
            distanceDetail: distanceDetail,
            caution: caution
        )
    }
}

/// Calculates conditional estimates. It never treats one field reading as enough
/// to independently solve for both current and distance.
enum CurrentEstimateCalculator {
    /// Below this field change, sensor noise and placement errors can dominate.
    static let minimumUsableFieldChangeMicrotesla = 0.5
    static let maximumInputDistanceCentimeters = 1_000.0
    static let maximumReferenceCurrentAmperes = 100_000.0

    static func evaluate(
        fieldChangeMicrotesla: Double?,
        isAC: Bool,
        conductor: ConductorConfiguration,
        reference: EstimationReference,
        sensorCalibrationQuality: String
    ) -> CurrentEstimate {
        guard let field = fieldChangeMicrotesla else {
            return .unavailable(
                currentDetail: "Start measuring",
                distanceDetail: "Start measuring"
            )
        }
        guard field.isFinite, field >= 0 else {
            return .unavailable(
                currentDetail: "Invalid field reading",
                distanceDetail: "Invalid field reading",
                caution: "The sensor value is not finite or is negative. Stop and restart the measurement."
            )
        }

        guard field >= minimumUsableFieldChangeMicrotesla else {
            return .unavailable(
                currentDetail: "Signal too weak",
                distanceDetail: "Signal too weak",
                caution: "The field change is below the minimum threshold. Move closer only if safe, keep the phone still, and capture a fresh reading."
            )
        }

        var sensorWarning: String?
        let quality = sensorCalibrationQuality.lowercased()
        if quality == "uncalibrated" || quality == "low" || quality == "unknown" {
            sensorWarning = "The phone reports \(sensorCalibrationQuality) magnetic calibration. Treat any estimate as low-confidence."
        }

        switch conductor {
        case .singleConductor:
            guard !isAC else {
                return .unavailable(
                    currentDetail: "AC RMS not resolved",
                    distanceDetail: "AC field bandwidth limited",
                    caution: "The iPhone magnetic-field stream does not reliably resolve a 50/60 Hz waveform's RMS value. A straight-wire DC field formula cannot safely produce an AC current or distance estimate."
                )
            }

            switch reference {
            case .knownDistanceCentimeters(let distance):
                guard distance.isFinite,
                      distance > 0,
                      distance <= maximumInputDistanceCentimeters else {
                    return .unavailable(
                        currentDetail: "Check distance input",
                        distanceDetail: "Enter 0–1,000 cm",
                        caution: "Distance must be greater than zero and no more than 1,000 cm."
                    )
                }

                // For a long, isolated straight conductor: B(µT) = 20 * I(A) / r(cm).
                let current = field * distance / 20.0
                guard current.isFinite, current >= 0 else {
                    return .unavailable(
                        currentDetail: "Outside calculation range",
                        distanceDetail: "Reference distance entered"
                    )
                }
                return CurrentEstimate(
                    currentAmperes: current,
                    distanceCentimeters: distance,
                    currentDetail: "Straight-wire model · approximate",
                    distanceDetail: "Entered reference · not measured",
                    caution: joinWarnings(
                        "Assumes one long, isolated conductor with the sensor distance measured to the conductor's center. Phone sensor offset, cable insulation, metal nearby, return-current paths, and orientation can change the result.",
                        sensorWarning
                    )
                )

            case .knownCurrentAmperes(let current):
                guard current.isFinite,
                      current > 0,
                      current <= maximumReferenceCurrentAmperes else {
                    return .unavailable(
                        currentDetail: "Enter a valid reference",
                        distanceDetail: "Check current input",
                        caution: "Reference current must be greater than zero and no more than 100,000 A."
                    )
                }

                let distance = 20.0 * current / field
                guard distance.isFinite, distance > 0 else {
                    return .unavailable(
                        currentDetail: "Reference current entered",
                        distanceDetail: "Outside calculation range"
                    )
                }
                return CurrentEstimate(
                    currentAmperes: current,
                    distanceCentimeters: distance,
                    currentDetail: "Entered reference · not measured",
                    distanceDetail: "Straight-wire model · approximate",
                    caution: joinWarnings(
                        "Assumes one long, isolated conductor. Distance is from the magnetic sensor to the conductor's center, not from the phone's outer surface. This model is not valid for a complete phase/neutral cable.",
                        sensorWarning
                    )
                )

            case .missing:
                return .unavailable(
                    currentDetail: "Enter distance or current",
                    distanceDetail: "One reference is required",
                    caution: "One known value is required because a single magnetic-field reading cannot independently determine both current and distance."
                )
            case .invalid:
                return .unavailable(
                    currentDetail: "Check setup input",
                    distanceDetail: "Check setup input",
                    caution: "Enter a positive numeric reference value."
                )
            case .empiricalMicroteslaPerAmp:
                return .unavailable(
                    currentDetail: "Wrong reference type",
                    distanceDetail: "Use single-wire setup"
                )
            }

        case .completeCable:
            guard case .empiricalMicroteslaPerAmp(let sensitivity) = reference else {
                return .unavailable(
                    currentDetail: "Calibration required",
                    distanceDetail: "Not inferable for full cable",
                    caution: "Phase and neutral conductors can cancel much of their magnetic field. Calibrate with a known reference current using the same cable, phone position, orientation, and load type."
                )
            }
            guard sensitivity.isFinite, sensitivity > 0 else {
                return .unavailable(
                    currentDetail: "Calibration required",
                    distanceDetail: "Not inferable for full cable",
                    caution: "The saved calibration must be a finite, positive field-change-per-amp value."
                )
            }

            let current = field / sensitivity
            guard current.isFinite, current >= 0 else {
                return .unavailable(
                    currentDetail: "Outside calculation range",
                    distanceDetail: "Not inferable for full cable"
                )
            }
            return CurrentEstimate(
                currentAmperes: current,
                distanceCentimeters: nil,
                currentDetail: isAC
                    ? "Empirical AC estimate · validate"
                    : "Empirical DC estimate · validate",
                distanceDetail: "Not inferable for full cable",
                caution: joinWarnings(
                    isAC
                        ? "This is valid only as a setup-specific empirical estimate and only if the iPhone sensor responds consistently to that AC source. Calibrate at the same frequency and load, and verify with a clamp meter; the app cannot certify AC RMS accuracy."
                        : "Calibrate with a reference ammeter at the same cable, phone placement, orientation, and load range. This estimates current only; distance cannot be separated from cable geometry.",
                    sensorWarning
                )
            )
        }
    }

    private static func joinWarnings(_ first: String, _ second: String?) -> String {
        guard let second, !second.isEmpty else { return first }
        return first + " " + second
    }
}
