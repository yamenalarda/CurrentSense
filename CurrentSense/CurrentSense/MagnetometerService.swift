import Foundation
import CoreMotion
import Combine

struct MagneticSample: Identifiable {
    let id = UUID()
    /// Wall-clock time when Core Motion delivered this sample to the app.
    let timestamp: Date
    /// Calibrated magnetic-field components in microtesla, when available.
    let x: Double
    let y: Double
    let z: Double
    /// Total calibrated field magnitude, including Earth's field.
    let magnitude: Double
    /// Vector change from the averaged start baseline. Nil while the baseline is being captured.
    let deltaMagnitude: Double?

    var csvRow: String {
        let formatter = ISO8601DateFormatter()
        let delta = deltaMagnitude.map { String($0) } ?? ""
        return "\(formatter.string(from: timestamp)),\(x),\(y),\(z),\(magnitude),\(delta)"
    }
}

@MainActor
final class MagnetometerService: ObservableObject {
    @Published private(set) var isAvailable = false
    @Published private(set) var isRunning = false
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
    private var baselineX: Double?
    private var baselineY: Double?
    private var baselineZ: Double?

    init() {
        isAvailable = motionManager.isDeviceMotionAvailable && motionManager.isMagnetometerAvailable
    }

    func start() {
        guard motionManager.isDeviceMotionAvailable && motionManager.isMagnetometerAvailable else {
            errorMessage = "Device motion or magnetometer is unavailable on this device."
            isAvailable = false
            return
        }
        guard !isRunning else { return }

        errorMessage = nil
        rawSamples.removeAll(keepingCapacity: true)
        samples.removeAll(keepingCapacity: true)
        latestSample = nil
        lastUIPublish = .distantPast
        lastDeliveryTimestamp = nil
        observedDeliveryRateHz = nil
        smoothedDeliveryRateHz = nil
        baselineCaptured = false
        calibrationQuality = "Unknown"
        baselineStartTimestamp = nil
        baselineStartWallClock = nil
        baselineSampleCount = 0
        baselineSumX = 0
        baselineSumY = 0
        baselineSumZ = 0
        baselineX = nil
        baselineY = nil
        baselineZ = nil

        // Request 100 Hz to improve time resolution. Core Motion and the device
        // hardware may deliver less; observedDeliveryRateHz reports the actual rate.
        // This does not make mains-frequency AC current measurement reliable by itself.
        motionManager.deviceMotionUpdateInterval = 1.0 / 100.0
        motionManager.startDeviceMotionUpdates(using: .xArbitraryCorrectedZVertical,
                                              to: queue) { [weak self] motion, error in
            if let error {
                Task { @MainActor in
                    guard let self else { return }
                    self.errorMessage = "Motion update failed: \(error.localizedDescription)"
                    self.stop()
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
                guard let self, self.isRunning else { return }
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

                // Average the first two seconds as an environmental reference.
                // Start with the phone away from the cable, then move it close when ready.
                if !self.baselineCaptured {
                    self.baselineSumX += x
                    self.baselineSumY += y
                    self.baselineSumZ += z
                    self.baselineSampleCount += 1

                    let elapsed = deliveryTimestamp - (self.baselineStartTimestamp ?? deliveryTimestamp)
                    if elapsed >= self.baselineCaptureDuration &&
                       self.baselineSampleCount >= self.minimumBaselineSamples {
                        let count = Double(self.baselineSampleCount)
                        self.baselineX = self.baselineSumX / count
                        self.baselineY = self.baselineSumY / count
                        self.baselineZ = self.baselineSumZ / count
                        self.baselineCaptured = true
                    }
                }

                let magnitude = sqrt(x * x + y * y + z * z)
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
                    deltaMagnitude: deltaMagnitude
                )

                self.rawSamples.append(sample)
                if self.rawSamples.count > self.maximumStoredSamples {
                    // Trim in chunks rather than shifting a 20k-element array every sample.
                    self.rawSamples.removeFirst(max(1, self.maximumStoredSamples / 100))
                }

                if let previous = self.lastDeliveryTimestamp {
                    let delta = deliveryTimestamp - previous
                    if delta > 0 {
                        let instantaneousRate = 1.0 / delta
                        // Keep the per-sample estimate private; publish it at the UI update rate.
                        self.smoothedDeliveryRateHz = self.smoothedDeliveryRateHz.map {
                            $0 * 0.8 + instantaneousRate * 0.2
                        } ?? instantaneousRate
                    }
                }
                self.lastDeliveryTimestamp = deliveryTimestamp

                let now = Date()
                if now.timeIntervalSince(self.lastUIPublish) >= self.uiPublishInterval {
                    self.latestSample = sample
                    self.observedDeliveryRateHz = self.smoothedDeliveryRateHz
                    self.samples.append(sample)
                    if self.samples.count > self.maximumChartSamples {
                        // Trim in chunks to avoid repeated large array shifts during long sessions.
                        self.samples.removeFirst(max(1, self.maximumChartSamples / 100))
                    }
                    self.lastUIPublish = now
                }
            }
        }
        isRunning = true
    }

    func stop() {
        motionManager.stopDeviceMotionUpdates()
        isRunning = false
        if let latestSample, samples.last?.id != latestSample.id {
            samples.append(latestSample)
            if samples.count > maximumChartSamples {
                samples.removeFirst(samples.count - maximumChartSamples)
            }
        }
    }

    func clearSamples() {
        rawSamples.removeAll()
        samples.removeAll()
        latestSample = nil
        lastDeliveryTimestamp = nil
        observedDeliveryRateHz = nil
        smoothedDeliveryRateHz = nil
        baselineCaptured = false
        calibrationQuality = "Unknown"
        baselineStartTimestamp = nil
        baselineStartWallClock = nil
        baselineSampleCount = 0
        baselineSumX = 0
        baselineSumY = 0
        baselineSumZ = 0
        baselineX = nil
        baselineY = nil
        baselineZ = nil
        lastUIPublish = .distantPast
    }

    func exportCSV() -> URL? {
        guard !rawSamples.isEmpty else { return nil }
        let header = "timestamp_iso8601,x_uT,y_uT,z_uT,total_magnitude_uT,delta_from_baseline_uT"
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
