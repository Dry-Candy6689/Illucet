import XCTest

@MainActor
final class RefinementUITests: XCTestCase {
    private func launch(_ screen: String) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        // Each screen supplies its own jobs. Do not restore the frozen transfer
        // fixture into a later Storage test, where active work blocks deletion.
        app.launchArguments = ["--ui-testing", "--ui-polish-reset", "--ui-empty-state", "--ui-screen=\(screen)", "--ui-reduce-motion"]
        app.launch()
        return app
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }
    private func settings(_ name: String, app: XCUIApplication) {
        selectWorkspaceTab("Settings", in: app)
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
        for _ in 0..<6 where !row.isHittable { app.swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: 4)); row.tap()
    }

    func testThirdManualStartPromptsAcrossVideoAndAudioTransferStages() {
        let app = launch("transfer-limit")
        let add = app.buttons["Add to queue"]
        for _ in 0..<8 where !add.isHittable { app.swipeUp() }
        XCTAssertTrue(add.isHittable); add.tap()
        let prompt = app.alerts["Download limit reached"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 5))
        XCTAssertTrue(prompt.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "2 downloads")).firstMatch.exists)
        XCTAssertTrue(prompt.buttons["Queue"].exists)
        XCTAssertTrue(prompt.buttons["Start anyway"].exists)
        capture(app, "Third manual download with video and audio transfers active")
        prompt.buttons["Cancel"].tap()
        XCTAssertTrue(prompt.waitForNonExistence(timeout: 3))
        XCTAssertTrue(add.exists)
    }

    func testSelectionStaysOnItsOwnTabAndCancelAllIsDisabledForFinishedWork() {
        let app = launch("subtitles-output-truth")
        selectWorkspaceTab("History", in: app)
        let record = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "history.record.")).firstMatch
        XCTAssertTrue(record.waitForExistence(timeout: 4))
        let before = record.frame
        record.press(forDuration: 0.6)
        XCTAssertTrue(app.buttons["selection.cancel"].waitForExistence(timeout: 3))
        XCTAssertEqual(record.frame.size, before.size)
        capture(app, "Inline History selection border and action bar")
        selectWorkspaceTab("Settings", in: app)
        XCTAssertFalse(app.buttons["selection.cancel"].exists)
        selectWorkspaceTab("History", in: app)
        XCTAssertTrue(app.buttons["selection.cancel"].exists)
        selectWorkspaceTab("Queue", in: app)
        XCTAssertFalse(app.buttons["selection.cancel"].exists)
        app.buttons["queue.actions"].tap()
        XCTAssertFalse(app.buttons["Cancel all"].isEnabled)
        app.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.55)).tap()
        selectWorkspaceTab("History", in: app)
        app.buttons["selection.cancel"].tap()
        XCTAssertFalse(app.buttons["selection.cancel"].exists)
    }

    func testSponsorBlockLabelsAndDismissibleDefinitions() {
        let app = launch("download")
        settings("SponsorBlock", app: app)
        let enabled = app.switches["sponsorblock.enabled"]
        XCTAssertTrue(enabled.waitForExistence(timeout: 4))
        if enabled.value as? String == "0" { enabled.switches.firstMatch.tap() }
        for id in ["sponsor", "selfpromo", "interaction", "poi_highlight", "intro", "outro", "preview", "hook", "filler"] {
            let label = app.buttons["sponsorblock.help.\(id)"]
            for _ in 0..<4 where !label.isHittable { app.swipeUp() }
            XCTAssertTrue(label.exists)
        }
        capture(app, "SponsorBlock one-line category labels")
        for _ in 0..<5 where !app.buttons["sponsorblock.help.sponsor"].isHittable { app.swipeDown() }
        app.buttons["sponsorblock.help.sponsor"].tap()
        let explanation = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Paid promotion, paid referrals")).firstMatch
        XCTAssertTrue(explanation.waitForExistence(timeout: 3))
        capture(app, "Compact SponsorBlock definition popover")
        app.coordinate(withNormalizedOffset: .init(dx: 0.9, dy: 0.15)).tap()
        XCTAssertTrue(explanation.waitForNonExistence(timeout: 3))
    }

    func testStorageCleanupFeedbackKeepsTheRowDividers() {
        let app = launch("download")
        settings("Storage", app: app)
        let logs = app.buttons["storage.clearLogs"]
        for _ in 0..<5 where !logs.isHittable { app.swipeUp() }
        logs.tap()
        XCTAssertTrue(app.staticTexts["Cleared"].waitForExistence(timeout: 3))
        app.buttons["storage.deleteFiles"].tap()
        XCTAssertTrue(app.buttons["Delete files"].waitForExistence(timeout: 3))
        capture(app, "Storage dividers with Cleared and Delete files confirmation")
        if app.buttons["Cancel"].firstMatch.exists { app.buttons["Cancel"].firstMatch.tap() }
        else { app.coordinate(withNormalizedOffset: .init(dx: 0.9, dy: 0.12)).tap() }
        capture(app, "Storage dividers after confirmation dismissal")
    }

    func testShortcutButtonOpensAddShortcutInsteadOfSharing() {
        let app = launch("download")
        settings("Shortcuts", app: app)
        app.buttons["shortcuts.install"].tap()
        let shortcuts = XCUIApplication(bundleIdentifier: "com.apple.shortcuts")
        XCTAssertTrue(shortcuts.wait(for: .runningForeground, timeout: 10))
        XCTAssertTrue(shortcuts.buttons["Add Shortcut"].waitForExistence(timeout: 12))
        capture(shortcuts, "Direct Add Shortcut for Download with Illucet")
        shortcuts.buttons["Cancel"].firstMatch.tap()
        app.activate()
    }
}
