import XCTest

@MainActor
final class AccountSettingsUITests: XCTestCase {
    func testAccountSettingsAndEmptySessionRefusal() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        selectWorkspaceTab("Settings", in: app)
        let accounts = app.buttons["YouTube accounts"]
        XCTAssertTrue(accounts.waitForExistence(timeout: 8))
        accounts.tap()
        let signIn = app.buttons["accounts.signIn"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 5))
        signIn.tap()
        XCTAssertTrue(app.textFields["accounts.label"].waitForExistence(timeout: 5))
        app.buttons["accounts.save"].tap()
        XCTAssertTrue(app.staticTexts["Finish signing in to YouTube before saving the account."]
            .waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(signIn.waitForExistence(timeout: 5))
    }
}
