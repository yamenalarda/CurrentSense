import Foundation
import CoreMotion
import Combine

private struct AttitudeSnapshot {
    let timestamp: TimeInterval
    let m11: Double; let m12: Double; let m13: Double
    let m21: Double; let m22: Double; let m23: Double
    let m31: Double; let m32: Double; let m33: Double

    func rotate(_ vector: MagneticFieldVector) -> MagneticFieldVector {
        vector.rotated(
            m11: m11, m12: m12, m13: m13,
            m21: m21, m22: m22, m23: m23,
            m31: m31, m32: m32, m33: m33
        )
    }
}

struct MagneticSample: Identifiable {
    let id = UUID()
    /// Wall-clock time mapped from Core Motion's monotonic timestamp.
    let timestamp: Date
    /// Raw magnetometer-field components in device coordinates, in microtesla.
    let x: Double
    let y: Double
    let z: Double
    /// Magnitude of the raw magnetometer field, including Earth's field and sensor bias.
    let magnitude: Double
    /// Raw vector difference from the baseline, before filtering.
    let deltaMagnitude: Double?
    /// Robust median/EMA-filtered difference used for display and estimation.
    let filteredDeltaMagnitude: Double?
    let calibrationQuality: String

    func csvRow(using formatter: ISO8601DateFormatter) -> String {
        let rawDelta = deltaMagnitude.map { String($0) } ?? ""
        let filteredDelta = filteredDeltaMagnitude.map { String($0) } ?? ""
        return "\(formatter.string(from: timestamp)),\(x),\(y),\(z),\(magnitude),\(rawDelta),\(filteredDelta),\(calibrationQuality)"
    }
}

@MainActor
final class MagnetometerService: ObservableObject {
    @Published private(set) var isAvailable = false
    /// True only while the user has requested a measurement session.
    @Published private(set) var isRunning = false
    /// Low-rate magnetic monitoring used to animate the idle glass orb.
    @Published private(set) var isMonitoring = false
    @Published private(set) var magneticSourceDetected = false
    @Published private(set) var latestSample: MagneticSample?
    @Published private(set) var samples: [MagneticSample] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var observedDeliveryRateHz: Double?
    @Published private(set) var baselineCaptured = false
    @Published private(set) var baselineNoiseSigmaMicrotesla: Double?
    @Published private(set) var calibrationQuality = "Unknown"

    /// At least 0.5 µT, raised when baseline noise is high.
    var minimumUsableFieldChangeMicrotesla: Double {
        guard let noise = baselineNoiseSigmaMicrotesla, noise.isFinite, noise > 0 else {
            return 0.5
        }
        return max(0.5, noise * 5.0)
    }

    private let motionManager = CMMotionManager()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "CurrentSense.MagnetometerQueue"
        q.qualityOfService = .userInitiated
        q.maxConcurrentOperationCount = 1
        return q
    }()

    private let maximumStoredSamples = 60_000
    private let maximumChartSamples = 5_000
    private let uiPublishInterval: TimeInterval = 0.10
    private let baselineCaptureDuration: TimeInterval = 2.0
    private let minimumBaselineSamples = 10
    private let standbyUpdateInterval: TimeInterval = 1.0 / 10.0
    // Do not request exactly 100 Hz (the Nyquist boundary for 50 Hz mains).
    // The non-synchronous target can help reveal changes, but cannot guarantee
    // waveform reconstruction or true-RMS AC measurement.
    private let measurementUpdateInterval: TimeInterval = 1.0 / 80.0

    private var rawSamples: [MagneticSample] = []
    private var lastUIPublish: Date = .distantPast
    private var lastDeliveryTimestamp: TimeInterval?
    private var smoothedDeliveryRateHz: Double?
    /// Invalidates callbacks queued by a previous Core Motion session/rate.
    private var motionGeneration: UInt64 = 0
    private var baselineStartTimestamp: TimeInterval?
    private var baselineStartWallClock: Date?
    private var baselineSampleCount = 0
    private var baselineVectors: [MagneticFieldVector] = []
    private var anomalyDetector = MagneticAnomalyDetector()
    private var fieldDeltaFilter = FieldDeltaFilter()
    private var latestAttitude: AttitudeSnapshot?

    init() {
        isAvailable = motionManager.isDeviceMotionAvailable && motionManager.isMagnetometerAvailable
    }

    /// Starts low-rate monitoring so the idle orb can react to a stable field change.
    /// The detector estimates a nearby magnetic anomaly; it cannot prove cable contact.
    func startMonitoring() {
        guard !isMonitoring else { return }
        guard motionManager.isDeviceMotionAvailable && motionManager.isMagnetometerAvailable else {
            errorMessage = "Device motion or magnetometer is unavailable on this device."
            isAvailable = false
            return
        }

        errorMessage = nil
        isAvailable = true
        isMonitoring = true
        resetBaseline()
        lastDeliveryTimestamp = nil
        smoothedDeliveryRateHz = nil
        lastUIPublish = .distantPast
        motionManager.deviceMotionUpdateInterval = standbyUpdateInterval
        motionManager.magnetometerUpdateInterval = standbyUpdateInterval
        startMotionUpdates()
    }

    /// Starts a measurement session with a fresh baseline captured after this tap.
    /// The user should hold the phone away from the cable until baselineCaptured is true.
    func start() {
        guard !isRunning else { return }
        if !isMonitoring {
            startMonitoring()
        }
        guard isMonitoring else { return }

        // The phone may have been opened while already near the cable.
        // Capture a fresh reference only after the user deliberately starts a reading.
        // This prevents a nearby field from being treated as the zero baseline.
        resetBaseline()
        rawSamples.removeAll(keepingCapacity: true)
        samples.removeAll(keepingCapacity: true)
        lastUIPublish = .distantPast
        observedDeliveryRateHz = nil
        isRunning = true
        setMotionUpdateInterval(measurementUpdateInterval)
    }

    /// Ends the measurement, but leaves low-rate monitoring active for the idle orb.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        setMotionUpdateInterval(standbyUpdateInterval)
        if let latestSample, samples.last?.id != latestSample.id {
            samples.append(latestSample)
            if samples.count > maximumChartSamples {
                samples.removeFirst(max(1, maximumChartSamples / 100))
            }
        }
    }

    /// Update the target sample interval without restarting Core Motion.
    /// Keeping the same session preserves its attitude reference frame for vector comparisons.
    private func setMotionUpdateInterval(_ interval: TimeInterval) {
        guard isMonitoring else { return }
        motionManager.deviceMotionUpdateInterval = interval
        motionManager.magnetometerUpdateInterval = interval
        lastDeliveryTimestamp = nil
        smoothedDeliveryRateHz = nil
    }

    /// Stops sensor use when the screen goes away.
    func stopMonitoring() {
        // Invalidate already-enqueued callback tasks before stopping Core Motion.
        motionGeneration &+= 1
        motionManager.stopDeviceMotionUpdates()
        motionManager.stopMagnetometerUpdates()
        latestAttitude = nil
        isRunning = false
        isMonitoring = false
        magneticSourceDetected = false
    }

    private func resetBaseline() {
        baselineCaptured = false
        baselineStartTimestamp = nil
        baselineStartWallClock = nil
        baselineSampleCount = 0
        baselineVectors.removeAll(keepingCapacity: true)
        anomalyDetector.reset()
        fieldDeltaFilter.reset()
        baselineNoiseSigmaMicrotesla = nil
        magneticSourceDetected = false
        latestSample = nil
        calibrationQuality = "Unknown"
    }

    private func startMotionUpdates() {
        motionGeneration &+= 1
        let generation = motionGeneration

        // The calibrated CMDeviceMotion magnetic field can suppress device bias and,
        // in some cases, nearby magnetic fields. Use device motion for attitude only,
        // and obtain the measured field from the raw CMMagnetometerData stream.
        motionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical,
                                               to: queue) { [weak self] motion, error in
            if let error {
                Task { @MainActor in
                    guard let self, self.motionGeneration == generation else { return }
                    self.errorMessage = "Motion update failed: \(error.localizedDescription)"
                    self.isAvailable = false
                    self.stopMonitoring()
                }
                return
            }
            guard let motion else { return }

            let rotation = motion.attitude.rotationMatrix
            let attitude = AttitudeSnapshot(
                timestamp: motion.timestamp,
                m11: rotation.m11, m12: rotation.m12, m13: rotation.m13,
                m21: rotation.m21, m22: rotation.m22, m23: rotation.m23,
                m31: rotation.m31, m32: rotation.m32, m33: rotation.m33
            )
            let quality: String
            switch motion.magneticField.accuracy {
            case .high: quality = "High"
            case .medium: quality = "Medium"
            case .low: quality = "Low"
            case .uncalibrated: quality = "Uncalibrated"
            @unknown default: quality = "Unknown"
            }

            Task { @MainActor in
                guard let self,
                      self.isMonitoring,
                      self.motionGeneration == generation else { return }
                self.latestAttitude = attitude
                if self.calibrationQuality != quality {
                    self.calibrationQuality = quality
                }
            }
        }

        motionManager.startMagnetometerUpdates(to: queue) { [weak self] data, error in
            if let error {
                Task { @MainActor in
                    guard let self, self.motionGeneration == generation else { return }
                    self.errorMessage = "Magnetometer update failed: \(error.localizedDescription)"
                    self.isAvailable = false
                    self.stopMonitoring()
                }
                return
            }
            guard let data else { return }

            // CMMagnetometerData is the raw magnetic field. It retains surrounding
            // field changes that the calibrated CMDeviceMotion field can suppress.
            let field = data.magneticField
            let x = field.x
            let y = field.y
            let z = field.z
            guard x.isFinite, y.isFinite, z.isFinite else { return }

            let deliveryTimestamp = data.timestamp
            let deliveryWallClock = Date()

            Task { @MainActor in
                guard let self,
                      self.isMonitoring,
                      self.motionGeneration == generation else { return }
                guard let attitude = self.latestAttitude,
                      abs(deliveryTimestamp - attitude.timestamp) <= 0.25 else {
                    // Do not turn a missing/stale attitude into a false magnetic change.
                    return
                }

                let rawVector = MagneticFieldVector(x: x, y: y, z: z)
                let referenceVector = attitude.rotate(rawVector)
                guard referenceVector.isFinite else { return }

                if self.baselineStartTimestamp == nil {
                    self.baselineStartTimestamp = deliveryTimestamp
                    self.baselineStartWallClock = deliveryWallClock
                }
                let sampleTimestamp: Date
                if let startMotionTime = self.baselineStartTimestamp,
                   let startWallClock = self.baselineStartWallClock {
                    sampleTimestamp = startWallClock.addingTimeInterval(deliveryTimestamp - startMotionTime)
                } else {
                    sampleTimestamp = deliveryWallClock
                }

                let magnitude = sqrt(x * x + y * y + z * z)
                self.updateBaselineIfNeeded(
                    vector: referenceVector,
                    timestamp: deliveryTimestamp
                )
                self.updateMagneticSourceDetection(vector: referenceVector)

                let deltaMagnitude = self.anomalyDetector.baselineVector.map {
                    referenceVector.distance(to: $0)
                }
                let filteredDeltaMagnitude = self.fieldDeltaFilter.update(deltaMagnitude)

                let sample = MagneticSample(
                    timestamp: sampleTimestamp,
                    x: x,
                    y: y,
                    z: z,
                    magnitude: magnitude,
                    deltaMagnitude: deltaMagnitude,
                    filteredDeltaMagnitude: filteredDeltaMagnitude,
                    calibrationQuality: self.calibrationQuality
                )

                if let previous = self.lastDeliveryTimestamp {
                    let interval = deliveryTimestamp - previous
                    if interval > 0 {
                        let instantaneousRate = 1.0 / interval
                        self.smoothedDeliveryRateHz = self.smoothedDeliveryRateHz.map {
                            $0 * 0.8 + instantaneousRate * 0.2
                        } ?? instantaneousRate
                    }
                }
                self.lastDeliveryTimestamp = deliveryTimestamp

                // The UI publishes at a lower rate, while the raw trace retains every
                // accepted magnetometer sample so AC aliasing/noise can be inspected later.
                if self.isRunning {
                    self.rawSamples.append(sample)
                    if self.rawSamples.count > self.maximumStoredSamples {
                        self.rawSamples.removeFirst(max(1, self.maximumStoredSamples / 100))
                    }
                }

                let now = Date()
                if now.timeIntervalSince(self.lastUIPublish) >= self.uiPublishInterval {
                    self.latestSample = sample
                    if self.isRunning {
                        self.observedDeliveryRateHz = self.smoothedDeliveryRateHz
                        self.samples.append(sample)
                        if self.samples.count > self.maximumChartSamples {
                            self.samples.removeFirst(max(1, self.maximumChartSamples / 100))
                        }
                    }
                    self.lastUIPublish = now
                }
            }
        }
    }

    private func updateBaselineIfNeeded(
        vector: MagneticFieldVector,
        timestamp: TimeInterval
    ) {
        guard !baselineCaptured else { return }
        if baselineStartTimestamp == nil {
            baselineStartTimestamp = timestamp
        }

        baselineVectors.append(vector)
        baselineSampleCount += 1

        let elapsed = timestamp - (baselineStartTimestamp ?? timestamp)
        guard elapsed >= baselineCaptureDuration,
              baselineSampleCount >= minimumBaselineSamples else { return }

        anomalyDetector.setBaseline(from: baselineVectors)
        baselineCaptured = anomalyDetector.hasBaseline
        baselineNoiseSigmaMicrotesla = anomalyDetector.hasBaseline
            ? anomalyDetector.noiseSigmaEstimate
            : nil
        fieldDeltaFilter.reset()
        baselineVectors.removeAll(keepingCapacity: true)
    }

    private func updateMagneticSourceDetection(vector: MagneticFieldVector) {
        // This signals a sustained field change only, not cable contact or current.
        // Publish only state transitions; writing the same @Published value at 100 Hz
        // would cause unnecessary SwiftUI invalidations.
        let detected = anomalyDetector.update(vector: vector)
        if magneticSourceDetected != detected {
            magneticSourceDetected = detected
        }
    }

    func clearSamples() {
        rawSamples.removeAll()
        samples.removeAll()
        latestSample = nil
        lastDeliveryTimestamp = nil
        observedDeliveryRateHz = nil
        smoothedDeliveryRateHz = nil
        lastUIPublish = .distantPast
        // Keep the reference baseline and idle detector stable during this session.
    }

    func exportCSV() -> URL? {
        guard !rawSamples.isEmpty else { return nil }
        let header = "timestamp_iso8601,raw_device_x_uT,raw_device_y_uT,raw_device_z_uT,raw_field_magnitude_uT,raw_reference_vector_delta_uT,filtered_reference_vector_delta_uT,device_motion_calibration_quality"
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let body = rawSamples.map { $0.csvRow(using: formatter) }.joined(separator: "\n")
        let contents = header + "\n" + body + "\n"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CurrentSense-\(Int(Date().timeIntervalSince1970)).csv")
        do {
            try contents.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            errorMessage = "Could not export CSV: \(error.localizedDescription)"
            return nil
        }
    }

    deinit {
        motionManager.stopDeviceMotionUpdates()
        motionManager.stopMagnetometerUpdates()
    }
}