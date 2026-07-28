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
    private var screenObserver: NSObjectProtocol?

    // Frame handoff between the capture sample queue and the flush queue.
    // A frame arriving mid-flush replaces the pending one, its damage unioned,
    // so no dirty region is ever silently dropped.
    private let stateLock = NSLock()
    private var pendingFrame: (buffer: CVPixelBuffer, damage: DamageRect)?
    private var flushInFlight = false

    // Reused across flushes to avoid per-frame allocation.
    private let packBuffer = NSMutableData()
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
        try applyState(mode)
        try client.setControllerEnabled(true)
        try client.commit()
        try client.setDisplayEnabled(true)
        self.mode = mode
        fbWidth = Int(mode.hdisplay)
        fbHeight = Int(mode.vdisplay)

        var displayID: CGDirectDisplayID?
        DispatchQueue.main.sync {
            displayID = virtualDisplay.create(
                name: displayName,
                modes: availableModes.map {
                    VirtualDisplayController.Mode(width: Int($0.hdisplay), height: Int($0.vdisplay), refreshRate: $0.refreshRate)
                },
                physicalSizeMillimeters: edidInfo?.physicalSizeMillimeters,
                serialNumber: 1
            )
        }
        guard let displayID else {
            log.error("CGVirtualDisplay creation failed")
            close(deviceGone: false)
            return
        }
        currentDisplayID = displayID
        log.info("Virtual display \(displayID) created: \(self.fbWidth)x\(self.fbHeight)@\(Int(mode.refreshRate)) format \(String(describing: format)) lz4 \(self.compressionEnabled)")

        startCapture(displayID: displayID)
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

    private func startCapture(displayID: CGDirectDisplayID) {
        capture.frameHandler = { [weak self] frame in
            self?.handle(frame: frame)
        }
        capture.stoppedHandler = { [weak self] error in
            self?.log.error("Capture stopped: \(String(describing: error), privacy: .public)")
        }
        Task { [capture, fbWidth, fbHeight] in
            do {
                try await capture.start(displayID: displayID, pixelWidth: fbWidth, pixelHeight: fbHeight)
            } catch {
                self.log.error("Capture start failed: \(String(describing: error), privacy: .public)")
            }
        }
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
        guard let displayID = currentDisplayID,
              let screen = NSScreen.screens.first(where: { $0.displayID == displayID })
        else { return }
        let scale = screen.backingScaleFactor
        let pixelWidth = Int(screen.frame.width * scale)
        let pixelHeight = Int(screen.frame.height * scale)
        queue.async { [self] in
            guard pixelWidth != fbWidth || pixelHeight != fbHeight else { return }
            guard let newMode = availableModes.first(where: { Int($0.hdisplay) == pixelWidth && Int($0.vdisplay) == pixelHeight }) else {
                log.warning("No device mode for \(pixelWidth)x\(pixelHeight); ignoring")
                return
            }
            switchMode(to: newMode)
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

    // MARK: Frame pipeline

    // Runs on the capture sample queue: compute this frame's damage, then
    // either kick off a flush or fold it into the pending frame.
    private func handle(frame: CaptureController.Frame) {
        let full = DamageRect(x: 0, y: 0, width: fbWidth, height: fbHeight)
        var damage: DamageRect
        if frame.isFirstFrame || frame.dirtyRects.isEmpty || client.descriptor?.flags.contains(.fullUpdate) == true {
            damage = full
        } else {
            damage = frame.dirtyRects
                .map { DamageRect(x: Int($0.minX), y: Int($0.minY), width: Int($0.width.rounded(.up)), height: Int($0.height.rounded(.up))) }
                .reduce(nil) { acc, rect in acc.map { DamageRect.union($0, rect) } ?? rect }!
        }
        damage = damage.clamped(toWidth: fbWidth, height: fbHeight)
        guard damage.width > 0, damage.height > 0 else { return }

        stateLock.lock()
        let merged = pendingFrame.map { DamageRect.union($0.damage, damage) } ?? damage
        if flushInFlight {
            // Later frame supersedes the pending one; carry the union of damage.
            pendingFrame = (frame.pixelBuffer, merged)
            stateLock.unlock()
            return
        }
        flushInFlight = true
        pendingFrame = nil
        stateLock.unlock()

        let buffer = frame.pixelBuffer
        flushQueue.async { [weak self] in
            self?.flushLoop(buffer: buffer, damage: merged)
        }
    }

    // Runs on the flush queue: flush, then drain any frame that arrived meanwhile.
    private func flushLoop(buffer: CVPixelBuffer, damage: DamageRect) {
        var next: (buffer: CVPixelBuffer, damage: DamageRect)? = (buffer, damage)
        while let current = next {
            flush(buffer: current.buffer, damage: current.damage)
            recordFlush(bytes: 0)
            stateLock.lock()
            next = pendingFrame
            pendingFrame = nil
            if next == nil {
                flushInFlight = false
            }
            stateLock.unlock()
        }
    }

    private func flush(buffer: CVPixelBuffer, damage rawDamage: DamageRect) {
        let damage = rawDamage.aligned(for: format, fbWidth: fbWidth)

        // Split into whole-line bands no larger than the transfer limit
        // (the limit applies to the uncompressed size).
        let pitch = format.minPitch(width: damage.width)
        let linesPerBand = max(1, maxTransferBytes / max(1, pitch))
        var y = damage.y
        while y < damage.maxY {
            let bandHeight = min(linesPerBand, damage.maxY - y)
            let band = DamageRect(x: damage.x, y: y, width: damage.width, height: bandHeight)
            guard flushBand(buffer: buffer, band: band) else { return }
            y += bandHeight
        }
    }

    private func flushBand(buffer: CVPixelBuffer, band: DamageRect) -> Bool {
        guard PixelConverter.pack(buffer, rect: band, as: format, into: packBuffer) else { return false }

        var payload = packBuffer
        var compressed = false
        if compressionEnabled,
           LZ4Compressor.compress(packBuffer.bytes, length: packBuffer.length, into: compressBuffer)
        {
            payload = compressBuffer
            compressed = true
        }

        let uncompressedLength = packBuffer.length
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

    private func recordFlush(bytes: Int) {
        statsLock.lock()
        statFrames += 1
        statBytes += bytes
        statsLock.unlock()
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
