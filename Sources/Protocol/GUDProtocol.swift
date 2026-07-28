import Foundation

// Wire protocol definitions for GUD (Generic USB Display), protocol version 1.
// The Linux host driver (drivers/gpu/drm/gud, include/drm/gud.h) is the de
// facto specification; constants and layouts below mirror it. All multi-byte
// fields are little-endian and structs are packed.

enum GUD {
    static let vendorID = 0x1d50
    static let productID = 0x614d
    static let magic: UInt32 = 0x1d50_614d
    static let protocolVersion: UInt8 = 1

    enum Request: UInt8 {
        case getStatus = 0x00
        case getDescriptor = 0x01
        case getFormats = 0x40
        case getProperties = 0x41
        case getConnectors = 0x50
        case getConnectorProperties = 0x51
        case getConnectorTVModeValues = 0x52
        case setConnectorForceDetect = 0x53
        case getConnectorStatus = 0x54
        case getConnectorModes = 0x55
        case getConnectorEDID = 0x56
        case setBuffer = 0x60
        case setStateCheck = 0x61
        case setStateCommit = 0x62
        case setControllerEnable = 0x63
        case setDisplayEnable = 0x64
    }

    enum Status: UInt8 {
        case ok = 0x00
        case busy = 0x01
        case requestNotSupported = 0x02
        case protocolError = 0x03
        case invalidParameter = 0x04
        case error = 0x05
    }

    struct DisplayFlags: OptionSet {
        let rawValue: UInt32
        // Device requires GET_STATUS after every successful SET request.
        static let statusOnSet = DisplayFlags(rawValue: 1 << 0)
        // Device needs the full framebuffer on every flush; SET_BUFFER is
        // omitted except as a resync after a failed bulk transfer.
        static let fullUpdate = DisplayFlags(rawValue: 1 << 1)
    }

    static let compressionLZ4: UInt8 = 1 << 0

    enum PixelFormat: UInt8, CaseIterable {
        case r1 = 0x01
        case r8 = 0x08
        case xrgb1111 = 0x20
        case rgb332 = 0x30
        case rgb565 = 0x40
        case rgb888 = 0x50
        case xrgb8888 = 0x80
        case argb8888 = 0x81

        var bitsPerPixel: Int {
            switch self {
            case .r1: return 1
            case .xrgb1111: return 4
            case .r8, .rgb332: return 8
            case .rgb565: return 16
            case .rgb888: return 24
            case .xrgb8888, .argb8888: return 32
            }
        }

        func minPitch(width: Int) -> Int {
            (width * bitsPerPixel + 7) / 8
        }
    }

    struct DisplayDescriptor {
        static let byteSize = 30

        let magic: UInt32
        let version: UInt8
        let flags: DisplayFlags
        let compression: UInt8
        let maxBufferSize: UInt32
        let minWidth: UInt32
        let maxWidth: UInt32
        let minHeight: UInt32
        let maxHeight: UInt32

        init?(parsing data: Data) {
            guard data.count >= Self.byteSize else { return nil }
            magic = data.leUInt32(at: 0)
            version = data[data.startIndex + 4]
            flags = DisplayFlags(rawValue: data.leUInt32(at: 5))
            compression = data[data.startIndex + 9]
            maxBufferSize = data.leUInt32(at: 10)
            minWidth = data.leUInt32(at: 14)
            maxWidth = data.leUInt32(at: 18)
            minHeight = data.leUInt32(at: 22)
            maxHeight = data.leUInt32(at: 26)
        }
    }

    struct DisplayMode: Equatable {
        static let byteSize = 24
        static let flagPreferred: UInt32 = 1 << 10

        var clock: UInt32 // pixel clock in kHz
        var hdisplay: UInt16
        var hsyncStart: UInt16
        var hsyncEnd: UInt16
        var htotal: UInt16
        var vdisplay: UInt16
        var vsyncStart: UInt16
        var vsyncEnd: UInt16
        var vtotal: UInt16
        var flags: UInt32

        var isPreferred: Bool { flags & Self.flagPreferred != 0 }

        var refreshRate: Double {
            let denominator = Double(htotal) * Double(vtotal)
            guard denominator > 0 else { return 60 }
            return Double(clock) * 1000 / denominator
        }

        init(clock: UInt32,
             hdisplay: UInt16, hsyncStart: UInt16, hsyncEnd: UInt16, htotal: UInt16,
             vdisplay: UInt16, vsyncStart: UInt16, vsyncEnd: UInt16, vtotal: UInt16,
             flags: UInt32)
        {
            self.clock = clock
            self.hdisplay = hdisplay
            self.hsyncStart = hsyncStart
            self.hsyncEnd = hsyncEnd
            self.htotal = htotal
            self.vdisplay = vdisplay
            self.vsyncStart = vsyncStart
            self.vsyncEnd = vsyncEnd
            self.vtotal = vtotal
            self.flags = flags
        }

        init?(parsing data: Data, at offset: Int) {
            guard data.count >= offset + Self.byteSize else { return nil }
            clock = data.leUInt32(at: offset)
            hdisplay = data.leUInt16(at: offset + 4)
            hsyncStart = data.leUInt16(at: offset + 6)
            hsyncEnd = data.leUInt16(at: offset + 8)
            htotal = data.leUInt16(at: offset + 10)
            vdisplay = data.leUInt16(at: offset + 12)
            vsyncStart = data.leUInt16(at: offset + 14)
            vsyncEnd = data.leUInt16(at: offset + 16)
            vtotal = data.leUInt16(at: offset + 18)
            flags = data.leUInt32(at: offset + 20)
        }

        func encoded() -> Data {
            var data = Data(capacity: Self.byteSize)
            data.appendLE(clock)
            data.appendLE(hdisplay)
            data.appendLE(hsyncStart)
            data.appendLE(hsyncEnd)
            data.appendLE(htotal)
            data.appendLE(vdisplay)
            data.appendLE(vsyncStart)
            data.appendLE(vsyncEnd)
            data.appendLE(vtotal)
            data.appendLE(flags)
            return data
        }
    }

    struct Connector {
        static let byteSize = 5
        static let flagPollStatus: UInt32 = 1 << 0

        let type: UInt8
        let flags: UInt32

        var wantsStatusPolling: Bool { flags & Self.flagPollStatus != 0 }

        init?(parsing data: Data, at offset: Int) {
            guard data.count >= offset + Self.byteSize else { return nil }
            type = data[data.startIndex + offset]
            flags = data.leUInt32(at: offset + 1)
        }
    }

    struct Property {
        static let byteSize = 10

        let prop: UInt16
        let val: UInt64

        init?(parsing data: Data, at offset: Int) {
            guard data.count >= offset + Self.byteSize else { return nil }
            prop = data.leUInt16(at: offset)
            val = data.leUInt64(at: offset + 2)
        }
    }

    struct ConnectorStatus {
        let raw: UInt8
        // Low two bits: 0 disconnected, 1 connected, 2 unknown.
        var isConnected: Bool { raw & 0x03 == 1 }
        // Device signals "modes changed, re-enumerate" even if connection state is unchanged.
        var changed: Bool { raw & 0x80 != 0 }
    }

    struct SetBufferHeader {
        var x: UInt32
        var y: UInt32
        var width: UInt32
        var height: UInt32
        var length: UInt32
        var compression: UInt8
        var compressedLength: UInt32

        func encoded() -> Data {
            var data = Data(capacity: 25)
            data.appendLE(x)
            data.appendLE(y)
            data.appendLE(width)
            data.appendLE(height)
            data.appendLE(length)
            data.append(compression)
            data.appendLE(compressedLength)
            return data
        }
    }

    struct StateRequest {
        var mode: DisplayMode
        var format: PixelFormat
        var connector: UInt8
        // The complete property set must be resent with every state check.
        var properties: [Property]

        func encoded() -> Data {
            var data = mode.encoded()
            data.append(format.rawValue)
            data.append(connector)
            for property in properties {
                data.appendLE(property.prop)
                data.appendLE(property.val)
            }
            return data
        }
    }
}

extension Data {
    func leUInt16(at offset: Int) -> UInt16 {
        let i = startIndex + offset
        return UInt16(self[i]) | UInt16(self[i + 1]) << 8
    }

    func leUInt32(at offset: Int) -> UInt32 {
        let i = startIndex + offset
        return UInt32(self[i]) | UInt32(self[i + 1]) << 8 | UInt32(self[i + 2]) << 16 | UInt32(self[i + 3]) << 24
    }

    func leUInt64(at offset: Int) -> UInt64 {
        UInt64(leUInt32(at: offset)) | UInt64(leUInt32(at: offset + 4)) << 32
    }

    mutating func appendLE(_ value: UInt16) {
        append(UInt8(value & 0xff))
        append(UInt8(value >> 8))
    }

    mutating func appendLE(_ value: UInt32) {
        appendLE(UInt16(value & 0xffff))
        appendLE(UInt16(value >> 16))
    }

    mutating func appendLE(_ value: UInt64) {
        appendLE(UInt32(value & 0xffff_ffff))
        appendLE(UInt32(value >> 32))
    }
}
