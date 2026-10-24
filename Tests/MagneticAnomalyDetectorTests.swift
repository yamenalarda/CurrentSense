import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

// A single extreme baseline sample must not move the median materially.
var detector = MagneticAnomalyDetector()
detector.setBaseline(from: [49.9, 50.0, 50.0, 50.1, 50.1, 50.2, 50.0, 90.0])
expect(detector.hasBaseline, "baseline should be accepted")
expect(abs((detector.baselineMagnitude ?? 0) - 50.05) < 0.001,
       "median baseline should resist an outlier")

// Stable environmental field should never trigger the indicator.
for _ in 0..<30 {
    _ = detector.update(magnitude: 50.1)
}
expect(!detector.isDetected, "stable field should stay undetected")

// One brief spike must not trigger the indicator.
_ = detector.update(magnitude: 54.0)
for _ in 0..<12 {
    _ = detector.update(magnitude: 50.1)
}
expect(!detector.isDetected, "single spike should be ignored")

// A sustained change should trigger after the configured persistence count.
_ = detector.update(magnitude: 53.5)
_ = detector.update(magnitude: 53.5)
expect(!detector.isDetected, "two consecutive samples should not trigger")
_ = detector.update(magnitude: 53.5)
expect(detector.isDetected, "three consecutive strong samples should trigger")

// Hysteresis requires a full stable-clear window before releasing the indicator.
for _ in 0..<9 {
    _ = detector.update(magnitude: 50.1)
}
expect(detector.isDetected, "detector should not clear too early")
_ = detector.update(magnitude: 50.1)
expect(!detector.isDetected, "ten clear samples should release the indicator")

// Invalid input must not create a positive detection.
_ = detector.update(magnitude: .nan)
expect(!detector.isDetected, "non-finite magnitude must not trigger")

detector.reset()
expect(!detector.hasBaseline && !detector.isDetected, "reset should clear baseline and state")

print("PASS: MagneticAnomalyDetectorTests")
