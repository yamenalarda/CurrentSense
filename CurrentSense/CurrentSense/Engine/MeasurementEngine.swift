import Foundation
import CurrentSenseCore

/// Owns the sensor subscription, the processing pipeline and the stall watchdog.
/// Everything runs on one serial queue; the UI only receives rate-limited snapshots.
final class MeasurementEngine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.currentsense.engine", qos: .userInitiated)
    private let operationQueue = OperationQueue()
    private let pipeline = MeasurementPipeline()
    private let source: MagnetometerSource
    private let onSnapshot: @Sendable (MeasurementSnapshot) -> Void
    private var watchdog: DispatchSourceTimer?
    private var sensorRunning = false

    init(source: MagnetometerSource, onSnapshot: @escaping @Sendable (MeasurementSnapshot) -> Void) {
        self.source = source
        self.onSnapshot = onSnapshot
        operationQueue.maxConcurrentOperationCount = 1
        operationQueue.underlyingQueue = queue
        operationQueue.name = "com.currentsense.sensor"
    }

    // MARK: Commands (thread-safe, serialised)

    func start(mode: MeasurementMode, session: Int, geometry: GeometryModel) {
        queue.async {
            self.pipeline.start(mode: mode, session: session, geometry: geometry, now: ProcessInfo.processInfo.systemUptime)
            self.beginSensorLocked()
            self.onSnapshot(self.pipeline.currentSnapshot())
        }
    }

    func setMode(_ mode: MeasurementMode, session: Int) {
        queue.async {
            self.pipeline.setMode(mode, session: session, now: ProcessInfo.processInfo.systemUptime)
            self.onSnapshot(self.pipeline.currentSnapshot())
        }
    }

    func setGeometry(_ geometry: GeometryModel) {
        queue.async { self.pipeline.setGeometry(geometry) }
    }

    func stop() {
        queue.async {
            self.pipeline.stop()
            self.endSensorLocked()
            self.onSnapshot(self.pipeline.currentSnapshot())
        }
    }

    // MARK: Queue-confined internals

    private func beginSensorLocked() {
        guard source.isAvailable else {
            pipeline.abort(issue: .sensorUnavailable)
            return
        }
        guard !sensorRunning else { return }   // never a second subscription
        sensorRunning = true
        source.start(queue: operationQueue,
                     handler: { [weak self] sample in self?.handle(sample) },
                     onError: { [weak self] _ in self?.queue.async { self?.handleSensorError() } })
        startWatchdogLocked()
    }

    private func endSensorLocked() {
        watchdog?.cancel()
        watchdog = nil
        if sensorRunning {
            source.stop()
            sensorRunning = false
        }
    }

    private func handle(_ sample: MagSample) {
        guard sensorRunning, let snap = pipeline.ingest(sample) else { return }
        onSnapshot(snap)
        if snap.phase == .stopped { endSensorLocked() }   // e.g. baseline failed: release the sensor
    }

    private func handleSensorError() {
        guard sensorRunning else { return }
        pipeline.abort(issue: .sensorError)
        endSensorLocked()
        onSnapshot(pipeline.currentSnapshot())
    }

    private func startWatchdogLocked() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.25, repeating: 0.25, leeway: .milliseconds(50))
        t.setEventHandler { [weak self] in
            guard let self = self else { return }
            if let s = self.pipeline.checkStall(now: ProcessInfo.processInfo.systemUptime) { self.onSnapshot(s) }
        }
        t.resume()
        watchdog = t
    }
}
