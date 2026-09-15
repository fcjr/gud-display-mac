import Foundation

// Per-device touch on/off, keyed on the USB serial (or the port when the
// device has none) so it follows the panel across replugs.
enum TouchPreference {
    static func key(serialNumber: String?, locationID: UInt32) -> String {
        if let serialNumber, !serialNumber.isEmpty {
            return "TouchEnabled-" + serialNumber
        }
        return "TouchEnabled-port-" + String(locationID, radix: 16)
    }

    static func isEnabled(serialNumber: String?, locationID: UInt32, defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key(serialNumber: serialNumber, locationID: locationID)) as? Bool ?? true
    }

    static func setEnabled(_ enabled: Bool, serialNumber: String?, locationID: UInt32, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: key(serialNumber: serialNumber, locationID: locationID))
    }
}

// Per-device rotation in the clockwise degrees the menu shows, keyed like
// the touch setting.
enum RotationPreference {
    static func key(serialNumber: String?, locationID: UInt32) -> String {
        "Rotation-" + TouchPreference.key(serialNumber: serialNumber, locationID: locationID)
    }

    static func degrees(serialNumber: String?, locationID: UInt32, defaults: UserDefaults = .standard) -> Int {
        defaults.object(forKey: key(serialNumber: serialNumber, locationID: locationID)) as? Int ?? 0
    }

    static func setDegrees(_ degrees: Int, serialNumber: String?, locationID: UInt32, defaults: UserDefaults = .standard) {
        defaults.set(degrees, forKey: key(serialNumber: serialNumber, locationID: locationID))
    }
}
