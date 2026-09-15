import XCTest
@testable import GUDDisplay

final class AppPermissionTests: XCTestCase {
    func testEveryPermissionHasASettingsPaneAndChecksWithoutPrompting() {
        XCTAssertEqual(AppPermission.allCases.count, 3)
        for permission in AppPermission.allCases {
            // Foundation versions disagree on how to split this scheme's URL,
            // so check the string the system will actually open.
            XCTAssertEqual(permission.settingsURL.absoluteString,
                           "x-apple.systempreferences:com.apple.preference.security?" + permission.settingsPane)
            XCTAssertFalse(permission.name.isEmpty)
            XCTAssertFalse(permission.purpose.isEmpty)
            // A plain query under the test host: must not hang or prompt.
            _ = permission.granted
        }
        XCTAssertEqual(Set(AppPermission.allCases.map(\.settingsPane)).count, 3)
    }
}
