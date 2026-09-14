import Foundation

// Abstraction over the USB transport so GUDDeviceClient can be exercised
// against mock devices in tests. GUDUSBTransport is the real implementation.
protocol GUDTransport: AnyObject {
    func controlIn(request: UInt8, wValue: UInt16, length: UInt16) throws -> Data
    func controlOut(request: UInt8, wValue: UInt16, data: Data?) throws
    // Pair every successful begin with a wait before the next SET_BUFFER.
    func beginBulkWrite(_ data: NSMutableData) throws
    func waitBulkWrite() throws
}

extension GUDUSBTransport: GUDTransport {
    func controlIn(request: UInt8, wValue: UInt16, length: UInt16) throws -> Data {
        try controlIn(withRequest: request, wValue: wValue, length: length)
    }

    func controlOut(request: UInt8, wValue: UInt16, data: Data?) throws {
        try controlOut(withRequest: request, wValue: wValue, data: data)
    }

    // bulkWrite(_:) is satisfied directly by the imported Objective-C method.
}
