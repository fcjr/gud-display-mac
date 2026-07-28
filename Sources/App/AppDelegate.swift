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
        statusItem.button?.image = NSImage(systemSymbolName: "display", accessibilityDescription: "gudmac")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        if !ScreenRecordingPermission.granted {
            ScreenRecordingPermission.request()
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

        if !ScreenRecordingPermission.granted {
            let item = NSMenuItem(title: "⚠︎ Screen Recording permission missing",
                                  action: #selector(openPermissionSettings), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            menu.addItem(.separator())
        }

        if sessions.isEmpty {
            menu.addItem(disabledItem("No GUD displays connected"))
        } else {
            for (key, session) in sessions {
                let size = session.currentPixelSize
                menu.addItem(disabledItem("\(session.displayName) — \(size.width)×\(size.height)"))
                menu.addItem(disabledItem("    " + statsLine(for: key, session: session)))

                let resolutionMenu = NSMenu()
                for choice in session.modeChoices {
                    let item = NSMenuItem(title: "\(choice.width)×\(choice.height)",
                                          action: #selector(selectResolution(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = ResolutionChoice(session: session, width: choice.width, height: choice.height)
                    item.state = choice.width == size.width && choice.height == size.height ? .on : .off
                    resolutionMenu.addItem(item)
                }
                let resolutionItem = NSMenuItem(title: "    Resolution", action: nil, keyEquivalent: "")
                resolutionItem.submenu = resolutionMenu
                menu.addItem(resolutionItem)
                menu.addItem(.separator())
            }
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
        menu.addItem(NSMenuItem(title: "Quit gudmac", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
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

    @objc private func openPermissionSettings() {
        ScreenRecordingPermission.openSystemSettings()
    }
}
