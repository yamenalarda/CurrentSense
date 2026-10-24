import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct CurrentEstimateCalculatorTests {
    static func main() {
        // B(µT) = 20 * I(A) / r(cm) for a long, isolated straight conductor.
        let knownDistance = CurrentEstimateCalculator.evaluate(
            fieldChangeMicrotesla: 20,
            isAC: false,
            conductor: .singleConductor,
            reference: .knownDistanceCentimeters(1),
            sensorCalibrationQuality: "High"
        )
        expect(abs((knownDistance.currentAmperes ?? -1) - 1.0) < 1e-9,
               "20 µT at 1 cm should model to 1 A")
        expect(knownDistance.distanceCentimeters == 1,
               "known distance should remain marked as the entered reference")
        expect(knownDistance.currentDetail.contains("approximate"),
               "physical current estimate must be labeled approximate")

        let knownCurrent = CurrentEstimateCalculator.evaluate(
            fieldChangeMicrotesla: 20,
            isAC: false,
            conductor: .singleConductor,
            reference: .knownCurrentAmperes(1),
            sensorCalibrationQuality: "High"
        )
        expect(abs((knownCurrent.distanceCentimeters ?? -1) - 1.0) < 1e-9,
               "1 A at 20 µT should model to 1 cm")
        expect(knownCurrent.currentAmperes == 1,
               "entered current should be shown as reference, not measured current")
        expect(knownCurrent.currentDetail.contains("not measured"),
               "reference current must not be mislabeled as measured")

        let calibratedCable = CurrentEstimateCalculator.evaluate(
            fieldChangeMicrotesla: 12,
            isAC: false,
            conductor: .completeCable,
            reference: .empiricalMicroteslaPerAmp(4),
            sensorCalibrationQuality: "High"
        )
        expect(abs((calibratedCable.currentAmperes ?? -1) - 3.0) < 1e-9,
               "12 µT at 4 µT/A should produce a 3 A empirical estimate")
        expect(calibratedCable.distanceCentimeters == nil,
               "full-cable setup must not claim an inferred distance")

        let uncalibratedCable = CurrentEstimateCalculator.evaluate(
            fieldChangeMicrotesla: 12,
            isAC: false,
            conductor: .completeCable,
            reference: .missing,
            sensorCalibrationQuality: "High"
        )
        expect(uncalibratedCable.currentAmperes == nil,
               "complete cable must not invent current before calibration")
        expect(uncalibratedCable.caution?.contains("Calibration") == true ||
               uncalibratedCable.currentDetail.contains("Calibration"),
               "missing cable calibration must be explained")

        let acStraightWire = CurrentEstimateCalculator.evaluate(
            fieldChangeMicrotesla: 20,
            isAC: true,
            conductor: .singleConductor,
            reference: .knownDistanceCentimeters(1),
            sensorCalibrationQuality: "High"
        )
        expect(acStraightWire.currentAmperes == nil && acStraightWire.distanceCentimeters == nil,
               "AC cannot use the DC straight-wire estimate")

        let weakField = CurrentEstimateCalculator.evaluate(
            fieldChangeMicrotesla: 0.1,
            isAC: false,
            conductor: .singleConductor,
            reference: .knownDistanceCentimeters(1),
            sensorCalibrationQuality: "High"
        )
        expect(weakField.currentAmperes == nil && weakField.distanceCentimeters == nil,
               "weak signal must not produce an estimate")

        let missingField = CurrentEstimateCalculator.evaluate(
            fieldChangeMicrotesla: nil,
            isAC: false,
            conductor: .singleConductor,
            reference: .knownDistanceCentimeters(1),
            sensorCalibrationQuality: "High"
        )
        expect(missingField.currentAmperes == nil, "missing field must not produce current")

        let nonFiniteField = CurrentEstimateCalculator.evaluate(
            fieldChangeMicrotesla: .nan,
            isAC: false,
            conductor: .singleConductor,
            reference: .knownDistanceCentimeters(1),
            sensorCalibrationQuality: "High"
        )
        expect(nonFiniteField.currentAmperes == nil, "NaN field must be rejected")

        let invalidDistance = CurrentEstimateCalculator.evaluate(
            fieldChangeMicrotesla: 20,
            isAC: false,
            conductor: .singleConductor,
            reference: .knownDistanceCentimeters(.infinity),
            sensorCalibrationQuality: "High"
        )
        expect(invalidDistance.currentAmperes == nil, "infinite distance must be rejected")

        let invalidCurrent = CurrentEstimateCalculator.evaluate(
            fieldChangeMicrotesla: 20,
            isAC: false,
            conductor: .singleConductor,
            reference: .knownCurrentAmperes(-1),
            sensorCalibrationQuality: "High"
        )
        expect(invalidCurrent.distanceCentimeters == nil, "negative reference current must be rejected")

        let invalidSensitivity = CurrentEstimateCalculator.evaluate(
            fieldChangeMicrotesla: 20,
            isAC: false,
            conductor: .completeCable,
            reference: .empiricalMicroteslaPerAmp(.nan),
            sensorCalibrationQuality: "High"
        )
        expect(invalidSensitivity.currentAmperes == nil, "NaN sensitivity must be rejected")

        let noisyBaseline = CurrentEstimateCalculator.evaluate(
            fieldChangeMicrotesla: 1.1,
            isAC: false,
            conductor: .singleConductor,
            reference: .knownDistanceCentimeters(1),
            sensorCalibrationQuality: "High",
            baselineNoiseSigmaMicrotesla: 0.25
        )
        expect(noisyBaseline.currentAmperes == nil,
               "field signal below five times measured baseline noise must be rejected")
        expect(noisyBaseline.caution?.contains("1.250 µT") == true,
               "adaptive noise threshold must be visible in the warning")

        let lowCalibration = CurrentEstimateCalculator.evaluate(
            fieldChangeMicrotesla: 20,
            isAC: false,
            conductor: .singleConductor,
            reference: .knownDistanceCentimeters(1),
            sensorCalibrationQuality: "Uncalibrated"
        )
        expect(lowCalibration.currentAmperes != nil, "model may still be computed with a warning")
        expect(lowCalibration.caution?.contains("low-confidence") == true,
               "uncalibrated sensor must lower confidence explicitly")

        print("PASS: CurrentEstimateCalculatorTests")
    }
}
