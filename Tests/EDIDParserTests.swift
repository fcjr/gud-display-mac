import XCTest
@testable import GUDDisplay

final class EDIDParserTests: XCTestCase {
    // Synthetic base block: one 1024x600@60-ish DTD + monitor name descriptor.
    private func makeEDID() -> Data {
        var edid = [UInt8](repeating: 0, count: 128)
        edid.replaceSubrange(0..<8, with: [0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00])
        edid[21] = 22 // 220 mm wide
        edid[22] = 13 // 130 mm high

        // DTD at 54: clock 4900 (49.00 MHz), 1024x600, hblank 320, vblank 35,
        // hsync offset 48 width 32, vsync offset 3 width 5, digital separate
        // sync with positive polarities.
        let dtd: [UInt8] = [
            0x24, 0x13, // pixel clock / 10 kHz, little-endian
            0x00,       // hactive low
            0x40,       // hblank low
            0x41,       // hactive high 4 | hblank high 1
            0x58,       // vactive low
            0x23,       // vblank low
            0x20,       // vactive high 2 | vblank high 0
            0x30,       // hsync offset low
            0x20,       // hsync width low
            0x35,       // vsync offset low 3 | vsync width low 5
            0x00,       // upper bits
            0x00, 0x00, 0x00, // physical size (unused here)
            0x00, 0x00,
            0x1e,       // interlace off, digital separate sync, +v +h
        ]
        edid.replaceSubrange(54..<72, with: dtd)

        // Monitor name descriptor at 72: tag 0xFC, "PICO DISPLAY\n"
        edid[72 + 3] = 0xfc
        let name = Array("Pico Panel\n".utf8)
        edid.replaceSubrange((72 + 5)..<(72 + 5 + name.count), with: name)

        var checksum: UInt8 = 0
        for byte in edid.prefix(127) {
            checksum = checksum &+ byte
        }
        edid[127] = 0 &- checksum
        return Data(edid)
    }

    func testParsesDTDAndName() throws {
        let result = try XCTUnwrap(EDIDParser.parse(makeEDID()))

        XCTAssertEqual(result.name, "Pico Panel")
        XCTAssertEqual(result.physicalSizeMillimeters, CGSize(width: 220, height: 130))
        XCTAssertEqual(result.modes.count, 1)

        let mode = result.modes[0]
        XCTAssertEqual(mode.clock, 49000)
        XCTAssertEqual(mode.hdisplay, 1024)
        XCTAssertEqual(mode.hsyncStart, 1072)
        XCTAssertEqual(mode.hsyncEnd, 1104)
        XCTAssertEqual(mode.htotal, 1344)
        XCTAssertEqual(mode.vdisplay, 600)
        XCTAssertEqual(mode.vsyncStart, 603)
        XCTAssertEqual(mode.vsyncEnd, 608)
        XCTAssertEqual(mode.vtotal, 635)
        XCTAssertTrue(mode.isPreferred)
        XCTAssertEqual(mode.flags & 0b1111, 0b0101) // PHSYNC | PVSYNC
        XCTAssertEqual(Int(mode.refreshRate.rounded()), 57)
    }

    func testRejectsGarbage() {
        XCTAssertNil(EDIDParser.parse(Data([0x00])))
        XCTAssertNil(EDIDParser.parse(Data(count: 128)))
    }

    func testKeepsNameWithoutModesOrPhysicalSize() throws {
        var edid = makeEDID()
        edid[21] = 0
        edid[22] = 0
        edid.replaceSubrange(54..<72, with: repeatElement(UInt8(0), count: 18))
        let result = try XCTUnwrap(EDIDParser.parse(edid))
        XCTAssertEqual(result.name, "Pico Panel")
        XCTAssertTrue(result.modes.isEmpty)
        XCTAssertNil(result.physicalSizeMillimeters)
    }

    func testTrimsNullTerminatedName() {
        var edid = makeEDID()
        edid.replaceSubrange(77..<90, with: Array("Panel  ".utf8) + [UInt8](repeating: 0, count: 6))
        XCTAssertEqual(EDIDParser.parse(edid)?.name, "Panel")
    }

    func testIgnoresBlankName() {
        var edid = makeEDID()
        edid.replaceSubrange(77..<90, with: repeatElement(UInt8(0x20), count: 13))
        XCTAssertNil(EDIDParser.parse(edid)?.name)
    }
}
