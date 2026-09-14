import Foundation
import CoreMedia
import ScreenCaptureKit

// Copy pixels while ScreenCaptureKit owns the sample, then keep only the
// newest image. A busy main thread must not retain an unbounded frame queue.
final class DisplayPreviewOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    let queue = DispatchQueue(label: "com.leftshift.gud.preview")
    private let lock = NSLock()
    private var image: CGImage?
    private var error: Error?

    var failure: Error? {
        lock.lock()
        defer { lock.unlock() }
        return error
    }

    func markFailed(_ error: Error) {
        lock.lock()
        self.error = error
        image = nil
        lock.unlock()
    }

    func takeImage() -> CGImage? {
        lock.lock()
        defer { lock.unlock() }
        let result = image
        image = nil
        return result
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { markFailed(error) }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus),
              status == .complete || status == .started,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let image = DisplayPreviewSource.copyImage(buffer) else { return }
        lock.lock()
        self.image = image
        lock.unlock()
    }
}
