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

    var displayID: CGDirectDisplayID? {
        display?.displayID
    }

    // Must be called on the main queue. All device modes are registered so
    // the user can switch resolution in System Settings; `modes` must be
    // non-empty and the first entry is used for sizing bounds fallback.
    func create(name: String,
                modes: [Mode],
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
        // With hiDPI enabled macOS synthesizes the scaled "looks like" variants.
        settings.hiDPI = maxWidth >= 1920 ? 1 : 0
        settings.modes = modes.map {
            CGVirtualDisplayMode(width: UInt($0.width), height: UInt($0.height), refreshRate: $0.refreshRate)
        }
        guard display.apply(settings) else {
            return nil
        }

        self.display = display
        return display.displayID
    }

    func destroy() {
        display = nil
    }
}
