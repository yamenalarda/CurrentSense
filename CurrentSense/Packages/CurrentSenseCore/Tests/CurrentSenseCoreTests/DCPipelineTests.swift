import XCTest
@testable import CurrentSenseCore

final class DCPipelineTests: XCTestCase {
    func testConstantBackgroundGivesNoDelta() {
        var g = Synth()
        let p = makePipeline(.dc)
        let out = feed(p, g.samples(from: 0, duration: 6))
        let last = out.last!
        XCTAssertEqual(p.phase, .measuring)
        XCTAssertLessThan(last.deltaMagnitude!, 0.15)
        XCTAssertLessThan(last.signalToNoise!, 8, "pure noise must not look like a strong signal")
        XCTAssertEqual(last.level, 0, accuracy: 0.0001)
        XCTAssertEqual(last.currentEstimate, .unavailable(.notCalibrated))
    }

    func testKnownDCStepIsRecoveredAsVectorDelta() {
        var g = Synth()
        let p = makePipeline(.dc)
        feed(p, g.samples(from: 0, duration: 2.5))
        let out = feed(p, g.samples(from: 2.5, duration: 4) { _ in Vector3(0, 0, 3) })
        let last = out.last!
        XCTAssertEqual(last.deltaMagnitude!, 3, accuracy: 0.15)
        XCTAssertEqual(last.deltaVector!.z, 3, accuracy: 0.15)
        XCTAssertEqual(last.deltaVector!.x, 0, accuracy: 0.15)
        XCTAssertGreaterThan(last.signalToNoise!, 30)
        XCTAssertEqual(last.confidence, .high)
        XCTAssertGreaterThan(last.level, 0.3)
    }

    func testCalibratedCurrentWithinTolerance() {
        let cal = Calibration(sensitivityMicroteslaPerAmp: 1.5, referenceCurrentAmps: 2, relativeUncertainty: 0.05)
        var g = Synth()
        let p = makePipeline(.dc, geometry: .calibrated(cal))
        feed(p, g.samples(from: 0, duration: 2.5))
        let last = feed(p, g.samples(from: 2.5, duration: 4) { _ in Vector3(0, 0, 3) }).last!
        guard case .available(let amps, let u, _)? = last.currentEstimate else { return XCTFail("expected estimate") }
        XCTAssertEqual(amps, 2.0, accuracy: 0.1)
        XCTAssertLessThan(u, 0.1)
    }

    func testIdealGeometryEstimate() {
        var g = Synth()
        let p = makePipeline(.dc, geometry: .idealSingleConductor(distanceMeters: 0.01, distanceRelativeUncertainty: 0.1))
        feed(p, g.samples(from: 0, duration: 2.5))
        let last = feed(p, g.samples(from: 2.5, duration: 4) { _ in Vector3(0, 0, 200) }).last!
        guard case .available(let amps, _, .idealSingleConductor)? = last.currentEstimate else { return XCTFail("expected estimate") }
        XCTAssertEqual(amps, 10, accuracy: 0.3)
    }

    func testWeakSignalYieldsUnavailableNotANumber() {
        let cal = Calibration(sensitivityMicroteslaPerAmp: 1.5, referenceCurrentAmps: 2, relativeUncertainty: 0.05)
        var g = Synth()
        let p = makePipeline(.dc, geometry: .calibrated(cal))
        feed(p, g.samples(from: 0, duration: 2.5))
        let last = feed(p, g.samples(from: 2.5, duration: 4) { _ in Vector3(0, 0, 0.05) }).last!
        XCTAssertEqual(last.currentEstimate, .unavailable(.lowSignal))
    }

    func testIrregularSamplingAndDropoutsStillAccurate() {
        var g = Synth(seed: 9); g.jitter = 0.3; g.dropout = 0.1
        let p = makePipeline(.dc)
        feed(p, g.samples(from: 0, duration: 2.6))
        XCTAssertEqual(p.phase, .measuring)
        let last = feed(p, g.samples(from: 2.6, duration: 4) { _ in Vector3(1, 2, 2) }).last!
        XCTAssertEqual(last.deltaMagnitude!, 3, accuracy: 0.25)
    }

    func testMotionBlocksReadingsAndEstimate() {
        let cal = Calibration(sensitivityMicroteslaPerAmp: 1.5, referenceCurrentAmps: 2, relativeUncertainty: 0.05)
        var g = Synth()
        let p = makePipeline(.dc, geometry: .calibrated(cal))
        feed(p, g.samples(from: 0, duration: 2.5))
        feed(p, g.samples(from: 2.5, duration: 2) { _ in Vector3(0, 0, 3) })
        g.rotationRate = Vector3(1, 0, 0)
        let moving = feed(p, g.samples(from: 4.5, duration: 1) { _ in Vector3(0, 0, 3) }).last!
        XCTAssertEqual(moving.issue, .holdStill)
        XCTAssertNil(moving.deltaMagnitude)
        XCTAssertEqual(moving.currentEstimate, .unavailable(.motion))
        XCTAssertEqual(moving.level, 0)
        XCTAssertEqual(moving.confidence, .none)
    }

    func testOrientationChangeInvalidatesBaseline() {
        var g = Synth()
        let p = makePipeline(.dc)
        feed(p, g.samples(from: 0, duration: 2.5))
        g.attitude = Quaternion.axisAngle(axis: Vector3(0, 1, 0), angle: 20 * .pi / 180)
        let last = feed(p, g.samples(from: 2.5, duration: 1)).last!
        XCTAssertEqual(last.issue, .orientationChanged)
        XCTAssertNil(last.deltaMagnitude)
        XCTAssertEqual(last.currentEstimate, .unavailable(.baselineInvalid))
    }

    func testMissingOrientationDegradesConfidence() {
        var g = Synth(); g.attitude = nil
        let p = makePipeline(.dc)
        feed(p, g.samples(from: 0, duration: 2.5))
        let last = feed(p, g.samples(from: 2.5, duration: 4) { _ in Vector3(0, 0, 3) }).last!
        XCTAssertFalse(last.hasOrientation)
        XCTAssertLessThanOrEqual(last.confidence, .moderate)
    }

    func testStaleBaselineIsDetected() {
        var g = Synth()
        let p = makePipeline(.dc)
        feed(p, g.samples(from: 0, duration: 2.5))
        // jump the clock 400 s ahead (gap resets filters), keep sampling
        let late = feed(p, g.samples(from: 400, duration: 1))
        XCTAssertEqual(late.last!.issue, .baselineStale)
    }

    func testBaselineRejectsNoisyEnvironment() {
        var g = Synth(); g.noise = 3
        let p = makePipeline(.dc)
        let out = feed(p, g.samples(from: 0, duration: 2.5))
        XCTAssertEqual(p.phase, .stopped)
        XCTAssertEqual(out.last?.issue, .environmentUnstable)
    }

    func testBaselineRejectsDrift() {
        var g = Synth()
        let p = makePipeline(.dc)
        let out = feed(p, g.samples(from: 0, duration: 2.5) { t in Vector3(0, 0, 2 * t) }) // 2 uT/s ramp
        XCTAssertEqual(p.phase, .stopped)
        XCTAssertEqual(out.last?.issue, .environmentUnstable)
    }

    func testBaselineRestartsWhileMoving() {
        var g = Synth()
        let p = makePipeline(.dc)
        g.rotationRate = Vector3(1, 0, 0)
        let moving = feed(p, g.samples(from: 0, duration: 1))
        XCTAssertEqual(moving.last?.issue, .holdStill)
        XCTAssertEqual(p.phase, .acquiring)
        g.rotationRate = .zero
        let out = feed(p, g.samples(from: 1, duration: 2.5))
        XCTAssertEqual(p.phase, .measuring)
        XCTAssertGreaterThanOrEqual(out.first { $0.phase == .measuring }!.time, 3.0 - 0.02, "needs a full still window after motion")
    }

    func testTooSlowSensorIsRejected() {
        var g = Synth(); g.rate = 10
        let p = makePipeline(.dc)
        let out = feed(p, g.samples(from: 0, duration: 3))
        XCTAssertEqual(p.phase, .stopped)
        XCTAssertEqual(out.last?.issue, .samplingTooSlow)
    }
}
