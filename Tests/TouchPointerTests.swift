import CoreGraphics
import XCTest
@testable import GUDDisplay

final class TouchPointerTests: XCTestCase {
    private let bounds = CGRect(x: 1000, y: 100, width: 800, height: 934)

    private func contact(_ tip: Bool, _ x: Int, _ y: Int) -> TouchContact {
        TouchContact(tip: tip, x: x, y: y, xRange: 0...239, yRange: 0...279)
    }

    func testMapsPanelCornersAndCentreIntoDisplayBounds() {
        let topLeft = TouchPointer.position(of: contact(true, 0, 0), in: bounds)
        XCTAssertEqual(topLeft.x, 1000 + 0.5 / 240 * 800, accuracy: 0.001)
        XCTAssertEqual(topLeft.y, 100 + 0.5 / 280 * 934, accuracy: 0.001)

        let bottomRight = TouchPointer.position(of: contact(true, 239, 279), in: bounds)
        XCTAssertEqual(bottomRight.x, 1000 + 239.5 / 240 * 800, accuracy: 0.001)
        XCTAssertEqual(bottomRight.y, 100 + 279.5 / 280 * 934, accuracy: 0.001)
        XCTAssertLessThan(bottomRight.x, bounds.maxX)
        XCTAssertLessThan(bottomRight.y, bounds.maxY)

        let centre = TouchPointer.position(of: contact(true, 120, 140), in: bounds)
        XCTAssertEqual(centre.x, 1000 + 120.5 / 240 * 800, accuracy: 0.001)
        XCTAssertEqual(centre.y, 100 + 140.5 / 280 * 934, accuracy: 0.001)
    }

    func testOutOfRangeValuesClampInsideBounds() {
        let wild = TouchContact(tip: true, x: 5000, y: -50, xRange: 0...239, yRange: 0...279)
        let point = TouchPointer.position(of: wild, in: bounds)
        XCTAssertEqual(point.x, bounds.maxX - 1)
        XCTAssertEqual(point.y, bounds.minY)
    }

    func testDownDragUpSequence() {
        var pointer = TouchPointer()
        let t0 = Date()
        let down = pointer.update(contact(true, 10, 10), bounds: bounds, at: t0)
        let p0 = TouchPointer.position(of: contact(true, 10, 10), in: bounds)
        XCTAssertEqual(down, [.move(p0), .down(p0, clickCount: 1)])

        XCTAssertEqual(pointer.update(contact(true, 10, 10), bounds: bounds, at: t0), [])

        let p1 = TouchPointer.position(of: contact(true, 20, 30), in: bounds)
        XCTAssertEqual(pointer.update(contact(true, 20, 30), bounds: bounds, at: t0), [.drag(p1)])

        // Lift-off reports the finger's last position; the up lands there.
        XCTAssertEqual(pointer.update(contact(false, 20, 30), bounds: bounds, at: t0), [.up(p1, clickCount: 1)])
        XCTAssertEqual(pointer.update(contact(false, 20, 30), bounds: bounds, at: t0), [])
    }

    func testStrayLiftOffWithoutDownIsIgnored() {
        var pointer = TouchPointer()
        XCTAssertEqual(pointer.update(contact(false, 5, 5), bounds: bounds), [])
    }

    func testDoubleTapCountsTwoClicksWhenCloseInTimeAndSpace() {
        var pointer = TouchPointer(doubleClickInterval: 0.5)
        let t0 = Date()
        _ = pointer.update(contact(true, 100, 100), bounds: bounds, at: t0)
        _ = pointer.update(contact(false, 100, 100), bounds: bounds, at: t0.addingTimeInterval(0.05))
        let second = pointer.update(contact(true, 100, 100), bounds: bounds, at: t0.addingTimeInterval(0.2))
        let p = TouchPointer.position(of: contact(true, 100, 100), in: bounds)
        XCTAssertEqual(second, [.move(p), .down(p, clickCount: 2)])
        XCTAssertEqual(pointer.update(contact(false, 100, 100), bounds: bounds, at: t0.addingTimeInterval(0.25)),
                       [.up(p, clickCount: 2)])
    }

    func testSlowOrDistantSecondTapIsASingleClick() {
        var pointer = TouchPointer(doubleClickInterval: 0.5)
        let t0 = Date()
        _ = pointer.update(contact(true, 100, 100), bounds: bounds, at: t0)
        _ = pointer.update(contact(false, 100, 100), bounds: bounds, at: t0)
        let late = pointer.update(contact(true, 100, 100), bounds: bounds, at: t0.addingTimeInterval(0.8))
        XCTAssertEqual(late.last, .down(TouchPointer.position(of: contact(true, 100, 100), in: bounds), clickCount: 1))
        _ = pointer.update(contact(false, 100, 100), bounds: bounds, at: t0.addingTimeInterval(0.85))

        let far = pointer.update(contact(true, 200, 200), bounds: bounds, at: t0.addingTimeInterval(0.9))
        XCTAssertEqual(far.last, .down(TouchPointer.position(of: contact(true, 200, 200), in: bounds), clickCount: 1))
    }

    func testReleaseLiftsAHeldFingerOnce() {
        var pointer = TouchPointer()
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertEqual(pointer.release(), [])
        _ = pointer.update(TouchContact(tip: true, x: 5, y: 5, xRange: 0...9, yRange: 0...9), bounds: bounds)
        let lifted = pointer.release()
        XCTAssertEqual(lifted.count, 1)
        if case .up = lifted[0] {} else { XCTFail("expected up, got \(lifted)") }
        XCTAssertEqual(pointer.release(), [])
        XCTAssertEqual(pointer.update(TouchContact(tip: false, x: 5, y: 5, xRange: 0...9, yRange: 0...9), bounds: bounds), [])
    }

    func testRotationTurnsTheGlassUnderTheDesktop() {
        // A 10x20 portrait panel under a 200x100 landscape desktop.
        let bounds = CGRect(x: 0, y: 0, width: 200, height: 100)
        func check(_ x: Int, _ y: Int, _ rotation: GUD.Rotation, _ expected: CGPoint, line: UInt = #line) {
            let point = TouchPointer.position(of: TouchContact(tip: true, x: x, y: y, xRange: 0...9, yRange: 0...19),
                                              in: bounds, rotation: rotation)
            XCTAssertEqual(point.x, expected.x, accuracy: 0.001, line: line)
            XCTAssertEqual(point.y, expected.y, accuracy: 0.001, line: line)
        }
        // Rotate 90 (counter-clockwise): the desktop's right edge is at the
        // top of the glass, so the glass's bottom-left is the desktop's top-left.
        check(0, 19, .rotate90, CGPoint(x: 5, y: 5))
        check(0, 0, .rotate90, CGPoint(x: 195, y: 5))
        check(9, 19, .rotate90, CGPoint(x: 5, y: 95))
        // Rotate 270: the desktop's left edge is at the top of the glass.
        check(0, 0, .rotate270, CGPoint(x: 5, y: 95))
        check(9, 0, .rotate270, CGPoint(x: 5, y: 5))
        check(0, 19, .rotate270, CGPoint(x: 195, y: 95))
        // Rotate 180 on a portrait desktop.
        let portrait = CGRect(x: 0, y: 0, width: 100, height: 200)
        let flipped = TouchPointer.position(of: TouchContact(tip: true, x: 0, y: 0, xRange: 0...9, yRange: 0...19),
                                            in: portrait, rotation: .rotate180)
        XCTAssertEqual(flipped.x, 95, accuracy: 0.001)
        XCTAssertEqual(flipped.y, 195, accuracy: 0.001)
    }
}
