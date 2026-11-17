import XCTest

@MainActor
final class AccountSettingsUITests: XCTestCase {
    func testAccountSettingsAndEmptySessionRefusal() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        selectWorkspaceTab("Settings", in: app)
        let accounts = app.buttons["settings.accounts"]
        XCTAssertTrue(accounts.waitForExistence(timeout: 8))
        accounts.tap()
        XCTAssertTrue(app.navigationBars["Accounts"].waitForExistence(timeout: 5))
        let youtube = app.buttons["accounts.site.youtube"]
        XCTAssertTrue(youtube.waitForExistence(timeout: 5))
        youtube.tap()
        let signIn = app.buttons["accounts.signIn"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 5))
        signIn.tap()
        XCTAssertTrue(app.textFields["accounts.label"].waitForExistence(timeout: 5))
        app.buttons["accounts.save"].tap()
        XCTAssertTrue(app.staticTexts["Finish signing in to this website before saving the account."]
            .waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(signIn.waitForExistence(timeout: 5))
    }

    func testCaptureAccountsAndSharingSettings() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        selectWorkspaceTab("Settings", in: app)
        let current = app.buttons["settings.accounts"]
        let baseline = app.buttons["Website accounts"]
        let accounts = current.exists ? current : baseline
        XCTAssertTrue(accounts.waitForExistence(timeout: 8))
        let accountsTitle = current.exists ? "Accounts" : "Website accounts"
        accounts.tap()
        XCTAssertTrue(app.navigationBars[accountsTitle].waitForExistence(timeout: 5))
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "accounts"
        capture.lifetime = .keepAlways
        add(capture)
        selectWorkspaceTab("Settings", in: app)
        let currentSharing = app.buttons["Sharing & Shortcuts"]
        for _ in 0..<3 where !currentSharing.exists && !app.buttons["Shortcuts"].exists { app.swipeUp() }
        let sharing = currentSharing.exists ? currentSharing : app.buttons["Shortcuts"]
        XCTAssertTrue(sharing.waitForExistence(timeout: 5))
        sharing.tap()
        XCTAssertTrue(app.navigationBars["Sharing & Shortcuts"].exists || app.navigationBars["Shortcuts"].exists)
        let preferences = XCTAttachment(screenshot: app.screenshot())
        preferences.name = "sharing"
        preferences.lifetime = .keepAlways
        add(preferences)
    }

    func testAuthorizedLocalTokenGenerator() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ILLUCET_LOCAL_TOKEN_LIVE"] == "1")
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        selectWorkspaceTab("Settings", in: app)
        let accounts = app.buttons["settings.accounts"]
        XCTAssertTrue(accounts.waitForExistence(timeout: 8))
        accounts.tap()
        app.buttons["accounts.site.youtube"].tap()
        app.buttons["Local token generation"].tap()
        app.buttons["tokens.test"].tap()
        let generated = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Generated two local tokens")).firstMatch
        XCTAssertTrue(generated.waitForExistence(timeout: 50))
        if generated.exists { print("ILLUCET_PO_TEST \(generated.label)") }
    }
}
