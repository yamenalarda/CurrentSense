import XCTest
@testable import CurrentSenseCore

final class EstimationTests: XCTestCase {
    let cfg = PipelineConfig.default

    func testIdealWireKnownAnswers() {
        // B = mu0 I / (2 pi r): 10 A at 1 cm -> 200 uT
        XCTAssertEqual(CurrentEstimator.idealSingleConductorField(amps: 10, distanceMeters: 0.01), 200, accuracy: 1e-6)
        XCTAssertEqual(CurrentEstimator.idealSingleConductorCurrent(fieldMicrotesla: 200, distanceMeters: 0.01), 10, accuracy: 1e-9)
        // 1 uT at 1 cm -> 0.05 A
        XCTAssertEqual(CurrentEstimator.idealSingleConductorCurrent(fieldMicrotesla: 1, distanceMeters: 0.01), 0.05, accuracy: 1e-6)
        // Inverse-distance scaling
        let a = CurrentEstimator.idealSingleConductorField(amps: 5, distanceMeters: 0.02)
        let b = CurrentEstimator.idealSingleConductorField(amps: 5, distanceMeters: 0.04)
        XCTAssertEqual(a / b, 2, accuracy: 1e-9)
    }

    private func est(delta: Double? = 3, snr: Double? = 100, spread: Double? = 0.01, issue: PipelineIssue = .none,
                     model: GeometryModel) -> CurrentEstimate {
        CurrentEstimator.estimate(deltaMagnitude: delta, snr: snr, spread: spread, issue: issue, model: model, config: cfg)
    }

    func testNoModelIsUnavailable() {
        XCTAssertEqual(est(model: .none), .unavailable(.notCalibrated))
    }

    func testCalibratedEstimate() {
        let cal = Calibration(sensitivityMicroteslaPerAmp: 1.5, referenceCurrentAmps: 2, relativeUncertainty: 0.05)
        guard case .available(let a, let u, let basis) = est(model: .calibrated(cal)) else { return XCTFail("expected estimate") }
        XCTAssertEqual(a, 2.0, accuracy: 1e-9)
        XCTAssertEqual(u, (0.05 * 0.05 + 1e-4).squareRoot(), accuracy: 1e-9)
        XCTAssertEqual(basis, .calibration)
    }

    func testGatingRejectsInvalidConditions() {
        let cal = Calibration(sensitivityMicroteslaPerAmp: 1.5, referenceCurrentAmps: 2, relativeUncertainty: 0.05)
        let m = GeometryModel.calibrated(cal)
        XCTAssertEqual(est(snr: 5, model: m), .unavailable(.lowSignal))
        XCTAssertEqual(est(delta: nil, snr: nil, model: m), .unavailable(.lowSignal))
        XCTAssertEqual(est(spread: 0.2, model: m), .unavailable(.unstable))
        XCTAssertEqual(est(spread: nil, model: m), .unavailable(.unstable))
        XCTAssertEqual(est(issue: .holdStill, model: m), .unavailable(.motion))
        XCTAssertEqual(est(issue: .orientationChanged, model: m), .unavailable(.baselineInvalid))
        XCTAssertEqual(est(issue: .sensorStalled, model: m), .unavailable(.measurementInvalid))
        XCTAssertEqual(est(delta: 30, model: m), .unavailable(.outOfCalibratedRange), "20 A against a 2 A calibration")
        let sloppy = Calibration(sensitivityMicroteslaPerAmp: 1.5, referenceCurrentAmps: 2, relativeUncertainty: 0.6)
        XCTAssertEqual(est(model: .calibrated(sloppy)), .unavailable(.excessiveUncertainty))
        XCTAssertEqual(est(model: .idealSingleConductor(distanceMeters: 5, distanceRelativeUncertainty: 0.1)), .unavailable(.invalidGeometry))
    }

    func testIdealModelCarriesLargeModelUncertainty() {
        guard case .available(let a, let u, let basis) = est(delta: 200, model: .idealSingleConductor(distanceMeters: 0.01, distanceRelativeUncertainty: 0.1)) else { return XCTFail() }
        XCTAssertEqual(a, 10, accuracy: 1e-6)
        XCTAssertGreaterThanOrEqual(u, 0.3)
        XCTAssertEqual(basis, .idealSingleConductor)
        XCTAssertEqual(est(delta: 200, model: .idealSingleConductor(distanceMeters: 0.01, distanceRelativeUncertainty: 0.45)), .unavailable(.excessiveUncertainty))
    }

    func testConfidenceRules() {
        XCTAssertEqual(QualityAssessor.dcConfidence(snr: 100, spread: 0.01, hasOrientation: true, config: cfg), .high)
        XCTAssertEqual(QualityAssessor.dcConfidence(snr: 100, spread: 0.01, hasOrientation: false, config: cfg), .moderate)
        XCTAssertEqual(QualityAssessor.dcConfidence(snr: 15, spread: 0.04, hasOrientation: true, config: cfg), .moderate)
        XCTAssertEqual(QualityAssessor.dcConfidence(snr: 15, spread: 0.2, hasOrientation: true, config: cfg), .low)
        XCTAssertEqual(QualityAssessor.dcConfidence(snr: 1, spread: 0.01, hasOrientation: true, config: cfg), .low)
        XCTAssertEqual(QualityAssessor.dcLevel(snr: 2, config: cfg), 0)
        XCTAssertEqual(QualityAssessor.dcLevel(snr: 1000, config: cfg), 1, accuracy: 1e-9)
    }

    func testCalibrationRecorder() {
        var rec = CalibrationRecorder(referenceAmps: 2)
        func snap(_ t: Double, delta: Double = 3, snr: Double = 100, issue: PipelineIssue = .none) -> MeasurementSnapshot {
            var s = MeasurementSnapshot(session: 1, mode: .dc, phase: .measuring)
            s.isLive = true; s.time = t; s.issue = issue
            s.deltaMagnitude = delta; s.signalToNoise = snr; s.relativeSpread = 0.01
            return s
        }
        var status = CalibrationRecorder.Status.inProgress(0)
        for i in 0..<20 { status = rec.add(snap(Double(i) * 0.1)) }
        if case .inProgress(let progress) = status { XCTAssertLessThan(progress, 1) } else { XCTFail("must not finish after 1.9 s") }
        for i in 20...35 { status = rec.add(snap(Double(i) * 0.1)) }
        guard case .succeeded(let cal) = status else { return XCTFail("expected calibration") }
        XCTAssertEqual(cal.sensitivityMicroteslaPerAmp, 1.5, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(cal.relativeUncertainty, 0.05)

        var rec2 = CalibrationRecorder(referenceAmps: 2)
        for i in 0..<20 { _ = rec2.add(snap(Double(i) * 0.1)) }
        XCTAssertEqual(rec2.add(snap(2.0, issue: .holdStill)), .inProgress(0), "motion restarts the recording")
        var rec3 = CalibrationRecorder(referenceAmps: 2)
        for i in 0..<60 { status = rec3.add(snap(Double(i) * 0.1, snr: 4)) }
        XCTAssertEqual(status, .inProgress(0), "weak signal can never produce a calibration")
    }
}
