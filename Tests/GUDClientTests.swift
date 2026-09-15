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

    func testAsyncFlushCompletesBeforeNextSetBuffer() throws {
        let transport = MockGUDTransport.kernelGadget()
        let client = GUDDeviceClient(transport: transport)
        try client.initialize()
        let start = transport.events.count
        let payload = NSMutableData(data: Data([1, 2, 3, 4]))
        for y in 0..<2 {
            try client.flush(x: 0, y: y, width: 2, height: 1,
                             uncompressedLength: 4, payload: payload, compressed: false)
        }
        XCTAssertEqual(Array(transport.events.dropFirst(start)), [
            .controlOut(0x60), .controlIn(0x00), .beginBulk, .waitBulk,
            .controlOut(0x60), .controlIn(0x00), .beginBulk, .waitBulk,
        ])
    }

    func testRejectedSetBufferDoesNotSubmitBulk() throws {
        let transport = MockGUDTransport.kernelGadget()
        let client = GUDDeviceClient(transport: transport)
        try client.initialize()
        transport.profile.status = 0x04
        let start = transport.events.count
        XCTAssertThrowsError(try client.flush(x: 0, y: 0, width: 2, height: 1,
                                              uncompressedLength: 4,
                                              payload: NSMutableData(length: 4)!, compressed: false))
        XCTAssertEqual(Array(transport.events.dropFirst(start)), [.controlOut(0x60), .controlIn(0x00)])
        XCTAssertTrue(transport.bulkPayloads.isEmpty)
    }

    func testEnqueueFailureDoesNotWaitAndFullUpdateResynchronizes() throws {
        try assertFullUpdateRecovery(failEnqueue: true)
    }

    func testCompletionFailureMakesFullUpdateResynchronize() throws {
        try assertFullUpdateRecovery(failEnqueue: false)
    }

    private func assertFullUpdateRecovery(failEnqueue: Bool) throws {
        let transport = MockGUDTransport.pico()
        let client = GUDDeviceClient(transport: transport)
        try client.initialize()
        let failure = NSError(domain: "test.usb", code: 42)
        if failEnqueue {
            transport.beginBulkError = failure
        } else {
            transport.waitBulkError = failure
        }
        let payload = NSMutableData(length: 320 * 240 * 2)!
        let start = transport.events.count
        XCTAssertThrowsError(try client.flush(x: 0, y: 0, width: 320, height: 240,
                                              uncompressedLength: payload.length,
                                              payload: payload, compressed: false)) { error in
            guard case GUDClientError.transport(let underlying) = error else {
                return XCTFail("Expected transport error, got \(error)")
            }
            XCTAssertEqual((underlying as NSError).code, failure.code)
        }
        XCTAssertEqual(Array(transport.events.dropFirst(start)),
                       failEnqueue ? [.beginBulk] : [.beginBulk, .waitBulk])

        transport.beginBulkError = nil
        transport.waitBulkError = nil
        // A failed recovery header must not clear prevFlushFailed.
        transport.controlOutError = failure
        XCTAssertThrowsError(try client.flush(x: 0, y: 0, width: 320, height: 240,
                                              uncompressedLength: payload.length,
                                              payload: payload, compressed: false))
        transport.controlOutError = nil
        let recovery = transport.events.count
        try client.flush(x: 0, y: 0, width: 320, height: 240,
                         uncompressedLength: payload.length, payload: payload, compressed: false)
        try client.flush(x: 0, y: 0, width: 320, height: 240,
                         uncompressedLength: payload.length, payload: payload, compressed: false)
        XCTAssertEqual(Array(transport.events.dropFirst(recovery)), [
            .controlOut(0x60), .beginBulk, .waitBulk,
            .beginBulk, .waitBulk,
        ])
    }

    func testCompressedAsyncFlushKeepsWireAndPixelLengthsDistinct() throws {
        let transport = MockGUDTransport.sloppyGadget()
        let client = GUDDeviceClient(transport: transport)
        try client.initialize()
        let payload = NSMutableData(data: Data([1, 2, 3]))
        try client.flush(x: 4, y: 6, width: 8, height: 2,
                         uncompressedLength: 32, payload: payload, compressed: true)
        let header = try XCTUnwrap(transport.controlLog.last(where: { $0.request == 0x60 })?.out)
        XCTAssertEqual(header.leUInt32(at: 16), 32)
        XCTAssertEqual(header[20], GUD.compressionLZ4)
        XCTAssertEqual(header.leUInt32(at: 21), 3)
        XCTAssertEqual(transport.bulkPayloads, [Data([1, 2, 3])])
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

    func testRotationPropertyIsParsedAndSentWithTheState() throws {
        var profile = MockGUDTransport.kernelGadget().profile
        // GUD_PROPERTY_ROTATION (50) offering 0/90/180/270, followed by an
        // unknown plane property that must be passed through untouched.
        profile.properties = Data([50, 0, 0x0F, 0, 0, 0, 0, 0, 0, 0,
                                   99, 0, 7, 0, 0, 0, 0, 0, 0, 0])
        let client = GUDDeviceClient(transport: MockGUDTransport(profile: profile))
        try client.initialize()
        XCTAssertEqual(client.supportedRotations, 0x0F)
        XCTAssertTrue(client.supports(.rotate270))
        XCTAssertEqual(client.planeProperties.count, 2)
        XCTAssertEqual(client.planeProperties[1], GUD.Property(prop: 99, val: 7))

        let none = GUDDeviceClient(transport: MockGUDTransport.kernelGadget())
        try none.initialize()
        XCTAssertEqual(none.supportedRotations, 0)
        XCTAssertFalse(none.supports(.rotate0))

        // ROTATE_0 is mandatory; a device without it offers nothing usable.
        profile.properties = Data([50, 0, 0x0E, 0, 0, 0, 0, 0, 0, 0])
        let broken = GUDDeviceClient(transport: MockGUDTransport(profile: profile))
        try broken.initialize()
        XCTAssertEqual(broken.supportedRotations, 0)
    }

    func testRotationMatchesDisplaySettingsAndTurnsTheFramebuffer() {
        XCTAssertEqual(GUD.Rotation(displayDegrees: 0), .rotate0)
        XCTAssertEqual(GUD.Rotation(displayDegrees: 90), .rotate270)
        XCTAssertEqual(GUD.Rotation(displayDegrees: 180), .rotate180)
        XCTAssertEqual(GUD.Rotation(displayDegrees: 270), .rotate90)
        XCTAssertNil(GUD.Rotation(displayDegrees: 45))
        XCTAssertEqual(GUD.Rotation.rotate90.framebufferSize(width: 240, height: 280).width, 280)
        XCTAssertEqual(GUD.Rotation.rotate180.framebufferSize(width: 240, height: 280).width, 240)
        let encoded = GUD.StateRequest(mode: GUD.DisplayMode(parsing: Data(repeating: 0, count: 24), at: 0)!,
                                       format: .rgb565, connector: 0,
                                       properties: [GUD.Property(prop: GUD.Property.rotation, val: GUD.Rotation.rotate90.rawValue)]).encoded()
        XCTAssertEqual(Array(encoded.suffix(10)), [50, 0, 2, 0, 0, 0, 0, 0, 0, 0])
    }
}
