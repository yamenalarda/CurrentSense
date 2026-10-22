import Foundation
import CoreMotion
import Combine

struct MagneticSample: Identifiable {
    let id = UUID()
    /// Wall-clock time when Core Motion delivered this sample to the app.
    /// This is not the sensor's hardware acquisition timestamp.
    let timestamp: Date
    let x: Double
    let y: Double
    let z: Double
    let magnitude: Double

    var csvRow: String {
        let formatter = ISO8601DateFormatter()
        return "\(formatter.string(from: timestamp)),\(x),\(y),\(z),\(magnitude)"
    }
}

@MainActor
final class MagnetometerService: ObservableObject {
    @Published private(set) var isAvailable = false
    @Published private(set) var isRunning = false
    @Published private(set) var latestSample: MagneticSample?
    /// UI/chart snapshots are published at a lower rate to keep animations smooth.
    @Published private(set) var samples: [MagneticSample] = []
    @Published private(set) var errorMessage: String?

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
    private var rawSamples: [MagneticSample] = []
    private var lastUIPublish: Date = .distantPast
    private var lastDeliveryTimestamp: TimeInterval?
    @Published private(set) var observedDeliveryRateHz: Double?

    init() {
        isAvailable = motionManager.isMagnetometerAvailable
    }

    func start() {
        guard motionManager.isMagnetometerAvailable else {
            errorMessage = "The magnetometer is not available on this device."
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

        // Requested interval only; Core Motion/hardware may deliver at a different rate.
        motionManager.magnetometerUpdateInterval = 1.0 / 50.0
        motionManager.startMagnetometerUpdates(to: queue) { [weak self] data, error in
            if let error {
                Task { @MainActor in
                    guard let self else { return }
                    self.errorMessage = "Magnetometer update failed: \(error.localizedDescription)"
                    self.stop()
                }
                return
            }
            guard let data else { return }

            let field = data.magneticField
            let x = field.x
            let y = field.y
            let z = field.z
            guard x.isFinite, y.isFinite, z.isFinite else { return }
            let sample = MagneticSample(
                timestamp: Date(),
                x: x,
                y: y,
                z: z,
                magnitude: sqrt(x * x + y * y + z * z)
            )
            let deliveryTimestamp = data.timestamp

            Task { @MainActor in
                guard let self, self.isRunning else { return }
                self.rawSamples.append(sample)
                if self.rawSamples.count > self.maximumStoredSamples {
                    self.rawSamples.removeFirst(self.rawSamples.count - self.maximumStoredSamples)
                }

                if let previous = self.lastDeliveryTimestamp {
                    let delta = deliveryTimestamp - previous
                    if delta > 0 {
                        self.observedDeliveryRateHz = 1.0 / delta
                    }
                }
                self.lastDeliveryTimestamp = deliveryTimestamp

                // Keep the prominent numeric readout responsive, but don't force a
                // full chart/layout refresh for every Core Motion callback.
                self.latestSample = sample
                let now = Date()
                if now.timeIntervalSince(self.lastUIPublish) >= self.uiPublishInterval {
                    self.samples.append(sample)
                    if self.samples.count > self.maximumChartSamples {
                        self.samples.removeFirst(self.samples.count - self.maximumChartSamples)
                    }
                    self.lastUIPublish = now
                }
            }
        }
        isRunning = true
    }

    func stop() {
        motionManager.stopMagnetometerUpdates()
        isRunning = false
        // Preserve the latest point on pause without copying the full raw recording.
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
        lastUIPublish = .distantPast
    }

    func exportCSV() -> URL? {
        guard !rawSamples.isEmpty else { return nil }
        let header = "timestamp_iso8601,x_uT,y_uT,z_uT,magnitude_uT"
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
        motionManager.stopMagnetometerUpdates()
    }
}
