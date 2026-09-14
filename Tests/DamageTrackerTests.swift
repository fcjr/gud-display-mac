import CoreVideo
import XCTest
@testable import GUDDisplay

final class DamageTrackerTests: XCTestCase {
    private func makeBuffer(width: Int, height: Int) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer), kCVReturnSuccess)
        return buffer!
    }

    private func fill(_ buffer: CVPixelBuffer, value: UInt8) {
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddress(buffer), Int32(value),
               CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer))
        CVPixelBufferUnlockBaseAddress(buffer, [])
    }

    private func poke(_ buffer: CVPixelBuffer, x: Int, y: Int, value: UInt8) {
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!
        let row = CVPixelBufferGetBytesPerRow(buffer)
        (base + y * row + x * 4).storeBytes(of: value, as: UInt8.self)
        CVPixelBufferUnlockBaseAddress(buffer, [])
    }

    private func update(_ tracker: inout DamageTracker, _ buffer: CVPixelBuffer, forceFull: Bool = false) -> [Bool]? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        return tracker.update(buffer, forceFull: forceFull)
    }

    func testFirstFrameIsFullAndUnchangedFrameIsNothing() {
        var tracker = DamageTracker(width: 64, height: 48)
        let buffer = makeBuffer(width: 64, height: 48)
        fill(buffer, value: 7)
        let first = update(&tracker, buffer)
        XCTAssertEqual(first?.filter { $0 }.count, 4 * 3)
        XCTAssertEqual(tracker.rects(for: first!), [DamageRect(x: 0, y: 0, width: 64, height: 48)])
        XCTAssertNil(update(&tracker, buffer))
    }

    func testSinglePixelChangeIsOneTile() {
        var tracker = DamageTracker(width: 64, height: 48)
        let buffer = makeBuffer(width: 64, height: 48)
        fill(buffer, value: 0)
        _ = update(&tracker, buffer)
        poke(buffer, x: 40, y: 20, value: 1)
        let tiles = update(&tracker, buffer)
        XCTAssertEqual(tiles?.filter { $0 }.count, 1)
        XCTAssertEqual(tracker.rects(for: tiles!), [DamageRect(x: 32, y: 16, width: 16, height: 16)])
    }

    func testSeparatedChangesBecomeSeparateRects() {
        var tracker = DamageTracker(width: 64, height: 64)
        let buffer = makeBuffer(width: 64, height: 64)
        fill(buffer, value: 0)
        _ = update(&tracker, buffer)
        poke(buffer, x: 2, y: 2, value: 1)
        poke(buffer, x: 60, y: 60, value: 1)
        let rects = tracker.rects(for: update(&tracker, buffer)!)
        XCTAssertEqual(rects, [DamageRect(x: 0, y: 0, width: 16, height: 16),
                               DamageRect(x: 48, y: 48, width: 16, height: 16)])
    }

    func testCarriedTilesRideAlongWithNextFrame() {
        var tracker = DamageTracker(width: 64, height: 48)
        let buffer = makeBuffer(width: 64, height: 48)
        fill(buffer, value: 0)
        _ = update(&tracker, buffer)
        var carried = [Bool](repeating: false, count: 4 * 3)
        carried[5] = true
        tracker.carry(tiles: carried)
        poke(buffer, x: 0, y: 40, value: 1)
        let tiles = update(&tracker, buffer)!
        XCTAssertTrue(tiles[5])
        XCTAssertTrue(tiles[8])
        XCTAssertEqual(tiles.filter { $0 }.count, 2)
        // Carried tiles are consumed.
        XCTAssertNil(update(&tracker, buffer))
    }

    func testRectsClampToFrame() {
        let tracker = DamageTracker(width: 50, height: 30)
        var tiles = [Bool](repeating: false, count: tracker.tilesX * tracker.tilesY)
        tiles[tiles.count - 1] = true
        XCTAssertEqual(tracker.rects(for: tiles), [DamageRect(x: 48, y: 16, width: 2, height: 14)])
    }
}
