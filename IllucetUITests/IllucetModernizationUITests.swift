import XCTest

@MainActor
final class IllucetModernizationUITests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
        try super.tearDownWithError()
    }

    func testLightAndDarkAppearanceKeepNavigationAndAnalysisUsable() {
        let app = XCUIApplication()
        for appearance in ["Light", "Dark"] {
            app.launchArguments = ["--ui-testing"]
            app.launch()
            XCTAssertTrue(waitForWorkspaceGeometry(app, portrait: true))
            XCTAssertTrue(waitForWorkspaceShell(app))
            selectWorkspaceTab("Settings", in: app)
            if !app.navigationBars["Interface"].exists {
                let appearanceRow = scrollUntilHittable(
                    "Interface", type: .staticText, in: app
                )
                appearanceRow.tap()
            }
            let theme = app.segmentedControls.buttons[appearance]
            XCTAssertTrue(theme.waitForExistence(timeout: 3))
            theme.tap()
            XCTAssertTrue(theme.isSelected)
            attachWorkspaceScreenshot(app, named: "Appearance-\(appearance)")

            selectWorkspaceTab("Download", in: app)
            let analyze = scrollUntilHittable("download.analyze", in: app)
            XCTAssertTrue(analyze.isEnabled)
            attachWorkspaceScreenshot(app, named: "Download-\(appearance)")
            analyze.tap()
            XCTAssertTrue(app.otherElements["metadata.sheet"].waitForExistence(timeout: 6))
            let configure = scrollUntilHittable("metadata.configure", in: app)
            XCTAssertTrue(configure.isEnabled)
            attachWorkspaceScreenshot(app, named: "Metadata-\(appearance)")
            app.buttons["metadata.close"].tap()
            XCTAssertTrue(app.otherElements["metadata.sheet"].waitForNonExistence(timeout: 3))

            selectWorkspaceTab("Queue", in: app)
            XCTAssertTrue(app.navigationBars["Queue"].waitForExistence(timeout: 3))
            selectWorkspaceTab("History", in: app)
            XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 3))
            app.terminate()
        }
    }

    func testLargestAccessibilityTextKeepsAnalysisAndDownloadOptionsReachable() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing",
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXXL",
        ]
        app.launch()
        XCTAssertTrue(waitForWorkspaceGeometry(app, portrait: true))
        XCTAssertTrue(waitForWorkspaceShell(app))
        let analyze = scrollUntilHittable("download.analyze", in: app)
        XCTAssertTrue(analyze.isEnabled)
        attachWorkspaceScreenshot(app, named: "Download-AccessibilityXXXL")
        analyze.tap()
        XCTAssertTrue(app.otherElements["metadata.sheet"].waitForExistence(timeout: 6))
        let configure = scrollUntilHittable("metadata.configure", in: app)
        configure.tap()
        XCTAssertTrue(app.otherElements["configuration.sheet"].waitForExistence(timeout: 4))

        scrollUntilHittable("configuration.output", in: app).tap()
        let audio = scrollUntilHittable("configuration.mode.Audio Only", in: app)
        audio.tap()
        let review = scrollUntilHittable(
            "configuration.review", in: app, maximumSwipes: 40
        )
        XCTAssertTrue(review.isEnabled)
        attachWorkspaceScreenshot(app, named: "Configuration-AccessibilityXXXL")
        review.tap()
        XCTAssertTrue(app.otherElements["confirmation.sheet"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "Audio Only"
        )).firstMatch.exists)
    }

    func testRotationPreservesInputAndAdaptiveNavigation() {
        verifyRotation(.landscapeLeft)
    }

    func testRightRotationPreservesInputAndAdaptiveNavigation() {
        verifyRotation(.landscapeRight)
    }

    private func verifyRotation(_ orientation: UIDeviceOrientation) {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(waitForWorkspaceGeometry(app, portrait: true))
        XCTAssertTrue(waitForWorkspaceShell(app))
        let field = scrollUntilHittable("download.urlField", type: .textField, in: app)
        let initialValue = field.value as? String
        XCTAssertTrue(initialValue?.contains("https://") == true)

        XCUIDevice.shared.orientation = orientation
        XCTAssertTrue(waitForWorkspaceGeometry(app, portrait: false))
        selectWorkspaceTab("Queue", in: app)
        XCTAssertTrue(app.navigationBars["Queue"].waitForExistence(timeout: 3))
        selectWorkspaceTab("History", in: app)
        XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 3))
        selectWorkspaceTab("Download", in: app)
        let rotatedField = scrollUntilHittable(
            "download.urlField", type: .textField, in: app, initiallyScrollDown: true
        )
        XCTAssertEqual(rotatedField.value as? String, initialValue)
        rotatedField.tap()
        rotatedField.typeText("&rotation=1")
        XCTAssertTrue((rotatedField.value as? String)?.contains("&rotation=1") == true)
        let unusedSpace = app.descendants(matching: .any).matching(
            identifier: "download.unusedSpace"
        ).firstMatch
        tapUnusedWorkspaceSpace(unusedSpace, in: app)
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3))
        scrollUntilHittable("download.analyze", in: app)
        attachWorkspaceScreenshot(app, named: "Download-Landscape")

        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(waitForWorkspaceGeometry(app, portrait: true))
        selectWorkspaceTab("Settings", in: app)
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 3))
    }
}
