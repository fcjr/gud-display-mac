import Foundation
import CoreGraphics

// Owns one CGVirtualDisplay (private CoreGraphics SPI) representing a GUD
// device. Releasing the display object tears the virtual display down.
final class VirtualDisplayController {
    struct Mode {
        var width: Int
        var height: Int
        var refreshRate: Double
    }

    private(set) var display: CGVirtualDisplay?
    private var desktopSize: (width: Int, height: Int)?

    var displayID: CGDirectDisplayID? {
        display?.displayID
    }

    // Must be called on the main queue. `desktop` is the mode selected after
    // creation; it must be one of `modes`. Note macOS picks the largest
    // non-low-resolution mode on its own and refuses to switch to a mode
    // narrower than 800 px while a larger one exists.
    func create(name: String,
                modes: [Mode],
                desktop: Mode,
                physicalSizeMillimeters: CGSize?,
                serialNumber: UInt32) -> CGDirectDisplayID?
    {
        guard !modes.isEmpty else { return nil }
        let maxWidth = modes.map(\.width).max()!
        let maxHeight = modes.map(\.height).max()!

        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.setDispatchQueue(DispatchQueue.main)
        descriptor.name = name
        descriptor.maxPixelsWide = UInt32(maxWidth)
        descriptor.maxPixelsHigh = UInt32(maxHeight)
        // Fall back to ~96 DPI if the device EDID gave no physical size.
        descriptor.sizeInMillimeters = physicalSizeMillimeters
            ?? CGSize(width: Double(maxWidth) * 25.4 / 96.0, height: Double(maxHeight) * 25.4 / 96.0)
        descriptor.vendorID = UInt32(GUD.vendorID)
        descriptor.productID = UInt32(GUD.productID)
        descriptor.serialNum = serialNumber
        descriptor.terminationHandler = { _, _ in }

        let display = CGVirtualDisplay(descriptor: descriptor)

        let settings = CGVirtualDisplaySettings()
        // Not HiDPI: macOS would synthesize a family of larger scaled modes
        // and pick the biggest, rendering the desktop huge and downsampling.
        settings.hiDPI = 0
        settings.modes = modes.map {
            CGVirtualDisplayMode(width: UInt($0.width), height: UInt($0.height), refreshRate: $0.refreshRate)
        }
        guard display.apply(settings) else {
            return nil
        }

        self.display = display
        self.desktopSize = (desktop.width, desktop.height)
        return display.displayID
    }

    // Call off the main thread (display registration needs main-runloop
    // turns) and BEFORE starting capture: ScreenCaptureKit binds the display's
    // geometry when the stream is created, so a mode or origin change
    // afterwards leaves the stream compositing the cursor at stale
    // coordinates.
    func finalizeGeometry() {
        guard let displayID = display?.displayID, let size = desktopSize else { return }
        selectMode(width: size.width, height: size.height, on: displayID)
        placeAdjacentToMainDisplay(displayID)
    }

    // macOS drops a new display at an arbitrary spot in the arrangement —
    // often above-left, where windows can't easily be dragged onto it. Put it
    // flush against the right edge of the main display instead.
    private func placeAdjacentToMainDisplay(_ displayID: CGDirectDisplayID) {
        let mainBounds = CGDisplayBounds(CGMainDisplayID())
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return }
        CGConfigureDisplayOrigin(config, displayID, Int32(mainBounds.maxX), 0)
        CGCompleteDisplayConfiguration(config, .forSession)
    }

    // Modes register asynchronously after applySettings, so retry until the
    // wanted mode appears and sticks.
    //
    // Deliberately uses CGDisplaySetDisplayMode rather than a
    // Begin/CompleteDisplayConfiguration transaction: the transactional form
    // lets macOS re-evaluate the whole display arrangement and can promote
    // this display to main, which yanks the menu bar onto a tiny panel.
    @discardableResult
    func selectMode(width: Int, height: Int, on displayID: CGDirectDisplayID) -> Bool {
        for _ in 0..<20 {
            if let current = CGDisplayCopyDisplayMode(displayID), current.pixelWidth == width, current.pixelHeight == height {
                return true
            }
            // Low-resolution modes are omitted unless explicitly requested,
            // and a small panel's native mode counts as one.
            let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
            if let modes = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode],
               let target = modes.first(where: { $0.pixelWidth == width && $0.pixelHeight == height })
            {
                CGDisplaySetDisplayMode(displayID, target, nil)
            }
            Thread.sleep(forTimeInterval: 0.15)
        }
        guard let current = CGDisplayCopyDisplayMode(displayID) else { return false }
        return current.pixelWidth == width && current.pixelHeight == height
    }

    func destroy() {
        display = nil
    }
}
