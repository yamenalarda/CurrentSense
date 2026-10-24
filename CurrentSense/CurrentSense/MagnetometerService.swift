import Foundation
import CoreMotion
import Combine

/// A calibrated magnetic sample and its attitude captured from the same CMDeviceMotion
/// event. Keeping them together prevents rotation compensation from using a stale attitude.
private struct ProcessedMotionReading: Sendable {
    let timestamp: TimeInterval
    let wallClock: Date
    let deviceX: Double
    let deviceY: Double
    let deviceZ: Double
    let referenceX: Double
    let referenceY: Double
    let referenceZ: Double
    let magnitude: Double
    let rotationRateRadiansPerSecond: Double
    let calibrationQuality: String
}

struct MagneticSample: Identifiable {
    let id = UUID()
    /// Wall-clock time mapped from Core Motion's monotonic timestamp.
    let timestamp: Date
    /// Calibrated magnetic-field components in device coordinates, in microtesla.
    let x: Double
    let y: Double
    let z: Double
    /// Magnitude of the calibrated field (Earth plus surrounding fields, minus device bias).
    let magnitude: Double
    /// Raw vector difference from the baseline, before filtering.
    let deltaMagnitude: Double?
    /// Robust median/EMA-filtered difference used for display and estimation.
    let filteredDeltaMagnitude: Double?
    let calibrationQuality: String

    func csvRow(using formatter: ISO8601DateFormatter) -> String {
        let delta = deltaMagnitude.map { String($0) } ?? ""
        let filteredDelta = filteredDeltaMagnitude.map { String($0) } ?? ""
        return "\(formatter.string(from: timestamp)),\(x),\(y),\(z),\(magnitude),\(delta),\(filteredDelta),\(calibrationQuality)"
    }
}

@MainActor
final class MagnetometerService: ObservableObject {
    @Published private(set) var isAvailable = false
    /// True only while the user has requested a measurement session.
    @Published private(set) var isRunning = false
    /// Low-rate magnetic monitoring used to animate the idle glass orb.
    @Published private(set) var isMonitoring = false
    /// False while the phone is rotating fast enough to corrupt stable field estimates.
    @Published private(set) var isOrientationStable = false
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

    // Bound in-memory traces so long scans do not grow without limit.
    private let maximumStoredSamples = 30_000
    private let maximumChartSamples = 1_200
    // Keep display updates lightweight; Core Motion still feeds the filter at the requested rate.
    private let uiPublishInterval: TimeInterval = 0.16
    private let baselineCaptureDuration: TimeInterval = 2.0
    private let minimumBaselineSamples = 10
    private let standbyUpdateInterval: TimeInterval = 1.0 / 10.0
    // Do not request exactly 100 Hz (the Nyquist boundary for 50 Hz mains).
    // The non-synchronous target can help reveal changes, but cannot guarantee
    // waveform reconstruction or true-RMS AC measurement.
    private let measurementUpdateInterval: TimeInterval = 1.0 / 40.0

    private var recordedSamples: [MagneticSample] = []
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
    private var orientationStabilityGate = OrientationStabilityGate()

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
        recordedSamples.removeAll(keepingCapacity: true)
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
        lastDeliveryTimestamp = nil
        smoothedDeliveryRateHz = nil
    }

    /// Stops sensor use when the screen goes away.
    func stopMonitoring() {
        // Invalidate already-enqueued callback tasks before stopping Core Motion.
        motionGeneration &+= 1
        motionManager.stopDeviceMotionUpdates()
        isRunning = false
        isMonitoring = false
        isOrientationStable = false
        orientationStabilityGate.reset()
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
        orientationStabilityGate.reset()
        isOrientationStable = false
        baselineNoiseSigmaMicrotesla = nil
        magneticSourceDetected = false
        latestSample = nil
        calibrationQuality = "Unknown"
    }

    private func startMotionUpdates() {
        motionGeneration &+= 1
        let generation = motionGeneration

        // Use one synchronized Core Motion stream. Its calibrated field and attitude
        // share the same timestamp, avoiding stale cross-stream rotations. Calibration
        // removes device bias, a major cause of false changes when the phone is turned.
        // A separate raw-magnetometer callback is intentionally not used for estimates:
        // raw data contains hard-iron device bias and can swing as the handset rotates.
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

            let field = motion.magneticField.field
            let x = field.x
            let y = field.y
            let z = field.z
            guard x.isFinite, y.isFinite, z.isFinite else { return }

            let rotation = motion.attitude.rotationMatrix
            let deviceVector = MagneticFieldVector(x: x, y: y, z: z)
            let referenceVector = deviceVector.rotated(
                m11: rotation.m11, m12: rotation.m12, m13: rotation.m13,
                m21: rotation.m21, m22: rotation.m22, m23: rotation.m23,
                m31: rotation.m31, m32: rotation.m32, m33: rotation.m33
            )
            guard referenceVector.isFinite else { return }

            let rate = motion.rotationRate
            let rotationRateMagnitude = sqrt(rate.x * rate.x + rate.y * rate.y + rate.z * rate.z)
            guard rotationRateMagnitude.isFinite else { return }

            let quality: String
            switch motion.magneticField.accuracy {
            case .high: quality = "High"
            case .medium: quality = "Medium"
            case .low: quality = "Low"
            case .uncalibrated: quality = "Uncalibrated"
            @unknown default: quality = "Unknown"
            }

            let reading = ProcessedMotionReading(
                timestamp: motion.timestamp,
                wallClock: Date(),
                deviceX: x, deviceY: y, deviceZ: z,
                referenceX: referenceVector.x,
                referenceY: referenceVector.y,
                referenceZ: referenceVector.z,
                magnitude: sqrt(x * x + y * y + z * z),
                rotationRateRadiansPerSecond: rotationRateMagnitude,
                calibrationQuality: quality
            )

            // Only one main-actor handoff per sensor sample now (instead of separate
            // attitude + magnetometer tasks). Sensor fusion above is time-aligned.
            Task { @MainActor [weak self] in
                guard let self,
                      self.isMonitoring,
                      self.motionGeneration == generation else { return }
                self.processMotionSample(reading)
            }
        }
    }

    private func processMotionSample(_ reading: ProcessedMotionReading) {
        if calibrationQuality != reading.calibrationQuality {
            calibrationQuality = reading.calibrationQuality
        }

        if let previous = lastDeliveryTimestamp {
            let interval = reading.timestamp - previous
            if interval > 0 {
                let instantaneousRate = 1.0 / interval
                smoothedDeliveryRateHz = smoothedDeliveryRateHz.map {
                    $0 * 0.8 + instantaneousRate * 0.2
                } ?? instantaneousRate
            }
        }
        lastDeliveryTimestamp = reading.timestamp

        let wasStable = orientationStabilityGate.isStable
        let stable = orientationStabilityGate.update(
            rotationRateRadiansPerSecond: reading.rotationRateRadiansPerSecond
        )
        if isOrientationStable != stable {
            isOrientationStable = stable
        }

        guard stable else {
            // Clear the display/filter window only on entry to motion, not for every
            // moving sample. This prevents a turn from leaving a plausible-looking spike.
            if wasStable {
                fieldDeltaFilter.reset()
                samples.removeAll(keepingCapacity: true)
                latestSample = nil
                lastUIPublish = .distantPast
                if !baselineCaptured {
                    // Do not mix pre-turn and post-turn samples into a baseline window.
                    baselineVectors.removeAll(keepingCapacity: true)
                    baselineSampleCount = 0
                    baselineStartTimestamp = nil
                    baselineStartWallClock = nil
                }
            }
            return
        }

        let referenceVector = MagneticFieldVector(
            x: reading.referenceX,
            y: reading.referenceY,
            z: reading.referenceZ
        )
        if baselineStartTimestamp == nil {
            baselineStartTimestamp = reading.timestamp
            baselineStartWallClock = reading.wallClock
        }

        let sampleTimestamp: Date
        if let startMotionTime = baselineStartTimestamp,
           let startWallClock = baselineStartWallClock {
            sampleTimestamp = startWallClock.addingTimeInterval(reading.timestamp - startMotionTime)
        } else {
            sampleTimestamp = reading.wallClock
        }

        updateBaselineIfNeeded(vector: referenceVector, timestamp: reading.timestamp)
        updateMagneticSourceDetection(vector: referenceVector)

        let deltaMagnitude = anomalyDetector.baselineVector.map {
            referenceVector.distance(to: $0)
        }
        let filteredDeltaMagnitude = fieldDeltaFilter.update(deltaMagnitude)
        let sample = MagneticSample(
            timestamp: sampleTimestamp,
            x: reading.deviceX,
            y: reading.deviceY,
            z: reading.deviceZ,
            magnitude: reading.magnitude,
            deltaMagnitude: deltaMagnitude,
            filteredDeltaMagnitude: filteredDeltaMagnitude,
            calibrationQuality: reading.calibrationQuality
        )

        if isRunning {
            recordedSamples.append(sample)
            if recordedSamples.count > maximumStoredSamples {
                recordedSamples.removeFirst(max(1, maximumStoredSamples / 100))
            }
        }

        if reading.wallClock.timeIntervalSince(lastUIPublish) >= uiPublishInterval {
            latestSample = sample
            if isRunning {
                observedDeliveryRateHz = smoothedDeliveryRateHz
                samples.append(sample)
                if samples.count > maximumChartSamples {
                    samples.removeFirst(max(1, maximumChartSamples / 100))
                }
            }
            lastUIPublish = reading.wallClock
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
        // This signals a sustained magnetic change only, not cable contact or current.
        // Publish only state transitions to avoid unnecessary SwiftUI invalidations.
        let detected = anomalyDetector.update(vector: vector)
        if magneticSourceDetected != detected {
            magneticSourceDetected = detected
        }
    }

    func clearSamples() {
        recordedSamples.removeAll()
        samples.removeAll()
        latestSample = nil
        lastDeliveryTimestamp = nil
        observedDeliveryRateHz = nil
        smoothedDeliveryRateHz = nil
        lastUIPublish = .distantPast
        // Keep the reference baseline and idle detector stable during this session.
    }

    func exportCSV() -> URL? {
        guard !recordedSamples.isEmpty else { return nil }
        let header = "timestamp_iso8601,calibrated_device_x_uT,calibrated_device_y_uT,calibrated_device_z_uT,calibrated_field_magnitude_uT,reference_vector_delta_uT,filtered_reference_vector_delta_uT,device_motion_calibration_quality"
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let body = recordedSamples.map { $0.csvRow(using: formatter) }.joined(separator: "\n")
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
    }
}