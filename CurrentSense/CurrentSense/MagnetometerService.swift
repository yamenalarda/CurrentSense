import Foundation
import CoreMotion
import Combine

struct MagneticSample: Identifiable {
    let id = UUID()
    /// Wall-clock time mapped from Core Motion's monotonic timestamp.
    let timestamp: Date
    /// Calibrated magnetic-field components in microtesla.
    let x: Double
    let y: Double
    let z: Double
    /// Total field magnitude, including the Earth's field.
    let magnitude: Double
    /// Vector difference from the baseline captured when monitoring started.
    let deltaMagnitude: Double?
    let calibrationQuality: String

    var csvRow: String {
        let formatter = ISO8601DateFormatter()
        let delta = deltaMagnitude.map { String($0) } ?? ""
        return "\(formatter.string(from: timestamp)),\(x),\(y),\(z),\(magnitude),\(delta),\(calibrationQuality)"
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
    @Published private(set) var calibrationQuality = "Unknown"

    private let motionManager = CMMotionManager()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "CurrentSense.MagnetometerQueue"
        q.qualityOfService = .userInitiated
        q.maxConcurrentOperationCount = 1
        return q
    }()

    private let maximumStoredSamples = 20_000
    private let maximumChartSamples = 5_000
    private let uiPublishInterval: TimeInterval = 0.10
    private let baselineCaptureDuration: TimeInterval = 2.0
    private let minimumBaselineSamples = 10
    private let standbyUpdateInterval: TimeInterval = 1.0 / 10.0
    private let measurementUpdateInterval: TimeInterval = 1.0 / 100.0

    private var rawSamples: [MagneticSample] = []
    private var lastUIPublish: Date = .distantPast
    private var lastDeliveryTimestamp: TimeInterval?
    private var smoothedDeliveryRateHz: Double?
    private var baselineStartTimestamp: TimeInterval?
    private var baselineStartWallClock: Date?
    private var baselineSampleCount = 0
    private var baselineSumX = 0.0
    private var baselineSumY = 0.0
    private var baselineSumZ = 0.0
    private var baselineMagnitudeSum = 0.0
    private var baselineMagnitudeSquareSum = 0.0
    private var baselineX: Double?
    private var baselineY: Double?
    private var baselineZ: Double?
    private var baselineMagnitude: Double?
    private var baselineMagnitudeDeviation = 0.0
    private var candidateAboveCount = 0
    private var clearBelowCount = 0

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

    /// Starts a measurement session without throwing away the standby baseline.
    /// If the phone is already near a magnetic source, the live delta is preserved.
    func start() {
        guard !isRunning else { return }
        if !isMonitoring {
            startMonitoring()
        }
        guard isMonitoring else { return }

        rawSamples.removeAll(keepingCapacity: true)
        samples.removeAll(keepingCapacity: true)
        lastUIPublish = .distantPast
        observedDeliveryRateHz = nil
        isRunning = true
        restartMotionUpdates(interval: measurementUpdateInterval)
    }

    /// Ends the measurement, but leaves low-rate monitoring active for the idle orb.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        restartMotionUpdates(interval: standbyUpdateInterval)
        if let latestSample, samples.last?.id != latestSample.id {
            samples.append(latestSample)
            if samples.count > maximumChartSamples {
                samples.removeFirst(max(1, maximumChartSamples / 100))
            }
        }
    }

    /// Apply rate changes by restarting Core Motion, while retaining the baseline.
    private func restartMotionUpdates(interval: TimeInterval) {
        guard isMonitoring else { return }
        motionManager.stopDeviceMotionUpdates()
        motionManager.deviceMotionUpdateInterval = interval
        lastDeliveryTimestamp = nil
        smoothedDeliveryRateHz = nil
        startMotionUpdates()
    }

    /// Stops sensor use when the screen goes away.
    func stopMonitoring() {
        motionManager.stopDeviceMotionUpdates()
        isRunning = false
        isMonitoring = false
        magneticSourceDetected = false
    }

    private func resetBaseline() {
        baselineCaptured = false
        baselineStartTimestamp = nil
        baselineStartWallClock = nil
        baselineSampleCount = 0
        baselineSumX = 0
        baselineSumY = 0
        baselineSumZ = 0
        baselineMagnitudeSum = 0
        baselineMagnitudeSquareSum = 0
        baselineX = nil
        baselineY = nil
        baselineZ = nil
        baselineMagnitude = nil
        baselineMagnitudeDeviation = 0
        candidateAboveCount = 0
        clearBelowCount = 0
        magneticSourceDetected = false
        latestSample = nil
        calibrationQuality = "Unknown"
    }

    private func startMotionUpdates() {
        motionManager.startDeviceMotionUpdates(using: .xArbitraryCorrectedZVertical,
                                               to: queue) { [weak self] motion, error in
            if let error {
                Task { @MainActor in
                    guard let self else { return }
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

            let deliveryTimestamp = motion.timestamp
            let deliveryWallClock = Date()
            let calibrationQuality: String
            switch motion.magneticField.accuracy {
            case .high: calibrationQuality = "High"
            case .medium: calibrationQuality = "Medium"
            case .low: calibrationQuality = "Low"
            case .uncalibrated: calibrationQuality = "Uncalibrated"
            @unknown default: calibrationQuality = "Unknown"
            }

            Task { @MainActor in
                guard let self, self.isMonitoring else { return }
                if self.calibrationQuality != calibrationQuality {
                    self.calibrationQuality = calibrationQuality
                }

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
                    x: x, y: y, z: z, magnitude: magnitude,
                    timestamp: deliveryTimestamp
                )
                self.updateMagneticSourceDetection(magnitude: magnitude)

                var deltaMagnitude: Double?
                if let bx = self.baselineX, let by = self.baselineY, let bz = self.baselineZ {
                    let dx = x - bx
                    let dy = y - by
                    let dz = z - bz
                    deltaMagnitude = sqrt(dx * dx + dy * dy + dz * dz)
                }

                let sample = MagneticSample(
                    timestamp: sampleTimestamp,
                    x: x,
                    y: y,
                    z: z,
                    magnitude: magnitude,
                    deltaMagnitude: deltaMagnitude,
                    calibrationQuality: calibrationQuality
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

                // The idle orb only needs the newest sample. Save the raw trace only
                // while measuring so standby monitoring does not grow a hidden data log.
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
        x: Double, y: Double, z: Double, magnitude: Double,
        timestamp: TimeInterval
    ) {
        guard !baselineCaptured else { return }
        if baselineStartTimestamp == nil {
            baselineStartTimestamp = timestamp
        }

        baselineSumX += x
        baselineSumY += y
        baselineSumZ += z
        baselineMagnitudeSum += magnitude
        baselineMagnitudeSquareSum += magnitude * magnitude
        baselineSampleCount += 1

        let elapsed = timestamp - (baselineStartTimestamp ?? timestamp)
        guard elapsed >= baselineCaptureDuration,
              baselineSampleCount >= minimumBaselineSamples else { return }

        let count = Double(baselineSampleCount)
        baselineX = baselineSumX / count
        baselineY = baselineSumY / count
        baselineZ = baselineSumZ / count
        let meanMagnitude = baselineMagnitudeSum / count
        let variance = max(0, baselineMagnitudeSquareSum / count - meanMagnitude * meanMagnitude)
        baselineMagnitude = meanMagnitude
        baselineMagnitudeDeviation = sqrt(variance)
        baselineCaptured = true
    }

    private func updateMagneticSourceDetection(magnitude: Double) {
        guard baselineCaptured, let baselineMagnitude else {
            magneticSourceDetected = false
            return
        }

        // Magnitude is orientation-invariant; hysteresis and persistence reduce flicker.
        // This detects a sustained local field change, not a specific object or wire.
        let difference = abs(magnitude - baselineMagnitude)
        let triggerThreshold = max(3.0, baselineMagnitudeDeviation * 4.0)
        let releaseThreshold = triggerThreshold * 0.55

        if difference >= triggerThreshold {
            candidateAboveCount += 1
            clearBelowCount = 0
            if candidateAboveCount >= 3 {
                magneticSourceDetected = true
            }
        } else if difference < releaseThreshold {
            clearBelowCount += 1
            candidateAboveCount = 0
            if clearBelowCount >= 10 {
                magneticSourceDetected = false
            }
        } else {
            candidateAboveCount = 0
            clearBelowCount = 0
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
        let header = "timestamp_iso8601,x_uT,y_uT,z_uT,total_magnitude_uT,delta_from_baseline_uT,calibration_quality"
        let body = rawSamples.map(\.csvRow).joined(separator: "\n")
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