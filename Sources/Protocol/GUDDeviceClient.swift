import Foundation
import os.log

enum GUDClientError: Error {
    case notGUDDevice
    case unsupportedProtocolVersion(UInt8)
    case malformedResponse
    case noModes
    case deviceStatus(GUD.Status)
    case transport(Error)
}

// Implements the host side of the GUD control protocol over a claimed USB
// interface. Mirrors the behavior of the Linux host driver: serialized control
// requests, GET_STATUS after failures, and STATUS_ON_SET handling.
final class GUDDeviceClient {
    private let transport: GUDTransport
    private let log = Logger(subsystem: "com.leftshift.gud", category: "protocol")
    // All device IO must be strictly serialized (the Linux host's ctrl_lock/
    // buf_lock): concurrent EP0 SETUP packets wedge real gadget firmware.
    // Recursive because flush() holds it across SET_BUFFER + bulk, and error
    // paths issue GET_STATUS while inside a request.
    private let ioLock = NSRecursiveLock()

    private(set) var descriptor: GUD.DisplayDescriptor?
    // After a failed flush the device may be mid-transfer; re-send SET_BUFFER
    // on the next one even for FULL_UPDATE devices (Linux: prev_flush_failed).
    private var prevFlushFailed = false
    private(set) var formats: [GUD.PixelFormat] = []
    private(set) var connectors: [GUD.Connector] = []
    private(set) var connectorProperties: [[GUD.Property]] = []

    private var statusOnSet: Bool {
        descriptor?.flags.contains(.statusOnSet) ?? false
    }

    init(transport: GUDTransport) {
        self.transport = transport
    }

    // MARK: Initialization sequence

    func initialize() throws {
        // Devices can stall EP0 briefly while their firmware settles after
        // SET_CONFIGURATION (observed on real hardware); retry with backoff.
        var raw = Data()
        for attempt in 0..<5 {
            do {
                raw = try controlIn(.getDescriptor, length: GUD.DisplayDescriptor.byteSize)
                break
            } catch {
                guard attempt < 4 else { throw error }
                log.info("GET_DESCRIPTOR attempt \(attempt + 1) failed; retrying")
                Thread.sleep(forTimeInterval: 0.25)
            }
        }
        guard let descriptor = GUD.DisplayDescriptor(parsing: raw) else {
            throw GUDClientError.malformedResponse
        }
        guard descriptor.magic == GUD.magic else {
            throw GUDClientError.notGUDDevice
        }
        guard descriptor.version == GUD.protocolVersion else {
            throw GUDClientError.unsupportedProtocolVersion(descriptor.version)
        }
        self.descriptor = descriptor

        let formatData = try controlIn(.getFormats, length: 32)
        formats = formatData.compactMap { GUD.PixelFormat(rawValue: $0) }

        // Plane properties (rotation). Unknown properties must be skipped for
        // forward compatibility; we currently use none of them.
        _ = try? controlIn(.getProperties, length: 32 * GUD.Property.byteSize)

        let connectorData = try controlIn(.getConnectors, length: 32 * GUD.Connector.byteSize)
        connectors = stride(from: 0, to: connectorData.count, by: GUD.Connector.byteSize).compactMap {
            GUD.Connector(parsing: connectorData, at: $0)
        }

        connectorProperties = connectors.indices.map { index in
            let data = (try? controlIn(.getConnectorProperties, connector: index, length: 32 * GUD.Property.byteSize)) ?? Data()
            return stride(from: 0, to: data.count, by: GUD.Property.byteSize).compactMap {
                GUD.Property(parsing: data, at: $0)
            }
        }
    }

    // Cheap EP0 liveness check (GET_DESCRIPTOR is supported by every device).
    func ping() throws {
        _ = try controlIn(.getDescriptor, length: GUD.DisplayDescriptor.byteSize)
    }

    // MARK: Connector queries

    func connectorStatus(_ index: Int, forceDetect: Bool = false) throws -> GUD.ConnectorStatus {
        if forceDetect {
            try controlOut(.setConnectorForceDetect, connector: index, data: nil)
        }
        let data = try controlIn(.getConnectorStatus, connector: index, length: 1)
        guard let byte = data.first else { throw GUDClientError.malformedResponse }
        return GUD.ConnectorStatus(raw: byte)
    }

    func edid(forConnector index: Int) throws -> Data {
        let data = try controlIn(.getConnectorEDID, connector: index, length: 2048)
        // A compliant EDID is a multiple of 128 bytes; tolerate sloppy devices
        // (e.g. gadgets replying a single zero byte) by treating short replies as none.
        guard data.count >= 128, data.count % 128 == 0 else { return Data() }
        return data
    }

    // If the device returns modes, that is the mode list; if empty, modes
    // should be parsed from the EDID (TODO: EDID mode parsing).
    func modes(forConnector index: Int) throws -> [GUD.DisplayMode] {
        let data = try controlIn(.getConnectorModes, connector: index, length: 128 * GUD.DisplayMode.byteSize)
        return stride(from: 0, to: data.count, by: GUD.DisplayMode.byteSize).compactMap {
            GUD.DisplayMode(parsing: data, at: $0)
        }
    }

    // MARK: State and enable

    func checkState(_ state: GUD.StateRequest) throws {
        try controlOut(.setStateCheck, data: state.encoded())
    }

    func commit() throws {
        try controlOut(.setStateCommit, data: nil)
    }

    func setControllerEnabled(_ enabled: Bool) throws {
        try controlOut(.setControllerEnable, data: Data([enabled ? 1 : 0]))
    }

    func setDisplayEnabled(_ enabled: Bool) throws {
        try controlOut(.setDisplayEnable, data: Data([enabled ? 1 : 0]))
    }

    // MARK: Framebuffer flush

    // Sends one damage-rect update: SET_BUFFER header followed by the payload
    // on the bulk endpoint. `payload` must be tightly packed to the rect (no
    // framebuffer stride), possibly LZ4-block-compressed; the buffer is used
    // directly for IO and may be reused by the caller between flushes.
    func flush(x: Int, y: Int, width: Int, height: Int,
               uncompressedLength: Int, payload: NSMutableData, compressed: Bool) throws
    {
        ioLock.lock()
        defer { ioLock.unlock() }
        let header = GUD.SetBufferHeader(
            x: UInt32(x), y: UInt32(y),
            width: UInt32(width), height: UInt32(height),
            length: UInt32(uncompressedLength),
            compression: compressed ? GUD.compressionLZ4 : 0,
            compressedLength: compressed ? UInt32(payload.length) : 0
        )
        do {
            if descriptor?.flags.contains(.fullUpdate) != true || prevFlushFailed {
                try controlOut(.setBuffer, data: header.encoded())
            }
            // Submit through IOUSBHost's async API, but preserve GUD's wire
            // order: finish this payload before the next SET_BUFFER. Holding
            // ioLock also prevents state changes from splitting the update.
            try transport.beginBulkWrite(payload)
            try transport.waitBulkWrite()
        } catch let error as GUDClientError {
            prevFlushFailed = true
            throw error
        } catch {
            prevFlushFailed = true
            throw GUDClientError.transport(error)
        }
        prevFlushFailed = false
    }

    // MARK: Control plumbing

    private func controlIn(_ request: GUD.Request, connector: Int = 0, length: Int) throws -> Data {
        ioLock.lock()
        defer { ioLock.unlock() }
        do {
            return try transport.controlIn(request: request.rawValue, wValue: UInt16(connector), length: UInt16(length))
        } catch {
            throw mappedError(error, request: request)
        }
    }

    private func controlOut(_ request: GUD.Request, connector: Int = 0, data: Data?) throws {
        ioLock.lock()
        defer { ioLock.unlock() }
        do {
            try transport.controlOut(request: request.rawValue, wValue: UInt16(connector), data: data)
        } catch {
            throw mappedError(error, request: request)
        }
        if statusOnSet {
            try assertStatusOK()
        }
    }

    // On a failed/stalled request the device reports why via GET_STATUS.
    private func mappedError(_ error: Error, request: GUD.Request) -> Error {
        log.error("Request \(String(describing: request), privacy: .public) failed: \((error as NSError).domain, privacy: .public) 0x\(String(UInt32(bitPattern: Int32((error as NSError).code)), radix: 16), privacy: .public)")
        if request != .getStatus, let status = try? readStatus(), status != .ok {
            log.error("Device status after failed \(String(describing: request)): \(status.rawValue)")
            return GUDClientError.deviceStatus(status)
        }
        return GUDClientError.transport(error)
    }

    private func readStatus() throws -> GUD.Status {
        let data = try transport.controlIn(request: GUD.Request.getStatus.rawValue, wValue: 0, length: 1)
        guard let byte = data.first, let status = GUD.Status(rawValue: byte) else {
            throw GUDClientError.malformedResponse
        }
        return status
    }

    private func assertStatusOK() throws {
        let status = try readStatus()
        guard status == .ok else {
            throw GUDClientError.deviceStatus(status)
        }
    }
}
