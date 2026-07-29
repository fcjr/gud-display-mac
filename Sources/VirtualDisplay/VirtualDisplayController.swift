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
    private var nativeSize: (width: Int, height: Int)?

    var displayID: CGDirectDisplayID? {
        display?.displayID
    }

    // Must be called on the main queue. `modes[0]` is the panel's native mode:
    // it determines HiDPI treatment and is selected as the active mode after
    // creation, so the desktop really runs at the panel's resolution. Any
    // further modes are larger fallbacks that exist only so mirroring has a
    // shared resolution to pick (content is scaled down before transfer).
    func create(name: String,
                modes: [Mode],
                physicalSizeMillimeters: CGSize?,
                serialNumber: UInt32) -> CGDirectDisplayID?
    {
        guard let nativeMode = modes.first else { return nil }
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
        // Small panels are published as HiDPI modes: macOS refuses to bring a
        // display online whose *point* size is tiny, but a HiDPI mode keeps
        // the backing store at the panel's exact pixel count (336x262 pixels
        // presented as 168x131 points) — so the panel still gets a real,
        // unscaled, pixel-for-pixel image.
        settings.hiDPI = 0
        settings.modes = modes.map {
            CGVirtualDisplayMode(width: UInt($0.width), height: UInt($0.height), refreshRate: $0.refreshRate)
        }
        guard display.apply(settings) else {
            return nil
        }

        self.display = display
        self.nativeSize = (nativeMode.width, nativeMode.height)
        return display.displayID
    }

    // Call off the main thread (display registration needs main-runloop
    // turns) and BEFORE starting capture: ScreenCaptureKit binds the display's
    // geometry when the stream is created, so a mode or origin change
    // afterwards leaves the stream compositing the cursor at stale
    // coordinates.
    func finalizeGeometry() {
        guard let displayID = display?.displayID, let size = nativeSize else { return }
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

    // macOS may otherwise pick a synthesized scaled mode ("looks like" half
    // size) over the panel's real one. Modes register asynchronously after
    // applySettings, so retry until the native mode appears and sticks.
    //
    // Deliberately uses CGDisplaySetDisplayMode rather than a
    // Begin/CompleteDisplayConfiguration transaction: the transactional form
    // lets macOS re-evaluate the whole display arrangement and can promote
    // this display to main, which yanks the menu bar onto a tiny panel.
    @discardableResult
    func selectMode(width: Int, height: Int, on displayID: CGDirectDisplayID) -> Bool {
        for _ in 0..<20 {
            if CGDisplayCopyDisplayMode(displayID)?.pixelWidth == width {
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
        return CGDisplayCopyDisplayMode(displayID)?.pixelWidth == width
    }

    func destroy() {
        display = nil
    }
}
