import AppKit
import ScreenCaptureKit
import XCTest
@testable import GUDDisplay

final class CapturePermissionTests: XCTestCase {
    func testAuthorizationFailuresWaitForUserInsteadOfRetrying() {
        for code in [SCStreamError.Code.userDeclined, .userStopped, .missingEntitlements] {
            XCTAssertTrue(CaptureError.requiresUserAction(NSError(domain: SCStreamErrorDomain, code: code.rawValue)))
        }
        XCTAssertFalse(CaptureError.requiresUserAction(NSError(domain: SCStreamErrorDomain,
                                                               code: SCStreamError.Code.noDisplayList.rawValue)))
        XCTAssertFalse(CaptureError.requiresUserAction(NSError(domain: NSCocoaErrorDomain,
                                                               code: SCStreamError.Code.userDeclined.rawValue)))
    }

    @MainActor
    func testTestHostDoesNotStartApplicationServicesOrPermissionPrompts() {
        XCTAssertNil(NSApplication.shared.delegate)
    }
}
