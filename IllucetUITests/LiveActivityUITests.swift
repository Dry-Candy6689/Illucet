import XCTest

@MainActor
final class LiveActivityUITests: XCTestCase {
    func testSystemActivityShowsOpeningAndFailureInsteadOfFrozenProgress() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--live-activity-proof"]
        app.launchEnvironment["ILLUCET_LIVE_ACTIVITY_PROOF"] = "1"
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["activityProof.start"].waitForExistence(timeout: 15))
        app.buttons["activityProof.start"].tap()
        XCTAssertTrue(app.staticTexts["System activity started"].waitForExistence(timeout: 10))
        for (button, status, text) in [("activityProof.handoff", "System activity needs opening", "Open Illucet to continue"),
                                       ("activityProof.failed", "System activity failed", "Download failed")] {
            let control = app.buttons[button]
            let hittable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: control)
            XCTAssertEqual(XCTWaiter.wait(for: [hittable], timeout: 10), .completed)
            control.tap()
            XCTAssertTrue(app.staticTexts[status].waitForExistence(timeout: 10))
            XCUIDevice.shared.press(.home)
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            XCTAssertTrue(springboard.wait(for: .runningForeground, timeout: 10))
            Thread.sleep(forTimeInterval: 2)
            let island = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            island.name = status + " Island"; island.lifetime = .keepAlways; add(island)
            springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.01))
                .press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.8)))
            XCTAssertTrue(springboard.staticTexts[text].waitForExistence(timeout: 10))
            let lock = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            lock.name = status + " Lock Screen"; lock.lifetime = .keepAlways; add(lock)
            if springboard.buttons["Allow"].exists { springboard.buttons["Allow"].tap() }
            XCUIDevice.shared.press(.home)
            app.activate()
        }
        let end = app.buttons["activityProof.end"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isHittable == true"), object: end)], timeout: 10), .completed)
        end.tap()
        XCTAssertTrue(app.staticTexts["System activity ended"].waitForExistence(timeout: 5))
    }

    func testSystemActivityStartsUpdatesAndEnds() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--live-activity-proof"]
        app.launchEnvironment["ILLUCET_LIVE_ACTIVITY_PROOF"] = "1"
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["activityProof.start"].waitForExistence(timeout: 15))
        app.buttons["activityProof.start"].tap()
        XCTAssertTrue(app.staticTexts["System activity started"].waitForExistence(timeout: 10))
        app.buttons["activityProof.processing"].tap()
        XCTAssertTrue(app.staticTexts["System activity updated"].waitForExistence(timeout: 10))
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(XCUIApplication(bundleIdentifier: "com.apple.springboard").wait(for: .runningForeground, timeout: 10))
        // Let the system's Home transition finish before capturing the activity.
        Thread.sleep(forTimeInterval: 2)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Simulator Dynamic Island activity"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.01))
            .press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.8)))
        Thread.sleep(forTimeInterval: 1)
        let notificationCenter = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        notificationCenter.name = "Simulator Notification Center live activity"
        notificationCenter.lifetime = .keepAlways
        add(notificationCenter)
        XCTAssertFalse(springboard.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Updated '")).firstMatch.exists)
        app.activate()
        let end = app.buttons["activityProof.end"]
        let hittable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: end)
        XCTAssertEqual(XCTWaiter.wait(for: [hittable], timeout: 10), .completed)
        end.tap()
        XCTAssertTrue(app.staticTexts["System activity ended"].waitForExistence(timeout: 5))
    }
}
