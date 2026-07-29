import CoreVideo
import XCTest
@testable import gudmac

final class PixelConverterTests: XCTestCase {
    // 4x2 BGRA buffer: red, green, blue, white / black, white, black, white
    private func makeBuffer() -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 4, 2, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
        let buffer = pixelBuffer!
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let rows: [[[UInt8]]] = [
            [[0, 0, 255, 255], [0, 255, 0, 255], [255, 0, 0, 255], [255, 255, 255, 255]],
            [[0, 0, 0, 255], [255, 255, 255, 255], [0, 0, 0, 255], [255, 255, 255, 255]],
        ]
        for (y, row) in rows.enumerated() {
            for (x, pixel) in row.enumerated() {
                let p = base + y * bytesPerRow + x * 4
                p.copyMemory(from: pixel, byteCount: 4)
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    func testRGB565Packing() {
        let out = NSMutableData()
        XCTAssertTrue(PixelConverter.pack(makeBuffer(), rect: DamageRect(x: 0, y: 0, width: 4, height: 1), as: .rgb565, into: out))
        XCTAssertEqual(out.length, 8)
        let words = Data(referencing: out)
        XCTAssertEqual(words.leUInt16(at: 0), 0xf800) // red
        XCTAssertEqual(words.leUInt16(at: 2), 0x07e0) // green
        XCTAssertEqual(words.leUInt16(at: 4), 0x001f) // blue
        XCTAssertEqual(words.leUInt16(at: 6), 0xffff) // white
    }

    func testR1PackingMSBFirst() {
        let out = NSMutableData()
        // Second row: black, white, black, white -> bits 0101 followed by zeros.
        XCTAssertTrue(PixelConverter.pack(makeBuffer(), rect: DamageRect(x: 0, y: 1, width: 4, height: 1), as: .r1, into: out))
        XCTAssertEqual(out.length, 1)
        XCTAssertEqual(Data(referencing: out)[0], 0b0101_0000)
    }

    func testXRGB1111NibbleOrder() {
        let out = NSMutableData()
        // First row: red, green -> high nibble 0b100, low nibble 0b010.
        XCTAssertTrue(PixelConverter.pack(makeBuffer(), rect: DamageRect(x: 0, y: 0, width: 2, height: 1), as: .xrgb1111, into: out))
        XCTAssertEqual(out.length, 1)
        XCTAssertEqual(Data(referencing: out)[0], 0b0100_0010)
    }

    func testTightPackingDropsStride() {
        let out = NSMutableData()
        // 1x2 column: rows must be pitch-adjacent with no stride between them.
        XCTAssertTrue(PixelConverter.pack(makeBuffer(), rect: DamageRect(x: 3, y: 0, width: 1, height: 2), as: .xrgb8888, into: out))
        XCTAssertEqual(out.length, 8)
        let bytes = Data(referencing: out)
        XCTAssertEqual(Array(bytes.prefix(3)), [255, 255, 255])
        XCTAssertEqual(Array(bytes.dropFirst(4).prefix(3)), [255, 255, 255])
    }

    func testDamageAlignment() {
        let rect = DamageRect(x: 3, y: 0, width: 6, height: 1)

        // R1 packs 8 pixels per byte, so it needs the widest grouping.
        let alignedR1 = rect.aligned(for: .r1, fbWidth: 64)
        XCTAssertEqual(alignedR1.x, 0)
        XCTAssertEqual(alignedR1.width, 16)

        // Every other format aligns to 4 pixels so row offsets and transfer
        // lengths stay word-aligned for the device.
        for format in [GUD.PixelFormat.xrgb1111, .rgb565, .rgb888, .xrgb8888] {
            let aligned = rect.aligned(for: format, fbWidth: 64)
            XCTAssertEqual(aligned.x, 0, "\(format) x")
            XCTAssertEqual(aligned.width, 12, "\(format) width")
            XCTAssertEqual(aligned.x % 4, 0)
            XCTAssertEqual(aligned.width % 4, 0)
        }
    }

    func testAlignmentClampsToFramebuffer() {
        let rect = DamageRect(x: 60, y: 0, width: 3, height: 1)
        let aligned = rect.aligned(for: .rgb888, fbWidth: 63)
        XCTAssertEqual(aligned.x, 60)
        XCTAssertLessThanOrEqual(aligned.x + aligned.width, 63)
    }
}
