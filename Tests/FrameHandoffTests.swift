import XCTest
@testable import GUDDisplay

final class FrameHandoffTests: XCTestCase {
    func testReplacingQueuedFrameCannotRaceUSBReadingItsPayload() {
        var handoff = FrameHandoff()
        let first = handoff.beginCapture()
        XCTAssertTrue(handoff.publish(first.slot))
        XCTAssertEqual(handoff.beginFlush(), first.slot)

        let queued = handoff.beginCapture()
        XCTAssertNotEqual(queued.slot, first.slot)
        XCTAssertFalse(handoff.publish(queued.slot))

        // Capture starts overwriting the pending frame while USB finishes
        // the older one. USB must see no frame until publication finishes.
        let replacement = handoff.beginCapture()
        XCTAssertEqual(replacement.replaced, queued.slot)
        handoff.finishFlush()
        XCTAssertNil(handoff.beginFlush())
        XCTAssertTrue(handoff.publish(replacement.slot))
        XCTAssertEqual(handoff.beginFlush(), replacement.slot)
    }

    func testReplacementBeforeFlushWorkerStartsIsAlsoExclusive() {
        var handoff = FrameHandoff()
        let first = handoff.beginCapture()
        XCTAssertTrue(handoff.publish(first.slot))
        let replacement = handoff.beginCapture()
        XCTAssertEqual(replacement.replaced, first.slot)
        XCTAssertNil(handoff.beginFlush())
        XCTAssertTrue(handoff.publish(replacement.slot))
        XCTAssertEqual(handoff.beginFlush(), replacement.slot)
    }

    func testRewritingPendingFrameDoesNotChangeInFlightBytes() {
        var handoff = FrameHandoff()
        let buffers = [NSMutableData(data: Data([1, 2])), NSMutableData(data: Data([3, 4]))]
        let first = handoff.beginCapture()
        _ = handoff.publish(first.slot)
        let usbSlot = handoff.beginFlush()!
        let pending = handoff.beginCapture()
        _ = handoff.publish(pending.slot)
        let replacement = handoff.beginCapture()
        buffers[replacement.slot].length = 0
        buffers[replacement.slot].append(Data([9, 8, 7]))
        XCTAssertEqual(buffers[usbSlot] as Data, Data([1, 2]))
        handoff.finishFlush()
        XCTAssertNil(handoff.beginFlush())
        _ = handoff.publish(replacement.slot)
        XCTAssertEqual(buffers[handoff.beginFlush()!] as Data, Data([9, 8, 7]))
    }

    func testFailureDuringCaptureForcesFollowingFrameToRedraw() {
        var handoff = FrameHandoff()
        let preparing = handoff.beginCapture()
        XCTAssertFalse(preparing.redraw)
        handoff.requestRedraw() // USB failed while capture was packing.
        _ = handoff.publish(preparing.slot)
        let next = handoff.beginCapture()
        XCTAssertTrue(next.redraw)
        XCTAssertEqual(next.replaced, preparing.slot)
        _ = handoff.publish(next.slot)
        XCTAssertNotNil(handoff.beginFlush())
        handoff.finishFlush()
        XCTAssertFalse(handoff.beginCapture().redraw)
    }
}
