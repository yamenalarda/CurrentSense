import XCTest
@testable import CurrentSenseCore

final class LifecycleTests: XCTestCase {
    func testStopIsIdempotentAndHaltsProcessing() {
        var g = Synth()
        let p = makePipeline(.dc)
        feed(p, g.samples(from: 0, duration: 3))
        p.stop(); p.stop()
        XCTAssertEqual(p.phase, .stopped)
        XCTAssertNil(p.ingest(g.samples(from: 3, duration: 0.1)[0]), "no processing after stop")
        let snap = p.currentSnapshot()
        XCTAssertFalse(snap.isLive)
        XCTAssertEqual(snap.phase, .stopped)
        XCTAssertEqual(ReadingsPresenter.present(snap).header, "Last result")
    }

    func testRepeatedStartStopLeavesConsistentState() {
        var g = Synth()
        let p = MeasurementPipeline()
        for i in 1...50 {
            p.start(mode: i % 2 == 0 ? .ac : .dc, session: i, geometry: .none, now: 0)
            p.stop()
        }
        p.start(mode: .dc, session: 51, geometry: .none, now: 0)
        XCTAssertEqual(p.phase, .acquiring)
        feed(p, g.samples(from: 0, duration: 3))
        XCTAssertEqual(p.phase, .measuring)
        XCTAssertEqual(p.currentSnapshot().session, 51)
    }

    func testOrdinaryHandRepositioningDoesNotPauseMeasurement() {
        var g = Synth()
        let p = makePipeline(.dc)
        _ = feed(p, g.samples(from: 0, duration: 3))
        XCTAssertEqual(p.phase, .measuring)

        // A modest 0.9 rad/s rotation is below the operating rejection threshold.
        g.rotationRate = Vector3(0.9, 0, 0)
        let snapshots = feed(p, g.samples(from: 3, duration: 1))
        XCTAssertFalse(snapshots.isEmpty)
        XCTAssertTrue(snapshots.contains { $0.phase == .measuring && $0.issue == .none })
        XCTAssertFalse(snapshots.contains { $0.issue == .holdStill })
    }

    func testModeSwitchClearsWhenIdleAndReacquiresWhenRunning() {
        var g = Synth()
        let p = makePipeline(.dc)
        feed(p, g.samples(from: 0, duration: 3))
        p.setMode(.ac, session: 2, now: 3)
        XCTAssertEqual(p.phase, .acquiring)
        XCTAssertEqual(p.currentSnapshot().mode, .ac)
        XCTAssertNil(p.currentSnapshot().deltaMagnitude, "no content from the previous mode")
        p.stop()
        p.setMode(.dc, session: 3, now: 4)
        XCTAssertEqual(p.phase, .idle)
        XCTAssertEqual(p.currentSnapshot().mode, .dc)
        XCTAssertNil(p.currentSnapshot().fieldPresent)
        XCTAssertEqual(ReadingsPresenter.present(p.currentSnapshot()).header, "Ready")
    }

    func testPublishRateIsLimited() {
        var g = Synth()
        let p = makePipeline(.dc)
        let out = feed(p, g.samples(from: 0, duration: 12))
        let measuring = out.filter { $0.phase == .measuring }.count
        XCTAssertLessThanOrEqual(measuring, 10 * 10 + 5)   // ~10 Hz over ~10 s, not 100 Hz
        XCTAssertGreaterThan(measuring, 80)
    }

    func testStallDetectionAndRecovery() {
        var g = Synth()
        let p = makePipeline(.dc)
        feed(p, g.samples(from: 0, duration: 3))
        XCTAssertNil(p.checkStall(now: 3.2))
        let stalled = p.checkStall(now: 4.0)
        XCTAssertEqual(stalled?.issue, .sensorStalled)
        XCTAssertFalse(stalled!.isLive)
        XCTAssertNil(stalled?.deltaMagnitude)
        XCTAssertNil(p.checkStall(now: 4.5), "reported once")
        let resumed = feed(p, g.samples(from: 6, duration: 1))
        XCTAssertEqual(resumed.first?.issue, PipelineIssue.none, "stale state must clear on fresh data")
        XCTAssertTrue(resumed.first?.isLive ?? false)
    }

    func testStartWithNoSamplesStalls() {
        let p = makePipeline(.ac)
        XCTAssertEqual(p.checkStall(now: 1.0)?.issue, .sensorStalled)
    }

    func testInvalidSamplesAreDroppedAndPersistentInvalidityIsFlagged() {
        var g = Synth()
        let p = makePipeline(.dc)
        feed(p, g.samples(from: 0, duration: 3))
        XCTAssertNil(p.ingest(MagSample(timestamp: 2.0, field: Vector3(1, 1, 1))), "non-monotonic dropped")
        var flagged: MeasurementSnapshot?
        for i in 0..<25 { flagged = p.ingest(MagSample(timestamp: 10 + Double(i) * 0.01, field: Vector3(.nan, 0, 0))) ?? flagged }
        XCTAssertEqual(flagged?.issue, .invalidData)
    }

    func testAbortReportsUnavailableSensor() {
        let p = makePipeline(.dc)
        p.abort(issue: .sensorUnavailable)
        XCTAssertEqual(p.phase, .stopped)
        let pres = ReadingsPresenter.present(p.currentSnapshot())
        XCTAssertTrue(pres.status.contains("not available"))
    }

    func testPresenterNeverShowsStaleAsLive() {
        var g = Synth()
        let p = makePipeline(.dc)
        feed(p, g.samples(from: 0, duration: 4))
        XCTAssertTrue(ReadingsPresenter.present(p.currentSnapshot()).isLive)
        p.stop()
        XCTAssertFalse(ReadingsPresenter.present(p.currentSnapshot()).isLive)
    }

    func testAudioMapperMonotonicSmoothAndSilent() {
        var last = 0.0
        for i in 0...100 {
            let f = AudioToneMapper.frequency(forLevel: Double(i) / 100)
            XCTAssertGreaterThanOrEqual(f, last); last = f
        }
        XCTAssertEqual(AudioToneMapper.frequency(forLevel: 0), 220, accuracy: 1e-9)
        XCTAssertEqual(AudioToneMapper.frequency(forLevel: 1), 880, accuracy: 1e-9)

        var m = AudioToneMapper()
        let a = m.update(level: 0.5, active: true, dt: 0.1)
        let b = m.update(level: 0.51, active: true, dt: 0.1)
        XCTAssertEqual(a.frequencyHz, b.frequencyHz, accuracy: 1e-9, "deadband suppresses jitter")
        let c = m.update(level: 1.0, active: true, dt: 0.1)
        XCTAssertLessThanOrEqual(log2(c.frequencyHz / b.frequencyHz), 0.1501, "slew limit")
        XCTAssertEqual(m.update(level: 0.8, active: false, dt: 0.1).amplitude, 0)
        XCTAssertEqual(m.update(level: 0, active: true, dt: 0.1).amplitude, 0)
        XCTAssertLessThanOrEqual(a.amplitude, 0.2)
    }
    func testRoughCurrentIsLabelled() {
        XCTAssertEqual(ReadingsPresenter.formatCurrent(amps: 2.04, relativeUncertainty: 0.32, rough: true),
                       "≈ 2.0 A ±30% (rough)")
        XCTAssertFalse(ReadingsPresenter.formatCurrent(amps: 2, relativeUncertainty: 0.1).contains("rough"))
    }
}
