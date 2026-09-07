import Foundation

// Minimal EDID parser for GUD devices that provide an EDID but no mode list.
// Extracts detailed timing descriptors (DTDs) from the base block — which
// covers panel-class devices — and the physical size. Standard/established
// timings and extension blocks are not parsed.
enum EDIDParser {
    struct Result {
        var modes: [GUD.DisplayMode]
        var physicalSizeMillimeters: CGSize?
        var name: String?
    }

    private static let header: [UInt8] = [0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00]

    static func parse(_ edid: Data) -> Result? {
        guard edid.count >= 128 else { return nil }
        let bytes = [UInt8](edid.prefix(128))
        guard Array(bytes[0..<8]) == header else { return nil }

        var result = Result(modes: [], physicalSizeMillimeters: nil, name: nil)

        // Bytes 21/22: max image size in cm (0 = unknown/aspect-ratio-coded).
        if bytes[21] > 0, bytes[22] > 0 {
            result.physicalSizeMillimeters = CGSize(width: Int(bytes[21]) * 10, height: Int(bytes[22]) * 10)
        }

        // Four 18-byte descriptors at 54/72/90/108. Pixel clock != 0 → DTD;
        // descriptor tag 0xFC → monitor name.
        var isFirstDTD = true
        for offset in stride(from: 54, through: 108, by: 18) {
            let clockRaw = UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
            if clockRaw != 0 {
                if let mode = parseDTD(bytes, at: offset, preferred: isFirstDTD) {
                    result.modes.append(mode)
                    isFirstDTD = false
                }
            } else if bytes[offset + 3] == 0xfc {
                let nameBytes = bytes[(offset + 5)..<(offset + 18)].prefix { $0 != 0x0a && $0 != 0 }
                if let name = String(bytes: nameBytes, encoding: .ascii)?
                    .trimmingCharacters(in: .whitespaces), !name.isEmpty {
                    result.name = name
                }
            }
        }

        return result.modes.isEmpty && result.physicalSizeMillimeters == nil && result.name == nil ? nil : result
    }

    private static func parseDTD(_ b: [UInt8], at o: Int, preferred: Bool) -> GUD.DisplayMode? {
        let clock10kHz = UInt32(b[o]) | UInt32(b[o + 1]) << 8

        let hactive = UInt16(b[o + 2]) | UInt16(b[o + 4] & 0xf0) << 4
        let hblank = UInt16(b[o + 3]) | UInt16(b[o + 4] & 0x0f) << 8
        let vactive = UInt16(b[o + 5]) | UInt16(b[o + 7] & 0xf0) << 4
        let vblank = UInt16(b[o + 6]) | UInt16(b[o + 7] & 0x0f) << 8

        let hsyncOffset = UInt16(b[o + 8]) | UInt16(b[o + 11] & 0xc0) << 2
        let hsyncWidth = UInt16(b[o + 9]) | UInt16(b[o + 11] & 0x30) << 4
        let vsyncOffset = UInt16(b[o + 10] >> 4) | UInt16(b[o + 11] & 0x0c) << 2
        let vsyncWidth = UInt16(b[o + 10] & 0x0f) | UInt16(b[o + 11] & 0x03) << 4

        guard hactive > 0, vactive > 0 else { return nil }

        var flags: UInt32 = 0
        let features = b[o + 17]
        if features & 0x80 != 0 {
            flags |= 1 << 4 // INTERLACE
        }
        // Sync polarities only apply to digital separate sync (bits 4-3 == 11).
        if features & 0x18 == 0x18 {
            flags |= features & 0x02 != 0 ? 1 << 0 : 1 << 1 // PHSYNC : NHSYNC
            flags |= features & 0x04 != 0 ? 1 << 2 : 1 << 3 // PVSYNC : NVSYNC
        }
        if preferred {
            flags |= GUD.DisplayMode.flagPreferred
        }

        return GUD.DisplayMode(
            clock: clock10kHz * 10,
            hdisplay: hactive,
            hsyncStart: hactive + hsyncOffset,
            hsyncEnd: hactive + hsyncOffset + hsyncWidth,
            htotal: hactive + hblank,
            vdisplay: vactive,
            vsyncStart: vactive + vsyncOffset,
            vsyncEnd: vactive + vsyncOffset + vsyncWidth,
            vtotal: vactive + vblank,
            flags: flags
        )
    }
}
