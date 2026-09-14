import AppKit
import XCTest
@testable import GUDDisplay

final class DisplayPreviewTests: XCTestCase {
    @MainActor
    func testPreviewFillsContentAndDrawsTopRowAtTop() throws {
        // Two BGRA rows: red above blue. The pointer mapping uses this same
        // top-left origin, so an upside-down preview would click wrong targets.
        let pixels: [UInt8] = [0, 0, 255, 255, 255, 0, 0, 255]
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let image = try XCTUnwrap(CGImage(width: 1, height: 2, bitsPerComponent: 8, bitsPerPixel: 32,
                                         bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
                                             .union(.byteOrder32Little),
                                         provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let view = DisplayPreviewView(frame: NSRect(x: 0, y: 0, width: 100, height: 200))
        view.image = image
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let top = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 8)?.usingColorSpace(.deviceRGB))
        let bottom = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh * 7 / 8)?.usingColorSpace(.deviceRGB))
        let edge = try XCTUnwrap(bitmap.colorAt(x: 0, y: bitmap.pixelsHigh / 8)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(top.redComponent, 0.9)
        XCTAssertLessThan(top.blueComponent, 0.1)
        XCTAssertGreaterThan(bottom.blueComponent, 0.9)
        XCTAssertLessThan(bottom.redComponent, 0.1)
        XCTAssertGreaterThan(edge.redComponent, 0.9)
    }

    @MainActor
    func testWindowContentKeepsDisplayAspectThroughModeChangesAndZoom() throws {
        let controller = DisplayWindowController(displayName: "Test", source: DisplayPreviewSource())
        let window = try XCTUnwrap(controller.window)
        defer { controller.close() }
        for size in [CGSize(width: 800, height: 600), CGSize(width: 480, height: 800),
                     CGSize(width: 1920, height: 480)] {
            controller.updateGeometry(displaySize: size)
            let ratio = size.width / size.height
            let content = try XCTUnwrap(window.contentView)
            XCTAssertTrue(content is DisplayPreviewView)
            XCTAssertEqual(window.contentAspectRatio.width / window.contentAspectRatio.height, ratio, accuracy: 0.001)
            XCTAssertEqual(content.bounds.width / content.bounds.height, ratio, accuracy: 0.01)
            XCTAssertEqual(window.contentMinSize.width / window.contentMinSize.height, ratio, accuracy: 0.001)
            let zoomed = controller.windowWillUseStandardFrame(window, defaultFrame: NSRect(x: 0, y: 0, width: 1200, height: 900))
            let zoomedContent = window.contentRect(forFrameRect: zoomed)
            XCTAssertEqual(zoomedContent.width / zoomedContent.height, ratio, accuracy: 0.001)
        }
    }

    func testPortraitAndWideDisplaysFitAvailableScreenWithoutChangingRatio() {
        XCTAssertEqual(DisplayWindowController.fittedSize(CGSize(width: 480, height: 800),
                                                          within: CGSize(width: 900, height: 600)),
                       CGSize(width: 360, height: 600))
        XCTAssertEqual(DisplayWindowController.fittedSize(CGSize(width: 1920, height: 480),
                                                          within: CGSize(width: 900, height: 600)),
                       CGSize(width: 900, height: 225))
    }

    func testCachedFrameOwnsPixelsAfterCaptureBufferIsReused() throws {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 4, 4, kCVPixelFormatType_32BGRA, nil, &buffer), kCVReturnSuccess)
        let pixels = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        memset(CVPixelBufferGetBaseAddress(pixels), 255, CVPixelBufferGetDataSize(pixels))
        CVPixelBufferUnlockBaseAddress(pixels, [])
        let image = try XCTUnwrap(DisplayPreviewSource.copyImage(pixels))
        CVPixelBufferLockBaseAddress(pixels, [])
        memset(CVPixelBufferGetBaseAddress(pixels), 0, CVPixelBufferGetDataSize(pixels))
        CVPixelBufferUnlockBaseAddress(pixels, [])
        let bitmap = NSBitmapImageRep(cgImage: image)
        let color = try XCTUnwrap(bitmap.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB))
        XCTAssertEqual(color.redComponent, 1, accuracy: 0.001)
        XCTAssertEqual(color.alphaComponent, 1, accuracy: 0.001)
    }

    func testCoordinatesUseDesktopPointsAndTopLeftOrigin() {
        // A display above and left of the primary screen, captured at 2x.
        let desktop = CGRect(x: -800, y: -600, width: 800, height: 600)
        let rect = CGRect(x: 0, y: 0, width: 1200, height: 900)
        XCTAssertEqual(DisplayPreviewView.displayPoint(for: CGPoint(x: 0, y: 0), imageRect: rect,
                                                      displayBounds: desktop), CGPoint(x: -800, y: -600))
        XCTAssertEqual(DisplayPreviewView.displayPoint(for: CGPoint(x: 600, y: 450), imageRect: rect,
                                                      displayBounds: desktop), CGPoint(x: -400, y: -300))
        XCTAssertEqual(DisplayPreviewView.displayPoint(for: CGPoint(x: 900, y: 675), imageRect: rect,
                                                      displayBounds: desktop), CGPoint(x: -200, y: -150))
    }

    func testUnavailableDisplayCannotReceivePointer() {
        XCTAssertEqual(DisplayWindowController.fittedSize(.zero, within: CGSize(width: 900, height: 600)), .zero)
        XCTAssertNil(DisplayPreviewView.displayPoint(for: .zero, imageRect: .zero,
                                                    displayBounds: CGRect(x: 0, y: 0, width: 800, height: 600)))
        XCTAssertNil(DisplayPreviewView.displayPoint(for: CGPoint(x: 100, y: 100),
                                                    imageRect: CGRect(x: 0, y: 0, width: 900, height: 600),
                                                    displayBounds: .zero))
    }
}
