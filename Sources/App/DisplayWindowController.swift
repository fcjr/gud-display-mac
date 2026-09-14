import AppKit
import CoreMedia
import ScreenCaptureKit

// This stream captures the desktop before it is downscaled for the USB panel.
// It exists only while the window is open, separately from the USB stream.
final class DisplayWindowController: NSWindowController, NSWindowDelegate {
    private let preview = DisplayPreviewView()
    private let status = NSTextField(wrappingLabelWithString: "Waiting for the display…")
    private let source: DisplayPreviewSource
    private var displayID: CGDirectDisplayID?
    private var captureBounds = CGRect.zero
    private var stream: SCStream?
    private var output: DisplayPreviewOutput?
    private var startTask: Task<Void, Never>?
    private var generation = UUID()
    private var timer: Timer?
    private var hasLiveFrame = false

    init(displayName: String, source: DisplayPreviewSource) {
        self.source = source
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 900, height: 680),
                            styleMask: [.titled, .closable, .miniaturizable, .resizable, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.title = "\(displayName) · Display Window"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.fullScreenAuxiliary, .fullScreenDisallowsTiling]
        super.init(window: panel)
        panel.delegate = self

        panel.contentView = preview
        preview.toolTip = "Click to move your pointer onto this display, then click to interact. Move back across the display edge to return."
        status.translatesAutoresizingMaskIntoConstraints = false
        status.font = .systemFont(ofSize: NSFont.systemFontSize)
        status.textColor = .secondaryLabelColor
        status.alignment = .center
        preview.addSubview(status)
        NSLayoutConstraint.activate([
            status.centerYAnchor.constraint(equalTo: preview.centerYAnchor),
            status.leadingAnchor.constraint(equalTo: preview.leadingAnchor, constant: 24),
            status.trailingAnchor.constraint(equalTo: preview.trailingAnchor, constant: -24),
        ])
        preview.movePointer = { [weak self] point in
            guard let self, let displayID,
                  CGDisplayIsOnline(displayID) != 0,
                  CGDisplayBounds(displayID) == captureBounds else { return }
            CGWarpMouseCursorPosition(point)
        }

        // NSScreen.main may be the GUD screen if its app currently has focus.
        let screen = NSScreen.screens.first { $0.displayID == CGMainDisplayID() }
        if let screen {
            let area = screen.visibleFrame.insetBy(dx: 30, dy: 30)
            let size = NSSize(width: min(panel.frame.width, area.width),
                              height: min(panel.frame.height, area.height))
            panel.setFrame(NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2,
                                  width: size.width, height: size.height), display: false)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func showWindow(_ sender: Any?) {
        if output?.failure != nil { stopCapture() }
        if let snapshot = source.snapshot, CGDisplayIsOnline(snapshot.displayID) != 0,
           snapshot.bounds == CGDisplayBounds(snapshot.displayID) {
            if displayID != snapshot.displayID || captureBounds != snapshot.bounds { stopCapture() }
            displayID = snapshot.displayID
            captureBounds = snapshot.bounds
            updateGeometry(displaySize: snapshot.bounds.size)
            if preview.image == nil, let image = snapshot.image { present(image) }
        }
        if window?.isMiniaturized == true { window?.deminiaturize(sender) }
        window?.orderFrontRegardless()
        if timer == nil {
            let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        refresh()
    }

    func setDisplayID(_ displayID: CGDirectDisplayID?) {
        let changed = self.displayID != displayID
        self.displayID = displayID
        if changed { stopCapture() }
        refresh()
    }

    private func refresh() {
        guard window?.isVisible == true, window?.isMiniaturized == false else { return }
        guard let displayID, CGDisplayIsOnline(displayID) != 0 else {
            stopCapture()
            status.stringValue = "Waiting for the display…"
            return
        }
        let bounds = CGDisplayBounds(displayID)
        guard bounds.width > 0, bounds.height > 0 else { return }
        if bounds != captureBounds { stopCapture() }
        updateGeometry(displaySize: bounds.size)
        guard stream == nil, startTask == nil else { return }
        captureBounds = bounds
        let snapshot = source.snapshot.flatMap {
            $0.displayID == displayID && $0.bounds == bounds ? $0 : nil
        }
        if let image = snapshot?.image { present(image) }
        if preview.image == nil { status.stringValue = "Opening display…" }
        let token = generation
        let output = DisplayPreviewOutput()
        self.output = output
        startTask = Task { @MainActor [weak self] in
            do {
                try Task.checkCancellation()
                let filter: SCContentFilter
                let pixelSize: CGSize
                if let snapshot {
                    filter = snapshot.filter
                    pixelSize = snapshot.pixelSize
                } else {
                    // Only needed if the USB stream has not discovered this
                    // display yet, such as during device bring-up.
                    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                    try Task.checkCancellation()
                    guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                        throw CaptureError.displayNotFound
                    }
                    let apps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
                    filter = SCContentFilter(display: display, excludingApplications: apps, exceptingWindows: [])
                    pixelSize = CGSize(width: display.width, height: display.height)
                }
                let configuration = SCStreamConfiguration()
                let scale = min(1, 2560.0 / max(pixelSize.width, pixelSize.height))
                configuration.width = max(1, Int(pixelSize.width * scale))
                configuration.height = max(1, Int(pixelSize.height * scale))
                configuration.pixelFormat = kCVPixelFormatType_32BGRA
                configuration.showsCursor = true
                configuration.queueDepth = 3
                configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
                let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
                try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
                do {
                    try await stream.startCapture()
                } catch {
                    try? await stream.stopCapture()
                    throw error
                }
                guard let self, !Task.isCancelled, self.generation == token else {
                    try? await stream.stopCapture()
                    return
                }
                self.stream = stream
                self.startTask = nil
            } catch {
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.startTask = nil
                // Leave the output in place to distinguish a failed start
                // from a window that has not yet tried to start.
                output.markFailed(error)
            }
        }
    }

    private func tick() {
        guard window?.isMiniaturized == false else { return }
        if let error = output?.failure {
            if preview.image != nil { preview.image = nil }
            preview.displayBounds = .zero
            status.isHidden = false
            status.stringValue = "Display preview stopped: \(error.localizedDescription)"
            return
        }
        if let image = output?.takeImage() {
            hasLiveFrame = true
            present(image)
        } else if !hasLiveFrame, let snapshot = source.snapshot,
                  snapshot.displayID == displayID, snapshot.bounds == captureBounds,
                  snapshot.bounds == CGDisplayBounds(snapshot.displayID),
                  let image = snapshot.image, image !== preview.image {
            // Keep the window usable through stream startup, using the
            // already-running USB capture until the sharper frames arrive.
            present(image)
        }
    }

    private func present(_ image: CGImage) {
        preview.image = image
        preview.displayBounds = captureBounds
        status.isHidden = true
    }

    static func fittedSize(_ displaySize: CGSize, within available: CGSize) -> CGSize {
        guard displaySize.width > 0, displaySize.height > 0, available.width > 0, available.height > 0 else { return .zero }
        let scale = min(available.width / displaySize.width, available.height / displaySize.height)
        return CGSize(width: displaySize.width * scale, height: displaySize.height * scale)
    }

    // The preview is the entire content view. AppKit constrains interactive
    // resizing, while explicit mode changes resize the window to match.
    func updateGeometry(displaySize: CGSize) {
        guard let window, displaySize.width > 0, displaySize.height > 0 else { return }
        let oldRatio = window.contentAspectRatio
        guard oldRatio.width / max(1, oldRatio.height) != displaySize.width / displaySize.height else { return }
        let screen = window.screen ?? NSScreen.screens.first
        let area = screen?.visibleFrame.insetBy(dx: 30, dy: 30) ?? window.frame
        let titleHeight = window.frame.height - window.contentLayoutRect.height
        let maximum = Self.fittedSize(displaySize, within: CGSize(width: area.width, height: area.height - titleHeight))
        let minimumScale = min(max(240 / displaySize.width, 160 / displaySize.height), maximum.width / displaySize.width)
        window.contentMinSize = CGSize(width: displaySize.width * minimumScale, height: displaySize.height * minimumScale)
        window.contentAspectRatio = displaySize
        let preferred = window.contentLayoutRect.size
        let fitted = Self.fittedSize(displaySize, within: CGSize(width: min(preferred.width, maximum.width),
                                                               height: min(preferred.height, maximum.height)))
        window.setContentSize(CGSize(width: max(fitted.width, window.contentMinSize.width),
                                     height: max(fitted.height, window.contentMinSize.height)))
    }

    func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame newFrame: NSRect) -> NSRect {
        let content = window.contentRect(forFrameRect: newFrame)
        let size = Self.fittedSize(window.contentAspectRatio, within: content.size)
        return window.frameRect(forContentRect: NSRect(origin: content.origin, size: size))
    }

    private func stopCapture() {
        generation = UUID()
        startTask?.cancel()
        startTask = nil
        stream?.stopCapture { _ in }
        stream = nil
        output = nil
        hasLiveFrame = false
        preview.image = nil
        preview.displayBounds = .zero
        status.isHidden = false
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
        stopCapture()
    }

    func windowDidMiniaturize(_ notification: Notification) { stopCapture() }
    func windowDidDeminiaturize(_ notification: Notification) { refresh() }
}
