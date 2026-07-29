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
    private var maxTransferBytes = 1 << 20
    private var compressionEnabled = false
    private var fbWidth = 0
    private var fbHeight = 0
    private var closed = false
    private(set) var displayName = "GUD Display"
    private var currentDisplayID: CGDirectDisplayID?

    private var pollTimer: DispatchSourceTimer?
    private var heartbeatTimer: DispatchSourceTimer?
    private var patternTimer: DispatchSourceTimer?
    private var screenObserver: NSObjectProtocol?
    private var recovering = false
    private var resetAttempts = 0
    private var displayRecreations = 0
    private var loggedFrameGeometry = false
    private var lastFlushAt = Date.distantPast
    private var flushDurationEMA: Double = 0
    private var currentMaxFrameRate = 60
    // Hard ceiling on capture rate (defaults write com.leftshift.gud MaxFrameRate N).
    // Some firmware crashes under sustained full-rate streaming regardless of
    // USB flow control; this bounds the adaptive throttle.
    private let frameRateCap = min(60, max(5, UserDefaults.standard.object(forKey: "MaxFrameRate") as? Int ?? 60))
    // Lowered on each wedge; shared so they survive device re-enumeration.
    private static var sustainableFrameRate = 60
    private static var fullFrameOnly = UserDefaults.standard.bool(forKey: "FullFrameOnly")
    private var effectiveFrameRateCap: Int { min(frameRateCap, Self.sustainableFrameRate) }

    // Frame handoff between the capture sample queue and the flush queue.
    // A frame arriving mid-flush replaces the pending one, its damage unioned,
    // so no dirty region is ever silently dropped.
    private let stateLock = NSLock()
    private var pendingDamage: DamageRect?
    private var pendingSlot: Int?
    private var pendingRect: DamageRect?
    private var readingSlot: Int?
    private var flushInFlight = false

    // Double-buffered so the sample queue can convert the next frame while the
    // flush queue is still transferring the previous one.
    private let packBuffers = [NSMutableData(), NSMutableData()]
    private let bandBuffer = NSMutableData()
    private let compressBuffer = NSMutableData()

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
                startHeartbeat()
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
        if let name = edidInfo?.name {
            displayName = name
        }

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

        // The display runs at the panel's real resolution: a 336x262 panel is
        // a 336x262 desktop, pixel for pixel, no scaling in the path.
        //
        // Larger modes are opt-in via
        //   defaults write com.leftshift.gud ScaledModes -bool YES
        // They only exist to give mirroring a shared resolution to pick
        // (macOS otherwise drags every mirrored display down to the panel's
        // mode); their content is downscaled before transfer.
        let deviceModes = availableModes.map {
            VirtualDisplayController.Mode(width: Int($0.hdisplay), height: Int($0.vdisplay), refreshRate: mode.refreshRate)
        }
        // macOS will not bring a display online below roughly 640x480, so a
        // small panel needs at least one larger companion mode to exist at
        // all; the native mode is then selected explicitly.
        let companion = fbWidth < 640
            ? [VirtualDisplayController.Mode(width: 640, height: 480, refreshRate: 60)]
            : []
        let scaledModes = UserDefaults.standard.bool(forKey: "ScaledModes")
            ? Self.standardModes
                .filter { $0.width > fbWidth }
                .map { VirtualDisplayController.Mode(width: $0.width, height: $0.height, refreshRate: 60) }
            : companion

        var displayID: CGDirectDisplayID?
        DispatchQueue.main.sync {
            displayID = virtualDisplay.create(
                name: displayName,
                modes: deviceModes + scaledModes,
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
        log.info("Virtual display \(displayID) created: \(self.fbWidth)x\(self.fbHeight)@\(Int(mode.refreshRate)) format \(String(describing: format)) lz4 \(self.compressionEnabled)")

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
            PixelConverter.testPattern(width: fbWidth, height: fbHeight, format: format, into: packBuffers[0])
            do {
                try client.flush(x: 0, y: 0, width: fbWidth, height: fbHeight,
                                 uncompressedLength: packBuffers[0].length, payload: packBuffers[0], compressed: false)
                log.info("Test pattern sent (\(self.packBuffers[0].length, privacy: .public) bytes)")
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
            properties: client.connectorProperties[safe: connectorIndex] ?? []
        )
        try client.checkState(state)
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
        Task { [weak self, capture, fbWidth, fbHeight, log] in
            for attempt in 0..<3 {
                guard let self, !self.closed, self.currentDisplayID != nil else { return }
                do {
                    try await capture.start(displayID: target, pixelWidth: fbWidth, pixelHeight: fbHeight,
                                            maxFrameRate: self.effectiveFrameRateCap)
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

    // MARK: Wedge detection & recovery

    // Real firmware has been observed to crash and stop responding on EP0
    // ("frozen until unplug"). Detect it — via failed mandatory flushes or the
    // idle heartbeat — and force a USB reset. The device re-enumerates as a
    // new service, this session closes, and the monitor attaches a fresh one.
    private func recoverFromWedge(context: String) {
        stateLock.lock()
        let alreadyRecovering = recovering
        recovering = true
        resetAttempts += 1
        let attempts = resetAttempts
        stateLock.unlock()
        guard !alreadyRecovering else { return }
        // Don't hammer firmware that reset can't revive; leave it for a replug.
        guard attempts <= 3 else {
            log.error("Device still unresponsive after \(attempts - 1, privacy: .public) resets; giving up until replug")
            close(deviceGone: true)
            return
        }
        // Back off hard on throughput — sustained streaming is what kills this
        // class of firmware — then try to recover WITHOUT a USB reset, since a
        // reset re-enumerates the device and in practice needs a physical
        // replug. Reset is the last resort.
        Self.sustainableFrameRate = max(4, Self.sustainableFrameRate / 2)
        log.error("Device unresponsive (\(context, privacy: .public)); pausing stream, capping capture at \(Self.sustainableFrameRate, privacy: .public) fps (attempt \(attempts, privacy: .public))")
        capture.stop()

        // Give the firmware a chance to drain and come back on its own.
        queue.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, !closed else { return }
            if (try? client.ping()) != nil {
                log.info("Device responsive again; resuming at \(Self.sustainableFrameRate, privacy: .public) fps")
                stateLock.lock(); recovering = false; stateLock.unlock()
                if let displayID = currentDisplayID { startCapture(displayID: displayID) }
                return
            }
            log.error("Device still unresponsive after pause; resetting (re-enumerates, may need a replug)")
            try? transport.resetDevice()
        }
        return
        // Termination fires close(deviceGone: true); if reset itself failed the
        // device is beyond software recovery until replug.
    }

    // While no frames are flowing nothing would notice a dead device; ping
    // EP0 during idle so recovery starts before the user sees a frozen frame.
    private func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 3, repeating: 3)
        timer.setEventHandler { [weak self] in
            guard let self, !closed else { return }
            stateLock.lock()
            let idle = Date().timeIntervalSince(lastFlushAt) > 3
            stateLock.unlock()
            guard idle else { return }
            if (try? client.ping()) == nil {
                recoverFromWedge(context: "idle heartbeat")
            }
        }
        timer.resume()
        heartbeatTimer = timer
    }

    // Adapt the capture rate to what the device actually sustains, so slow
    // firmware is paced by us rather than drowned.
    private func noteFlushDuration(_ duration: TimeInterval) {
        flushDurationEMA = flushDurationEMA == 0 ? duration : flushDurationEMA * 0.8 + duration * 0.2
        guard flushDurationEMA > 0 else { return }
        let sustainable = min(effectiveFrameRateCap, max(5, Int(0.9 / flushDurationEMA)))
        if abs(sustainable - currentMaxFrameRate) >= 5 {
            currentMaxFrameRate = sustainable
            log.info("Adjusting capture rate to \(sustainable, privacy: .public) fps (flush EMA \(Int(self.flushDurationEMA * 1000), privacy: .public) ms)")
            capture.setMaxFrameRate(sustainable)
        }
    }

    // MARK: Frame pipeline

    // Runs on the capture sample queue: compute this frame's damage, then
    // either kick off a flush or fold it into the pending frame.
    private func handle(frame: CaptureController.Frame) {
        if !loggedFrameGeometry {
            loggedFrameGeometry = true
            let bufW = CVPixelBufferGetWidth(frame.pixelBuffer)
            let bufH = CVPixelBufferGetHeight(frame.pixelBuffer)
            let stride = CVPixelBufferGetBytesPerRow(frame.pixelBuffer)
            let fourCC = CVPixelBufferGetPixelFormatType(frame.pixelBuffer)
            log.info("""
            Capture buffer: \(bufW, privacy: .public)x\(bufH, privacy: .public) \
            stride \(stride, privacy: .public) (tight would be \(bufW * 4, privacy: .public)) \
            fourCC \(fourCC, privacy: .public) — panel expects \(self.fbWidth, privacy: .public)x\(self.fbHeight, privacy: .public)
            """)
        }
        let full = DamageRect(x: 0, y: 0, width: fbWidth, height: fbHeight)
        var damage: DamageRect
        if frame.isFirstFrame || frame.dirtyRects.isEmpty || Self.fullFrameOnly
            || client.descriptor?.flags.contains(.fullUpdate) == true
        {
            damage = full
        } else {
            damage = frame.dirtyRects
                .map { DamageRect(x: Int($0.minX), y: Int($0.minY), width: Int($0.width.rounded(.up)), height: Int($0.height.rounded(.up))) }
                .reduce(nil) { acc, rect in acc.map { DamageRect.union($0, rect) } ?? rect }!
        }
        damage = damage.clamped(toWidth: fbWidth, height: fbHeight)
        guard damage.width > 0, damage.height > 0 else { return }

        // Convert to the device format HERE, on the sample queue, while the
        // IOSurface is guaranteed live. ScreenCaptureKit recycles buffers from
        // a small pool, so reading one on the flush queue after this callback
        // returns races the compositor and ships stale or torn pixels.
        stateLock.lock()
        let merged = pendingDamage.map { DamageRect.union($0, damage) } ?? damage
        // Never write into the buffer the flush queue is currently reading.
        let slot = readingSlot == 0 ? 1 : 0
        stateLock.unlock()

        let aligned = merged.aligned(for: format, fbWidth: fbWidth)
        guard aligned.width > 0, aligned.height > 0,
              PixelConverter.pack(frame.pixelBuffer, rect: aligned, as: format, into: packBuffers[slot])
        else { return }

        stateLock.lock()
        pendingSlot = slot
        pendingRect = aligned
        pendingDamage = nil
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
            guard let slot = pendingSlot, let rect = pendingRect else {
                flushInFlight = false
                stateLock.unlock()
                return
            }
            pendingSlot = nil
            pendingRect = nil
            readingSlot = slot
            stateLock.unlock()

            let started = Date()
            flush(packed: packBuffers[slot], damage: rect)
            noteFlushDuration(Date().timeIntervalSince(started))
            recordFlush(bytes: 0)

            stateLock.lock()
            readingSlot = nil
            lastFlushAt = Date()
            stateLock.unlock()
        }
    }

    // `packed` already holds the rect's pixels in the device format, tightly
    // packed. Split into whole-line bands no larger than the transfer limit
    // (which applies to the uncompressed size).
    private func flush(packed: NSMutableData, damage: DamageRect) {
        let pitch = format.minPitch(width: damage.width)
        let linesPerBand = max(1, maxTransferBytes / max(1, pitch))
        var row = 0
        while row < damage.height {
            let bandHeight = min(linesPerBand, damage.height - row)
            let band = DamageRect(x: damage.x, y: damage.y + row, width: damage.width, height: bandHeight)
            let byteRange = NSRange(location: row * pitch, length: bandHeight * pitch)
            guard byteRange.upperBound <= packed.length else { return }
            bandBuffer.length = byteRange.length
            packed.getBytes(bandBuffer.mutableBytes, range: byteRange)
            guard flushBand(band) else { return }
            row += bandHeight
        }
    }

    private func flushBand(_ band: DamageRect) -> Bool {
        var payload = bandBuffer
        var compressed = false
        if compressionEnabled,
           LZ4Compressor.compress(bandBuffer.bytes, length: bandBuffer.length, into: compressBuffer)
        {
            payload = compressBuffer
            compressed = true
        }

        let uncompressedLength = bandBuffer.length
        statsLock.lock()
        statBytes += payload.length
        statsLock.unlock()
        do {
            try client.flush(x: band.x, y: band.y, width: band.width, height: band.height,
                             uncompressedLength: uncompressedLength, payload: payload, compressed: compressed)
        } catch {
            // Protocol policy: retry once, then drop until new damage.
            log.warning("Flush failed, retrying once: \(String(describing: error), privacy: .public)")
            guard (try? client.flush(x: band.x, y: band.y, width: band.width, height: band.height,
                                     uncompressedLength: uncompressedLength, payload: payload, compressed: compressed)) != nil
            else {
                // SET_BUFFER and the bulk pipe are mandatory on every device;
                // failing both attempts means the firmware is gone.
                recoverFromWedge(context: "flush failed after retry")
                return false
            }
        }
        return true
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

    private func recordFlush(bytes: Int) {
        statsLock.lock()
        statFrames += 1
        statBytes += bytes
        totalFlushes += 1
        let count = totalFlushes
        statsLock.unlock()
        if count == 1 || count % 600 == 0 {
            log.info("Flushed \(count, privacy: .public) frames to device")
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
            heartbeatTimer?.cancel()
            heartbeatTimer = nil
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
