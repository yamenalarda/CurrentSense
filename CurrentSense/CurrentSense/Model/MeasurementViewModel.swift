import SwiftUI
import CurrentSenseCore

@MainActor
final class MeasurementViewModel: ObservableObject {
    @Published private(set) var snapshot: MeasurementSnapshot
    @Published private(set) var mode: MeasurementMode = .dc
    @Published private(set) var isRunning = false
    @Published private(set) var notice: String?
    @Published private(set) var geometryChoice: GeometryChoice
    @Published private(set) var idealDistanceCm: Double
    @Published private(set) var calibration: Calibration?
    @Published private(set) var calibrationProgress: Double?
    @Published private(set) var calibrationMessage: String?
    @Published var audioEnabled: Bool {
        didSet {
            settings.audioEnabled = audioEnabled
            if !audioEnabled { audio.silence() }
        }
    }

    private let settings = SettingsStore()
    private let audio = AudioFeedbackService()
    private var engine: MeasurementEngine!
    private var session = 0
    private var recorder: CalibrationRecorder?

    init() {
        snapshot = .cleared(mode: .dc, phase: .idle, session: 0)
        audioEnabled = settings.audioEnabled
        geometryChoice = settings.geometryChoice
        idealDistanceCm = settings.idealDistanceCm
        calibration = settings.calibration
        engine = MeasurementEngine(source: Self.makeSource()) { [weak self] snap in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.receive(snap) }
            }
        }
        audio.onFailure = { [weak self] message in self?.notice = message }
    }

    private static func makeSource() -> MagnetometerSource {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-UITestSyntheticSensor") { return SyntheticSource() }
        #endif
        return CoreMotionSource()
    }

    // MARK: User intents

    func toggle() { isRunning ? stop() : start() }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        notice = nil
        session += 1
        snapshot = .cleared(mode: mode, phase: .acquiring, session: session)
        engine.start(mode: mode, session: session, geometry: currentGeometry)
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        audio.stop()
        cancelCalibration()
        engine.stop()
        var s = snapshot            // reflect immediately; the engine confirms with the same session
        s.phase = .stopped
        s.isLive = false
        s.issue = .none
        snapshot = s
    }

    func setMode(_ newMode: MeasurementMode) {
        guard newMode != mode else { return }
        mode = newMode
        session += 1
        audio.silence()
        cancelCalibration()
        notice = nil
        snapshot = .cleared(mode: newMode, phase: isRunning ? .acquiring : .idle, session: session)
        engine.setMode(newMode, session: session)   // same sensor subscription, no restart
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        guard phase != .active, isRunning else { return }
        stop()
        notice = "Measurement stopped because the app left the screen."
    }

    // MARK: Current-estimate setup

    func setGeometryChoice(_ choice: GeometryChoice) {
        geometryChoice = choice
        settings.geometryChoice = choice
        engine.setGeometry(currentGeometry)
    }

    func setIdealDistance(cm: Double) {
        idealDistanceCm = cm
        settings.idealDistanceCm = cm
        engine.setGeometry(currentGeometry)
    }

    func beginCalibration(referenceAmps: Double) {
        guard mode == .dc, snapshot.phase == .measuring, referenceAmps > 0 else { return }
        recorder = CalibrationRecorder(referenceAmps: referenceAmps)
        calibrationProgress = 0
        calibrationMessage = "Hold the phone still in the position you will use."
    }

    func removeCalibration() {
        calibration = nil
        settings.calibration = nil
        if geometryChoice == .calibrated { setGeometryChoice(.off) }
        calibrationMessage = "Calibration removed."
    }

    private func cancelCalibration() {
        recorder = nil
        calibrationProgress = nil
    }

    private var currentGeometry: GeometryModel {
        switch geometryChoice {
        case .off: return .none
        case .calibrated: return calibration.map { .calibrated($0) } ?? .none
        case .idealWire:
            // +/-15 % placement tolerance on the declared distance is an assumption, not a measurement.
            return .idealSingleConductor(distanceMeters: idealDistanceCm / 100, distanceRelativeUncertainty: 0.15)
        }
    }

    // MARK: Engine output (main actor, ~10 Hz)

    private func receive(_ s: MeasurementSnapshot) {
        guard s.session == session else { return }       // drop output of superseded sessions
        snapshot = s
        if s.phase == .stopped, isRunning {              // pipeline ended the session itself (failure)
            isRunning = false
            audio.stop()
            cancelCalibration()
        }
        if isRunning, s.phase == .measuring, s.isLive, s.issue == .none {
            audio.update(level: s.level, enabled: audioEnabled)
        } else if isRunning {
            audio.silence()
        }
        if var r = recorder {
            switch r.add(s) {
            case .inProgress(let p):
                recorder = r
                calibrationProgress = p
            case .succeeded(let c):
                calibration = c
                settings.calibration = c
                recorder = nil
                calibrationProgress = nil
                calibrationMessage = String(format: "Calibration saved: %.2f \u{00B5}T per A, \u{00B1}%d%%.",
                                            c.sensitivityMicroteslaPerAmp, Int((c.relativeUncertainty * 100).rounded()))
                setGeometryChoice(.calibrated)
            }
        }
    }
}
