import AppKit
import CoreGraphics
import CoreVideo
import Foundation
import os.log

// One attached GUD device: owns the USB transport, protocol client, virtual
// display, capture stream, and the frame pipeline connecting them.
final class DeviceSession {
    private let log = Logger(subsystem: "com.leftshift.gud", category: "session")
    private let queue = DispatchQueue(label: "com.leftshift.gud.session")
    private let flushQueue = DispatchQueue(label: "com.leftshift.gud.flush")

    private let transport: GUDUSBTransport
    private let client: GUDDeviceClient
    private let virtualDisplay = VirtualDisplayController()
    private let capture = CaptureController()
    private var touch: TouchInputController?
    // Window ownership and all access to it stay on the main queue.
    private var displayWindow: DisplayWindowController?

    private var format: GUD.PixelFormat = .xrgb8888
    private var mode: GUD.DisplayMode?
    private var availableModes: [GUD.DisplayMode] = []
    private var connectorIndex = 0
    // The connector's properties as last checked. The protocol wants the
    // complete set with every STATE_CHECK, so a change is an edit to this
    // copy followed by check and commit.
    private var connectorProperties: [GUD.Property] = []
    private var requestedBrightness: Int?
    private var maxTransferBytes = 1 << 20
    private var compressionEnabled = false
    // The panel's mode, and the framebuffer the device takes under the
    // current rotation (width and height swapped for 90 and 270).
    private var panelWidth = 0
    private var panelHeight = 0
    private var fbWidth = 0
    private var fbHeight = 0
    // Session queue only; the touch controller reads its own copy under stateLock.
    private var rotation: GUD.Rotation = .rotate0 {
        didSet {
            stateLock.lock()
            touchRotation = rotation
            stateLock.unlock()
        }
    }
    private var touchRotation: GUD.Rotation = .rotate0
    // Desktop mode per shape (true: landscape framebuffer).
    private var desktops: [Bool: VirtualDisplayController.Mode] = [:]
    private var closed = false
    private(set) var displayName = "GUD Display"
    // Session queue only; the touch controller reads its own copy under stateLock.
    private var currentDisplayID: CGDirectDisplayID? {
        didSet {
            stateLock.lock()
            touchDisplayID = currentDisplayID
            stateLock.unlock()
        }
    }
    private var touchDisplayID: CGDirectDisplayID?

    private var pollTimer: DispatchSourceTimer?
    private var patternTimer: DispatchSourceTimer?
    private var screenObserver: NSObjectProtocol?
    private var lastFlushErrorLogAt = Date.distantPast
    private var displayRecreations = 0
    private var lastFrameGeometry: (width: Int, height: Int, stride: Int, fourCC: OSType)?
    private var lastFlushAt = Date.distantPast
    private var flushDurationEMA: Double = 0
    private var currentMaxFrameRate = 60
    private var lastRateAdjustAt = Date.distantPast
    // Hard ceiling on capture rate (defaults write com.leftshift.gud MaxFrameRate N);
    // bounds the adaptive throttle. Pacing otherwise comes from the device
    // itself, through USB flow control and damage merging, as in the Linux
    // driver: nothing here lowers the rate in response to errors.
    private let frameRateCap = min(60, max(5, UserDefaults.standard.object(forKey: "MaxFrameRate") as? Int ?? 60))
    private static var fullFrameOnly = UserDefaults.standard.bool(forKey: "FullFrameOnly")

    // Frame handoff between the capture sample queue and the flush queue.
    // A frame arriving mid-flush replaces the pending one; the tiles the
    // replaced frame changed are carried into the next diff, so no dirty
    // region is ever silently dropped.
    private let stateLock = NSLock()
    private var handoff = FrameHandoff()
    // Session queue only: coalesce USB errors into one delayed capture restart.
    private var flushRecoveryScheduled = false

    // One transfer: a band of one damage rect, already in the device format
    // and (when it helps) LZ4 compressed, so the flush queue only moves bytes.
    private struct PendingTransfer {
        var rect: DamageRect
        var payload: NSMutableData
        var uncompressedLength: Int
        var compressed: Bool
    }

    // Double-buffered so the sample queue can convert and compress the next
    // frame while the flush queue is still transferring the previous one.
    private final class FrameSlot {
        var transfers: [PendingTransfer] = []
        var tiles: [Bool] = []
        let packBuffer = NSMutableData()
        // Reused across frames; grows to the most bands a frame has needed.
        var payloadBuffers: [NSMutableData] = []
        var scratch = NSMutableData()
    }
    private let slots = [FrameSlot(), FrameSlot()]
    private var damageTracker: DamageTracker?

    // Cumulative flush counters; the menu reads and resets them to derive rates.
    private let statsLock = NSLock()
    private var statFrames = 0
    private var statBytes = 0

    var onClosed: (() -> Void)?

    init?(service: io_service_t) {
        var terminationHandler: (() -> Void)?
        do {
            transport = try GUDUSBTransport(service: service, terminationHandler: { terminationHandler?() })
        } catch {
            Logger(subsystem: "com.leftshift.gud", category: "session")
                .error("Failed to claim GUD interface: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        self.client = GUDDeviceClient(transport: transport)
        terminationHandler = { [weak self] in self?.close(deviceGone: true) }
    }

    func start() {
        queue.async { [self] in
            // The panel's touch screen, if it has one, is a sibling HID
            // interface on the same USB device; it maps onto whatever
            // virtual display this session currently owns.
            let touch = TouchInputController(
                locationID: transport.locationID,
                serialNumber: transport.serialNumber,
                enabled: TouchPreference.isEnabled(serialNumber: transport.serialNumber, locationID: transport.locationID)
            ) { [weak self] in
                guard let self else { return nil }
                stateLock.lock()
                defer { stateLock.unlock() }
                return touchDisplayID.map { ($0, self.touchRotation) }
            }
            self.touch = touch
            touch.start()
            rotation = GUD.Rotation(displayDegrees: Double(RotationPreference.degrees(
                serialNumber: transport.serialNumber, locationID: transport.locationID))) ?? .rotate0
            do {
                try client.initialize()
                guard let descriptor = client.descriptor else { throw GUDClientError.malformedResponse }
                if descriptor.maxBufferSize > 0 {
                    maxTransferBytes = Int(descriptor.maxBufferSize)
                }
                // FULL_UPDATE is incompatible with compression per the protocol.
                compressionEnabled = descriptor.compression & GUD.compressionLZ4 != 0
                    && !descriptor.flags.contains(.fullUpdate)

                // Pick the first connected connector, falling back to the first
                // one (protocol allows only one active connector).
                connectorIndex = client.connectors.indices.first { index in
                    (try? client.connectorStatus(index))?.isConnected == true
                } ?? 0

                let speedNames = ["low (1.5 Mbps)", "full (12 Mbps)", "high (480 Mbps)", "super (5 Gbps)", "super+ (10 Gbps)"]
                let speed = transport.deviceSpeed
                log.info("USB link: \(speed >= 0 && speed < speedNames.count ? speedNames[speed] : "unknown", privacy: .public), bulk max packet \(self.transport.bulkMaxPacketSize, privacy: .public) bytes")

                try configureConnector()
                startPollingIfNeeded()
                installScreenObserver()
            } catch {
                log.error("Device bring-up failed: \(String(describing: error), privacy: .public)")
                close(deviceGone: false)
            }
        }
    }

    // MARK: Connector configuration (session queue)

    private func configureConnector() throws {
        let edidInfo = (try? client.edid(forConnector: connectorIndex)).flatMap(EDIDParser.parse)
        // Prefer the connected monitor's name; fixed panels without EDID
        // can still identify themselves through the USB product string.
        displayName = [edidInfo?.name, transport.productName]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "GUD Display"
        log.info("Display name: \(self.displayName, privacy: .public)")

        // Device mode list wins; EDID modes are the fallback for EDID-only devices.
        var modes = try client.modes(forConnector: connectorIndex)
        if modes.isEmpty {
            modes = edidInfo?.modes ?? []
        }
        guard let mode = modes.first(where: \.isPreferred) ?? modes.first else {
            throw GUDClientError.noModes
        }
        availableModes = modes

        // Prefer the richest format the device offers; the host framebuffer is BGRA.
        let preference: [GUD.PixelFormat] = [.xrgb8888, .argb8888, .rgb888, .rgb565, .rgb332, .xrgb1111, .r8, .r1]
        guard let format = preference.first(where: client.formats.contains) else {
            throw GUDClientError.malformedResponse
        }
        self.format = format

        connectorProperties = client.connectorProperties[safe: connectorIndex] ?? []
        if rotation != .rotate0, !client.supports(rotation) {
            log.warning("Device offers no \(String(describing: self.rotation), privacy: .public) rotation; using none")
            rotation = .rotate0
        }

        // Enable sequence per the Linux host driver:
        // STATE_CHECK -> CONTROLLER_ENABLE -> STATE_COMMIT -> DISPLAY_ENABLE.
        // Best-effort: minimal fixed-mode devices (observed on real hardware)
        // stall the requests they don't need — their output is always on.
        // Only the queries that define the pipeline are fatal.
        attempt("state check") { try applyState(mode) }
        attempt("controller enable") { try client.setControllerEnabled(true) }
        attempt("commit") { try client.commit() }
        attempt("display enable") { try client.setDisplayEnabled(true) }
        self.mode = mode
        setPanelSize(width: Int(mode.hdisplay), height: Int(mode.vdisplay))

        // Modes the panel can actually run, as the host sees them, in both
        // shapes when the device can turn the framebuffer: rotating is then
        // a mode switch rather than a display rebuild, and picking the
        // other shape in System Settings rotates too.
        let shapes: [Bool] = client.supports(.rotate90) || client.supports(.rotate270) ? [false, true] : [false]
        var deviceModes: [VirtualDisplayController.Mode] = []
        desktops = [:]
        var companions: [VirtualDisplayController.Mode] = []
        for landscape in shapes {
            for available in availableModes {
                let (w, h) = landscape ? (Int(available.vdisplay), Int(available.hdisplay))
                                       : (Int(available.hdisplay), Int(available.vdisplay))
                deviceModes.append(VirtualDisplayController.Mode(width: w, height: h, refreshRate: mode.refreshRate))
            }
            let native = deviceModes[landscape ? availableModes.count : 0]
            let plan = Self.desktopPlan(native: native)
            desktops[landscape] = plan.desktop
            companions += plan.companion
        }
        let desktop = desktops[rotation.swapsAxes] ?? deviceModes[0]
        // Larger modes are opt-in via
        //   defaults write com.leftshift.gud ScaledModes -bool YES
        // They only exist to give mirroring a shared resolution to pick
        // (macOS otherwise drags every mirrored display down to the panel's
        // mode); their content is downscaled before transfer.
        let widest = (deviceModes + companions).map(\.width).max() ?? 0
        let scaledModes = UserDefaults.standard.bool(forKey: "ScaledModes")
            ? Self.standardModes
                .filter { $0.width > widest }
                .map { VirtualDisplayController.Mode(width: $0.width, height: $0.height, refreshRate: 60) }
            : []
        let companion = companions.filter { c in !deviceModes.contains { $0.width == c.width && $0.height == c.height } }

        var displayID: CGDirectDisplayID?
        DispatchQueue.main.sync {
            displayID = virtualDisplay.create(
                name: displayName,
                modes: deviceModes + companion + scaledModes,
                desktop: desktop,
                physicalSizeMillimeters: edidInfo?.physicalSizeMillimeters,
                serialNumber: displaySerialNumber
            )
        }
        guard let displayID else {
            log.error("CGVirtualDisplay creation failed")
            close(deviceGone: false)
            return
        }
        // Settle mode and arrangement before capture binds to the display.
        virtualDisplay.finalizeGeometry()
        currentDisplayID = displayID

        // defaults write com.leftshift.gud TestPattern -bool YES
        if UserDefaults.standard.bool(forKey: "TestPattern") {
            startTestPattern()
            return
        }
        log.info("Virtual display \(displayID) created: panel \(self.panelWidth)x\(self.panelHeight)@\(Int(mode.refreshRate)) desktop \(desktop.width)x\(desktop.height) format \(String(describing: format), privacy: .public) lz4 \(self.compressionEnabled) rotation \(String(describing: self.rotation), privacy: .public)")

        startCapture(displayID: displayID)
    }

    // CGVirtualDisplay identifies a display by vendor, product and serial, and
    // macOS keys arrangement and per-display settings on that. Derive it from
    // the device so two GUD displays don't collide and one keeps its settings
    // across replugs: a hash of the USB serial string, else the port.
    private var displaySerialNumber: UInt32 {
        if let serial = transport.serialNumber, !serial.isEmpty {
            var hash: UInt32 = 2_166_136_261 // FNV-1a
            for byte in serial.utf8 {
                hash = (hash ^ UInt32(byte)) &* 16_777_619
            }
            return hash == 0 ? 1 : hash
        }
        return transport.locationID == 0 ? 1 : transport.locationID
    }

    // The desktop mode for a panel shape, and any companion modes it needs.
    // macOS treats modes narrower than 800 px as "low resolution": it
    // never selects one while a larger mode exists, and System Settings
    // hides a display sitting in one. A small panel therefore gets a
    // desktop mode at the smallest aspect-preserving size that is 800 px
    // wide, and the desktop is downscaled into the panel.
    //
    //   defaults write com.leftshift.gud NativeResolution -bool YES
    // keeps the desktop pixel for pixel at the panel's size instead. The
    // display then disappears from System Settings; the 640x480 companion
    // exists only because macOS will not bring a display online below
    // roughly that size.
    static func desktopPlan(native: VirtualDisplayController.Mode)
        -> (desktop: VirtualDisplayController.Mode, companion: [VirtualDisplayController.Mode])
    {
        guard native.width < 800 else { return (native, []) }
        if UserDefaults.standard.bool(forKey: "NativeResolution") {
            return (native, [VirtualDisplayController.Mode(width: 640, height: 480, refreshRate: 60)])
        }
        let height = (800 * native.height / native.width + 1) / 2 * 2
        let desktop = VirtualDisplayController.Mode(width: 800, height: height, refreshRate: 60)
        return (desktop, [desktop])
    }

    // Offered alongside the panel's native mode so macOS has usable common
    // resolutions when mirroring; content is scaled down before transfer.
    private static let standardModes: [(width: Int, height: Int)] = [
        (640, 480), (800, 600), (1024, 768), (1280, 800), (1440, 900), (1512, 982), (1920, 1200),
    ]

    private func attempt(_ what: String, _ body: () throws -> Void) {
        do {
            try body()
        } catch {
            log.warning("Device declined \(what, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    // Streams a synthetic pattern instead of the desktop so transfer-layer
    // bugs (pitch, orientation, channel order) are readable off the panel.
    private func startTestPattern() {
        log.info("Test pattern mode: \(self.fbWidth, privacy: .public)x\(self.fbHeight, privacy: .public) \(String(describing: self.format), privacy: .public), pitch \(self.format.minPitch(width: self.fbWidth), privacy: .public) bytes/row")
        let timer = DispatchSource.makeTimerSource(queue: flushQueue)
        timer.schedule(deadline: .now(), repeating: 2)
        timer.setEventHandler { [weak self] in
            guard let self, !closed else { return }
            PixelConverter.testPattern(width: fbWidth, height: fbHeight, format: format, into: slots[0].packBuffer)
            do {
                try client.flush(x: 0, y: 0, width: fbWidth, height: fbHeight,
                                 uncompressedLength: slots[0].packBuffer.length, payload: slots[0].packBuffer, compressed: false)
                log.info("Test pattern sent (\(self.slots[0].packBuffer.length, privacy: .public) bytes)")
            } catch {
                log.error("Test pattern flush failed: \(String(describing: error), privacy: .public)")
            }
        }
        timer.resume()
        patternTimer = timer
    }

    private func applyState(_ mode: GUD.DisplayMode) throws {
        let state = GUD.StateRequest(
            mode: mode,
            format: format,
            connector: UInt8(connectorIndex),
            properties: planeProperties + connectorProperties
        )
        try client.checkState(state)
    }

    // The device's plane properties as reported, with rotation set to ours.
    // The whole set goes with every state, as the Linux host sends it.
    private var planeProperties: [GUD.Property] {
        client.planeProperties.map { property in
            property.prop == GUD.Property.rotation
                ? GUD.Property(prop: property.prop, val: rotation.rawValue)
                : property
        }
    }

    // Session queue.
    private func setPanelSize(width: Int, height: Int) {
        panelWidth = width
        panelHeight = height
        let fb = rotation.framebufferSize(width: width, height: height)
        fbWidth = fb.width
        fbHeight = fb.height
    }

    // MARK: Rotation

    // macOS shows no Rotation control for a virtual display, so the app
    // owns it: the display is created in the turned shape, the device is
    // told through the GUD rotation property and turns the framebuffer in
    // hardware, and touch is turned to match. Only offered when the device
    // advertises the property.
    var rotationChoices: [GUD.Rotation] {
        GUD.Rotation.allCases.filter(client.supports)
    }

    var currentRotation: GUD.Rotation {
        stateLock.lock()
        defer { stateLock.unlock() }
        return touchRotation
    }

    // Menu-driven; remembered per device. The device is turned first, then
    // the display is switched to the desktop mode of the new shape, which
    // costs one mode change rather than a display rebuild.
    func setRotation(_ wanted: GUD.Rotation) {
        RotationPreference.setDegrees(wanted.displayDegrees,
                                      serialNumber: transport.serialNumber, locationID: transport.locationID)
        queue.async { [self] in
            guard !closed, wanted != rotation, client.supports(wanted), let mode, let displayID = currentDisplayID else { return }
            capture.stop()
            let previous = rotation
            rotation = wanted
            do {
                try applyState(mode)
                try client.commit()
            } catch {
                rotation = previous
                log.error("Device declined rotation \(String(describing: wanted), privacy: .public): \(String(describing: error), privacy: .public)")
                startCapture(displayID: displayID)
                return
            }
            setPanelSize(width: panelWidth, height: panelHeight)
            log.info("Rotation \(String(describing: wanted), privacy: .public); framebuffer \(self.fbWidth)x\(self.fbHeight)")
            if previous.swapsAxes != wanted.swapsAxes, let desktop = desktops[wanted.swapsAxes] {
                virtualDisplay.selectMode(width: desktop.width, height: desktop.height, on: displayID)
            }
            startCapture(displayID: displayID)
        }
    }

    // Session queue. The user picked a mode of the other shape in System
    // Settings: turn the device to match, keeping the last landscape choice.
    private func adoptRotation(landscape: Bool) {
        guard let mode, let displayID = currentDisplayID else { return }
        var wanted: GUD.Rotation = landscape ? .rotate270 : .rotate0
        if landscape, let remembered = GUD.Rotation(displayDegrees: Double(RotationPreference.degrees(
            serialNumber: transport.serialNumber, locationID: transport.locationID))), remembered.swapsAxes {
            wanted = remembered
        }
        guard client.supports(wanted) else { return }
        capture.stop()
        let previous = rotation
        rotation = wanted
        do {
            try applyState(mode)
            try client.commit()
            RotationPreference.setDegrees(wanted.displayDegrees,
                                          serialNumber: transport.serialNumber, locationID: transport.locationID)
        } catch {
            rotation = previous
            log.error("Device declined rotation \(String(describing: wanted), privacy: .public): \(String(describing: error), privacy: .public)")
        }
        setPanelSize(width: panelWidth, height: panelHeight)
        log.info("Display shape changed; rotation \(String(describing: self.rotation), privacy: .public), framebuffer \(self.fbWidth)x\(self.fbHeight)")
        startCapture(displayID: displayID)
    }

    // MARK: Backlight

    // Current backlight level, or nil when the connector has no
    // BACKLIGHT_BRIGHTNESS property.
    var brightness: Int? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return connectorProperties.first { $0.prop == GUD.Property.backlightBrightness }.map { Int($0.val) }
    }

    // Menu-driven. A slider fires faster than a control round trip on a
    // full-speed link, so only the latest value is sent to the device.
    func setBrightness(_ percent: Int) {
        let percent = min(100, max(0, percent))
        stateLock.lock()
        let inFlight = requestedBrightness != nil
        requestedBrightness = percent
        stateLock.unlock()
        guard !inFlight else { return }
        queue.async { [self] in
            stateLock.lock()
            let target = requestedBrightness
            requestedBrightness = nil
            let index = connectorProperties.firstIndex { $0.prop == GUD.Property.backlightBrightness }
            guard let target, let index else {
                stateLock.unlock()
                return
            }
            let previous = connectorProperties[index]
            connectorProperties[index] = GUD.Property(prop: previous.prop, val: UInt64(target))
            stateLock.unlock()
            guard !closed, let mode else { return }
            do {
                try applyState(mode)
                try client.commit()
            } catch {
                stateLock.lock()
                connectorProperties[index] = previous
                stateLock.unlock()
                log.error("Device declined brightness \(target, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
    }

    private var captureTargetID: CGDirectDisplayID?

    func showDisplayWindow() {
        if displayWindow == nil {
            displayWindow = DisplayWindowController(displayName: displayName, source: capture.previewSource)
        }
        displayWindow?.showWindow(nil)
        updateDisplayWindow()
    }

    private func updateDisplayWindow() {
        queue.async { [weak self] in
            guard let self, !closed else { return }
            let target = resolveCaptureTarget()
            DispatchQueue.main.async { [weak self] in
                self?.displayWindow?.setDisplayID(target)
            }
        }
    }

    // When our display is a mirror destination it is no longer independently
    // capturable — capture the mirror source instead (its content is identical).
    private func resolveCaptureTarget() -> CGDirectDisplayID? {
        guard let displayID = currentDisplayID else { return nil }
        let mirrorSource = CGDisplayMirrorsDisplay(displayID)
        return mirrorSource == kCGNullDirectDisplay ? displayID : mirrorSource
    }

    private func startCapture(displayID: CGDirectDisplayID) {
        let target = resolveCaptureTarget() ?? displayID
        captureTargetID = target
        DispatchQueue.main.async { [weak self] in
            self?.displayWindow?.setDisplayID(target)
        }
        if target != displayID {
            log.info("Display \(displayID) is mirrored; capturing source display \(target)")
        }
        capture.frameHandler = { [weak self] frame in
            self?.handle(frame: frame)
        }
        // A stopped stream (display reconfiguration, mirroring toggles, TCC
        // changes) must never strand the device on a frozen frame — restart.
        capture.stoppedHandler = { [weak self] error in
            guard let self else { return }
            if let error, CaptureError.requiresUserAction(error) {
                log.error("Capture requires user action: \(String(describing: error), privacy: .public)")
                return
            }
            log.error("Capture stopped: \(String(describing: error), privacy: .public); restarting")
            queue.asyncAfter(deadline: .now() + 0.5) { self.restartCapture() }
        }
        // A new stream starts at the cap; the throttle re-derives from there.
        currentMaxFrameRate = frameRateCap
        flushDurationEMA = 0
        Task { [weak self, capture, fbWidth, fbHeight, log] in
            for attempt in 0..<3 {
                guard let self, !self.closed, self.currentDisplayID != nil else { return }
                do {
                    try await capture.start(displayID: target, pixelWidth: fbWidth, pixelHeight: fbHeight,
                                            maxFrameRate: self.frameRateCap)
                    return
                } catch {
                    log.error("Capture start failed (attempt \(attempt + 1)): \(String(describing: error), privacy: .public)")
                    // A denied permission cannot be fixed by retrying or
                    // recreating the display; repeated requests just nag.
                    if CaptureError.requiresUserAction(error) { return }
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
            }
            // ScreenCaptureKit can lose a virtual display permanently
            // (SCStreamErrorNoDisplaysOrWindows) even though CoreGraphics
            // still lists it; only recreating the display brings it back.
            // Without this the panel is stranded on its last frame.
            guard let self, !self.closed else { return }
            self.queue.async { self.recreateDisplayForCapture() }
        }
    }

    private func recreateDisplayForCapture() {
        guard !closed, displayRecreations < 3 else {
            if displayRecreations >= 3 {
                log.error("Capture unrecoverable after \(self.displayRecreations, privacy: .public) display recreations; giving up")
            }
            return
        }
        displayRecreations += 1
        log.info("Recreating virtual display to recover capture (attempt \(self.displayRecreations, privacy: .public))")
        reconfigureConnector()
    }

    // Session queue.
    private func restartCapture() {
        guard !closed, let displayID = currentDisplayID else { return }
        capture.stop()
        startCapture(displayID: displayID)
    }

    // Tears down capture and the virtual display, then reconfigures from
    // scratch — used when the connector or its mode list changes.
    private func reconfigureConnector() {
        capture.stop()
        DispatchQueue.main.sync {
            displayWindow?.setDisplayID(nil)
            virtualDisplay.destroy()
        }
        currentDisplayID = nil
        do {
            try configureConnector()
        } catch {
            log.error("Reconfigure failed: \(String(describing: error), privacy: .public)")
            close(deviceGone: false)
        }
    }

    // MARK: Mode switching (System Settings / menu)

    // Observe display reconfiguration; when our virtual display's pixel size
    // changes (user picked another resolution), renegotiate with the device.
    private func installScreenObserver() {
        DispatchQueue.main.async { [weak self] in
            self?.screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.screenParametersChanged()
            }
        }
    }

    private func screenParametersChanged() {
        updateDisplayWindow()
        guard let displayID = currentDisplayID else { return }

        // Mirroring toggles change the capture target without our screen
        // necessarily being listed in NSScreen.screens (mirror destinations
        // are not independent screens).
        queue.async { [self] in
            guard !closed else { return }
            if let target = resolveCaptureTarget(), target != captureTargetID {
                log.info("Capture target changed (mirroring toggled); restarting capture")
                restartCapture()
            }
        }

        queue.async { [self] in
            guard !closed else { return }
            // Notifications come several times during a reconfiguration, some
            // with stale frames; the display's mode is the settled truth.
            guard let current = CGDisplayCopyDisplayMode(displayID) else { return }
            var pixelWidth = current.pixelWidth
            var pixelHeight = current.pixelHeight
            let swappedShape = (pixelWidth > pixelHeight) != (panelWidth > panelHeight)
            if panelWidth != panelHeight, desktops.count > 1, swappedShape != rotation.swapsAxes {
                adoptRotation(landscape: swappedShape)
                return
            }
            // The display is in the framebuffer's shape; modes are the panel's.
            if rotation.swapsAxes {
                swap(&pixelWidth, &pixelHeight)
            }
            if pixelWidth != panelWidth || pixelHeight != panelHeight {
                // A resolution the device itself can run: renegotiate the panel.
                // Anything else is one of our scaled modes — the panel keeps its
                // native timing and ScreenCaptureKit downscales into it.
                if let newMode = availableModes.first(where: { Int($0.hdisplay) == pixelWidth && Int($0.vdisplay) == pixelHeight }) {
                    switchMode(to: newMode)
                } else {
                    log.info("Display now \(pixelWidth, privacy: .public)x\(pixelHeight, privacy: .public); scaling to panel \(self.panelWidth, privacy: .public)x\(self.panelHeight, privacy: .public)")
                }
            }
        }
    }

    // Session queue. The virtual display keeps its identity; only the device
    // state and capture stream are renegotiated.
    private func switchMode(to newMode: GUD.DisplayMode) {
        capture.stop()
        do {
            try applyState(newMode)
            try client.commit()
        } catch {
            log.error("Mode switch rejected by device: \(String(describing: error), privacy: .public)")
            return
        }
        mode = newMode
        setPanelSize(width: Int(newMode.hdisplay), height: Int(newMode.vdisplay))
        log.info("Switched to \(self.panelWidth)x\(self.panelHeight)")
        if let displayID = currentDisplayID {
            startCapture(displayID: displayID)
        }
    }

    // Menu-driven resolution change: ask macOS to switch the virtual display's
    // mode; the screen-parameters observer then renegotiates with the device.
    func requestMode(width: Int, height: Int) {
        DispatchQueue.main.async { [self] in
            guard let displayID = currentDisplayID,
                  let modeList = CGDisplayCopyAllDisplayModes(displayID, nil) as? [CGDisplayMode],
                  let target = modeList.first(where: { $0.pixelWidth == width && $0.pixelHeight == height })
            else { return }
            CGDisplaySetDisplayMode(displayID, target, nil)
        }
    }

    var currentPixelSize: (width: Int, height: Int) {
        (fbWidth, fbHeight)
    }

    var touchStatus: String? {
        touch?.status
    }

    // The device has a touch screen the app can drive.
    var touchAvailable: Bool {
        touch?.available ?? false
    }

    // Menu toggle; remembered per device.
    var touchEnabled: Bool {
        get { touch?.enabled ?? false }
        set {
            touch?.enabled = newValue
            TouchPreference.setEnabled(newValue, serialNumber: transport.serialNumber, locationID: transport.locationID)
        }
    }

    var modeChoices: [(width: Int, height: Int)] {
        availableModes.map { (Int($0.hdisplay), Int($0.vdisplay)) }
    }

    // Menu check marks compare against the panel mode, not the framebuffer.
    var currentPanelSize: (width: Int, height: Int) {
        (panelWidth, panelHeight)
    }

    // MARK: Connector status polling

    // 10-second status poll, matching the Linux host, for connectors that
    // request it. The CHANGED bit forces re-enumeration even when the
    // connected state is stable.
    private func startPollingIfNeeded() {
        guard client.connectors.contains(where: \.wantsStatusPolling) else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 10, repeating: 10)
        timer.setEventHandler { [weak self] in
            self?.pollConnectors()
        }
        timer.resume()
        pollTimer = timer
    }

    private func pollConnectors() {
        guard !closed else { return }
        guard let status = try? client.connectorStatus(connectorIndex) else { return }

        if !status.isConnected {
            // Current connector lost; move to another connected one if any.
            if let replacement = client.connectors.indices.first(where: { index in
                index != connectorIndex && (try? client.connectorStatus(index))?.isConnected == true
            }) {
                log.info("Connector \(self.connectorIndex) disconnected; switching to \(replacement)")
                connectorIndex = replacement
                reconfigureConnector()
            } else {
                log.info("Connector \(self.connectorIndex) disconnected; no replacement")
            }
        } else if status.changed {
            log.info("Connector \(self.connectorIndex) reports CHANGED; re-enumerating")
            reconfigureConnector()
        }
    }

    // Adapt the capture rate to what the device actually sustains, so slow
    // firmware is paced by us rather than drowned.
    private func noteFlushDuration(_ duration: TimeInterval) {
        // Slow EMA: with damage tracking, flush times swing from under a
        // millisecond (a cursor) to over a hundred (a full redraw) frame to
        // frame, and every rate change reconfigures the live capture stream.
        // Frames that arrive faster than they can be flushed are merged, so
        // the throttle only needs to keep the CPU honest, not protect USB.
        flushDurationEMA = flushDurationEMA == 0 ? duration : flushDurationEMA * 0.95 + duration * 0.05
        guard flushDurationEMA > 0 else { return }
        let cap = frameRateCap
        var sustainable = min(cap, max(5, Int(1.0 / flushDurationEMA)))
        // Snap to the cap when close to it and rate-limit changes.
        if sustainable >= cap - 15 { sustainable = cap }
        guard abs(sustainable - currentMaxFrameRate) >= 10,
              Date().timeIntervalSince(lastRateAdjustAt) >= 5
        else { return }
        currentMaxFrameRate = sustainable
        lastRateAdjustAt = Date()
        log.info("Adjusting capture rate to \(sustainable, privacy: .public) fps (flush EMA \(Int(self.flushDurationEMA * 1000), privacy: .public) ms)")
        capture.setMaxFrameRate(sustainable)
    }

    // MARK: Frame pipeline

    // Runs on the capture sample queue: work out what changed, convert and
    // compress those rects, then either kick off a flush or leave the frame
    // pending for the flush loop to pick up.
    private func handle(frame: CaptureController.Frame) {
        let bufW = CVPixelBufferGetWidth(frame.pixelBuffer)
        let bufH = CVPixelBufferGetHeight(frame.pixelBuffer)
        let stride = CVPixelBufferGetBytesPerRow(frame.pixelBuffer)
        let fourCC = CVPixelBufferGetPixelFormatType(frame.pixelBuffer)
        let usable = fourCC == kCVPixelFormatType_32BGRA && bufW >= fbWidth && bufH >= fbHeight
        if lastFrameGeometry.map({ $0 != (bufW, bufH, stride, fourCC) }) ?? true {
            lastFrameGeometry = (bufW, bufH, stride, fourCC)
            log.info("""
            Capture buffer: \(bufW, privacy: .public)x\(bufH, privacy: .public) \
            stride \(stride, privacy: .public) (tight would be \(bufW * 4, privacy: .public)) \
            fourCC \(fourCC, privacy: .public) — panel expects \(self.fbWidth, privacy: .public)x\(self.fbHeight, privacy: .public)\
            \(usable ? "" : "; UNUSABLE, dropping frames", privacy: .public)
            """)
        }
        // Never ship a buffer the converter can't read as tightly-cropped BGRA.
        guard usable else { return }

        if damageTracker == nil || damageTracker?.width != fbWidth || damageTracker?.height != fbHeight {
            damageTracker = DamageTracker(width: fbWidth, height: fbHeight)
        }

        // A packed frame the flush loop hasn't taken yet is about to be
        // replaced: whatever it changed must ride along with this one.
        stateLock.lock()
        let claim = handoff.beginCapture()
        let slot = claim.slot
        if let pending = claim.replaced {
            damageTracker?.carry(tiles: slots[pending].tiles)
        }
        stateLock.unlock()

        var published = false
        defer {
            // Preserve damage if a claimed pending frame could not be packed.
            if !published && (claim.redraw || claim.replaced != nil) {
                stateLock.lock()
                handoff.requestRedraw()
                stateLock.unlock()
            }
        }

        // Devices that need every flush to be the whole framebuffer, or the
        // debugging default, force full damage. ScreenCaptureKit's own dirty
        // rects are unusable here: a scaled stream reports none.
        let forceFull = claim.redraw || frame.isFirstFrame || Self.fullFrameOnly
            || client.descriptor?.flags.contains(.fullUpdate) == true

        // Everything that reads the IOSurface happens HERE, on the sample
        // queue, while it is guaranteed live. ScreenCaptureKit recycles buffers
        // from a small pool, so reading one on the flush queue after this
        // callback returns races the compositor and ships stale or torn pixels.
        guard CVPixelBufferLockBaseAddress(frame.pixelBuffer, .readOnly) == kCVReturnSuccess else { return }
        defer { CVPixelBufferUnlockBaseAddress(frame.pixelBuffer, .readOnly) }
        guard let tiles = damageTracker?.update(frame.pixelBuffer, forceFull: forceFull),
              let rects = damageTracker?.rects(for: tiles), !rects.isEmpty
        else { return }

        let frameSlot = slots[slot]
        frameSlot.tiles = tiles
        frameSlot.transfers.removeAll(keepingCapacity: true)
        var bufferIndex = 0
        for rect in rects {
            let aligned = rect.aligned(for: format, fbWidth: fbWidth)
            guard aligned.width > 0, aligned.height > 0,
                  PixelConverter.pack(frame.pixelBuffer, rect: aligned, as: format, into: frameSlot.packBuffer)
            else { continue }
            // Whole-line bands no larger than the device's transfer limit
            // (which applies to the uncompressed size), compressed now so the
            // flush queue only has to push bytes.
            let pitch = format.minPitch(width: aligned.width)
            let linesPerBand = max(1, maxTransferBytes / max(1, pitch))
            var row = 0
            while row < aligned.height {
                let bandHeight = min(linesPerBand, aligned.height - row)
                let band = DamageRect(x: aligned.x, y: aligned.y + row, width: aligned.width, height: bandHeight)
                let length = bandHeight * pitch
                let source = frameSlot.packBuffer.bytes + row * pitch
                while frameSlot.payloadBuffers.count <= bufferIndex {
                    frameSlot.payloadBuffers.append(NSMutableData())
                }
                let payload = frameSlot.payloadBuffers[bufferIndex]
                bufferIndex += 1
                var compressed = false
                if compressionEnabled, LZ4Compressor.compress(source, length: length, into: payload) {
                    compressed = true
                } else {
                    payload.length = length
                    payload.mutableBytes.copyMemory(from: source, byteCount: length)
                }
                frameSlot.transfers.append(PendingTransfer(rect: band, payload: payload,
                                                           uncompressedLength: length, compressed: compressed))
                row += bandHeight
            }
        }
        guard !frameSlot.transfers.isEmpty else { return }

        stateLock.lock()
        let shouldStart = handoff.publish(slot)
        published = true
        stateLock.unlock()

        guard shouldStart else { return }
        flushQueue.async { [weak self] in self?.flushLoop() }
    }

    // Runs on the flush queue: send whatever is packed, then drain anything
    // that arrived while the transfer was in progress.
    private func flushLoop() {
        while true {
            stateLock.lock()
            guard let slot = handoff.beginFlush() else {
                stateLock.unlock()
                return
            }
            stateLock.unlock()

            let started = Date()
            let result = flushFrame(slots[slot].transfers)
            if result.complete {
                noteFlushDuration(Date().timeIntervalSince(started))
                recordFlush(bytes: result.bytes, pixelBytes: result.pixelBytes)
            } else {
                recoverFailedFlush()
            }

            stateLock.lock()
            handoff.finishFlush()
            lastFlushAt = Date()
            stateLock.unlock()
        }
    }

    // Finish each band's payload before sending the next SET_BUFFER, as the
    // Linux GUD host does. GUD has no capability for queuing headers ahead of
    // unfinished payloads. Capture still packs the next frame concurrently.
    // Count only completed transfers.
    //
    // A failed transfer abandons the rest of this frame. Recovery requests a
    // fresh complete frame, even when the desktop has stopped changing.
    private func flushFrame(_ transfers: [PendingTransfer]) -> (bytes: Int, pixelBytes: Int, complete: Bool) {
        var bytes = 0
        var pixelBytes = 0
        for transfer in transfers {
            do {
                try client.flush(x: transfer.rect.x, y: transfer.rect.y,
                                 width: transfer.rect.width, height: transfer.rect.height,
                                 uncompressedLength: transfer.uncompressedLength,
                                 payload: transfer.payload, compressed: transfer.compressed)
                bytes += transfer.payload.length
                pixelBytes += transfer.uncompressedLength
            } catch {
                logFlushError(error, transfer)
                return (bytes, pixelBytes, false)
            }
        }
        return (bytes, pixelBytes, true)
    }

    private func recoverFailedFlush() {
        stateLock.lock()
        handoff.requestRedraw()
        stateLock.unlock()
        queue.async { [weak self] in
            guard let self, !closed, !flushRecoveryScheduled else { return }
            flushRecoveryScheduled = true
            queue.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self else { return }
                flushRecoveryScheduled = false
                guard !closed else { return }
                stateLock.lock()
                handoff.requestRedraw()
                stateLock.unlock()
                // Restart guarantees a fresh sample on an otherwise static
                // desktop. No partial payload is retried in place.
                log.info("Restarting capture for a full redraw after USB failure")
                restartCapture()
            }
        }
    }

    private func logFlushError(_ error: Error, _ t: PendingTransfer) {
        guard Date().timeIntervalSince(lastFlushErrorLogAt) >= 5 else { return }
        lastFlushErrorLogAt = Date()
        log.error("""
        Failed to flush framebuffer: \(String(describing: error), privacy: .public) \
        (rect \(t.rect.x, privacy: .public),\(t.rect.y, privacy: .public) \
        \(t.rect.width, privacy: .public)x\(t.rect.height, privacy: .public), \
        \(t.payload.length, privacy: .public) bytes on the wire for \
        \(t.uncompressedLength, privacy: .public), \
        \(t.compressed ? "lz4" : "raw", privacy: .public))
        """)
    }

    // MARK: Stats

    func consumeStats() -> (frames: Int, bytes: Int) {
        statsLock.lock()
        defer { statsLock.unlock() }
        let stats = (statFrames, statBytes)
        statFrames = 0
        statBytes = 0
        return stats
    }

    private var totalFlushes = 0
    private var totalWireBytes = 0
    private var totalPixelBytes = 0

    private func recordFlush(bytes: Int, pixelBytes: Int) {
        statsLock.lock()
        statFrames += 1
        statBytes += bytes
        totalFlushes += 1
        totalWireBytes += bytes
        totalPixelBytes += pixelBytes
        let count = totalFlushes
        let (wire, pixels) = (totalWireBytes, totalPixelBytes)
        statsLock.unlock()
        if count == 1 || count % 600 == 0 {
            log.info("Flushed \(count, privacy: .public) frames: \(wire / 1024, privacy: .public) KB on the wire for \(pixels / 1024, privacy: .public) KB of pixels (LZ4 level \(LZ4Compressor.level, privacy: .public))")
        }
    }

    // MARK: Sleep/wake

    // DPMS off + stop capturing on sleep; reverse on wake.
    func suspend() {
        queue.async { [self] in
            guard !closed else { return }
            capture.stop()
            DispatchQueue.main.async { [weak self] in self?.displayWindow?.setDisplayID(nil) }
            try? client.setDisplayEnabled(false)
        }
    }

    func resume() {
        queue.async { [self] in
            guard !closed else { return }
            try? client.setDisplayEnabled(true)
            if let displayID = currentDisplayID {
                startCapture(displayID: displayID)
            }
        }
    }

    // MARK: Teardown

    func close(deviceGone: Bool) {
        queue.async { [self] in
            guard !closed else { return }
            closed = true
            pollTimer?.cancel()
            pollTimer = nil
            patternTimer?.cancel()
            patternTimer = nil
            capture.stop()
            touch?.stop()
            if !deviceGone {
                try? client.setDisplayEnabled(false)
                try? client.setControllerEnabled(false)
            }
            transport.invalidate()
            DispatchQueue.main.async { [self] in
                displayWindow?.close()
                displayWindow = nil
                if let observer = screenObserver {
                    NotificationCenter.default.removeObserver(observer)
                    screenObserver = nil
                }
                virtualDisplay.destroy()
                onClosed?()
            }
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
