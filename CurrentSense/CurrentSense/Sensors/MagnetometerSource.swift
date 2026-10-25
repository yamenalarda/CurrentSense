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

/// Raw magnetometer (µT, device frame, includes hard-iron offsets) plus gyro/accelerometer-fused
/// attitude and rotation rate from device motion. The attitude reference frame `xArbitraryZVertical`
/// does NOT use the magnetometer, so heading jumps cannot corrupt the baseline-validity check.
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

        manager.magnetometerUpdateInterval = 1.0 / 100.0
        if manager.isDeviceMotionAvailable {
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
            let b = data.magneticField
            self.lock.lock()
            let m = self.motion
            self.lock.unlock()
            var attitude: Quaternion?
            var rate: Vector3?
            if let m = m, abs(data.timestamp - m.t) < 0.2 {   // ignore stale motion data
                attitude = m.q
                rate = m.w
            }
            handler(MagSample(timestamp: data.timestamp, field: Vector3(b.x, b.y, b.z),
                              attitude: attitude, rotationRate: rate))
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
