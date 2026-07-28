import Foundation
import IOKit
import IOKit.usb

// Watches IOKit for GUD interfaces (VID 0x1d50, PID 0x614d, vendor-specific
// class) arriving. Termination is handled per-device by the transport's
// interest handler, not here.
final class USBDeviceMonitor {
    var deviceMatched: ((io_service_t) -> Void)?

    private let queue = DispatchQueue(label: "com.leftshift.gud.usb-monitor")
    private var notifyPort: IONotificationPortRef?
    private var matchIterator: io_iterator_t = 0

    func start() {
        guard notifyPort == nil else { return }
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        notifyPort = port
        IONotificationPortSetDispatchQueue(port, queue)

        let matching = IOServiceMatching("IOUSBHostInterface")! as NSMutableDictionary
        matching["idVendor"] = GUD.vendorID
        matching["idProduct"] = GUD.productID
        matching["bInterfaceClass"] = 0xff

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let result = IOServiceAddMatchingNotification(
            port,
            kIOFirstMatchNotification,
            matching as CFMutableDictionary,
            { refcon, iterator in
                guard let refcon else { return }
                let monitor = Unmanaged<USBDeviceMonitor>.fromOpaque(refcon).takeUnretainedValue()
                monitor.drain(iterator: iterator)
            },
            refcon,
            &matchIterator
        )
        guard result == KERN_SUCCESS else { return }

        // Drain the iterator once to arm the notification and pick up
        // already-attached devices.
        drain(iterator: matchIterator)
    }

    func stop() {
        if matchIterator != 0 {
            IOObjectRelease(matchIterator)
            matchIterator = 0
        }
        if let port = notifyPort {
            IONotificationPortDestroy(port)
            notifyPort = nil
        }
    }

    private func drain(iterator: io_iterator_t) {
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            deviceMatched?(service)
            // The transport retains the service itself; drop our reference.
            IOObjectRelease(service)
        }
    }
}
