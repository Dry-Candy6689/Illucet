import XCTest
import UIKit

@MainActor
final class SharingAndCreatorUITests: XCTestCase {
    func testShortcutHandoffOpensOptionsAfterDismissingChoice() {
        let app = launch("--ui-screen=shortcut-handoff")
        XCTAssertTrue(app.buttons["Open download options"].waitForExistence(timeout: 5))
        app.buttons["Open download options"].tap()
        XCTAssertTrue(app.navigationBars["Download options"].waitForExistence(timeout: 5))
        screenshot("Shortcut foreground options", app)
    }

    func testLegacySharedLinkChoiceAndShortcutSettings() {
        let app = launch("--ui-screen=shared-link-choice")
        let remember = app.switches["sharing.rememberChoice"]
        XCTAssertTrue(remember.waitForExistence(timeout: 5))
        XCTAssertEqual(remember.value as? String, "1")
        screenshot("Remember shared link action", app)
        app.buttons["Open Home with URL filled"].tap()
        XCTAssertTrue(remember.waitForNonExistence(timeout: 5))
        selectWorkspaceTab("Settings", in: app)
        XCTAssertFalse(app.buttons["Privacy & diagnostics"].exists)
        app.buttons["Shortcuts"].tap()
        XCTAssertFalse(app.switches["shortcuts.background"].exists)
        screenshot("Shortcuts settings", app)
        XCTAssertTrue(app.descendants(matching: .any)["shortcuts.install"].exists)
        XCTAssertTrue(app.staticTexts["Show download options"].exists)
        screenshot("Shortcuts settings preserve legacy review choice", app)
    }

    func testClipboardSettingsRequireExplanationBeforeEnabling() {
        let app = launch("--ui-clipboard-unexplained")
        selectWorkspaceTab("Settings", in: app)
        let link = app.buttons["App opening & clipboard"]
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        link.tap()
        let toggle = app.switches["Check copied links automatically"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "0")
        toggle.switches.firstMatch.tap()
        XCTAssertTrue(app.alerts["Allow automatic clipboard checks?"].waitForExistence(timeout: 3))
        app.alerts.buttons["Keep off"].tap()
        XCTAssertEqual(toggle.value as? String, "0")
        let replace = app.switches["clipboard.replace"]
        XCTAssertTrue(replace.exists)
        XCTAssertFalse(replace.isEnabled)
        toggle.switches.firstMatch.tap()
        app.alerts.buttons["Enable checks"].tap()
        XCTAssertEqual(replace.value as? String, "1")
        XCTAssertTrue(replace.isEnabled)
        XCTAssertFalse(app.buttons["Check clipboard now"].exists)
        screenshot("Part 13 clipboard settings", app)
    }

    func testBulkHistorySeparatesRecordAndFileRemoval() {
        let app = launch("--ui-screen=subtitles-output-truth")
        selectWorkspaceTab("History", in: app)
        let record = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "history.record.")).firstMatch
        XCTAssertTrue(record.waitForExistence(timeout: 4))
        record.press(forDuration: 0.6)
        XCTAssertTrue(app.buttons["selection.selectAll"].waitForExistence(timeout: 5))
        app.buttons["selection.selectAll"].tap()
        app.buttons["selection.delete"].tap()
        XCTAssertTrue(app.buttons["Remove records"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Delete files and records"].exists)
        if app.buttons["Cancel"].exists { app.buttons["Cancel"].tap() }
        else { app.otherElements["PopoverDismissRegion"].firstMatch.tap() }
        XCTAssertTrue(app.buttons["Remove records"].waitForNonExistence(timeout: 3))
        screenshot("Part 13 History selection", app)
    }

    func testCollectionSearchNarrowsLoadedInventory() {
        let app = launch("--ui-screen=playlist")
        let search = app.textFields["collection.search"]
        for _ in 0..<5 where !search.isHittable { app.swipeUp() }
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("no-matching-title-123")
        XCTAssertTrue(app.buttons["collection.selectMatches"].label.contains("0"))
        screenshot("Part 13 collection search", app)
    }

    func testExtraFilesAndNetworkControlsRemainEditable() {
        let app = launch("--ui-screen=configuration")
        scrollUntilHittable("configuration.network", in: app).tap()
        let charging = app.switches["Start when charging"]
        for _ in 0..<8 where !charging.isHittable { app.swipeUp() }
        XCTAssertTrue(charging.isHittable)
        charging.switches.firstMatch.tap()
        XCTAssertEqual(charging.value as? String, "1")
        scrollUntilHittable("configuration.network", in: app, initiallyScrollDown: true).tap()
        XCTAssertTrue(app.staticTexts["When charging"].exists)
        XCTAssertTrue(charging.waitForNonExistence(timeout: 4))
        scrollUntilHittable("configuration.extraFiles", in: app).tap()
        let checksum = app.switches["SHA-256 checksum"]
        for _ in 0..<12 where !checksum.isHittable { app.swipeUp() }
        XCTAssertTrue(checksum.isHittable)
        let control = checksum.switches.firstMatch
        if control.exists { control.tap() } else { checksum.tap() }
        XCTAssertEqual(checksum.value as? String, "1")
        screenshot("Extra files and collapsed network conditions", app)
    }

    private func launch(_ extra: String? = nil) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"] + (extra.map { [$0] } ?? [])
        // Migration starts without native Shortcut preferences left by another fixture.
        if extra == "--ui-screen=shared-link-choice" { app.launchArguments.append("--ui-polish-reset") }
        if UIDevice.current.userInterfaceIdiom == .pad { app.launchArguments.append("--ui-light-appearance") }
        app.launch()
        XCTAssertTrue(waitForWorkspaceShell(app, timeout: 15))
        return app
    }
    private func screenshot(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
