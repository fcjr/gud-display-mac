// Slot ownership shared by the serial capture and USB flush queues. The caller
// holds its state lock for each operation; pixel work happens outside that lock.
struct FrameHandoff {
    private var pending: Int?
    private var reading: Int?
    private var flushing = false
    private var redraw = false

    mutating func beginCapture() -> (slot: Int, replaced: Int?, redraw: Bool) {
        let slot = reading == 0 ? 1 : 0
        let replaced = pending
        // Withdraw a queued frame BEFORE its mutable payloads are rewritten.
        // The flush queue must never see a slot while capture owns it.
        pending = nil
        let forceRedraw = redraw
        redraw = false
        return (slot, replaced, forceRedraw)
    }

    mutating func publish(_ slot: Int) -> Bool {
        precondition(slot != reading)
        pending = slot
        let start = !flushing
        flushing = true
        return start
    }

    mutating func beginFlush() -> Int? {
        precondition(reading == nil)
        guard let slot = pending else {
            flushing = false
            return nil
        }
        pending = nil
        reading = slot
        return slot
    }

    mutating func finishFlush() {
        reading = nil
    }

    mutating func requestRedraw() {
        redraw = true
    }
}
