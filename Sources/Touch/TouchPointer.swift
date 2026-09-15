import CoreGraphics
import Foundation

// One finger as reported by a HID touch screen, with the logical ranges the
// device declared for its axes.
struct TouchContact: Equatable {
    var tip: Bool
    var x: Int
    var y: Int
    var xRange: ClosedRange<Int>
    var yRange: ClosedRange<Int>
}

// Turns a stream of touch contacts into the mouse actions that make a
// single-touch panel behave like a click-and-drag surface over one display.
// Pure: the controller owns the HID side and posts what this returns.
struct TouchPointer {
    enum Action: Equatable {
        case move(CGPoint)
        case down(CGPoint, clickCount: Int)
        case drag(CGPoint)
        case up(CGPoint, clickCount: Int)
    }

    var doubleClickInterval: TimeInterval = 0.5
    var doubleClickDistance: CGFloat = 5

    private var down = false
    private var lastPosition = CGPoint.zero
    private var lastDownAt = Date.distantPast
    private var lastDownPosition: CGPoint?
    private var clickCount = 1

    init(doubleClickInterval: TimeInterval = 0.5) {
        self.doubleClickInterval = doubleClickInterval
    }

    // Maps a contact into `bounds` (global top-left coordinates), centring
    // each logical step on its pixel and never leaving the display. The
    // contact is in the panel's own frame; `rotation` is how the desktop
    // sits on the panel (the GUD rotation, counter-clockwise), so a finger
    // on the glass lands under the same spot of the turned desktop.
    static func position(of contact: TouchContact, in bounds: CGRect, rotation: GUD.Rotation = .rotate0) -> CGPoint {
        func unit(_ value: Int, _ range: ClosedRange<Int>) -> CGFloat {
            let span = CGFloat(range.upperBound - range.lowerBound + 1)
            return (CGFloat(value - range.lowerBound) + 0.5) / span
        }
        let u = unit(contact.x, contact.xRange)
        let v = unit(contact.y, contact.yRange)
        let (dx, dy): (CGFloat, CGFloat) = switch rotation {
        case .rotate0: (u, v)
        case .rotate90: (1 - v, u)
        case .rotate180: (1 - u, 1 - v)
        case .rotate270: (v, 1 - u)
        }
        func place(_ unit: CGFloat, _ origin: CGFloat, _ size: CGFloat) -> CGFloat {
            let last = max(origin, origin + size - 1)
            return min(last, max(origin, origin + unit * size))
        }
        return CGPoint(x: place(dx, bounds.minX, bounds.width), y: place(dy, bounds.minY, bounds.height))
    }

    // Lifts the finger if it is down; for when touch is switched off mid-drag.
    mutating func release() -> [Action] {
        guard down else { return [] }
        down = false
        return [.up(lastPosition, clickCount: clickCount)]
    }

    mutating func update(_ contact: TouchContact, bounds: CGRect, rotation: GUD.Rotation = .rotate0,
                         at time: Date = Date()) -> [Action] {
        let point = Self.position(of: contact, in: bounds, rotation: rotation)
        switch (down, contact.tip) {
        case (false, true):
            down = true
            lastPosition = point
            if let previous = lastDownPosition,
               time.timeIntervalSince(lastDownAt) <= doubleClickInterval,
               hypot(previous.x - point.x, previous.y - point.y) <= doubleClickDistance {
                clickCount += 1
            } else {
                clickCount = 1
            }
            lastDownAt = time
            lastDownPosition = point
            return [.move(point), .down(point, clickCount: clickCount)]
        case (true, true):
            guard point != lastPosition else { return [] }
            lastPosition = point
            return [.drag(point)]
        case (true, false):
            down = false
            return [.up(lastPosition, clickCount: clickCount)]
        case (false, false):
            return []
        }
    }
}
