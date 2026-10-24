import Foundation

enum ACFieldActivityLevel: Equatable {
    case idle
    case capturingBaseline
    case noDetectableChange
    case weak
    case moderate
    case strong
    case unavailable

    var title: String {
        switch self {
        case .idle: return "Ready to scan"
        case .capturingBaseline: return "Capturing reference"
        case .noDetectableChange: return "No detectable field change"
        case .weak: return "Weak field response"
        case .moderate: return "Moderate field response"
        case .strong: return "Strong field response"
        case .unavailable: return "Reading unavailable"
        }
    }

    /// A relative signal band, not a distance measurement.
    var relativeReachTitle: String {
        switch self {
        case .idle, .capturingBaseline, .noDetectableChange, .unavailable:
            return "Not detected"
        case .weak:
            return "Short response"
        case .moderate:
            return "Medium response"
        case .strong:
            return "Extended response"
        }
    }

    var strengthBars: Int {
        switch self {
        case .idle, .capturingBaseline, .noDetectableChange, .unavailable: return 0
        case .weak: return 1
        case .moderate: return 2
        case .strong: return 3
        }
    }

    var indicatesMagneticChange: Bool {
        switch self {
        case .weak, .moderate, .strong: return true
        default: return false
        }
    }
}

/// A qualitative classification for AC-mode presentation.
/// This is magnetic-field activity, NOT an NCV voltage test and NOT a safety indication.
enum ACFieldScanClassifier {
    static let absoluteFloorMicrotesla = 0.5
    static let noiseMultiplier = 5.0

    static func threshold(noiseSigmaMicrotesla: Double?) -> Double {
        let validNoise = noiseSigmaMicrotesla.flatMap {
            $0.isFinite && $0 > 0 ? $0 : nil
        } ?? 0
        return max(absoluteFloorMicrotesla, validNoise * noiseMultiplier)
    }

    static func classify(
        fieldChangeMicrotesla: Double?,
        noiseSigmaMicrotesla: Double?,
        isMeasuring: Bool,
        baselineCaptured: Bool
    ) -> ACFieldActivityLevel {
        guard isMeasuring else { return .idle }
        guard baselineCaptured else { return .capturingBaseline }
        guard let field = fieldChangeMicrotesla, field.isFinite, field >= 0 else {
            return .unavailable
        }

        let minimum = threshold(noiseSigmaMicrotesla: noiseSigmaMicrotesla)
        guard field >= minimum else { return .noDetectableChange }

        let ratio = field / minimum
        if ratio < 2.0 { return .weak }
        if ratio < 4.0 { return .moderate }
        return .strong
    }
}
