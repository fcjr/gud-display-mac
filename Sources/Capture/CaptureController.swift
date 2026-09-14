import Foundation
import ScreenCaptureKit
import CoreMedia

enum CaptureError: Error {
    case displayNotFound

    static func requiresUserAction(_ error: Error) -> Bool {
        let error = error as NSError
        guard error.domain == SCStreamErrorDomain else { return false }
        return [SCStreamError.Code.userDeclined, .userStopped, .missingEntitlements]
            .contains { $0.rawValue == error.code }
    }
}

// Captures one virtual display via ScreenCaptureKit and surfaces frames with
// dirty rects. Idle frames (unchanged content) are dropped here, which is the
// zero-USB-traffic-when-idle mechanism.
final class CaptureController: NSObject, SCStreamOutput, SCStreamDelegate {
    struct Frame {
        let pixelBuffer: CVPixelBuffer
        // In pixels; empty means "treat as full damage".
        let dirtyRects: [CGRect]
        let isFirstFrame: Bool
    }

    var frameHandler: ((Frame) -> Void)?
    var stoppedHandler: ((Error?) -> Void)?
    let previewSource = DisplayPreviewSource()

    private var stream: SCStream?
    // Retained so rate changes can be applied to the live stream. Pushing a
    // fresh SCStreamConfiguration into updateConfiguration replaces EVERY
    // property with its default (1920x1080, '420v' YCbCr), not just the ones
    // set on it — the converter would then read a luma plane as BGRA.
    private var configuration: SCStreamConfiguration?
    private let sampleQueue = DispatchQueue(label: "com.leftshift.gud.capture")

    func start(displayID: CGDirectDisplayID, pixelWidth: Int, pixelHeight: Int, maxFrameRate: Int = 60) async throws {
        stop() // replace any existing stream (capture restarts on reconfiguration)
        // A freshly created virtual display takes a moment to appear in the
        // shareable-content snapshot; poll briefly.
        var scDisplay: SCDisplay?
        var shareableContent: SCShareableContent?
        for _ in 0..<20 {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            scDisplay = content.displays.first { $0.displayID == displayID }
            if scDisplay != nil {
                shareableContent = content
                break
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        guard let scDisplay, let shareableContent else {
            throw CaptureError.displayNotFound
        }

        let configuration = SCStreamConfiguration()
        configuration.width = pixelWidth
        configuration.height = pixelHeight
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.queueDepth = 6
        configuration.showsCursor = true // GUD has no cursor plane; composite it into the frame.
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(maxFrameRate))

        let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        previewSource.prepare(content: shareableContent, display: scDisplay, stream: stream)
        try await stream.startCapture()
        self.stream = stream
        self.configuration = configuration
    }

    func stop() {
        previewSource.clear()
        stream?.stopCapture { _ in }
        stream = nil
        configuration = nil
    }

    // Raise/lower the capture rate without restarting the stream (USB backpressure).
    func setMaxFrameRate(_ maxFrameRate: Int) {
        guard let stream, let configuration else { return }
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(maxFrameRate))
        stream.updateConfiguration(configuration) { _ in }
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let statusRaw = info[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRaw)
        else { return }

        // .idle (unchanged), .blank, and .suspended produce no transfer.
        // TODO: map .blank/.suspended to SET_DISPLAY_ENABLE on the device.
        guard status == .complete || status == .started else { return }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        previewSource.update(pixelBuffer, from: stream)
        let dirtyRects = (info[.dirtyRects] as? [NSValue])?.map(\.rectValue) ?? []
        frameHandler?(Frame(pixelBuffer: pixelBuffer, dirtyRects: dirtyRects, isFirstFrame: status == .started))
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        stoppedHandler?(error)
    }
}
