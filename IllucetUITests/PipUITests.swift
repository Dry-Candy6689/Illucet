import XCTest
import UIKit

@MainActor
final class PipUITests: XCTestCase {
    private func launchGuide(large: Bool = false, dark: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-screen=onboarding", "--pip-fast-text", "--ui-polish-reset", "--ui-empty-state"]
        if dark { app.launchArguments.append("--ui-dark-appearance") }
        else { app.launchArguments.append("--ui-light-appearance") }
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"] }
        app.launch()
        let found = app.buttons["pip.skip"].waitForExistence(timeout: 10)
        if !found { print(app.debugDescription) }
        XCTAssertTrue(found)
        return app
    }

    private func advance(_ app: XCUIApplication) {
        let dialogue = app.staticTexts["pip.dialogue"]
        XCTAssertTrue(dialogue.waitForExistence(timeout: 4))
        dialogue.tap()
    }

    private func openPipSettings(_ app: XCUIApplication) {
        selectWorkspaceTab("Settings", in: app)
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 4))
        let link = app.buttons["settings.pip"]
        for _ in 0..<5 {
            if link.exists && link.isHittable { break }
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.40))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        if !link.exists { print(app.debugDescription) }
        XCTAssertTrue(link.waitForExistence(timeout: 3))
        link.tap()
    }

    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func brightness(_ image: UIImage) -> Double {
        guard let source = image.cgImage else { XCTFail("Missing screenshot pixels"); return 0 }
        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.interpolationQuality = .high
            context.draw(source, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return Double(Int(pixel[0]) + Int(pixel[1]) + Int(pixel[2])) / 765
    }

    private func launchFirstDownloadHint(extra: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-screen=pip-first-download", "--pip-fast-text",
            "--ui-polish-reset", "--ui-empty-state", "--ui-light-appearance"] + extra
        app.launch()
        return app
    }

    func testGuideVisitsRealPagesAndReturnsToDownloads() {
        let app = launchGuide()
        XCTAssertTrue(app.staticTexts["pip.dialogue"].label.contains("Welcome to Illucet"))
        screenshot(app, "PiP welcome")
        advance(app)
        XCTAssertTrue(app.staticTexts["pip.dialogue"].label.contains("Paste a video"))
        screenshot(app, "PiP link spotlight")
        advance(app)
        XCTAssertTrue(app.staticTexts["pip.dialogue"].label.contains("Quick Start"))
        screenshot(app, "PiP presets spotlight")
        advance(app)
        XCTAssertTrue(app.staticTexts["pip.route"].waitForExistence(timeout: 2))
        screenshot(app, "PiP shows the route to Home Quick Start")
        XCTAssertTrue(app.navigationBars["Home Quick Start"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["pip.dialogue"].waitForExistence(timeout: 3))
        screenshot(app, "PiP custom presets")
        advance(app)
        XCTAssertTrue(app.buttons["pip.notifications"].waitForExistence(timeout: 4))
        screenshot(app, "PiP notification spotlight")
        advance(app)
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons.matching(identifier: "pip.mascot").matching(NSPredicate(format: "value == %@", "Looking up")).firstMatch.waitForExistence(timeout: 4))
        screenshot(app, "PiP looks up at Appearance")
        advance(app)
        XCTAssertTrue(app.navigationBars["Interface"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons.matching(identifier: "pip.mascot").matching(NSPredicate(format: "value == %@", "Looking down")).firstMatch.waitForExistence(timeout: 4))
        screenshot(app, "PiP appearance spotlight")
        advance(app)
        XCTAssertTrue(app.navigationBars["PiP"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["pip.dialogue"].waitForExistence(timeout: 3))
        screenshot(app, "PiP activity settings spotlight")
        advance(app)
        XCTAssertTrue(app.staticTexts["pip.dialogue"].label.contains("All set"))
        screenshot(app, "PiP final message")
        advance(app)
        XCTAssertTrue(app.buttons["pip.skip"].waitForNonExistence(timeout: 4))
        // No input after the final message: allow the fade to finish by itself.
        Thread.sleep(forTimeInterval: 0.7)
        XCTAssertTrue(app.navigationBars["Illucet"].exists)
        XCTAssertTrue(app.staticTexts["download.hero"].isHittable)
        screenshot(app, "Guide returns visibly to Download without another tap")
        XCTAssertGreaterThan(brightness(app.staticTexts["download.hero"].screenshot().image), 0.35,
            "The light Download page must be visible, rather than an opaque exit cover")
    }

    func testSkipFromSettingsFadesBackToDownload() {
        let app = launchGuide(dark: true)
        for _ in 0..<6 { advance(app) }
        XCTAssertTrue(app.navigationBars["Interface"].waitForExistence(timeout: 4))
        app.buttons["pip.skip"].tap()
        XCTAssertTrue(app.buttons["pip.skip"].waitForNonExistence(timeout: 4))
        XCTAssertTrue(app.navigationBars["Illucet"].exists)
        XCTAssertTrue(app.staticTexts["download.hero"].isHittable)
        screenshot(app, "PiP skipped back to downloads")
    }

    func testSkipDuringSettingsRouteCancelsPendingNavigation() {
        let app = launchGuide()
        advance(app); advance(app); advance(app)
        XCTAssertTrue(app.staticTexts["pip.route"].waitForExistence(timeout: 2))
        app.buttons["pip.skip"].tap()
        XCTAssertTrue(app.buttons["pip.skip"].waitForNonExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["download.hero"].isHittable)
        XCTAssertFalse(app.navigationBars["Home Quick Start"].waitForExistence(timeout: 2))
    }

    func testPipSettingsPortraitReactsToRepeatedTaps() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-polish-reset", "--ui-empty-state", "--ui-light-appearance"]
        app.launch()
        openPipSettings(app)
        let portrait = app.buttons["pip.settingsPortrait"]
        XCTAssertTrue(portrait.waitForExistence(timeout: 4))
        let originalFrame = portrait.frame
        for reaction in ["Happy", "Shy", "Waving", "Side-eye"] {
            portrait.tap()
            XCTAssertEqual(portrait.value as? String, reaction)
            XCTAssertEqual(portrait.frame, originalFrame, "Animation must not move the button or surrounding settings.")
        }
        let relaxed = NSPredicate(format: "value == %@", "Relaxed")
        expectation(for: relaxed, evaluatedWith: portrait)
        waitForExpectations(timeout: 4)
        screenshot(app, "PiP reacts in settings")
    }

    func testPipSettingsReactionRespectsReducedMotionAndLeavingPage() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-polish-reset", "--ui-empty-state",
                               "--ui-dark-appearance", "--ui-reduce-motion"]
        app.launch()
        openPipSettings(app)
        let portrait = app.buttons["pip.settingsPortrait"]
        XCTAssertTrue(portrait.waitForExistence(timeout: 4))
        portrait.tap()
        XCTAssertEqual(portrait.value as? String, "Happy")
        screenshot(app, "PiP reduced-motion expression")
        selectWorkspaceTab("Download", in: app)
        selectWorkspaceTab("Settings", in: app)
        XCTAssertTrue(portrait.waitForExistence(timeout: 4))
        XCTAssertEqual(portrait.value as? String, "Relaxed")
    }

    func testDisableAppealOnlyOnceAndReplayDoesNotEnableCompanion() {
        let app = launchGuide()
        app.buttons["pip.skip"].tap()
        XCTAssertTrue(app.buttons["pip.skip"].waitForNonExistence(timeout: 4))
        openPipSettings(app)
        let enabled = app.switches["pip.enabled"]
        XCTAssertTrue(enabled.waitForExistence(timeout: 4))
        XCTAssertEqual(enabled.value as? String, "1")
        enabled.switches.firstMatch.tap()
        XCTAssertTrue(app.buttons["pip.turnOff"].waitForExistence(timeout: 3))
        screenshot(app, "PiP puppy-eyed appeal")
        app.buttons["Keep PiP"].tap()
        XCTAssertTrue(app.buttons["pip.turnOff"].waitForNonExistence(timeout: 3))
        XCTAssertEqual(enabled.value as? String, "1")
        enabled.switches.firstMatch.tap()
        XCTAssertTrue(app.buttons["pip.turnOff"].waitForExistence(timeout: 3))
        app.buttons["pip.turnOff"].tap()
        XCTAssertTrue(app.buttons["pip.turnOff"].waitForNonExistence(timeout: 3))
        XCTAssertEqual(enabled.value as? String, "0")
        app.buttons["pip.replay"].tap()
        XCTAssertTrue(app.buttons["pip.skip"].waitForExistence(timeout: 3))
        app.buttons["pip.skip"].tap()
        XCTAssertTrue(app.buttons["pip.skip"].waitForNonExistence(timeout: 4))
        openPipSettings(app)
        XCTAssertEqual(enabled.value as? String, "0")
        enabled.switches.firstMatch.tap()
        enabled.switches.firstMatch.tap()
        XCTAssertFalse(app.buttons["pip.turnOff"].exists)
        XCTAssertEqual(enabled.value as? String, "0")
    }

    func testLargeTextGuideCanAlwaysSkip() {
        let app = launchGuide(large: true, dark: true)
        XCTAssertTrue(app.buttons["pip.skip"].isHittable)
        screenshot(app, "PiP large text")
        app.buttons["pip.skip"].tap()
        XCTAssertTrue(app.buttons["pip.skip"].waitForNonExistence(timeout: 4))
    }

    func testSkipFromPresetsReturnsToTheActualPageTop() {
        let app = launchGuide()
        advance(app); advance(app)
        XCTAssertTrue(app.staticTexts["pip.dialogue"].label.contains("Quick Start"))
        app.buttons["pip.skip"].tap()
        XCTAssertTrue(app.buttons["pip.skip"].waitForNonExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["download.hero"].isHittable)
        screenshot(app, "PiP skips presets back to true top")
    }

    func testFirstDownloadTipIsPipAndLinksToHighlightedScreenSettings() {
        let app = launchFirstDownloadHint()
        XCTAssertTrue(app.buttons["pip.downloadSettings"].waitForExistence(timeout: 16))
        screenshot(app, "PiP first-download hint")
        app.buttons["pip.downloadSettings"].tap()
        XCTAssertTrue(app.navigationBars["Shortcuts"].waitForExistence(timeout: 4))
        let highlighted = brightness(app.switches["flow.skipDetails"].screenshot().image)
        XCTAssertTrue(app.switches["flow.skipDetails"].isHittable)
        XCTAssertTrue(app.switches["flow.skipReview"].isHittable)
        screenshot(app, "PiP highlights both download-screen switches")
        Thread.sleep(forTimeInterval: 3.5)
        screenshot(app, "PiP setting highlight has faded away")
        XCTAssertGreaterThan(brightness(app.switches["flow.skipDetails"].screenshot().image), highlighted + 0.025,
            "The temporary tint must fade back to the normal row background")
    }

    func testFirstDownloadHintDoesNotAppearWhenBothSkipSettingsAreAlreadyOn() {
        let app = launchFirstDownloadHint(extra: ["--ui-skip-details", "--ui-skip-review"])
        XCTAssertFalse(app.buttons["pip.downloadSettings"].waitForExistence(timeout: 13))
        app.buttons["navigation.settings"].tap()
        let shortcuts = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Shortcuts")).firstMatch
        for _ in 0..<5 where !shortcuts.isHittable { app.swipeUp() }
        XCTAssertTrue(shortcuts.waitForExistence(timeout: 4)); shortcuts.tap()
        XCTAssertEqual(app.switches["flow.skipDetails"].value as? String, "1")
        XCTAssertEqual(app.switches["flow.skipReview"].value as? String, "1")
        screenshot(app, "Both Skip settings enabled without a redundant PiP hint")
    }

    func testActivityOffersTwoDescriptiveChoicesAndOffUsesTheToggle() {
        let app = launchGuide()
        app.buttons["pip.skip"].tap()
        XCTAssertTrue(app.buttons["pip.skip"].waitForNonExistence(timeout: 4))
        openPipSettings(app)
        app.buttons["pip.frequency"].tap()
        XCTAssertTrue(app.buttons["Occasional tips"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Tips & download updates"].exists)
        XCTAssertFalse(app.buttons["Never"].exists)
        XCTAssertFalse(app.buttons["Medium"].exists)
        XCTAssertFalse(app.buttons["Often"].exists)
        screenshot(app, "PiP activity choices without a duplicate off option")
        app.buttons["Tips & download updates"].tap()
        app.switches["pip.enabled"].switches.firstMatch.tap()
        XCTAssertTrue(app.buttons["pip.turnOff"].waitForExistence(timeout: 3))
        app.buttons["pip.turnOff"].tap()
        XCTAssertTrue(app.buttons["pip.turnOff"].waitForNonExistence(timeout: 3))
        XCTAssertFalse(app.buttons["pip.frequency"].isEnabled)
        XCTAssertTrue(app.buttons["pip.replay"].isEnabled)
    }
}
