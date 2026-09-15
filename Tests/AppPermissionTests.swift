import XCTest
@testable import GUDDisplay

final class AppPermissionTests: XCTestCase {
    func testEveryPermissionHasASettingsPaneAndChecksWithoutPrompting() {
        XCTAssertEqual(AppPermission.allCases.count, 3)
        for permission in AppPermission.allCases {
            XCTAssertEqual(permission.settingsURL.scheme, "x-apple.systempreferences")
            XCTAssertEqual(permission.settingsURL.query, permission.settingsPane)
            XCTAssertFalse(permission.name.isEmpty)
            XCTAssertFalse(permission.purpose.isEmpty)
            // A plain query under the test host: must not hang or prompt.
            _ = permission.granted
        }
        XCTAssertEqual(Set(AppPermission.allCases.map(\.settingsPane)).count, 3)
    }
}
