import Foundation
import ScreenCaptureKit

// Reuse discovery and a recent panel frame from the stream that is already
// running. Opening a window need not wait for another content enumeration.
final class DisplayPreviewSource {
    struct Snapshot {
        let displayID: CGDirectDisplayID
        let bounds: CGRect
        let pixelSize: CGSize
        let filter: SCContentFilter
        var image: CGImage?
    }

    private let lock = NSLock()
    private weak var stream: SCStream?
    private var current: Snapshot?
    private var lastImageAt: TimeInterval = 0

    var snapshot: Snapshot? {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func prepare(content: SCShareableContent, display: SCDisplay, stream: SCStream) {
        let apps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: apps, exceptingWindows: [])
        let snapshot = Snapshot(displayID: display.displayID, bounds: CGDisplayBounds(display.displayID),
                                pixelSize: CGSize(width: display.width, height: display.height), filter: filter)
        lock.lock()
        self.stream = stream
        current = snapshot
        lastImageAt = 0
        lock.unlock()
    }

    func update(_ buffer: CVPixelBuffer, from stream: SCStream) {
        lock.lock()
        defer { lock.unlock() }
        guard self.stream === stream, current != nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        // Bound the extra copying even when the preview is closed. Idle
        // desktops keep their last frame without any additional work.
        guard current?.image == nil || now - lastImageAt >= 0.2 else { return }
        current?.image = Self.copyImage(buffer)
        lastImageAt = now
    }

    func clear() {
        lock.lock()
        stream = nil
        current = nil
        lock.unlock()
    }

    // Own the bytes; retaining an IOSurface-backed image would let the
    // compositor overwrite it as soon as it reuses the capture buffer.
    static func copyImage(_ buffer: CVPixelBuffer) -> CGImage? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let data = Data(bytes: base, count: stride * height)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: CVPixelBufferGetWidth(buffer), height: height,
                       bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stride,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
                           .union(.byteOrder32Little),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
