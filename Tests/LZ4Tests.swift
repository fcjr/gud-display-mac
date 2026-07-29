import XCTest
@testable import GUDDisplay

final class LZ4Tests: XCTestCase {
    func testRoundTrip() {
        // Compressible input: repeated pattern like a desktop framebuffer.
        var input = Data()
        for i in 0..<4096 {
            input.append(UInt8(i % 16))
        }

        let compressed = NSMutableData()
        XCTAssertTrue(input.withUnsafeBytes { raw in
            LZ4Compressor.compress(raw.baseAddress!, length: input.count, into: compressed)
        })
        XCTAssertLessThan(compressed.length, input.count)

        // Decompress with the raw block API and compare (validates that we
        // emit blocks, not LZ4 frames).
        var output = Data(count: input.count)
        let written = output.withUnsafeMutableBytes { outRaw in
            LZ4_decompress_safe(
                compressed.bytes.assumingMemoryBound(to: CChar.self),
                outRaw.baseAddress!.assumingMemoryBound(to: CChar.self),
                Int32(compressed.length),
                Int32(input.count)
            )
        }
        XCTAssertEqual(Int(written), input.count)
        XCTAssertEqual(output, input)
    }

    func testIncompressibleFallsBack() {
        var input = Data()
        var state: UInt64 = 0x1234_5678_9abc_def0
        for _ in 0..<4096 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            input.append(UInt8(truncatingIfNeeded: state >> 33))
        }
        let compressed = NSMutableData()
        let didCompress = input.withUnsafeBytes { raw in
            LZ4Compressor.compress(raw.baseAddress!, length: input.count, into: compressed)
        }
        XCTAssertFalse(didCompress, "Random data should not shrink; caller must send uncompressed")
    }
}
