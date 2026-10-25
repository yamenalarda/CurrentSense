import XCTest
@testable import CurrentSenseCore

final class CoreMathTests: XCTestCase {
    func testMagnitudeKnownAnswer() {
        XCTAssertEqual(Vector3(3, 4, 12).magnitude, 13, accuracy: 1e-12)
        XCTAssertEqual(Vector3.zero.magnitude, 0)
    }

    func testVectorSubtractionIsNotScalarSubtraction() {
        let bg = Vector3(20, -5, -40)
        let withTarget = bg + Vector3(0, 0, 3)
        XCTAssertEqual((withTarget - bg).magnitude, 3, accuracy: 1e-12)
        let scalarDiff = withTarget.magnitude - bg.magnitude
        XCTAssertGreaterThan(abs(abs(scalarDiff) - 3), 0.1, "scalar magnitude difference must differ from the vector delta")
    }

    func testQuaternionAngle() {
        let q = Quaternion.axisAngle(axis: Vector3(0, 0, 1), angle: 10 * .pi / 180)
        XCTAssertEqual(Quaternion.identity.angle(to: q), 10 * .pi / 180, accuracy: 1e-9)
        XCTAssertEqual(Quaternion.identity.angle(to: Quaternion(x: 0, y: 0, z: 0, w: -1)), 0, accuracy: 1e-9, "q and -q are the same rotation")
        XCTAssertEqual(Quaternion.identity.angle(to: Quaternion(x: 0, y: 0, z: 0, w: 0)), .pi, "degenerate attitude is treated as maximal change")
    }

    func testValidatorRejectsBadSamples() {
        var v = SampleValidator(maxMagnitude: 10_000)
        func s(_ t: Double, _ f: Vector3) -> MagSample { MagSample(timestamp: t, field: f) }
        XCTAssertEqual(v.validate(s(1, Vector3(1, 2, 3))), .valid)
        XCTAssertEqual(v.validate(s(1, Vector3(1, 2, 3))), .nonMonotonic)
        XCTAssertEqual(v.validate(s(0.5, Vector3(1, 2, 3))), .nonMonotonic)
        XCTAssertEqual(v.validate(s(2, Vector3(.nan, 0, 0))), .nonFinite)
        XCTAssertEqual(v.validate(s(2, Vector3(0, 0, 0))), .implausible)
        XCTAssertEqual(v.validate(s(2, Vector3(1e5, 0, 0))), .implausible)
        XCTAssertEqual(v.validate(s(2, Vector3(1, 0, 0))), .valid, "rejected samples must not advance the clock")
    }

    func testRateEstimatorIrregular() {
        var r = RateEstimator()
        var g = Synth(seed: 7); g.jitter = 0.3; g.dropout = 0.1
        for s in g.samples(from: 0, duration: 3) { r.add(s.timestamp) }
        XCTAssertEqual(r.rate!, 100, accuracy: 15)
    }

    func testLowPassTimeConstantAndIrregularSteps() {
        var lp = TimeAwareLowPass(tau: 0.25)
        lp.update(Vector3.zero, at: 0)
        var t = 0.0
        while t < 0.25 { t += 0.005; lp.update(Vector3(1, 0, 0), at: t) }
        XCTAssertEqual(lp.value!.x, 1 - exp(-1), accuracy: 0.01)
        var lp2 = TimeAwareLowPass(tau: 0.25)
        lp2.update(Vector3.zero, at: 0)
        for t in [0.01, 0.05, 0.07, 0.2, 0.25] { lp2.update(Vector3(1, 0, 0), at: t) }
        XCTAssertEqual(lp2.value!.x, 1 - exp(-1), accuracy: 0.01, "result depends on time, not on sample count")
    }

    func testHighPassRemovesDCAndPassesFastTone() {
        var hp = TimeAwareHighPass(cutoffHz: 8)
        var maxDC = 0.0, maxTone = 0.0
        for i in 0..<400 { // constant
            let y = hp.update(Vector3(5, 5, 5), at: Double(i) / 100)
            if i > 100 { maxDC = max(maxDC, y.magnitude) }
        }
        XCTAssertLessThan(maxDC, 1e-6)
        hp.reset()
        for i in 0..<400 {
            let y = hp.update(Vector3(sin(2 * Double.pi * 40 * Double(i) / 100), 0, 0), at: Double(i) / 100)
            if i > 100 { maxTone = max(maxTone, y.magnitude) }
        }
        XCTAssertGreaterThan(maxTone, 0.45)
        XCTAssertLessThan(maxTone, 1.0)
    }

    func testAliasingKnownAnswers() {
        XCTAssertEqual(SpectralTone.aliasedFrequency(60, sampleRate: 100), 40, accuracy: 1e-9)
        XCTAssertEqual(SpectralTone.aliasedFrequency(50, sampleRate: 100), 50, accuracy: 1e-9)
        XCTAssertEqual(SpectralTone.aliasedFrequency(50, sampleRate: 50), 0, accuracy: 1e-9)
        XCTAssertEqual(SpectralTone.aliasedFrequency(60, sampleRate: 120), 60, accuracy: 1e-9)
    }

    func testHysteresisDwellAndHold() {
        var h = HysteresisDetector(enter: 2, exit: 1.5, enterDwell: 0.3, exitDwell: 0.5)
        XCTAssertFalse(h.update(3, at: 0)); XCTAssertFalse(h.update(3, at: 0.2))
        XCTAssertFalse(h.update(1, at: 0.25), "spike shorter than dwell is ignored")
        XCTAssertFalse(h.update(3, at: 1.0)); XCTAssertTrue(h.update(3, at: 1.35))
        XCTAssertTrue(h.update(1.7, at: 2.0), "between exit and enter the state holds")
        XCTAssertTrue(h.update(1.0, at: 2.1)); XCTAssertTrue(h.update(1.0, at: 2.4))
        XCTAssertFalse(h.update(1.0, at: 2.7))
    }

    func testStrengthCategoryHysteresis() {
        let c = PipelineConfig.default
        XCTAssertEqual(ACProcessor.category(ratio: 3, previous: .none, config: c), .weak)
        XCTAssertEqual(ACProcessor.category(ratio: 5, previous: .none, config: c), .moderate)
        XCTAssertEqual(ACProcessor.category(ratio: 12, previous: .none, config: c), .strong)
        XCTAssertEqual(ACProcessor.category(ratio: 4.2, previous: .weak, config: c), .weak, "within 10% band of the boundary")
        XCTAssertEqual(ACProcessor.category(ratio: 4.5, previous: .weak, config: c), .moderate)
        XCTAssertEqual(ACProcessor.category(ratio: 3.8, previous: .moderate, config: c), .moderate)
        XCTAssertEqual(ACProcessor.category(ratio: 3.5, previous: .moderate, config: c), .weak)
    }
}
