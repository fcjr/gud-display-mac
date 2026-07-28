import Foundation
@testable import gudmac

// In-memory GUD device for protocol tests. Profiles model the real device
// ecosystem: the Linux kernel gadget, samcday/gud-gadget, and gud-pico.
final class MockGUDTransport: GUDTransport {
    struct Profile {
        var descriptor: Data
        var formats: Data
        var properties: Data = Data()
        var connectors: Data
        var connectorProperties: Data = Data()
        var modes: Data
        var edid: Data = Data()
        var status: UInt8 = 0x00
        var connectorStatus: UInt8 = 0x01
    }

    var profile: Profile
    private(set) var controlLog: [(request: UInt8, wValue: UInt16, out: Data?)] = []
    private(set) var bulkPayloads: [Data] = []
    private(set) var statusReadCount = 0

    init(profile: Profile) {
        self.profile = profile
    }

    func controlIn(request: UInt8, wValue: UInt16, length: UInt16) throws -> Data {
        controlLog.append((request, wValue, nil))
        switch request {
        case 0x00:
            statusReadCount += 1
            return Data([profile.status])
        case 0x01: return profile.descriptor
        case 0x40: return profile.formats
        case 0x41: return profile.properties
        case 0x50: return profile.connectors
        case 0x51: return profile.connectorProperties
        case 0x54: return Data([profile.connectorStatus])
        case 0x55: return profile.modes
        case 0x56: return profile.edid
        default: return Data()
        }
    }

    func controlOut(request: UInt8, wValue: UInt16, data: Data?) throws {
        controlLog.append((request, wValue, data))
    }

    func bulkWrite(_ data: NSMutableData) throws {
        bulkPayloads.append(Data(referencing: data))
    }

    // MARK: Profile builders

    static func descriptor(flags: UInt32, compression: UInt8, maxBufferSize: UInt32 = 0,
                           magic: UInt32 = GUD.magic, version: UInt8 = 1) -> Data
    {
        var data = Data()
        data.appendLE(magic)
        data.append(version)
        data.appendLE(flags)
        data.append(compression)
        data.appendLE(maxBufferSize)
        data.appendLE(UInt32(1))    // min width
        data.appendLE(UInt32(4096)) // max width
        data.appendLE(UInt32(1))    // min height
        data.appendLE(UInt32(4096)) // max height
        return data
    }

    static func connector(type: UInt8 = 0, flags: UInt32 = 0) -> Data {
        var data = Data()
        data.append(type)
        data.appendLE(flags)
        return data
    }

    static func mode(width: UInt16, height: UInt16, preferred: Bool = true) -> Data {
        GUD.DisplayMode(
            clock: UInt32(width) * UInt32(height) * 60 / 1000,
            hdisplay: width, hsyncStart: width + 8, hsyncEnd: width + 16, htotal: width + 32,
            vdisplay: height, vsyncStart: height + 2, vsyncEnd: height + 4, vtotal: height + 8,
            flags: preferred ? GUD.DisplayMode.flagPreferred : 0
        ).encoded()
    }

    // Linux kernel gadget (f_gud): STATUS_ON_SET, LZ4, rich formats.
    static func kernelGadget() -> MockGUDTransport {
        var profile = Profile(
            descriptor: descriptor(flags: 1 << 0, compression: 1),
            formats: Data([0x40, 0x80]),
            connectors: connector(type: 7, flags: 1),
            modes: mode(width: 1920, height: 1080)
        )
        var properties = Data()
        properties.appendLE(UInt16(12)) // backlight brightness
        properties.appendLE(UInt64(100))
        profile.connectorProperties = properties
        return MockGUDTransport(profile: profile)
    }

    // samcday/gud-gadget: no flags, sloppy zero-filled EDID and properties.
    static func sloppyGadget() -> MockGUDTransport {
        MockGUDTransport(profile: Profile(
            descriptor: descriptor(flags: 0, compression: 1),
            formats: Data([0x40]),
            properties: Data(count: 10),          // one zeroed property struct
            connectors: connector(),
            connectorProperties: Data(count: 10), // one zeroed property struct
            modes: mode(width: 800, height: 600),
            edid: Data([0x00])                    // single zero byte
        ))
    }

    // gud-pico: FULL_UPDATE, small buffer, no compression.
    static func pico() -> MockGUDTransport {
        MockGUDTransport(profile: Profile(
            descriptor: descriptor(flags: 1 << 1, compression: 0, maxBufferSize: 320 * 240 * 2),
            formats: Data([0x40, 0x01]),
            connectors: connector(),
            modes: mode(width: 320, height: 240)
        ))
    }
}
