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
    private var fbWidth = 0
    private var fbHeight = 0
    private var closed = false
    private(set) var displayName = "GUD Display"
    private var currentDisplayID: CGDirectDisplayID?

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
    private var pendingSlot: Int?
    private var readingSlot: Int?
    private var flushInFlight = false

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
        fbWidth = Int(mode.hdisplay)
        fbHeight = Int(mode.vdisplay)

        // Modes the panel can actually run; the desktop is captured at the
        // panel's size and downscaled from whatever mode the display sits in.
        let deviceModes = availableModes.map {
            VirtualDisplayController.Mode(width: Int($0.hdisplay), height: Int($0.vdisplay), refreshRate: mode.refreshRate)
        }
        let native = deviceModes[0]
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
        var desktop = native
        var companion: [VirtualDisplayController.Mode] = []
        if fbWidth < 800 {
            if UserDefaults.standard.bool(forKey: "NativeResolution") {
                companion = [VirtualDisplayController.Mode(width: 640, height: 480, refreshRate: 60)]
            } else {
                let height = (800 * fbHeight / fbWidth + 1) / 2 * 2
                desktop = VirtualDisplayController.Mode(width: 800, height: height, refreshRate: 60)
                companion = [desktop]
            }
        }
        // Larger modes are opt-in via
        //   defaults write com.leftshift.gud ScaledModes -bool YES
        // They only exist to give mirroring a shared resolution to pick
        // (macOS otherwise drags every mirrored display down to the panel's
        // mode); their content is downscaled before transfer.
        let scaledModes = UserDefaults.standard.bool(forKey: "ScaledModes")
            ? Self.standardModes
                .filter { $0.width > max(fbWidth, desktop.width) }
                .map { VirtualDisplayController.Mode(width: $0.width, height: $0.height, refreshRate: 60) }
            : []

        var displayID: CGDirectDisplayID?
        DispatchQueue.main.sync {
            displayID = virtualDisplay.create(
                name: displayName,
                modes: deviceModes + companion + scaledModes,
                desktop: desktop,
                physicalSizeMillimeters: edidInfo?.physicalSizeMillimeters,
                serialNumber: 1
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
        log.info("Virtual display \(displayID) created: panel \(self.fbWidth)x\(self.fbHeight)@\(Int(mode.refreshRate)) desktop \(desktop.width)x\(desktop.height) format \(String(describing: format), privacy: .public) lz4 \(self.compressionEnabled)")

        startCapture(displayID: displayID)
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
            properties: connectorProperties
        )
        try client.checkState(state)
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

        guard let screen = NSScreen.screens.first(where: { $0.displayID == displayID }) else { return }
        let scale = screen.backingScaleFactor
        let pixelWidth = Int(screen.frame.width * scale)
        let pixelHeight = Int(screen.frame.height * scale)
        queue.async { [self] in
            guard pixelWidth != fbWidth || pixelHeight != fbHeight else { return }
            // A resolution the device itself can run: renegotiate the panel.
            // Anything else is one of our scaled modes — the panel keeps its
            // native timing and ScreenCaptureKit downscales into it.
            if let newMode = availableModes.first(where: { Int($0.hdisplay) == pixelWidth && Int($0.vdisplay) == pixelHeight }) {
                switchMode(to: newMode)
            } else {
                log.info("Display now \(pixelWidth, privacy: .public)x\(pixelHeight, privacy: .public); scaling to panel \(self.fbWidth, privacy: .public)x\(self.fbHeight, privacy: .public)")
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
        fbWidth = Int(newMode.hdisplay)
        fbHeight = Int(newMode.vdisplay)
        log.info("Switched to \(self.fbWidth)x\(self.fbHeight)")
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

    var modeChoices: [(width: Int, height: Int)] {
        availableModes.map { (Int($0.hdisplay), Int($0.vdisplay)) }
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
        let slot = readingSlot == 0 ? 1 : 0
        if let pending = pendingSlot, pending == slot {
            damageTracker?.carry(tiles: slots[pending].tiles)
        }
        stateLock.unlock()

        // Devices that need every flush to be the whole framebuffer, or the
        // debugging default, force full damage. ScreenCaptureKit's own dirty
        // rects are unusable here: a scaled stream reports none.
        let forceFull = frame.isFirstFrame || Self.fullFrameOnly
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
        pendingSlot = slot
        let shouldStart = !flushInFlight
        if shouldStart { flushInFlight = true }
        stateLock.unlock()

        guard shouldStart else { return }
        flushQueue.async { [weak self] in self?.flushLoop() }
    }

    // Runs on the flush queue: send whatever is packed, then drain anything
    // that arrived while the transfer was in progress.
    private func flushLoop() {
        while true {
            stateLock.lock()
            guard let slot = pendingSlot else {
                flushInFlight = false
                stateLock.unlock()
                return
            }
            pendingSlot = nil
            readingSlot = slot
            stateLock.unlock()

            let started = Date()
            var bytes = 0
            var pixelBytes = 0
            for transfer in slots[slot].transfers {
                bytes += transfer.payload.length
                pixelBytes += transfer.uncompressedLength
                guard send(transfer) else { break }
            }
            noteFlushDuration(Date().timeIntervalSince(started))
            recordFlush(bytes: bytes, pixelBytes: pixelBytes)

            stateLock.lock()
            readingSlot = nil
            lastFlushAt = Date()
            stateLock.unlock()
        }
    }

    // Same policy as the Linux gud driver (gud_flush_damage): a failed
    // transfer abandons the rest of this flush, is logged rate-limited, and
    // the next damage simply tries again. No retry, no ping, no reset, no
    // rate change: a device that is gone is torn down by the termination
    // handler, and one that is merely slow is paced by USB flow control.
    private func send(_ transfer: PendingTransfer) -> Bool {
        let band = transfer.rect
        do {
            try client.flush(x: band.x, y: band.y, width: band.width, height: band.height,
                             uncompressedLength: transfer.uncompressedLength,
                             payload: transfer.payload, compressed: transfer.compressed)
            return true
        } catch {
            if Date().timeIntervalSince(lastFlushErrorLogAt) >= 5 {
                lastFlushErrorLogAt = Date()
                log.error("Failed to flush framebuffer: \(String(describing: error), privacy: .public)")
            }
            return false
        }
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
            if !deviceGone {
                try? client.setDisplayEnabled(false)
                try? client.setControllerEnabled(false)
            }
            transport.invalidate()
            DispatchQueue.main.async { [self] in
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
