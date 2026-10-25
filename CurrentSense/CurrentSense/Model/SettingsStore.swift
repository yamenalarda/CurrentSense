import Foundation
import CurrentSenseCore

enum GeometryChoice: String, CaseIterable, Identifiable {
    case off, calibrated, idealWire
    var id: String { rawValue }
}

/// Small persisted preferences. Contains no secrets.
final class SettingsStore {
    private let defaults = UserDefaults.standard

    var audioEnabled: Bool {
        get { defaults.object(forKey: "audioEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "audioEnabled") }
    }

    var geometryChoice: GeometryChoice {
        get { GeometryChoice(rawValue: defaults.string(forKey: "geometryChoice") ?? "") ?? .idealWire }
        set { defaults.set(newValue.rawValue, forKey: "geometryChoice") }
    }

    var idealDistanceCm: Double {
        get { defaults.object(forKey: "idealDistanceCm") as? Double ?? 1.0 }
        set { defaults.set(newValue, forKey: "idealDistanceCm") }
    }

    var calibration: Calibration? {
        get {
            guard let data = defaults.data(forKey: "calibration") else { return nil }
            return try? JSONDecoder().decode(Calibration.self, from: data)
        }
        set {
            if let v = newValue, let data = try? JSONEncoder().encode(v) { defaults.set(data, forKey: "calibration") }
            else { defaults.removeObject(forKey: "calibration") }
        }
    }
}
