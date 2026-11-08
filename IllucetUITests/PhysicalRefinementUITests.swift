import XCTest

/// Explicit opt-in only. Exercises the normal app with the user's saved state;
/// it never passes fixture/reset arguments or deletes media/accounts.
@MainActor
final class PhysicalRefinementUITests: XCTestCase {
    func testGuideAndDirectShortcutPreview() throws {
        guard ProcessInfo.processInfo.environment["ILLUCET_PHYSICAL_SMOKE"] == "1" else {
            throw XCTSkip("Requires the explicitly authorized iPhone verification invocation")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        if app.buttons["pip.skip"].waitForExistence(timeout: 3) {
            app.buttons["pip.skip"].tap()
            XCTAssertTrue(app.buttons["pip.skip"].waitForNonExistence(timeout: 4))
        }
        selectWorkspaceTab("Settings", in: app)
        let pip = app.buttons["settings.pip"]
        for _ in 0..<6 where !pip.isHittable { app.swipeUp() }
        XCTAssertTrue(pip.waitForExistence(timeout: 5)); pip.tap()
        app.buttons["pip.replay"].tap()
        XCTAssertTrue(app.buttons["pip.skip"].waitForExistence(timeout: 5))
        var seen: Set<String> = []
        for _ in 0..<24 where app.buttons["pip.skip"].exists {
            let step = app.staticTexts["pip.step"].label
            if seen.insert(step).inserted { capture(app, "Physical guide \(step)") }
            app.staticTexts["pip.dialogue"].tap()
        }
        XCTAssertFalse(app.buttons["pip.skip"].exists)
        XCTAssertTrue(app.staticTexts["download.hero"].isHittable)
        capture(app, "Physical guide finishes at true Download top")
        selectWorkspaceTab("Settings", in: app)
        let shortcutsRow = app.buttons["Shortcuts"]
        for _ in 0..<6 where !shortcutsRow.isHittable { app.swipeDown() }
        XCTAssertTrue(shortcutsRow.waitForExistence(timeout: 4)); shortcutsRow.tap()
        app.buttons["shortcuts.install"].tap()
        let shortcuts = XCUIApplication(bundleIdentifier: "com.apple.shortcuts")
        XCTAssertTrue(shortcuts.wait(for: .runningForeground, timeout: 12))
        XCTAssertTrue(shortcuts.buttons["Add Shortcut"].waitForExistence(timeout: 12))
        capture(shortcuts, "Physical direct Add Shortcut preview")
        shortcuts.buttons["Cancel"].firstMatch.tap()
        app.activate()
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }
}
