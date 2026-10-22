import Foundation
import CoreMotion
import Combine

struct MagneticSample: Identifiable {
    let id = UUID()
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
    private var lastTimestamp: TimeInterval?

    init() {
        isAvailable = motionManager.isMagnetometerAvailable
    }

    func start() {
        guard motionManager.isMagnetometerAvailable else {
            errorMessage = "The magnetometer is not available on this device."
            return
        }
        guard !isRunning else { return }

        errorMessage = nil
        samples.removeAll(keepingCapacity: true)
        latestSample = nil
        lastTimestamp = nil

        // This is a requested interval, not a guarantee of actual sensor sample rate.
        motionManager.magnetometerUpdateInterval = 1.0 / 50.0
        motionManager.startMagnetometerUpdates(to: queue) { [weak self] data, error in
            if let error {
                Task { @MainActor in
                    self?.errorMessage = error.localizedDescription
                }
                return
            }
            guard let data else { return }

            let field = data.magneticField
            let x = field.x
            let y = field.y
            let z = field.z
            let sample = MagneticSample(
                timestamp: Date(),
                x: x,
                y: y,
                z: z,
                magnitude: sqrt(x * x + y * y + z * z)
            )

            Task { @MainActor in
                guard let self else { return }
                self.latestSample = sample
                self.samples.append(sample)
                if self.samples.count > self.maximumStoredSamples {
                    self.samples.removeFirst(self.samples.count - self.maximumStoredSamples)
                }
                self.lastTimestamp = data.timestamp
            }
        }
        isRunning = true
    }

    func stop() {
        motionManager.stopMagnetometerUpdates()
        isRunning = false
    }

    func clearSamples() {
        samples.removeAll()
        latestSample = nil
        lastTimestamp = nil
    }

    func exportCSV() -> URL? {
        guard !samples.isEmpty else { return nil }
        let header = "timestamp_iso8601,x_uT,y_uT,z_uT,magnitude_uT"
        let body = samples.map(\.csvRow).joined(separator: "\n")
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
