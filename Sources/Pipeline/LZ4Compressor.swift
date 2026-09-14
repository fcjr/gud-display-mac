import Foundation

// Raw LZ4 block compression as the GUD wire format requires: no frame header,
// the SET_BUFFER request carries the uncompressed length out-of-band.
// (Apple's Compression framework only offers the framed variant, hence the
// vendored reference implementation.)
enum LZ4Compressor {
    // Compression effort. 0 and 1 are the fast LZ4 compressor; 2 and up are
    // LZ4 HC levels (same block format, the device can't tell). HC squeezes
    // 10 to 25% more out of desktop content at a CPU cost the Mac doesn't
    // notice; the bytes are what a full-speed USB link is short of.
    //   defaults write com.leftshift.gud LZ4Level N
    static let level: Int = {
        let value = UserDefaults.standard.object(forKey: "LZ4Level") as? Int ?? 6
        return min(max(value, 0), Int(LZ4HC_CLEVEL_MAX))
    }()

    // Compresses `length` bytes of `source` into `destination` (reused across
    // calls). Returns false when compression would not shrink the payload —
    // the caller must then send uncompressed, which is always valid.
    static func compress(_ source: UnsafeRawPointer, length: Int, into destination: NSMutableData,
                         level: Int = LZ4Compressor.level) -> Bool
    {
        guard length > 0, length <= Int(Int32.max) else { return false }
        destination.length = length
        let src = source.assumingMemoryBound(to: CChar.self)
        let dst = destination.mutableBytes.assumingMemoryBound(to: CChar.self)
        let written = level >= Int(LZ4HC_CLEVEL_MIN)
            ? LZ4_compress_HC(src, dst, Int32(length), Int32(length), Int32(level))
            : LZ4_compress_default(src, dst, Int32(length), Int32(length))
        guard written > 0, Int(written) < length else { return false }
        destination.length = Int(written)
        return true
    }
}
