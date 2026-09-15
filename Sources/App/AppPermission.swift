import AppKit
import CoreGraphics

// Every TCC grant the app can use, with a live check and the System Settings
// pane that grants it. None of the checks prompt; prompting stays with the
// code path that needs the permission.
enum AppPermission: CaseIterable {
    case screenRecording
    case inputMonitoring
    case accessibility

    var name: String {
        switch self {
        case .screenRecording: return "Screen Recording"
        case .inputMonitoring: return "Input Monitoring"
        case .accessibility: return "Accessibility"
        }
    }

    // What the app does with it, for the menu item's tooltip.
    var purpose: String {
        switch self {
        case .screenRecording: return "Mirrors the virtual display to the USB device."
        case .inputMonitoring: return "Reads the panel's touch screen instead of macOS."
        case .accessibility: return "Turns touches into clicks on the virtual display."
        }
    }

    var granted: Bool {
        switch self {
        case .screenRecording: return ScreenRecordingPermission.granted
        case .inputMonitoring: return TouchPermissions.inputMonitoringGranted
        case .accessibility: return TouchPermissions.accessibilityGranted
        }
    }

    var settingsPane: String {
        switch self {
        case .screenRecording: return "Privacy_ScreenCapture"
        case .inputMonitoring: return "Privacy_ListenEvent"
        case .accessibility: return "Privacy_Accessibility"
        }
    }

    var settingsURL: URL {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?" + settingsPane)!
    }

    func openSystemSettings() {
        NSWorkspace.shared.open(settingsURL)
    }
}
