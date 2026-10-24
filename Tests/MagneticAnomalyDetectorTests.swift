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

        print("PASS: MagneticAnomalyDetectorTests")
    }
}
