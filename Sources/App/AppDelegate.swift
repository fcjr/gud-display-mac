import AppKit
import ServiceManagement
import Sparkle

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let monitor = USBDeviceMonitor()
    private var sessions: [ObjectIdentifier: DeviceSession] = [:]
    private var lastStatsRead: [ObjectIdentifier: Date] = [:]
    private var statsLines: [ObjectIdentifier: String] = [:]

    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "display", accessibilityDescription: "GUD Display")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        if !ScreenRecordingPermission.granted && !ScreenRecordingPermission.request() {
            ScreenRecordingPermission.presentOnboardingAlert()
        }

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)

        monitor.deviceMatched = { [weak self] service in
            DispatchQueue.main.async { self?.attach(service: service) }
        }
        monitor.start()
    }

    // MARK: Devices

    private func attach(service: io_service_t) {
        // Balances the iterator reference handed over by USBDeviceMonitor;
        // the transport holds its own reference by the time this returns.
        defer { IOObjectRelease(service) }
        guard let session = DeviceSession(service: service) else { return }
        let key = ObjectIdentifier(session)
        sessions[key] = session
        lastStatsRead[key] = Date()
        session.onClosed = { [weak self] in
            self?.sessions.removeValue(forKey: key)
            self?.lastStatsRead.removeValue(forKey: key)
            self?.statsLines.removeValue(forKey: key)
        }
        session.start()
    }

    @objc private func willSleep(_ note: Notification) {
        sessions.values.forEach { $0.suspend() }
    }

    @objc private func didWake(_ note: Notification) {
        sessions.values.forEach { $0.resume() }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let missing = AppPermission.allCases.filter { !$0.granted }
        if !missing.isEmpty {
            for permission in missing {
                menu.addItem(permissionItem(permission))
            }
            menu.addItem(.separator())
        }

        if sessions.isEmpty {
            menu.addItem(disabledItem("No GUD displays connected"))
        } else {
            for (key, session) in sessions {
                let size = session.currentPixelSize
                menu.addItem(disabledItem("\(session.displayName) — \(size.width)×\(size.height)"))
                menu.addItem(disabledItem("    " + statsLine(for: key, session: session)))
                if let status = session.touchStatus {
                    menu.addItem(touchItem(status))
                    if session.touchAvailable {
                        let toggle = NSMenuItem(title: "    Touch", action: #selector(toggleTouch(_:)), keyEquivalent: "")
                        toggle.target = self
                        toggle.representedObject = session
                        toggle.state = session.touchEnabled ? .on : .off
                        menu.addItem(toggle)
                    }
                }

                let previewItem = NSMenuItem(title: "    Open Display Window",
                                              action: #selector(openDisplayWindow(_:)), keyEquivalent: "")
                previewItem.target = self
                previewItem.representedObject = session
                menu.addItem(previewItem)

                let resolutionMenu = NSMenu()
                for choice in session.modeChoices {
                    let item = NSMenuItem(title: "\(choice.width)×\(choice.height)",
                                          action: #selector(selectResolution(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = ResolutionChoice(session: session, width: choice.width, height: choice.height)
                    let panel = session.currentPanelSize
                    item.state = choice.width == panel.width && choice.height == panel.height ? .on : .off
                    resolutionMenu.addItem(item)
                }
                let resolutionItem = NSMenuItem(title: "    Resolution", action: nil, keyEquivalent: "")
                resolutionItem.submenu = resolutionMenu
                menu.addItem(resolutionItem)
                let rotations = session.rotationChoices
                if !rotations.isEmpty {
                    let rotationMenu = NSMenu()
                    let current = session.currentRotation
                    for rotation in rotations.sorted(by: { $0.displayDegrees < $1.displayDegrees }) {
                        let item = NSMenuItem(title: "\(rotation.displayDegrees)°",
                                              action: #selector(selectRotation(_:)), keyEquivalent: "")
                        item.target = self
                        item.representedObject = RotationChoice(session: session, rotation: rotation)
                        item.state = rotation == current ? .on : .off
                        rotationMenu.addItem(item)
                    }
                    let rotationItem = NSMenuItem(title: "    Rotation", action: nil, keyEquivalent: "")
                    rotationItem.submenu = rotationMenu
                    menu.addItem(rotationItem)
                }
                if let brightness = session.brightness {
                    menu.addItem(disabledItem("    Brightness"))
                    menu.addItem(brightnessItem(for: session, value: brightness))
                }
                menu.addItem(.separator())
            }
        }

        menu.addItem(.separator())

        // Every grant the app can use, checked live each time the menu opens.
        menu.addItem(disabledItem("Permissions"))
        for permission in AppPermission.allCases {
            menu.addItem(permissionItem(permission))
        }
        menu.addItem(.separator())

        let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)

        let updateItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit GUD Display", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func statsLine(for key: ObjectIdentifier, session: DeviceSession) -> String {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastStatsRead[key] ?? now)
        let stats = session.consumeStats()
        lastStatsRead[key] = now
        // Menus don't tick while open; show the rate since the last open.
        if elapsed > 0.5 {
            let fps = Double(stats.frames) / elapsed
            let mbps = Double(stats.bytes) / elapsed / 1_000_000
            statsLines[key] = String(format: "%.0f fps · %.1f MB/s", fps, mbps)
        }
        return statsLines[key] ?? "—"
    }

    private final class BrightnessSlider: NSSlider {
        weak var session: DeviceSession?
    }

    private func brightnessItem(for session: DeviceSession, value: Int) -> NSMenuItem {
        let slider = BrightnessSlider(value: Double(value), minValue: 0, maxValue: 100,
                                      target: self, action: #selector(changeBrightness(_:)))
        slider.session = session
        slider.isContinuous = true
        slider.frame = NSRect(x: 22, y: 4, width: 180, height: 20)
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 224, height: 28))
        view.addSubview(slider)
        let item = NSMenuItem()
        item.view = view
        return item
    }

    // A missing permission is a link to the pane that grants it.
    private func touchItem(_ status: String) -> NSMenuItem {
        let permission: AppPermission? = status.contains("Input Monitoring") ? .inputMonitoring
            : status.contains("Accessibility") ? .accessibility : nil
        guard let permission else { return disabledItem("    " + status) }
        let item = NSMenuItem(title: "    ⚠︎ " + status, action: #selector(openPermissionSettings(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = permission
        return item
    }

    // Granted: a ticked, inert line. Missing: a button to the pane that grants it.
    private func permissionItem(_ permission: AppPermission) -> NSMenuItem {
        let item: NSMenuItem
        if permission.granted {
            item = disabledItem("    ✓ " + permission.name)
        } else {
            item = NSMenuItem(title: "    ⚠︎ " + permission.name + " — Open System Settings…",
                              action: #selector(openPermissionSettings(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = permission
        }
        item.toolTip = permission.purpose
        return item
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: Actions

    private final class ResolutionChoice: NSObject {
        let session: DeviceSession
        let width: Int
        let height: Int
        init(session: DeviceSession, width: Int, height: Int) {
            self.session = session
            self.width = width
            self.height = height
        }
    }

    private final class RotationChoice: NSObject {
        let session: DeviceSession
        let rotation: GUD.Rotation
        init(session: DeviceSession, rotation: GUD.Rotation) {
            self.session = session
            self.rotation = rotation
        }
    }

    @objc private func selectRotation(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? RotationChoice else { return }
        choice.session.setRotation(choice.rotation)
    }

    @objc private func changeBrightness(_ sender: BrightnessSlider) {
        sender.session?.setBrightness(Int(sender.doubleValue.rounded()))
    }

    @objc private func openDisplayWindow(_ sender: NSMenuItem) {
        (sender.representedObject as? DeviceSession)?.showDisplayWindow()
    }

    @objc private func selectResolution(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? ResolutionChoice else { return }
        choice.session.requestMode(width: choice.width, height: choice.height)
    }

    @objc private func toggleLaunchAtLogin() {
        if SMAppService.mainApp.status == .enabled {
            try? SMAppService.mainApp.unregister()
        } else {
            try? SMAppService.mainApp.register()
        }
    }

    @objc private func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    @objc private func openPermissionSettings(_ sender: NSMenuItem) {
        (sender.representedObject as? AppPermission)?.openSystemSettings()
    }

    @objc private func toggleTouch(_ sender: NSMenuItem) {
        guard let session = sender.representedObject as? DeviceSession else { return }
        session.touchEnabled.toggle()
    }
}
