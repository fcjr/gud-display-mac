import XCTest
@testable import GUDDisplay

final class GUDClientTests: XCTestCase {
    func testKernelGadgetInitialization() throws {
        let transport = MockGUDTransport.kernelGadget()
        let client = GUDDeviceClient(transport: transport)
        try client.initialize()

        XCTAssertEqual(client.formats, [.rgb565, .xrgb8888])
        XCTAssertTrue(client.descriptor!.flags.contains(.statusOnSet))
        XCTAssertEqual(client.connectors.count, 1)
        XCTAssertTrue(client.connectors[0].wantsStatusPolling)
        XCTAssertEqual(client.connectorProperties[0].count, 1)
        XCTAssertEqual(client.connectorProperties[0][0].prop, 12)
        XCTAssertEqual(client.connectorProperties[0][0].val, 100)
    }

    func testStatusOnSetIssuesGetStatusAfterEverySet() throws {
        let transport = MockGUDTransport.kernelGadget()
        let client = GUDDeviceClient(transport: transport)
        try client.initialize()

        let statusReadsBefore = transport.statusReadCount
        try client.setDisplayEnabled(true)
        XCTAssertEqual(transport.statusReadCount, statusReadsBefore + 1)

        // Non-OK status after a SET must surface as a device error.
        transport.profile.status = 0x04 // INVALID_PARAMETER
        XCTAssertThrowsError(try client.setDisplayEnabled(false)) { error in
            guard case GUDClientError.deviceStatus(let status) = error else {
                return XCTFail("Expected deviceStatus, got \(error)")
            }
            XCTAssertEqual(status, .invalidParameter)
        }
    }

    func testSloppyGadgetTolerated() throws {
        let transport = MockGUDTransport.sloppyGadget()
        let client = GUDDeviceClient(transport: transport)
        try client.initialize()

        XCTAssertEqual(client.formats, [.rgb565])
        // Zeroed property struct is preserved (host must skip unknown IDs, not fail).
        XCTAssertEqual(client.connectorProperties[0].count, 1)
        XCTAssertEqual(client.connectorProperties[0][0].prop, 0)
        // One-zero-byte EDID is treated as absent.
        XCTAssertEqual(try client.edid(forConnector: 0), Data())
        // No GET_STATUS chatter without STATUS_ON_SET.
        let statusReadsBefore = transport.statusReadCount
        try client.setDisplayEnabled(true)
        XCTAssertEqual(transport.statusReadCount, statusReadsBefore)
    }

    func testFullUpdateOmitsSetBuffer() throws {
        let transport = MockGUDTransport.pico()
        let client = GUDDeviceClient(transport: transport)
        try client.initialize()

        let payload = NSMutableData(data: Data(count: 320 * 240 * 2))
        try client.flush(x: 0, y: 0, width: 320, height: 240,
                         uncompressedLength: payload.length, payload: payload, compressed: false)

        XCTAssertFalse(transport.controlLog.contains { $0.request == 0x60 })
        XCTAssertEqual(transport.bulkPayloads.count, 1)
        XCTAssertEqual(transport.bulkPayloads[0].count, 320 * 240 * 2)
    }

    func testNormalFlushSendsSetBufferHeader() throws {
        let transport = MockGUDTransport.kernelGadget()
        let client = GUDDeviceClient(transport: transport)
        try client.initialize()

        let payload = NSMutableData(data: Data(count: 64 * 4))
        try client.flush(x: 8, y: 16, width: 64, height: 1,
                         uncompressedLength: 256, payload: payload, compressed: false)

        guard let setBuffer = transport.controlLog.last(where: { $0.request == 0x60 }),
              let header = setBuffer.out
        else {
            return XCTFail("SET_BUFFER not sent")
        }
        XCTAssertEqual(header.count, 25)
        XCTAssertEqual(header.leUInt32(at: 0), 8)   // x
        XCTAssertEqual(header.leUInt32(at: 4), 16)  // y
        XCTAssertEqual(header.leUInt32(at: 8), 64)  // width
        XCTAssertEqual(header.leUInt32(at: 12), 1)  // height
        XCTAssertEqual(header.leUInt32(at: 16), 256) // length
        XCTAssertEqual(header[header.startIndex + 20], 0) // compression
    }

    func testStateRequestCarriesConnectorProperties() throws {
        let transport = MockGUDTransport.kernelGadget()
        let client = GUDDeviceClient(transport: transport)
        try client.initialize()

        var properties = client.connectorProperties[0]
        properties[0] = GUD.Property(prop: GUD.Property.backlightBrightness, val: 40)
        let mode = try client.modes(forConnector: 0)[0]
        let encoded = GUD.StateRequest(mode: mode, format: .rgb565, connector: 0, properties: properties).encoded()
        // mode (24) + format + connector, then one packed 10-byte property.
        XCTAssertEqual(encoded.count, 24 + 2 + 10)
        XCTAssertEqual(Array(encoded.suffix(10)), [12, 0, 40, 0, 0, 0, 0, 0, 0, 0])
    }

    func testRejectsWrongMagicAndVersion() {
        let wrongMagic = MockGUDTransport(profile: .init(
            descriptor: MockGUDTransport.descriptor(flags: 0, compression: 0, magic: 0xdead_beef),
            formats: Data([0x40]),
            connectors: MockGUDTransport.connector(),
            modes: MockGUDTransport.mode(width: 640, height: 480)
        ))
        XCTAssertThrowsError(try GUDDeviceClient(transport: wrongMagic).initialize())

        let wrongVersion = MockGUDTransport(profile: .init(
            descriptor: MockGUDTransport.descriptor(flags: 0, compression: 0, version: 2),
            formats: Data([0x40]),
            connectors: MockGUDTransport.connector(),
            modes: MockGUDTransport.mode(width: 640, height: 480)
        ))
        XCTAssertThrowsError(try GUDDeviceClient(transport: wrongVersion).initialize())
    }
}
