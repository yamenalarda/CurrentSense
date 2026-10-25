import Foundation
import CoreMotion
import CurrentSenseCore

/// Abstraction over the sensor so the engine can be driven by Core Motion (production)
/// or a deterministic generator (DEBUG UI tests only).
protocol MagnetometerSource: AnyObject {
    var isAvailable: Bool { get }
    /// Handlers are invoked on `queue` (a serial OperationQueue). Idempotent: a second start is ignored.
    func start(queue: OperationQueue, handler: @escaping (MagSample) -> Void, onError: @escaping (String) -> Void)
    /// Idempotent.
    func stop()
}

/// Magnetometer samples are transformed to a session-stable reference frame when Core Motion
/// attitude is available. Its `xArbitraryZVertical` frame does not use the magnetometer, avoiding
/// heading jumps; samples are skipped briefly rather than mixed across coordinate frames if stale.
final class CoreMotionSource: MagnetometerSource {
    private let manager = CMMotionManager()
    private let lock = NSLock()
    private var running = false
    private var motion: (t: TimeInterval, q: Quaternion, w: Vector3)?

    var isAvailable: Bool { manager.isMagnetometerAvailable }

    func start(queue: OperationQueue, handler: @escaping (MagSample) -> Void, onError: @escaping (String) -> Void) {
        lock.lock()
        if running { lock.unlock(); return }
        guard manager.isMagnetometerAvailable else {
            lock.unlock()
            onError("Magnetometer unavailable")
            return
        }
        running = true
        motion = nil
        lock.unlock()

        let canCompensateAttitude = manager.isDeviceMotionAvailable
        manager.magnetometerUpdateInterval = 1.0 / 100.0
        if canCompensateAttitude {
            manager.deviceMotionUpdateInterval = 1.0 / 50.0
            manager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: queue) { [weak self] m, _ in
                guard let self = self, let m = m else { return }
                let q = m.attitude.quaternion
                let r = m.rotationRate
                self.lock.lock()
                self.motion = (m.timestamp, Quaternion(x: q.x, y: q.y, z: q.z, w: q.w), Vector3(r.x, r.y, r.z))
                self.lock.unlock()
            }
        }
        manager.startMagnetometerUpdates(to: queue) { [weak self] data, error in
            guard let self = self else { return }
            if let error = error { onError(error.localizedDescription); return }
            guard let data = data else { return }
            let b = Vector3(data.magneticField.x, data.magneticField.y, data.magneticField.z)
            self.lock.lock()
            let m = self.motion
            self.lock.unlock()

            if canCompensateAttitude {
                // Never mix device-frame and reference-frame samples within one session: a stale
                // attitude causes this sample to be skipped instead of corrupting the baseline.
                guard let motion = m, abs(data.timestamp - motion.t) < 0.15 else { return }
                let stableField = b.rotated(by: motion.q.conjugate)
                handler(MagSample(timestamp: data.timestamp, field: stableField,
                                  attitude: .identity, rotationRate: motion.w))
            } else {
                // Fallback for devices without device-motion fusion: keep field samples live but
                // do not claim orientation compensation.
                handler(MagSample(timestamp: data.timestamp, field: b))
            }
        }
    }

    func stop() {
        lock.lock()
        let wasRunning = running
        running = false
        motion = nil
        lock.unlock()
        guard wasRunning else { return }
        manager.stopMagnetometerUpdates()
        manager.stopDeviceMotionUpdates()
    }
}

#if DEBUG
/// Deterministic generator used ONLY by UI tests (launch argument -UITestSyntheticSensor, Debug builds).
/// Not compiled into Release/IPA builds.
final class SyntheticSource: MagnetometerSource {
    private var timer: DispatchSourceTimer?
    private var startUptime = 0.0
    var isAvailable: Bool { true }

    func start(queue: OperationQueue, handler: @escaping (MagSample) -> Void, onError: @escaping (String) -> Void) {
        stop()
        guard let q = queue.underlyingQueue else { onError("No serial queue"); return }
        startUptime = ProcessInfo.processInfo.systemUptime
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in
            guard let self = self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            let el = now - self.startUptime
            func n() -> Double { (Double.random(in: -1...1) + Double.random(in: -1...1) + Double.random(in: -1...1)) * 0.0577 }
            var f = Vector3(20 + n(), -5 + n(), -40 + n())
            if el > 3.0 {                       // 1 s after the 2 s baseline: DC step + 60 Hz activity
                f.z += 3
                f.x += 2 * sin(2 * Double.pi * 60 * now)
            }
            handler(MagSample(timestamp: now, field: f, attitude: .identity, rotationRate: .zero))
        }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }
}
#endif
