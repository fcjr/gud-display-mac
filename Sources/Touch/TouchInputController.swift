import CoreGraphics
import Foundation
import IOKit.hid
import os.log

// Touch for one GUD device. The panel's touch controller shows up as a
// standard HID touch screen interface on the same USB device. macOS's own
// HID stack would turn it into an absolute pointer over the main display,
// so this seizes the device and re-posts its contacts as mouse events at the
// matching spot inside the session's virtual display.
final class TouchInputController {
    private let log = Logger(subsystem: "com.leftshift.gud", category: "touch")
    private let queue = DispatchQueue(label: "com.leftshift.gud.touch")
    private let locationID: UInt32
    private let serialNumber: String?
    // The session's virtual display and how the desktop is turned on the glass.
    private let display: () -> (id: CGDirectDisplayID, rotation: GUD.Rotation)?

    private var manager: IOHIDManager?
    // Our own object for the touch screen's IOService. The manager's copy is
    // already activated by the time it is handed out, and callbacks cannot
    // be registered on an activated device, so it is only used to find the
    // service.
    private var device: IOHIDDevice?
    // Matched but not yet seized: Input Monitoring was missing at the time.
    private var pendingDevice: IOHIDDevice?
    private var contacts: [Contact] = []
    private var contactCount: IOHIDElement?
    private var reportBuffer: UnsafeMutablePointer<UInt8>?
    private var reportBufferLength = 0
    private var pointer = TouchPointer()
    private var accessibilityCheckedAt = Date.distantPast
    private var accessibility = false

    private enum State {
        case idle, needsInputMonitoring, needsAccessibility, active
    }
    private let stateLock = NSLock()
    private var state = State.idle
    private var enabledFlag = true

    // The elements of one Finger collection.
    private struct Contact {
        var tip: IOHIDElement
        var x: IOHIDElement
        var y: IOHIDElement
    }

    private static let digitizerPage = 0x0D
    private static let touchScreenUsage = 0x04
    private static let tipSwitchUsage = 0x42
    private static let contactCountUsage = 0x54
    private static let desktopPage = 0x01
    private static let xUsage = 0x30
    private static let yUsage = 0x31

    init(locationID: UInt32, serialNumber: String?, enabled: Bool = true,
         display: @escaping () -> (id: CGDirectDisplayID, rotation: GUD.Rotation)?) {
        self.locationID = locationID
        self.serialNumber = serialNumber
        self.enabledFlag = enabled
        self.display = display
    }

    // Menu line, or nil while no touch interface has been seen.
    var status: String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        switch state {
        case .idle: return nil
        case .needsInputMonitoring: return "Touch: needs Input Monitoring"
        case .needsAccessibility: return "Touch: needs Accessibility"
        case .active: return enabledFlag ? "Touch: active" : "Touch: off"
        }
    }

    // A touch interface exists for this device (whatever its permissions).
    var available: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return state != .idle
    }

    // Off keeps the device seized, so touching the panel does nothing at
    // all rather than falling back to macOS's own main-display mapping.
    var enabled: Bool {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return enabledFlag
        }
        set {
            stateLock.lock()
            let changed = enabledFlag != newValue
            enabledFlag = newValue
            stateLock.unlock()
            guard changed else { return }
            queue.async { [self] in
                // Never leave a button held down across the switch.
                for action in pointer.release() {
                    post(action)
                }
                log.info("Touch \(newValue ? "enabled" : "disabled", privacy: .public)")
            }
        }
    }

    private func setState(_ new: State) {
        stateLock.lock()
        state = new
        stateLock.unlock()
    }

    func start() {
        queue.async { [self] in
            guard manager == nil else { return }
            let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
            let matching: [String: Any] = [
                kIOHIDVendorIDKey: GUD.vendorID,
                kIOHIDProductIDKey: GUD.productID,
                kIOHIDDeviceUsagePageKey: Self.digitizerPage,
                kIOHIDDeviceUsageKey: Self.touchScreenUsage,
            ]
            IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
            let context = Unmanaged.passUnretained(self).toOpaque()
            IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
                guard let context else { return }
                Unmanaged<TouchInputController>.fromOpaque(context).takeUnretainedValue().deviceMatched(device)
            }, context)
            IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
                guard let context else { return }
                Unmanaged<TouchInputController>.fromOpaque(context).takeUnretainedValue().deviceRemoved(device)
            }, context)
            IOHIDManagerSetCancelHandler(manager) {}
            // Not opened: the manager only enumerates. Each device is opened
            // (seized) individually once it is known to be ours.
            IOHIDManagerSetDispatchQueue(manager, queue)
            IOHIDManagerActivate(manager)
            self.manager = manager
        }
    }

    func stop() {
        queue.async { [self] in
            pendingDevice = nil
            closeDevice()
            if let manager {
                IOHIDManagerCancel(manager)
                self.manager = nil
            }
            setState(.idle)
        }
    }

    // MARK: Device lifecycle (touch queue)

    private func isOurs(_ device: IOHIDDevice) -> Bool {
        if let location = IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString) as? UInt32 {
            return location == locationID
        }
        if let serial = IOHIDDeviceGetProperty(device, kIOHIDSerialNumberKey as CFString) as? String,
           let serialNumber, !serialNumber.isEmpty {
            return serial == serialNumber
        }
        return false
    }

    private func deviceMatched(_ device: IOHIDDevice) {
        guard self.device == nil, pendingDevice == nil, isOurs(device) else { return }
        log.info("Touch screen found on device at location \(self.locationID, format: .hex, privacy: .public)")
        if !TouchPermissions.inputMonitoringGranted {
            TouchPermissions.requestInputMonitoring()
        }
        seize(device)
    }

    // Seize: the system stops generating its own pointer events from it.
    // Without Input Monitoring the open is refused; keep trying so a grant
    // in System Settings takes effect without a relaunch.
    private func seize(_ found: IOHIDDevice) {
        let service = IOHIDDeviceGetService(found)
        guard service != IO_OBJECT_NULL, let device = IOHIDDeviceCreate(kCFAllocatorDefault, service) else {
            log.error("Touch screen has no IOService; ignoring")
            return
        }
        let opened = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        guard opened == kIOReturnSuccess else {
            if pendingDevice == nil {
                log.error("Could not seize touch screen (\(String(opened, radix: 16), privacy: .public)); Input Monitoring permission is needed")
            }
            pendingDevice = found
            setState(.needsInputMonitoring)
            queue.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, self.manager != nil, self.pendingDevice == found else { return }
                self.seize(found)
            }
            return
        }
        pendingDevice = nil

        let (contacts, contactCount) = Self.contacts(of: device)
        guard !contacts.isEmpty else {
            log.error("Touch screen has no finger collection with tip switch, X and Y; ignoring")
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
            setState(.idle)
            return
        }
        self.contacts = contacts
        self.contactCount = contactCount
        self.device = device

        let maxReport = IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? Int ?? 64
        let length = max(1, maxReport)
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: length)
        reportBuffer = buffer
        reportBufferLength = length
        // Callbacks and the queue go on before activation, never after.
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, buffer, length, { context, result, _, _, _, _, _ in
            guard let context, result == kIOReturnSuccess else { return }
            Unmanaged<TouchInputController>.fromOpaque(context).takeUnretainedValue().reportArrived()
        }, context)
        IOHIDDeviceRegisterRemovalCallback(device, { context, _, sender in
            guard let context, let sender else { return }
            let device = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
            Unmanaged<TouchInputController>.fromOpaque(context).takeUnretainedValue().deviceRemoved(device)
        }, context)
        IOHIDDeviceSetCancelHandler(device) {}
        IOHIDDeviceSetDispatchQueue(device, queue)
        IOHIDDeviceActivate(device)

        pointer = TouchPointer()
        checkAccessibility(force: true)
        log.info("Touch screen seized: \(contacts.count, privacy: .public) contact(s), \(contacts[0].x.logicalRange.count, privacy: .public)x\(contacts[0].y.logicalRange.count, privacy: .public) logical")
    }

    // From the manager for a device that was never seized, or from our own
    // device object once it was.
    private func deviceRemoved(_ device: IOHIDDevice) {
        if device == pendingDevice {
            pendingDevice = nil
            setState(.idle)
        }
        guard device == self.device else { return }
        log.info("Touch screen removed")
        closeDevice()
        setState(.idle)
    }

    private func closeDevice() {
        guard let device else { return }
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        IOHIDDeviceCancel(device)
        self.device = nil
        contacts = []
        contactCount = nil
        reportBuffer?.deallocate()
        reportBuffer = nil
        reportBufferLength = 0
    }

    // MARK: Element discovery

    // Every Finger collection that carries a tip switch and both axes.
    private static func contacts(of device: IOHIDDevice) -> (contacts: [Contact], contactCount: IOHIDElement?) {
        guard let elements = IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] else {
            return ([], nil)
        }
        var tips: [(IOHIDElement, IOHIDElement)] = []   // (collection, tip)
        var axes: [(IOHIDElement, IOHIDElement, Int)] = [] // (collection, element, usage)
        var contactCount: IOHIDElement?
        for element in elements {
            let type = IOHIDElementGetType(element)
            guard type == kIOHIDElementTypeInput_Misc || type == kIOHIDElementTypeInput_Button else { continue }
            let page = Int(IOHIDElementGetUsagePage(element))
            let usage = Int(IOHIDElementGetUsage(element))
            switch (page, usage) {
            case (digitizerPage, tipSwitchUsage):
                if let collection = collection(containing: element) { tips.append((collection, element)) }
            case (desktopPage, xUsage), (desktopPage, yUsage):
                if let collection = collection(containing: element) { axes.append((collection, element, usage)) }
            case (digitizerPage, contactCountUsage):
                contactCount = element
            default:
                break
            }
        }
        var contacts: [Contact] = []
        for (collection, tip) in tips {
            let x = axes.first { $0.0 == collection && $0.2 == xUsage }?.1
            let y = axes.first { $0.0 == collection && $0.2 == yUsage }?.1
            if let x, let y {
                contacts.append(Contact(tip: tip, x: x, y: y))
            }
        }
        return (contacts, contactCount)
    }

    private static func collection(containing element: IOHIDElement) -> IOHIDElement? {
        var parent = IOHIDElementGetParent(element)
        while let candidate = parent {
            if IOHIDElementGetType(candidate) == kIOHIDElementTypeCollection {
                return candidate
            }
            parent = IOHIDElementGetParent(candidate)
        }
        return nil
    }

    // MARK: Reports (touch queue)

    private func reportArrived() {
        guard let device, !contacts.isEmpty else { return }
        // Values are parsed into the elements by the kernel before the raw
        // report callback fires, so read them by usage rather than by offset.
        func value(_ element: IOHIDElement) -> Int? {
            // The out pointer is non-optional in the Swift import; it is only
            // read when the call succeeds.
            let slot = UnsafeMutablePointer<Unmanaged<IOHIDValue>>.allocate(capacity: 1)
            defer { slot.deallocate() }
            guard IOHIDDeviceGetValue(device, element, slot) == kIOReturnSuccess else { return nil }
            return IOHIDValueGetIntegerValue(slot.pointee.takeUnretainedValue())
        }
        var read: [TouchContact] = []
        for contact in contacts {
            guard let tip = value(contact.tip), let x = value(contact.x), let y = value(contact.y) else { continue }
            read.append(TouchContact(tip: tip != 0, x: x, y: y,
                                     xRange: contact.x.logicalRange, yRange: contact.y.logicalRange))
        }
        guard let contact = read.first(where: \.tip) ?? read.first else { return }
        guard enabled, let (displayID, rotation) = display() else { return }
        // The panel reports in its own frame; the desktop may be turned on it.
        let bounds = CGDisplayBounds(displayID)

        checkAccessibility(force: false)
        for action in pointer.update(contact, bounds: bounds, rotation: rotation) {
            post(action)
        }
    }

    private func checkAccessibility(force: Bool) {
        guard force || Date().timeIntervalSince(accessibilityCheckedAt) > 2 else { return }
        accessibilityCheckedAt = Date()
        let granted = force && !TouchPermissions.accessibilityGranted
            ? TouchPermissions.requestAccessibility()
            : TouchPermissions.accessibilityGranted
        if granted != accessibility || force {
            accessibility = granted
            setState(granted ? .active : .needsAccessibility)
            if !granted {
                log.error("Accessibility permission missing; touch events will be dropped")
            }
        }
    }

    private func post(_ action: TouchPointer.Action) {
        let (type, point, clicks): (CGEventType, CGPoint, Int) = switch action {
        case .move(let p): (.mouseMoved, p, 0)
        case .down(let p, let n): (.leftMouseDown, p, n)
        case .drag(let p): (.leftMouseDragged, p, 0)
        case .up(let p, let n): (.leftMouseUp, p, n)
        }
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else {
            return
        }
        if clicks > 0 {
            event.setIntegerValueField(.mouseEventClickState, value: Int64(clicks))
        }
        event.post(tap: .cghidEventTap)
    }
}

private extension IOHIDElement {
    var logicalRange: ClosedRange<Int> {
        let lower = IOHIDElementGetLogicalMin(self)
        let upper = IOHIDElementGetLogicalMax(self)
        return lower...max(lower, upper)
    }
}
