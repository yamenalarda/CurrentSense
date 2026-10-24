import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct MagneticAnomalyDetectorTests {
    static func main() {
        // A single extreme sensor sample must not move the per-axis median much.
        let baseline = [
            MagneticFieldVector(x: 0.0, y: 50.0, z: 0.0),
            MagneticFieldVector(x: 0.1, y: 50.1, z: 0.0),
            MagneticFieldVector(x: -0.1, y: 49.9, z: 0.0),
            MagneticFieldVector(x: 0.05, y: 50.05, z: 0.05),
            MagneticFieldVector(x: -0.05, y: 49.95, z: -0.05),
            MagneticFieldVector(x: 0.0, y: 50.0, z: 0.0),
            MagneticFieldVector(x: 0.1, y: 50.1, z: 0.0),
            MagneticFieldVector(x: -0.1, y: 49.9, z: 0.0),
            MagneticFieldVector(x: 30.0, y: 40.0, z: 30.0)
        ]
        var detector = MagneticAnomalyDetector()
        detector.setBaseline(from: baseline)
        expect(detector.hasBaseline, "baseline should be accepted")
        let center = detector.baselineVector
        expect(center != nil, "baseline vector should be available")
        expect(abs((center?.x ?? 100) - 0.0) < 0.001,
               "x baseline median should resist an outlier")
        expect(abs((center?.y ?? 0) - 50.0) < 0.001,
               "y baseline median should resist an outlier")

        // A 90-degree device rotation should preserve the same reference-frame field.
        let rotatedField = MagneticFieldVector(x: -50.0, y: 0.0, z: 0.0).rotated(
            m11: 0, m12: -1, m13: 0,
            m21: 1, m22: 0, m23: 0,
            m31: 0, m32: 0, m33: 1
        )
        expect(rotatedField.distance(to: MagneticFieldVector(x: 0, y: 50, z: 0)) < 0.001,
               "orientation transform should map device field to reference frame")

        let stable = MagneticFieldVector(x: 0.1, y: 50.1, z: 0.0)
        for _ in 0..<30 { _ = detector.update(vector: stable) }
        expect(!detector.isDetected, "stable field should stay undetected")

        // One brief magnetic spike must not trigger the indicator.
        _ = detector.update(vector: MagneticFieldVector(x: 0, y: 54, z: 0))
        for _ in 0..<12 { _ = detector.update(vector: stable) }
        expect(!detector.isDetected, "single spike should be ignored")

        // A field change along any axis can trigger; it is not just a scalar-magnitude comparison.
        let changed = MagneticFieldVector(x: 3.0, y: 50.0, z: 0.0)
        _ = detector.update(vector: changed)
        _ = detector.update(vector: changed)
        expect(!detector.isDetected, "two consecutive samples should not trigger")
        _ = detector.update(vector: changed)
        expect(detector.isDetected, "three consecutive strong samples should trigger")

        for _ in 0..<9 { _ = detector.update(vector: stable) }
        expect(detector.isDetected, "detector should not clear too early")
        _ = detector.update(vector: stable)
        expect(!detector.isDetected, "ten clear samples should release the indicator")

        _ = detector.update(vector: MagneticFieldVector(x: .nan, y: 50, z: 0))
        expect(!detector.isDetected, "non-finite vector must not trigger")
        detector.reset()
        expect(!detector.hasBaseline && !detector.isDetected,
               "reset should clear baseline and state")

        // A lone raw spike must not dominate the filtered field-change value.
        var filter = FieldDeltaFilter(windowSize: 7, smoothingFactor: 0.4)
        var filtered: Double?
        for _ in 0..<7 { filtered = filter.update(1.0) }
        filtered = filter.update(100.0)
        expect(abs((filtered ?? -1) - 1.0) < 1e-9,
               "median filter should reject an isolated field spike")
        for _ in 0..<7 { filtered = filter.update(5.0) }
        expect((filtered ?? 0) > 1.0 && (filtered ?? 99) <= 5.0,
               "filtered output should track a sustained increase without overshooting")
        filter.reset()
        expect(filter.update(.nan) == nil,
               "non-finite field changes must be rejected by the filter")

        // The same static world field must remain identical after a quarter-turn.
        // CMRotationMatrix is transposed by MagneticFieldVector.rotated to recover
        // the reference-frame vector.
        let worldField = MagneticFieldVector(x: 30.0, y: -10.0, z: 20.0)
        let quarterTurnDeviceField = MagneticFieldVector(x: 10.0, y: 30.0, z: 20.0)
        let orientationCorrected = quarterTurnDeviceField.rotated(
            m11: 0.0, m12: -1.0, m13: 0.0,
            m21: 1.0, m22: 0.0, m23: 0.0,
            m31: 0.0, m32: 0.0, m33: 1.0
        )
        expect(abs(orientationCorrected.x - worldField.x) < 1e-9
               && abs(orientationCorrected.y - worldField.y) < 1e-9
               && abs(orientationCorrected.z - worldField.z) < 1e-9,
               "orientation compensation should recover a fixed field after a 90-degree turn")

        // Fast turns immediately invalidate the display; it recovers only after calm samples.
        var stabilityGate = OrientationStabilityGate()
        for _ in 0..<3 {
            expect(!stabilityGate.update(rotationRateRadiansPerSecond: 0.10),
                   "stability gate should debounce initial motion samples")
        }
        expect(stabilityGate.update(rotationRateRadiansPerSecond: 0.10),
               "stability gate should recover after four calm samples")
        expect(!stabilityGate.update(rotationRateRadiansPerSecond: 0.60),
               "fast phone rotation must immediately invalidate readings")
        expect(!stabilityGate.update(rotationRateRadiansPerSecond: 0.25),
               "the hysteresis band must not immediately mark a moving phone stable")
        for _ in 0..<4 {
            _ = stabilityGate.update(rotationRateRadiansPerSecond: 0.10)
        }
        expect(stabilityGate.isStable,
               "stability gate should recover after rotation stops")
        expect(!stabilityGate.update(rotationRateRadiansPerSecond: .infinity),
               "invalid angular-rate data must fail closed")

        // Robustly estimate the phone-fixed field bias from paired raw/calibrated vectors.
        let trueBias = MagneticFieldVector(x: 4.0, y: -3.0, z: 2.0)
        let calibratedWindow = (0..<15).map { i in
            MagneticFieldVector(x: Double(i), y: Double(i % 4) * 2.0, z: 25.0 - Double(i))
        }
        var rawWindow = calibratedWindow.map { $0.adding(trueBias) }
        rawWindow[3] = MagneticFieldVector(x: 400.0, y: -250.0, z: 100.0)
        let estimatedBias = MagneticFieldBiasEstimator.estimate(
            rawVectors: rawWindow,
            calibratedVectors: calibratedWindow,
            minimumPairs: 10
        )
        expect(estimatedBias != nil
               && abs((estimatedBias?.x ?? 0) - trueBias.x) < 1e-9
               && abs((estimatedBias?.y ?? 0) - trueBias.y) < 1e-9
               && abs((estimatedBias?.z ?? 0) - trueBias.z) < 1e-9,
               "median bias estimator must reject an isolated raw-field spike")

        // A fixed world field plus phone-fixed bias should be invariant after a 90-degree turn.
        let fixedWorld = MagneticFieldVector(x: 30.0, y: -10.0, z: 20.0)
        let bias = MagneticFieldVector(x: 4.0, y: -3.0, z: 2.0)
        let deviceFieldAfterTurn = MagneticFieldVector(x: -fixedWorld.y, y: fixedWorld.x, z: fixedWorld.z)
            .adding(bias)
        let correctedAfterTurn = deviceFieldAfterTurn.subtracting(bias).rotated(
            m11: 0.0, m12: -1.0, m13: 0.0,
            m21: 1.0, m22: 0.0, m23: 0.0,
            m31: 0.0, m32: 0.0, m33: 1.0
        )
        expect(abs(correctedAfterTurn.x - fixedWorld.x) < 1e-9
               && abs(correctedAfterTurn.y - fixedWorld.y) < 1e-9
               && abs(correctedAfterTurn.z - fixedWorld.z) < 1e-9,
               "bias correction plus attitude rotation must preserve a static field after a turn")

        expect(MagneticFieldBiasEstimator.estimate(
            rawVectors: Array(rawWindow.prefix(9)),
            calibratedVectors: Array(calibratedWindow.prefix(9)),
            minimumPairs: 10
        ) == nil, "bias calibration must reject insufficient paired samples")

        print("PASS: MagneticAnomalyDetectorTests")
    }
}
