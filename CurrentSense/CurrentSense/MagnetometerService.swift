import Foundation
import CoreMotion
import Combine

/// Device attitude and calibrated field from one Core Motion update.
private struct AttitudeSnapshot: Sendable {
    let timestamp: TimeInterval
    let m11: Double; let m12: Double; let m13: Double
    let m21: Double; let m22: Double; let m23: Double
    let m31: Double; let m32: Double; let m33: Double
    let calibratedField: MagneticFieldVector
    let rotationRateRadiansPerSecond: Double
    let calibrationQuality: String

    func rotateToReference(_ vector: MagneticFieldVector) -> MagneticFieldVector {
        vector.rotated(
            m11: m11, m12: m12, m13: m13,
            m21: m21, m22: m22, m23: m23,
            m31: m31, m32: m32, m33: m33
        )
    }
}

/// Matches raw magnetometer timestamps to the nearest attitude/calibrated field sample.
/// NSLock is used because Core Motion invokes handlers off the main actor.
private final class MotionSnapshotBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [AttitudeSnapshot] = []
    private let capacity = 24

    func append(_ snapshot: AttitudeSnapshot) {
        lock.lock()
        values.append(snapshot)
        if values.count > capacity {
            values.removeFirst(values.count - capacity)
        }
        lock.unlock()
    }

    func nearest(to timestamp: TimeInterval, maximumAge: TimeInterval) -> AttitudeSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard let nearest = values.min(by: {
            abs($0.timestamp - timestamp) < abs($1.timestamp - timestamp)
        }), abs(nearest.timestamp - timestamp) <= maximumAge else {
            return nil
        }
        return nearest
    }

    func reset() {
        lock.lock()
        values.removeAll(keepingCapacity: true)
        lock.unlock()
    }
}

/// A raw magnetic sample paired with a timestamp-near calibrated field and attitude.
private struct ProcessedMotionReading: Sendable {
    let timestamp: TimeInterval
    let wallClock: Date
    let rawField: MagneticFieldVector
    let attitude: AttitudeSnapshot
}

struct MagneticSample: Identifiable {
    let id = UUID()
    /// Wall-clock time mapped from Core Motion's monotonic timestamp.
    let timestamp: Date
    /// Raw magnetometer components in device coordinates, in microtesla.
    let x: Double
    let y: Double
    let z: Double
    /// Raw magnitude (includes the device-fixed bias); anomaly delta is bias-corrected.
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
    private let motionSnapshotBuffer = MotionSnapshotBuffer()
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
    private let minimumBaselineSamples = 24
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
    private var baselineReadings: [ProcessedMotionReading] = []
    private var estimatedDeviceBias: MagneticFieldVector?
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
        motionManager.magnetometerUpdateInterval = standbyUpdateInterval
        motionSnapshotBuffer.reset()
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
        motionSnapshotBuffer.reset()
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
        baselineReadings.removeAll(keepingCapacity: true)
        estimatedDeviceBias = nil
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
        let snapshotBuffer = motionSnapshotBuffer

        // Core Motion's calibrated stream supplies attitude + a bias-compensated
        // field for estimating the phone-fixed bias during the initial baseline.
        motionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical,
                                               to: queue) { [weak self, snapshotBuffer] motion, error in
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
            let calibrated = MagneticFieldVector(x: field.x, y: field.y, z: field.z)
            let rotation = motion.attitude.rotationMatrix
            let rate = motion.rotationRate
            let rateMagnitude = sqrt(rate.x * rate.x + rate.y * rate.y + rate.z * rate.z)
            guard calibrated.isFinite, rateMagnitude.isFinite else { return }

            let quality: String
            switch motion.magneticField.accuracy {
            case .high: quality = "High"
            case .medium: quality = "Medium"
            case .low: quality = "Low"
            case .uncalibrated: quality = "Uncalibrated"
            @unknown default: quality = "Unknown"
            }

            snapshotBuffer.append(AttitudeSnapshot(
                timestamp: motion.timestamp,
                m11: rotation.m11, m12: rotation.m12, m13: rotation.m13,
                m21: rotation.m21, m22: rotation.m22, m23: rotation.m23,
                m31: rotation.m31, m32: rotation.m32, m33: rotation.m33,
                calibratedField: calibrated,
                rotationRateRadiansPerSecond: rateMagnitude,
                calibrationQuality: quality
            ))
        }

        // Raw data is retained for anomaly detection because Apple's calibrated
        // CMDeviceMotion field can suppress some surrounding magnetic fields.
        motionManager.startMagnetometerUpdates(to: queue) { [weak self, snapshotBuffer] data, error in
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
            let magnetic = data.magneticField
            let raw = MagneticFieldVector(x: magnetic.x, y: magnetic.y, z: magnetic.z)
            guard raw.isFinite,
                  let attitude = snapshotBuffer.nearest(to: data.timestamp, maximumAge: 0.06) else {
                return
            }
            let reading = ProcessedMotionReading(
                timestamp: data.timestamp,
                wallClock: Date(),
                rawField: raw,
                attitude: attitude
            )
            Task { @MainActor [weak self] in
                guard let self,
                      self.isMonitoring,
                      self.motionGeneration == generation else { return }
                self.processMotionSample(reading)
            }
        }
    }

    private func processMotionSample(_ reading: ProcessedMotionReading) {
        if calibrationQuality != reading.attitude.calibrationQuality {
            calibrationQuality = reading.attitude.calibrationQuality
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
            rotationRateRadiansPerSecond: reading.attitude.rotationRateRadiansPerSecond
        )
        if isOrientationStable != stable {
            isOrientationStable = stable
        }

        guard stable else {
            if wasStable {
                fieldDeltaFilter.reset()
                samples.removeAll(keepingCapacity: true)
                latestSample = nil
                lastUIPublish = .distantPast
                if !baselineCaptured {
                    baselineReadings.removeAll(keepingCapacity: true)
                    baselineStartTimestamp = nil
                    baselineStartWallClock = nil
                }
            }
            return
        }

        // No trustworthy device-bias estimate is possible until Core Motion reports
        // calibration. Suppress values rather than silently treating raw as calibrated.
        guard reading.attitude.calibrationQuality != "Uncalibrated" else {
            isOrientationStable = false
            orientationStabilityGate.reset()
            magneticSourceDetected = false
            baselineCaptured = false
            baselineNoiseSigmaMicrotesla = nil
            estimatedDeviceBias = nil
            baselineReadings.removeAll(keepingCapacity: true)
            baselineStartTimestamp = nil
            baselineStartWallClock = nil
            anomalyDetector.reset()
            fieldDeltaFilter.reset()
            samples.removeAll(keepingCapacity: true)
            latestSample = nil
            lastUIPublish = .distantPast
            return
        }

        if baselineStartTimestamp == nil {
            baselineStartTimestamp = reading.timestamp
            baselineStartWallClock = reading.wallClock
        }

        if !baselineCaptured {
            baselineReadings.append(reading)
            if baselineReadings.count > 240 {
                baselineReadings.removeFirst(baselineReadings.count - 240)
            }
            captureBaselineIfNeeded(at: reading.timestamp)
            return
        }

        guard let estimatedDeviceBias else { return }
        let biasCorrectedDeviceField = reading.rawField.subtracting(estimatedDeviceBias)
        let referenceVector = reading.attitude.rotateToReference(biasCorrectedDeviceField)
        guard referenceVector.isFinite else { return }

        updateMagneticSourceDetection(vector: referenceVector)
        let deltaMagnitude = anomalyDetector.baselineVector.map {
            referenceVector.distance(to: $0)
        }
        let filteredDeltaMagnitude = fieldDeltaFilter.update(deltaMagnitude)
        let sample = MagneticSample(
            timestamp: sampleDate(for: reading),
            x: reading.rawField.x,
            y: reading.rawField.y,
            z: reading.rawField.z,
            magnitude: sqrt(reading.rawField.x * reading.rawField.x
                          + reading.rawField.y * reading.rawField.y
                          + reading.rawField.z * reading.rawField.z),
            deltaMagnitude: deltaMagnitude,
            filteredDeltaMagnitude: filteredDeltaMagnitude,
            calibrationQuality: reading.attitude.calibrationQuality
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

    private func sampleDate(for reading: ProcessedMotionReading) -> Date {
        guard let startMotionTime = baselineStartTimestamp,
              let startWallClock = baselineStartWallClock else {
            return reading.wallClock
        }
        return startWallClock.addingTimeInterval(reading.timestamp - startMotionTime)
    }

    private func captureBaselineIfNeeded(at timestamp: TimeInterval) {
        guard !baselineCaptured,
              let start = baselineStartTimestamp,
              timestamp - start >= baselineCaptureDuration,
              baselineReadings.count >= minimumBaselineSamples else { return }

        let raw = baselineReadings.map(\.rawField)
        let calibrated = baselineReadings.map { $0.attitude.calibratedField }
        guard let bias = MagneticFieldBiasEstimator.estimate(
            rawVectors: raw,
            calibratedVectors: calibrated,
            minimumPairs: minimumBaselineSamples
        ) else { return }

        let correctedReferenceVectors = baselineReadings.map { sample in
            sample.attitude.rotateToReference(sample.rawField.subtracting(bias))
        }.filter(\.isFinite)
        guard correctedReferenceVectors.count >= minimumBaselineSamples else { return }

        estimatedDeviceBias = bias
        anomalyDetector.setBaseline(from: correctedReferenceVectors)
        baselineCaptured = anomalyDetector.hasBaseline
        baselineNoiseSigmaMicrotesla = anomalyDetector.hasBaseline
            ? anomalyDetector.noiseSigmaEstimate
            : nil
        fieldDeltaFilter.reset()
        baselineReadings.removeAll(keepingCapacity: true)
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
        let header = "timestamp_iso8601,raw_device_x_uT,raw_device_y_uT,raw_device_z_uT,raw_field_magnitude_uT,bias_corrected_reference_delta_uT,filtered_bias_corrected_delta_uT,device_motion_calibration_quality"
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
        motionManager.stopMagnetometerUpdates()
    }
}