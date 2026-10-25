import XCTest
@testable import CurrentSenseCore

final class ACPipelineTests: XCTestCase {
    func runAC(_ g: inout Synth, quiet: Double = 2.5, active: Double = 4,
               extra: @escaping (Double) -> Vector3) -> [MeasurementSnapshot] {
        let p = makePipeline(.ac)
        feed(p, g.samples(from: 0, duration: quiet))
        return feed(p, g.samples(from: quiet, duration: active, extra: extra))
    }

    func testQuietNoiseNeverReportsAField() {
        var g = Synth(seed: 5)
        let p = makePipeline(.ac)
        let out = feed(p, g.samples(from: 0, duration: 40))
        XCTAssertTrue(out.allSatisfy { $0.fieldPresent != true })
        XCTAssertEqual(out.last?.fieldPresent, false)
        XCTAssertEqual(out.last?.strength, FieldStrengthCategory.none)
    }

    func test60HzToneAliasedTo40HzIsDetected() {
        var g = Synth()
        let out = runAC(&g, extra: tone(60, amplitude: 1.5))   // ratio ~7: mid "moderate" band
        let last = out.last!
        XCTAssertEqual(last.fieldPresent, true)
        XCTAssertEqual(last.strength, .moderate)
        XCTAssertEqual(last.mainsSignature?.line60, .present)
        XCTAssertEqual(last.mainsSignature?.line50, .unresolvable, "50 Hz sits at Nyquist for a 100 Hz sensor")
        XCTAssertGreaterThanOrEqual(last.confidence, .moderate)
    }

    func testStrongerToneGivesStrongerCategory() {
        var g = Synth()
        let last = runAC(&g, extra: tone(60, amplitude: 8)).last!
        XCTAssertEqual(last.strength, .strong)
        XCTAssertGreaterThan(last.level, runAC_level(1.5))
    }

    private func runAC_level(_ amp: Double) -> Double {
        var g = Synth()
        return runAC(&g, extra: tone(60, amplitude: amp)).last!.level
    }

    func testSubThresholdToneIsNotReported() {
        var g = Synth()
        let last = runAC(&g, extra: tone(60, amplitude: 0.2)).last!
        XCTAssertEqual(last.fieldPresent, false)
    }

    func test50HzAtNyquistIsPhaseDependent_KnownLimitation() {
        // At fs = 100 Hz a 50 Hz tone is sampled as A*sin(phase)*(-1)^n: invisible at phase 0.
        var g1 = Synth()
        XCTAssertEqual(runAC(&g1, extra: tone(50, amplitude: 2, phase: .pi / 2)).last?.fieldPresent, true)
        var g2 = Synth()
        XCTAssertEqual(runAC(&g2, extra: tone(50, amplitude: 2, phase: 0)).last?.fieldPresent, false,
                       "documented blind spot, see docs/SCIENCE.md")
    }

    func testAliasedHarmonicIsIndistinguishableFrom60Hz_KnownLimitation() {
        var g = Synth()
        let last = runAC(&g, extra: tone(140, amplitude: 2)).last!   // 140 Hz also aliases to 40 Hz
        XCTAssertEqual(last.mainsSignature?.line60, .present)
    }

    func testToneAt130HzIsDetectedAsActivityButNotMains() {
        var g = Synth()
        let last = runAC(&g, extra: tone(130, amplitude: 2)).last!   // aliases to 30 Hz
        XCTAssertEqual(last.fieldPresent, true)
        XCTAssertEqual(last.mainsSignature?.line60, .absent)
    }

    func testSlowHandMotionFieldChangeIsRejectedByHighPass() {
        var g = Synth()
        let last = runAC(&g, extra: tone(1.5, amplitude: 5)).last!   // 1.5 Hz sway of a magnet
        XCTAssertEqual(last.fieldPresent, false)
    }

    func testRotationSuppressesAC() {
        var g = Synth()
        let p = makePipeline(.ac)
        feed(p, g.samples(from: 0, duration: 2.5))
        g.rotationRate = Vector3(2.0, 0, 0) // fast rotation remains suppressed
        let last = feed(p, g.samples(from: 2.5, duration: 2, extra: tone(60, amplitude: 4))).last!
        XCTAssertEqual(last.issue, .holdStill)
        XCTAssertNil(last.fieldPresent)
        XCTAssertEqual(last.level, 0)
    }

    func testPresenceDoesNotChatter() {
        var g = Synth()
        let out = runAC(&g, active: 10, extra: tone(60, amplitude: 0.35))   // ratio ~2.0: right at the enter threshold
        let flips = zip(out, out.dropFirst()).filter { $0.0.fieldPresent != $0.1.fieldPresent }.count
        XCTAssertLessThanOrEqual(flips, 2)
    }

    func testACSnapshotsNeverCarryCurrent() {
        var g = Synth()
        let out = runAC(&g, extra: tone(60, amplitude: 8))
        XCTAssertFalse(out.isEmpty)
        for s in out {
            XCTAssertNil(s.currentEstimate)
            let pres = ReadingsPresenter.present(s)
            XCTAssertFalse(pres.rows.contains { $0.label.lowercased().contains("current") })
            XCTAssertFalse(pres.rows.contains { $0.value.contains(" A") })
            XCTAssertNotNil(pres.disclaimer)
        }
    }

    func testIrregularSamplingStillDetects() {
        var g = Synth(seed: 3); g.jitter = 0.2; g.dropout = 0.05
        let last = runAC(&g, extra: tone(60, amplitude: 4)).last!
        XCTAssertEqual(last.fieldPresent, true)
    }
}
