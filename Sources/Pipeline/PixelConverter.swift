import Foundation
import CoreVideo

struct DamageRect: Equatable {
    var x: Int
    var y: Int
    var width: Int
    var height: Int

    var maxY: Int { y + height }

    func clamped(toWidth fbWidth: Int, height fbHeight: Int) -> DamageRect {
        let x0 = max(0, min(x, fbWidth))
        let y0 = max(0, min(y, fbHeight))
        let x1 = max(x0, min(x + width, fbWidth))
        let y1 = max(y0, min(y + height, fbHeight))
        return DamageRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    // Sub-byte formats require the rect to start and end on byte boundaries
    // (the Linux host aligns x down the same way). Multi-byte formats get
    // 4-pixel alignment so the device's row offsets (x * bytesPerPixel) and
    // transfer lengths stay word-aligned — MCU firmware doing 32-bit copies
    // can fault on unaligned addresses, which wedges the device.
    func aligned(for format: GUD.PixelFormat, fbWidth: Int) -> DamageRect {
        let group = max(format.pixelsPerByteGroup, 4)
        let x0 = (x / group) * group
        let x1 = min(fbWidth, ((x + width + group - 1) / group) * group)
        return DamageRect(x: x0, y: y, width: x1 - x0, height: height)
    }

    static func union(_ a: DamageRect, _ b: DamageRect) -> DamageRect {
        let x0 = min(a.x, b.x)
        let y0 = min(a.y, b.y)
        let x1 = max(a.x + a.width, b.x + b.width)
        let y1 = max(a.maxY, b.maxY)
        return DamageRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}

extension GUD.PixelFormat {
    // Number of pixels that must share a byte (damage alignment requirement).
    var pixelsPerByteGroup: Int {
        switch self {
        case .r1: return 8
        case .xrgb1111: return 2
        default: return 1
        }
    }
}

// Extracts a damage rect from a BGRA CVPixelBuffer and repacks it tightly
// (no stride) in the device's pixel format, as the GUD wire format requires.
// Writes into a caller-owned reusable buffer to avoid per-flush allocation.
// TODO: use vImage/SIMD for the conversion loops; scalar code is scaffold-grade.
enum PixelConverter {
    static func pack(_ pixelBuffer: CVPixelBuffer, rect: DamageRect, as format: GUD.PixelFormat, into out: NSMutableData) -> Bool {
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return false }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        let pitch = format.minPitch(width: rect.width)
        out.length = pitch * rect.height
        let dst = out.mutableBytes
        for row in 0..<rect.height {
            let srcRow = base + (rect.y + row) * bytesPerRow + rect.x * 4
            let dstRow = dst + row * pitch
            convertRow(from: srcRow, to: dstRow, pixels: rect.width, format: format)
        }
        return true
    }

    // Diagnostic frame that makes transfer bugs self-evident on the panel:
    //   corner colors  -> orientation / flips / channel order
    //   vertical bars  -> row pitch (wrong stride shears them into diagonals)
    //   diagonal line  -> combined width/pitch errors
    static func testPattern(width: Int, height: Int, format: GUD.PixelFormat, into out: NSMutableData) {
        let pitch = format.minPitch(width: width)
        out.length = pitch * height
        let dst = out.mutableBytes
        var row = [UInt8](repeating: 255, count: width * 4)

        for y in 0..<height {
            for x in 0..<width {
                var r: UInt8 = 0, g: UInt8 = 0, b: UInt8 = 0
                switch (y < height / 2, x < width / 2) {
                case (true, true): r = 255                       // top-left    red
                case (true, false): g = 255                      // top-right   green
                case (false, true): b = 255                      // bottom-left blue
                case (false, false): (r, g, b) = (255, 255, 255) // bottom-right white
                }
                if x % 32 == 0 || y % 32 == 0 { (r, g, b) = (0, 0, 0) }
                if x == y { (r, g, b) = (255, 255, 0) }
                row[x * 4 + 0] = b
                row[x * 4 + 1] = g
                row[x * 4 + 2] = r
                row[x * 4 + 3] = 255
            }
            row.withUnsafeBytes { src in
                convertRow(from: src.baseAddress!, to: dst + y * pitch, pixels: width, format: format)
            }
        }
    }

    private static func convertRow(from src: UnsafeRawPointer, to dst: UnsafeMutableRawPointer, pixels: Int, format: GUD.PixelFormat) {
        let s = src.assumingMemoryBound(to: UInt8.self)
        switch format {
        case .xrgb8888, .argb8888:
            // BGRA in memory is byte-identical to little-endian [AX]RGB8888.
            dst.copyMemory(from: src, byteCount: pixels * 4)
        case .rgb888:
            let d = dst.assumingMemoryBound(to: UInt8.self)
            for i in 0..<pixels {
                d[i * 3 + 0] = s[i * 4 + 0]
                d[i * 3 + 1] = s[i * 4 + 1]
                d[i * 3 + 2] = s[i * 4 + 2]
            }
        case .rgb565:
            let d = dst.assumingMemoryBound(to: UInt16.self)
            for i in 0..<pixels {
                let b = UInt16(s[i * 4 + 0])
                let g = UInt16(s[i * 4 + 1])
                let r = UInt16(s[i * 4 + 2])
                d[i] = (r >> 3) << 11 | (g >> 2) << 5 | (b >> 3)
            }
        case .rgb332:
            let d = dst.assumingMemoryBound(to: UInt8.self)
            for i in 0..<pixels {
                let b = s[i * 4 + 0]
                let g = s[i * 4 + 1]
                let r = s[i * 4 + 2]
                d[i] = (r & 0xe0) | ((g & 0xe0) >> 3) | (b >> 6)
            }
        case .xrgb1111:
            // 2 px/byte; even pixel in the high nibble, bits r=2 g=1 b=0
            // (matches the Linux host's gud_xrgb8888_to_color).
            let d = dst.assumingMemoryBound(to: UInt8.self)
            let byteCount = (pixels + 1) / 2
            for byteIndex in 0..<byteCount {
                var packed: UInt8 = 0
                for half in 0..<2 {
                    let i = byteIndex * 2 + half
                    guard i < pixels else { break }
                    var color: UInt8 = 0
                    if s[i * 4 + 2] >= 128 { color |= 0b100 }
                    if s[i * 4 + 1] >= 128 { color |= 0b010 }
                    if s[i * 4 + 0] >= 128 { color |= 0b001 }
                    packed |= half == 0 ? color << 4 : color
                }
                d[byteIndex] = packed
            }
        case .r8:
            let d = dst.assumingMemoryBound(to: UInt8.self)
            for i in 0..<pixels {
                d[i] = luma(r: s[i * 4 + 2], g: s[i * 4 + 1], b: s[i * 4 + 0])
            }
        case .r1:
            let d = dst.assumingMemoryBound(to: UInt8.self)
            let byteCount = (pixels + 7) / 8
            for byteIndex in 0..<byteCount {
                var packed: UInt8 = 0
                for bit in 0..<8 {
                    let i = byteIndex * 8 + bit
                    guard i < pixels else { break }
                    let r = s[i * 4 + 2]
                    let g = s[i * 4 + 1]
                    let b = s[i * 4 + 0]
                    if luma(r: r, g: g, b: b) >= 128 {
                        let mask: UInt8 = 0x80 >> UInt8(bit) // MSB is the leftmost pixel
                        packed |= mask
                    }
                }
                d[byteIndex] = packed
            }
        }
    }

    private static func luma(r: UInt8, g: UInt8, b: UInt8) -> UInt8 {
        let weighted: Int = Int(r) * 299 + Int(g) * 587 + Int(b) * 114
        return UInt8(weighted / 1000)
    }
}
