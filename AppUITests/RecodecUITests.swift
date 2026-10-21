import XCTest

/// One smoke test: the app launches, shows its single window, and the Convert
/// button is there. No files are loaded, so the footer is the only thing under test.
final class RecodecUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testAppLaunchesWithItsWindowAndConvertButton() throws {
        let app = XCUIApplication()
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 30), "The app window never appeared")

        let convert = app.buttons["Convert"]
        XCTAssertTrue(convert.waitForExistence(timeout: 10), "The Convert button is missing")
        XCTAssertTrue(window.buttons["Convert"].exists)
    }
}
