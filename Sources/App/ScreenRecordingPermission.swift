import AppKit
import CoreGraphics

// Screen Recording (TCC) gatekeeping. Without this permission SCK delivers
// nothing, so the app would silently show a black display.
enum ScreenRecordingPermission {
    static var granted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    // Triggers the one-time system prompt and registers the app in the
    // System Settings list. Granting requires an app relaunch.
    @discardableResult
    static func request() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    // Onboarding alert shown at launch when permission is missing.
    static func presentOnboardingAlert() {
        let alert = NSAlert()
        alert.messageText = "Screen Recording permission needed"
        alert.informativeText = """
        GUD Display mirrors your virtual display to the USB display device, which \
        macOS treats as screen recording. Enable GUD Display under \
        Privacy & Security › Screen Recording, then relaunch the app.
        """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            openSystemSettings()
        }
    }
}
