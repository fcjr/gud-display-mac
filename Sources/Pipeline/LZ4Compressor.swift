import Foundation

// Raw LZ4 block compression as the GUD wire format requires: no frame header,
// the SET_BUFFER request carries the uncompressed length out-of-band.
// (Apple's Compression framework only offers the framed variant, hence the
// vendored reference implementation.)
enum LZ4Compressor {
    // Compresses `length` bytes of `source` into `destination` (reused across
    // calls). Returns false when compression would not shrink the payload —
    // the caller must then send uncompressed, which is always valid.
    static func compress(_ source: UnsafeRawPointer, length: Int, into destination: NSMutableData) -> Bool {
        guard length > 0, length <= Int(Int32.max) else { return false }
        destination.length = length
        let written = LZ4_compress_default(
            source.assumingMemoryBound(to: CChar.self),
            destination.mutableBytes.assumingMemoryBound(to: CChar.self),
            Int32(length),
            Int32(length)
        )
        guard written > 0, Int(written) < length else { return false }
        destination.length = Int(written)
        return true
    }
}
