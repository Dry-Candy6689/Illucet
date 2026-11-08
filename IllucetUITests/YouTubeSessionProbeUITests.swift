import XCTest

@MainActor
final class YouTubeSessionProbeUITests: XCTestCase {
    func testEmptySessionAndClear() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--youtube-signin-probe"]
        app.launch()
        XCTAssertTrue(app.staticTexts["YouTube sign-in test"].waitForExistence(timeout: 15))
        app.buttons["Test extraction"].tap()
        XCTAssertTrue(app.staticTexts["No YouTube session. Open YouTube and sign in first."]
            .waitForExistence(timeout: 5))
        app.buttons["Clear"].tap()
        XCTAssertTrue(app.staticTexts["Session cleared. Sign in to test again."]
            .waitForExistence(timeout: 5))
        app.buttons["Test extraction"].tap()
        XCTAssertTrue(app.staticTexts["No YouTube session. Open YouTube and sign in first."]
            .waitForExistence(timeout: 5))
    }
}
