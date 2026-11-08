import XCTest

@MainActor
final class NavigationRefinementUITests: XCTestCase {
    func testFirstPasteTipIsCompactDismissibleAndShownOnce() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-polish-reset", "--ui-empty-state",
            "--ui-first-paste", "--ui-light-appearance"]
        app.launch()
        XCTAssertTrue(app.buttons["download.paste"].waitForExistence(timeout: 10))
        app.buttons["download.paste"].tap()
        let message = app.staticTexts["clipboard.tip.message"]
        XCTAssertTrue(message.waitForExistence(timeout: 4))
        XCTAssertTrue(message.label.contains("Paste from Other Apps"))
        capture(app, "First paste permission tip light")
        app.buttons["clipboard.tip.dismiss"].tap()
        XCTAssertTrue(message.waitForNonExistence(timeout: 3))
        app.buttons["download.clear"].tap()
        app.buttons["download.paste"].tap()
        XCTAssertFalse(message.exists)
    }

    func testFirstPasteTipOpensIOSSettingsInLargeDarkAppearance() {
        continueAfterFailure = false
        // Isolate the external Settings app from earlier UI runs.
        XCUIApplication(bundleIdentifier: "com.apple.Preferences").terminate()
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-polish-reset", "--ui-empty-state",
            "--ui-first-paste", "--ui-dark-appearance", "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXL"]
        app.launch()
        XCTAssertTrue(app.buttons["download.paste"].waitForExistence(timeout: 10))
        scrollUntilHittable("download.paste", in: app)
        app.buttons["download.paste"].tap()
        XCTAssertTrue(app.staticTexts["clipboard.tip.message"].waitForExistence(timeout: 4))
        capture(app, "First paste permission tip large dark")
        let link = app.links["iOS Settings"]
        if !link.waitForExistence(timeout: 3) { print(app.debugDescription) }
        XCTAssertTrue(link.exists)
        link.tap()
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        XCTAssertTrue(settings.wait(for: .runningForeground, timeout: 8))
        // Simulator Settings receives the correct app destination, but its Apps
        // pane does not resolve on the installed 26.5/27.0 runtimes. A physical
        // device check remains separate from this cross-app UI assertion.
        #if !targetEnvironment(simulator)
        XCTAssertTrue(settings.navigationBars["Illucet"].waitForExistence(timeout: 6))
        #endif
        capture(settings, "iOS Settings opened from the inline permission link")
    }

    func testNotificationTipOffersSettingsWithoutEnablingAnything() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-polish-reset", "--ui-empty-state",
            "--ui-screen=pip-notifications", "--pip-fast-text", "--ui-light-appearance"]
        app.launch()
        XCTAssertTrue(app.buttons["pip.notificationSettings"].waitForExistence(timeout: 14))
        capture(app, "PiP optional notification tip")
        app.buttons["pip.notificationSettings"].tap()
        XCTAssertTrue(app.navigationBars["Notifications"].waitForExistence(timeout: 4))
        for title in ["Playlist complete", "Retries exhausted", "Download complete", "Failure"] {
            let toggle = app.switches[title]
            scrollUntilHittable(title, type: .switch, in: app)
            XCTAssertEqual(toggle.value as? String, "0")
        }
        capture(app, "Notification events start off")
    }
    private func launch(hints: Bool = false, dark: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-polish-reset", "--ui-empty-state",
            "--ui-screen=navigation-refinement", "--pip-fast-text", "--ui-reduce-motion",
            dark ? "--ui-dark-appearance" : "--ui-light-appearance"]
        if hints { app.launchArguments.append("--ui-selection-hints") }
        app.launch()
        XCTAssertTrue(waitForWorkspaceShell(app, timeout: 15))
        return app
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name; a.lifetime = .keepAlways; add(a)
    }

    private func openInterface(_ app: XCUIApplication) {
        selectWorkspaceTab("Settings", in: app)
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Interface")).firstMatch
        for _ in 0..<5 where !row.isHittable { app.swipeUp() }
        XCTAssertTrue(row.isHittable); row.tap()
        XCTAssertTrue(app.navigationBars["Interface"].waitForExistence(timeout: 4))
    }

    func testDownloadRemembersPositionAndRetapRevealsTheWholeTop() {
        let app = launch()
        let presets = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Quick start")).firstMatch
        app.swipeUp()
        XCTAssertTrue(presets.exists)
        let initialY = presets.frame.minY
        for tab in ["Queue", "History", "Settings"] {
            selectWorkspaceTab(tab, in: app)
            app.swipeUp(velocity: .fast)
            selectWorkspaceTab("Download", in: app)
            XCTAssertEqual(presets.frame.minY, initialY, accuracy: 4, "Returning from \(tab) must retain Download's position")
        }
        // A fresh gesture on returning must not be undone by a delayed top reset.
        app.swipeDown()
        app.swipeUp()
        let scrolledY = presets.frame.minY
        Thread.sleep(forTimeInterval: 0.4)
        XCTAssertEqual(presets.frame.minY, scrolledY, accuracy: 4)
        selectWorkspaceTab("Download", in: app)
        let hero = app.staticTexts["download.hero"]
        XCTAssertTrue(hero.isHittable)
        XCTAssertGreaterThanOrEqual(hero.frame.minY, app.navigationBars["Illucet"].frame.maxY)
        capture(app, "Download remembered position and true top")
    }

    func testSettingsReturnsToRootBeforeScrollingAndToggleOnlyDisablesScrolling() {
        let app = launch(dark: true)
        openInterface(app)
        let icon = app.buttons["interface.icon.purple"]
        for _ in 0..<5 where !icon.isHittable { app.swipeUp() }
        XCTAssertTrue(icon.exists)
        capture(app, "Interface app icon choices dark")
        let toggle = app.switches["interface.tapTabToTop"]
        for _ in 0..<5 where !toggle.isHittable { app.swipeUp() }
        XCTAssertEqual(toggle.value as? String, "1")
        toggle.switches.firstMatch.tap()
        selectWorkspaceTab("Settings", in: app)
        XCTAssertTrue(app.navigationBars["Settings"].exists)
        let interface = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Interface")).firstMatch
        let rootY = interface.frame.minY
        selectWorkspaceTab("Settings", in: app)
        XCTAssertEqual(interface.frame.minY, rootY, accuracy: 3)
        interface.tap()
        XCTAssertTrue(app.navigationBars["Interface"].exists)
        for _ in 0..<5 where !toggle.isHittable { app.swipeUp() }
        toggle.switches.firstMatch.tap()
        selectWorkspaceTab("Settings", in: app)
        XCTAssertEqual(interface.frame.minY, rootY, accuracy: 3)
        selectWorkspaceTab("Settings", in: app)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "YouTube accounts")).firstMatch.isHittable)
        capture(app, "Settings retap reaches root then top")
    }

    func testQueueAndHistoryRetapsReturnToTheirFirstItem() {
        let app = launch()
        for (tab, prefix) in [("Queue", "queue.job."), ("History", "history.record.")] {
            selectWorkspaceTab(tab, in: app)
            let cards = app.descendants(matching: .any).matching(NSPredicate(
                format: "identifier MATCHES %@", NSRegularExpression.escapedPattern(for: prefix) + "[A-Fa-f0-9-]{36}"))
            XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 4))
            let firstID = cards.firstMatch.identifier
            for _ in 0..<3 { app.swipeUp() }
            let first = app.descendants(matching: .any)[firstID].firstMatch
            XCTAssertFalse(first.isHittable)
            selectWorkspaceTab(tab, in: app)
            let visible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in first.exists && first.isHittable }, object: app)
            XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 4), .completed)
            capture(app, "\(tab) retap returns to the first item")
        }
    }

    func testSelectionHintsAppearOnceOnEachPageAndBubbleTapDismisses() {
        let app = launch(hints: true)
        selectWorkspaceTab("Queue", in: app)
        let bubble = app.otherElements["pip.companion"]
        XCTAssertTrue(bubble.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["Dismiss PiP"].exists)
        capture(app, "PiP first Queue selection hint")
        bubble.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(bubble.waitForNonExistence(timeout: 2))
        selectWorkspaceTab("Download", in: app)
        selectWorkspaceTab("Queue", in: app)
        XCTAssertFalse(bubble.exists)
        selectWorkspaceTab("History", in: app)
        XCTAssertTrue(bubble.waitForExistence(timeout: 3))
        capture(app, "PiP first History selection hint")
        bubble.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(bubble.waitForNonExistence(timeout: 2))
        selectWorkspaceTab("Download", in: app)
        selectWorkspaceTab("History", in: app)
        XCTAssertFalse(bubble.exists)
    }

    func testIconPickerAndAboutShowVersionOnly() {
        let app = launch()
        openInterface(app)
        for _ in 0..<5 where !app.buttons["interface.icon.blue"].isHittable { app.swipeUp() }
        for color in ["blue", "orange", "purple", "pink"] {
            XCTAssertTrue(app.buttons["interface.icon.\(color)"].exists)
        }
        capture(app, "Interface app icon choices light")
        for color in ["purple", "blue"] {
            let choice = app.buttons["interface.icon.\(color)"]
            choice.tap()
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            for owner in [app, springboard] {
                let alert = owner.alerts.firstMatch
                if alert.waitForExistence(timeout: 1) {
                    XCTAssertFalse(alert.label.contains("Couldn’t change"))
                    if alert.buttons["OK"].exists { alert.buttons["OK"].tap() }
                }
            }
            let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Selected"), object: choice)
            XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 4), .completed)
        }
        selectWorkspaceTab("Settings", in: app)
        let about = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "About & licenses")).firstMatch
        for _ in 0..<5 where !about.isHittable { app.swipeUp() }
        about.tap()
        XCTAssertTrue(app.staticTexts["1.0.1"].waitForExistence(timeout: 4))
        XCTAssertFalse(app.staticTexts["Build"].exists)
        XCTAssertFalse(app.staticTexts["Build characteristics"].exists)
        capture(app, "About version 1.0.1 without build details")
    }
}
