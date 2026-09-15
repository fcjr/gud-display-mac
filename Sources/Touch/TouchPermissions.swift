import AppKit
import ApplicationServices
import IOKit.hid

// TCC gatekeeping for touch. Reading (and seizing) a HID digitizer needs
// Input Monitoring; posting the resulting mouse events needs Accessibility.
// Both are asked for only once a touch device is actually attached, so users
// without touch hardware never see the prompts.
enum TouchPermissions {
    static var inputMonitoringGranted: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    @discardableResult
    static func requestInputMonitoring() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    static var accessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    static func requestAccessibility() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
