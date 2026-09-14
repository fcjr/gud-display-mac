import AppKit

final class DisplayPreviewView: NSView {
    var image: CGImage? { didSet { needsDisplay = true } }
    var displayBounds = CGRect.zero
    var movePointer: ((CGPoint) -> Void)?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    static func displayPoint(for point: CGPoint, imageRect: CGRect, displayBounds: CGRect) -> CGPoint? {
        guard imageRect.width > 0, imageRect.height > 0, imageRect.contains(point),
              displayBounds.width > 0, displayBounds.height > 0 else { return nil }
        return CGPoint(x: displayBounds.minX + (point.x - imageRect.minX) / imageRect.width * displayBounds.width,
                       y: displayBounds.minY + (point.y - imageRect.minY) / imageRect.height * displayBounds.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        guard let image else { return }
        NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            .draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
    }

    // Wait for release so the physical mouse-up does not land on a different
    // desktop from the corresponding mouse-down. The next click is native.
    override func mouseUp(with event: NSEvent) {
        guard image != nil, let point = Self.displayPoint(for: convert(event.locationInWindow, from: nil),
                                                         imageRect: bounds, displayBounds: displayBounds) else { return }
        movePointer?(point)
    }
}
