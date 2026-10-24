import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct ACFieldScanClassifierTests {
    static func main() {
        expect(
            ACFieldScanClassifier.classify(
                fieldChangeMicrotesla: 10,
                noiseSigmaMicrotesla: nil,
                isMeasuring: false,
                baselineCaptured: false
            ) == .idle,
            "idle mode should not claim a field was measured"
        )

        expect(
            ACFieldScanClassifier.classify(
                fieldChangeMicrotesla: nil,
                noiseSigmaMicrotesla: 0.1,
                isMeasuring: true,
                baselineCaptured: false
            ) == .capturingBaseline,
            "baseline state takes priority while reference is being captured"
        )

        expect(
            ACFieldScanClassifier.classify(
                fieldChangeMicrotesla: 0.49,
                noiseSigmaMicrotesla: 0.01,
                isMeasuring: true,
                baselineCaptured: true
            ) == .noDetectableChange,
            "sub-threshold field change must not claim detection"
        )

        expect(
            ACFieldScanClassifier.classify(
                fieldChangeMicrotesla: .nan,
                noiseSigmaMicrotesla: 0.1,
                isMeasuring: true,
                baselineCaptured: true
            ) == .unavailable,
            "NaN samples must not claim detection"
        )

        expect(
            ACFieldScanClassifier.threshold(noiseSigmaMicrotesla: 0.25) == 1.25,
            "threshold should rise to five times measured baseline noise"
        )

        expect(
            ACFieldScanClassifier.classify(
                fieldChangeMicrotesla: 1.5,
                noiseSigmaMicrotesla: 0.25,
                isMeasuring: true,
                baselineCaptured: true
            ) == .weak,
            "a response just above threshold should be weak"
        )

        expect(
            ACFieldScanClassifier.classify(
                fieldChangeMicrotesla: 3.0,
                noiseSigmaMicrotesla: 0.25,
                isMeasuring: true,
                baselineCaptured: true
            ) == .moderate,
            "two times threshold should be moderate"
        )

        let strong = ACFieldScanClassifier.classify(
            fieldChangeMicrotesla: 5.0,
            noiseSigmaMicrotesla: 0.25,
            isMeasuring: true,
            baselineCaptured: true
        )
        expect(strong == .strong, "four times threshold should be strong")
        expect(strong.strengthBars == 3, "strong level should show three visual bars")
        expect(strong.indicatesMagneticChange, "weak/moderate/strong mean a field change was observed")

        print("PASS: ACFieldScanClassifierTests")
    }
}
