import XCTest
@testable import GUDDisplay

final class TouchPreferenceTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        defaults = UserDefaults(suiteName: "TouchPreferenceTests")
        defaults.removePersistentDomain(forName: "TouchPreferenceTests")
    }

    func testDefaultsToEnabledAndPersistsPerSerial() {
        XCTAssertTrue(TouchPreference.isEnabled(serialNumber: "A", locationID: 1, defaults: defaults))
        TouchPreference.setEnabled(false, serialNumber: "A", locationID: 1, defaults: defaults)
        XCTAssertFalse(TouchPreference.isEnabled(serialNumber: "A", locationID: 1, defaults: defaults))
        // Same panel on another port keeps its setting; another panel does not.
        XCTAssertFalse(TouchPreference.isEnabled(serialNumber: "A", locationID: 2, defaults: defaults))
        XCTAssertTrue(TouchPreference.isEnabled(serialNumber: "B", locationID: 1, defaults: defaults))
    }

    func testFallsBackToPortWithoutSerial() {
        TouchPreference.setEnabled(false, serialNumber: nil, locationID: 0x1100000, defaults: defaults)
        XCTAssertFalse(TouchPreference.isEnabled(serialNumber: "", locationID: 0x1100000, defaults: defaults))
        XCTAssertTrue(TouchPreference.isEnabled(serialNumber: nil, locationID: 0x1200000, defaults: defaults))
    }

    func testRotationIsRememberedPerDeviceInDisplayDegrees() {
        XCTAssertEqual(RotationPreference.degrees(serialNumber: "A", locationID: 1, defaults: defaults), 0)
        RotationPreference.setDegrees(GUD.Rotation.rotate270.displayDegrees, serialNumber: "A", locationID: 1, defaults: defaults)
        XCTAssertEqual(RotationPreference.degrees(serialNumber: "A", locationID: 9, defaults: defaults), 90)
        XCTAssertEqual(GUD.Rotation(displayDegrees: 90), .rotate270)
        for rotation in GUD.Rotation.allCases {
            XCTAssertEqual(GUD.Rotation(displayDegrees: Double(rotation.displayDegrees)), rotation)
        }
        XCTAssertEqual(RotationPreference.degrees(serialNumber: "B", locationID: 1, defaults: defaults), 0)
    }
}
