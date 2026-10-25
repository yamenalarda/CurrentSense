import Foundation

/// Deterministic measurement state machine. NOT thread-safe: confine it to a single serial queue.
/// All timing uses sample timestamps (and a caller-supplied `now` for stall checks), never wall clocks.
public final class MeasurementPipeline {
    public let config: PipelineConfig
    public private(set) var mode: MeasurementMode = .dc
    public private(set) var phase: MeasurementPhase = .idle
    public private(set) var session: Int = 0
    public private(set) var geometry: GeometryModel = .none

    private var validator: SampleValidator
    private var rate = RateEstimator()
    private var acquirer: BaselineAcquirer
    private var baseline: Baseline?
    private var dc: DCProcessor
    private var ac: ACProcessor?
    private var motion = MotionGate()
    private var previousTimestamp: TimeInterval?
    private var lastPublishTime = -Double.infinity
    private var lastSampleTime: TimeInterval = 0
    private var consecutiveInvalid = 0
    private var externalIssue: PipelineIssue = .none
    private var acquisitionProgress = 0.0
    private var acquisitionIssue: PipelineIssue = .none
    private var isMoving = false
    private var orientationChanged = false
    private var hasOrientation = false
    private var latest: MeasurementSnapshot

    public init(config: PipelineConfig = .default) {
        self.config = config
        validator = SampleValidator(maxMagnitude: config.maxFieldMagnitude)
        acquirer = BaselineAcquirer(config: config)
        dc = DCProcessor(config: config)
        latest = .cleared(mode: .dc, phase: .idle, session: 0)
    }

    public func currentSnapshot() -> MeasurementSnapshot { latest }

    // MARK: Commands

    public func start(mode: MeasurementMode, session: Int, geometry: GeometryModel, now: TimeInterval) {
        self.mode = mode
        self.session = session
        self.geometry = geometry
        beginAcquisition(now: now)
    }

    /// Switching mode never carries content over: a running measurement re-acquires in the new mode,
    /// an idle/stopped one is cleared.
    public func setMode(_ newMode: MeasurementMode, session: Int, now: TimeInterval) {
        mode = newMode
        self.session = session
        if phase == .acquiring || phase == .measuring {
            beginAcquisition(now: now)
        } else {
            resetState()
            phase = .idle
            latest = .cleared(mode: newMode, phase: .idle, session: session)
        }
    }

    public func setGeometry(_ g: GeometryModel) { geometry = g }

    public func stop() {
        guard phase == .acquiring || phase == .measuring else { return }
        phase = .stopped
        latest.phase = .stopped
        latest.isLive = false
        latest.issue = .none
        externalIssue = .none
    }

    public func abort(issue: PipelineIssue) {
        phase = .stopped
        externalIssue = .none
        latest = .cleared(mode: mode, phase: .stopped, session: session, issue: issue)
    }

    /// Watchdog: call a few times per second while running.
    public func checkStall(now: TimeInterval) -> MeasurementSnapshot? {
        guard phase == .acquiring || phase == .measuring else { return nil }
        guard now - lastSampleTime > config.stallTimeout else { return nil }
        return flagIssue(.sensorStalled)
    }

    // MARK: Ingestion

    /// Feeds one sample. Returns a snapshot only when one is due (rate-limited) or state changed.
    public func ingest(_ s: MagSample) -> MeasurementSnapshot? {
        guard phase == .acquiring || phase == .measuring else { return nil }

        switch validator.validate(s) {
        case .valid:
            consecutiveInvalid = 0
        case .nonMonotonic:
            return nil
        case .nonFinite, .implausible:
            consecutiveInvalid += 1
            return consecutiveInvalid >= config.maxConsecutiveInvalid ? flagIssue(.invalidData) : nil
        }

        var forced = false
        if externalIssue != .none { externalIssue = .none; forced = true }
        lastSampleTime = s.timestamp
        rate.add(s.timestamp)
        if let prev = previousTimestamp, s.timestamp - prev > config.maxSampleGap { handleGap() }
        previousTimestamp = s.timestamp

        switch phase {
        case .acquiring:
            switch acquirer.add(s) {
            case .inProgress(let p, let issue):
                acquisitionProgress = p
                acquisitionIssue = issue
            case .completed(let b):
                baseline = b
                beginMeasuring(b)
                forced = true
            case .failed(let issue):
                phase = .stopped
                latest = .cleared(mode: mode, phase: .stopped, session: session, issue: issue)
                return latest
            }
        case .measuring:
            guard let b = baseline else { return nil }
            isMoving = motion.update(s, limit: config.maxOperatingRotationRate, holdoff: config.motionHoldoff)
            if let a0 = b.attitude, let a1 = s.attitude {
                hasOrientation = true
                orientationChanged = a0.angle(to: a1) > config.orientationInvalidationAngle
            } else {
                hasOrientation = false
                orientationChanged = false
            }
            switch mode {
            case .dc: dc.process(s, baseline: b)
            case .ac: ac?.process(s)
            }
        default:
            return nil
        }
        return publishIfDue(s.timestamp, force: forced)
    }

    // MARK: Internals

    private func resetState() {
        validator.reset()
        rate.reset()
        acquirer = BaselineAcquirer(config: config)
        baseline = nil
        dc.reset()
        ac = nil
        motion.reset()
        previousTimestamp = nil
        lastPublishTime = -.infinity
        consecutiveInvalid = 0
        externalIssue = .none
        acquisitionProgress = 0
        acquisitionIssue = .none
        isMoving = false
        orientationChanged = false
        hasOrientation = false
    }

    private func beginAcquisition(now: TimeInterval) {
        resetState()
        lastSampleTime = now
        phase = .acquiring
        latest = .cleared(mode: mode, phase: .acquiring, session: session)
    }

    private func beginMeasuring(_ b: Baseline) {
        phase = .measuring
        dc.reset()
        ac = ACProcessor(config: config, sampleRate: b.sampleRate)
        motion.reset()
        isMoving = false
        orientationChanged = false
    }

    private func handleGap() {
        dc.reset()
        ac?.reset()
        if phase == .acquiring { acquirer.restart(); acquisitionProgress = 0 }
    }

    private func flagIssue(_ issue: PipelineIssue) -> MeasurementSnapshot? {
        guard externalIssue != issue else { return nil }
        externalIssue = issue
        latest = .cleared(mode: mode, phase: phase, session: session, issue: issue)
        return latest
    }

    private func publishIfDue(_ t: Double, force: Bool) -> MeasurementSnapshot? {
        guard force || t - lastPublishTime >= config.publishInterval else { return nil }
        lastPublishTime = t
        latest = buildSnapshot(at: t)
        return latest
    }

    private func buildSnapshot(at t: Double) -> MeasurementSnapshot {
        switch phase {
        case .acquiring:
            var s = MeasurementSnapshot.cleared(mode: mode, phase: .acquiring, session: session,
                                                issue: acquisitionIssue, progress: acquisitionProgress)
            s.time = t
            s.isLive = true
            s.effectiveSampleRate = rate.rate
            return s
        case .measuring:
            return buildMeasuring(at: t)
        default:
            return latest
        }
    }

    private func buildMeasuring(at t: Double) -> MeasurementSnapshot {
        var s = MeasurementSnapshot(session: session, mode: mode, phase: .measuring)
        s.time = t
        s.isLive = true
        guard let b = baseline else { return s }
        let fs = rate.rate
        s.effectiveSampleRate = fs
        s.hasOrientation = hasOrientation

        var issue = PipelineIssue.none
        if isMoving { issue = .holdStill }
        else if mode == .dc && orientationChanged { issue = .orientationChanged }
        else if t - b.acquiredAt > config.baselineMaxAge { issue = .baselineStale }
        else if let f = fs, f < config.minSampleRate { issue = .samplingTooSlow }
        s.issue = issue

        switch mode {
        case .dc:
            if issue == .none, let f = fs, let r = dc.reading(baseline: b, sampleRate: f) {
                s.deltaVector = r.delta
                s.deltaMagnitude = r.deltaMagnitude
                s.fieldMagnitude = r.fieldMagnitude
                s.signalToNoise = r.snr
                s.relativeSpread = r.spread
                s.confidence = QualityAssessor.dcConfidence(snr: r.snr, spread: r.spread,
                                                            hasOrientation: hasOrientation, config: config)
                s.level = QualityAssessor.dcLevel(snr: r.snr, config: config)
                s.currentEstimate = CurrentEstimator.estimate(deltaMagnitude: r.deltaMagnitude, snr: r.snr,
                                                              spread: r.spread, issue: .none,
                                                              model: geometry, config: config)
            } else {
                s.currentEstimate = CurrentEstimator.estimate(deltaMagnitude: nil, snr: nil, spread: nil,
                                                              issue: issue, model: geometry, config: config)
            }
        case .ac:
            let r = ac?.evaluate(at: t, noiseFloor: b.acNoiseFloor, sampleRate: fs, suppress: issue != .none)
            if issue == .none, let r = r, let ratio = r.ratio {
                s.fieldPresent = r.present
                s.strength = r.present ? r.strength : FieldStrengthCategory.none
                s.acRatio = ratio
                s.mainsSignature = r.mains
                s.confidence = QualityAssessor.acConfidence(ratio: ratio, present: r.present, mains: r.mains, config: config)
                s.level = QualityAssessor.acLevel(ratio: ratio, present: r.present, config: config)
            }
            // currentEstimate stays nil: AC mode has no numerical current, by construction.
        }
        return s
    }
}
