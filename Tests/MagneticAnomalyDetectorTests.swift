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

        print("PASS: MagneticAnomalyDetectorTests")
    }
}
