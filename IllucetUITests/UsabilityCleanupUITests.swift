import XCTest

@MainActor
final class UsabilityCleanupUITests: XCTestCase {
    func testQueueChronologicalSortInLightMode() { checkQueueChronologicalSort(dark: false) }
    func testQueueChronologicalSortInDarkMode() { checkQueueChronologicalSort(dark: true) }

    private func checkQueueChronologicalSort(dark: Bool) {
        let app = launch(["--ui-screen=queue-completed-details",
            dark ? "--ui-dark-appearance" : "--ui-light-appearance"])
        let sort = app.buttons["queue.sort"]
        XCTAssertTrue(sort.waitForExistence(timeout: 4))
        sort.tap()
        app.buttons["Newest first"].tap()
        let cards = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier MATCHES %@", "queue.job.[A-Fa-f0-9-]{36}"))
        XCTAssertEqual(cards.count, 2)
        let firstID = cards.element(boundBy: 0).identifier
        let secondID = cards.element(boundBy: 1).identifier
        let firstY = app.descendants(matching: .any)[firstID].frame.minY
        let secondY = app.descendants(matching: .any)[secondID].frame.minY
        XCTAssertLessThan(firstY, secondY)
        capture("Queue newest first \(dark ? "dark" : "light")", app)
        sort.tap()
        app.buttons["Oldest first"].tap()
        XCTAssertGreaterThan(app.descendants(matching: .any)[firstID].frame.minY,
                             app.descendants(matching: .any)[secondID].frame.minY)
        capture("Queue oldest first \(dark ? "dark" : "light")", app)
        app.terminate()
        app.launch()
        XCTAssertTrue(waitForWorkspaceShell(app, timeout: 15))
        XCTAssertEqual(sort.value as? String, "Oldest first")
        sort.tap()
        XCTAssertFalse(app.buttons["Queue priority"].exists)
        app.buttons["Newest first"].tap()
    }

    func testSimplifiedStartingSettingsInLightMode() { checkSimplifiedStartingSettings(dark: false) }
    func testSimplifiedStartingSettingsInDarkMode() { checkSimplifiedStartingSettings(dark: true) }

    private func checkSimplifiedStartingSettings(dark: Bool) {
        let app = launch([dark ? "--ui-dark-appearance" : "--ui-light-appearance", "--ui-reduce-motion"])
        selectWorkspaceTab("Settings", in: app)
        XCTAssertFalse(app.buttons["Download flow"].exists)
        tap(app.buttons["Home Quick Start"], in: app)
        XCTAssertTrue(app.navigationBars["Home Quick Start"].waitForExistence(timeout: 4))
        XCTAssertFalse(app.navigationBars.buttons["Edit"].exists)
        XCTAssertFalse(app.buttons["Open iOS paste settings"].exists)
        XCTAssertFalse(app.buttons["Download flow & instant Quick Start"].exists)
        XCTAssertFalse(app.staticTexts["Uses the entered link, or a copied link if the field is empty."].exists)
        let immediate = app.switches["flow.instantQuickStart"]
        XCTAssertFalse(immediate.exists)
        let presets = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "quick.settings.preset."))
        XCTAssertGreaterThanOrEqual(presets.count, 4)
        let first = presets.element(boundBy: 0), second = presets.element(boundBy: 1)
        let firstID = first.identifier, secondID = second.identifier
        first.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5))
            .press(forDuration: 1.1,
                   thenDragTo: second.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.85)),
                   withVelocity: .slow, thenHoldForDuration: 1)
        XCTAssertGreaterThan(app.buttons[firstID].frame.minY, app.buttons[secondID].frame.minY)
        capture("Inline movable Home Quick Start presets \(dark ? "dark" : "light")", app)

        selectWorkspaceTab("Settings", in: app)
        tap(app.buttons["Shortcuts"], in: app)
        XCTAssertTrue(app.navigationBars["Shortcuts"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.descendants(matching: .any)["shortcuts.install"].exists)
        XCTAssertTrue(app.links["Get Illucet shortcut"].exists || app.buttons["Get Illucet shortcut"].exists)
        XCTAssertFalse(app.staticTexts["Use from the share sheet"].exists)
        for id in ["flow.skipDetails", "flow.skipReview"] {
            let toggle = app.switches[id]
            XCTAssertTrue(toggle.exists)
            toggle.switches.firstMatch.tap()
            XCTAssertEqual(toggle.value as? String, "1")
        }
        tap(app.buttons["flow.defaults"], in: app)
        XCTAssertEqual(app.alerts.count, 0)
        XCTAssertEqual(app.switches["flow.skipDetails"].value as? String, "0")
        XCTAssertEqual(app.switches["flow.skipReview"].value as? String, "0")
        capture("Shortcuts with download screen controls \(dark ? "dark" : "light")", app)
        app.buttons["shortcuts.info"].tap()
        XCTAssertTrue(app.navigationBars["About Shortcuts"].waitForExistence(timeout: 4))
        capture("Shortcuts essential information \(dark ? "dark" : "light")", app)
        app.buttons["Done"].tap()
        selectWorkspaceTab("Settings", in: app)
        tap(app.buttons["Home Quick Start"], in: app)
        XCTAssertFalse(app.switches["flow.instantQuickStart"].exists)
        XCTAssertGreaterThan(app.buttons[firstID].frame.minY, app.buttons[secondID].frame.minY)

        selectWorkspaceTab("Settings", in: app)
        tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Download defaults")).firstMatch, in: app)
        let thumbnail = app.buttons["settings.downloads.thumbnail"]
        for _ in 0..<10 where !thumbnail.isHittable { app.swipeUp() }
        XCTAssertTrue(thumbnail.isHittable)
        thumbnail.tap()
        app.buttons["Thumbnail only"].tap()
        let crop = app.switches["settings.downloads.squareCrop"]
        XCTAssertTrue(crop.waitForExistence(timeout: 4))
        XCTAssertEqual(crop.value as? String, "0")
        capture("Download defaults uncropped thumbnail \(dark ? "dark" : "light")", app)
        crop.switches.firstMatch.tap()
        XCTAssertEqual(crop.value as? String, "1")
    }

    func testTabBarHoldAcquiresInactiveTabAndTracksBelowBar() {
        let app = launch(["--ui-light-appearance"])
        let settings = app.buttons["navigation.settings"]
        let history = app.buttons["navigation.history"]
        let belowHistory = history.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1))
            .withOffset(CGVector(dx: 0, dy: 29))
        // Hold an inactive tab, then release below the bar in the black inset.
        settings.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.8, thenDragTo: belowHistory, withVelocity: .slow, thenHoldForDuration: 0.6)
        XCTAssertTrue(history.isSelected)
        settings.press(forDuration: 0.5)
        XCTAssertTrue(settings.isSelected)
        capture("Hold acquisition and below-bar release", app)
    }

    func testTabBarShortHoldAndImmediateDragRemainResponsive() {
        let app = launch(["--ui-light-appearance"])
        let settings = app.buttons["navigation.settings"]
        let queue = app.buttons["navigation.queue"]
        // Start moving while the acquisition animation is still in flight.
        settings.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.06, thenDragTo: queue.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)),
                   withVelocity: .fast, thenHoldForDuration: 0.15)
        XCTAssertTrue(queue.isSelected)
        settings.tap()
        XCTAssertTrue(settings.isSelected)
        capture("Short acquisition followed by immediate drag and tap", app)
    }

    func testStoragePullToRefreshAndCleanupFeedback() {
        let app = launch(["--ui-light-appearance"])
        selectWorkspaceTab("Settings", in: app)
        tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Storage")).firstMatch, in: app)
        XCTAssertFalse(app.buttons["storage.refresh"].exists)
        XCTAssertTrue(app.staticTexts["Illucet documents"].exists)
        XCTAssertTrue(app.staticTexts["Temporary files"].exists)
        XCTAssertFalse(app.staticTexts["Other documents"].exists)
        XCTAssertFalse(app.staticTexts["Other temporary files"].exists)
        let stamp = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "storage.usage.")).firstMatch
        XCTAssertTrue(stamp.waitForExistence(timeout: 5))
        for _ in 0..<2 {
            let old = stamp.identifier
            Thread.sleep(forTimeInterval: 2)
            let start = stamp.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 400)),
                withVelocity: .slow, thenHoldForDuration: 0.5)
            let changed = NSPredicate { _, _ in stamp.identifier != old }
            expectation(for: changed, evaluatedWith: stamp)
            waitForExpectations(timeout: 5)
        }
        XCTAssertFalse(app.staticTexts["Last refreshed"].exists)
        let clear = app.buttons["storage.clearLogs"]
        XCTAssertLessThan(clear.frame.height, 60)
        tap(clear, in: app)
        XCTAssertTrue(app.staticTexts["Cleared"].waitForExistence(timeout: 3))
        Thread.sleep(forTimeInterval: 3)
        clear.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()
        XCTAssertTrue(app.staticTexts["Cleared"].waitForExistence(timeout: 3))
        capture("Storage clear feedback after idle", app)
        let delete = app.buttons["storage.deleteFiles"]
        tap(delete, in: app)
        XCTAssertTrue(app.buttons["Delete files"].waitForExistence(timeout: 3))
        capture("Storage deletion confirmation", app)
        if app.buttons["Cancel"].exists { app.buttons["Cancel"].tap() }
        else { app.navigationBars["Storage"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        app.swipeUp()
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "security-scoped bookmark")).firstMatch.exists)
    }

    func testStorageCleanupDarkAppearance() {
        let app = launch(["--ui-dark-appearance", "--ui-empty-state"])
        selectWorkspaceTab("Settings", in: app)
        tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Storage")).firstMatch, in: app)
        XCTAssertFalse(app.buttons["storage.refresh"].exists)
        let stamp = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "storage.usage.")).firstMatch
        let old = stamp.identifier
        Thread.sleep(forTimeInterval: 2)
        let start = stamp.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: app.frame.width > 600 ? 600 : 400)),
                withVelocity: .slow, thenHoldForDuration: 0.5)
        expectation(for: NSPredicate { _, _ in stamp.identifier != old }, evaluatedWith: stamp)
        waitForExpectations(timeout: 5)
        capture("Storage compact controls dark", app)
        tap(app.buttons["storage.deleteFiles"], in: app)
        XCTAssertTrue(app.buttons["Delete files"].waitForExistence(timeout: 3))
        capture("Storage delete confirmation dark", app)
        if app.buttons["Cancel"].exists { app.buttons["Cancel"].tap() }
        else { app.navigationBars["Storage"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
    }

    func testBlackAndWhiteAccentPreviewsInBothDensities() {
        for (color, appearance) in [("black", "dark"), ("white", "light")] {
            let app = launch(["--ui-\(appearance)-appearance", "--ui-accent=\(color)", "--ui-oled"])
            selectWorkspaceTab("Settings", in: app)
            tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Interface")).firstMatch, in: app)
            let firstPreview = app.descendants(matching: .any)["appearance.cardPreview"].firstMatch
            XCTAssertTrue(firstPreview.isHittable)
            XCTAssertLessThan(firstPreview.frame.minY, app.segmentedControls["appearance.cardDensity"].frame.minY)
            for density in ["Compact", "Comfortable"] {
                let control = app.segmentedControls["appearance.cardDensity"].buttons[density]
                for _ in 0..<4 where !control.isHittable { app.swipeDown() }
                control.tap()
                let preview = app.descendants(matching: .any)["appearance.cardPreview"].firstMatch
                for _ in 0..<5 where !preview.isHittable { app.swipeUp() }
                XCTAssertTrue(preview.isHittable)
                XCTAssertEqual(preview.value as? String, density)
                capture("\(color) accent \(appearance) \(density)", app)
            }
            app.terminate()
        }
    }

    func testAppearanceColorPickerAndOLED() {
        let app = launch(["--ui-dark-appearance"])
        selectWorkspaceTab("Settings", in: app)
        tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Interface")).firstMatch, in: app)
        XCTAssertFalse(app.switches["Reduce motion"].exists)
        let oled = app.switches["appearance.oled"]
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "OLED uses a pure black")).firstMatch.exists)
        XCTAssertTrue(oled.waitForExistence(timeout: 5))
        for _ in 0..<4 {
            let tabBarTop = app.buttons["navigation.settings"].frame.minY
            if oled.isHittable && oled.frame.maxY < tabBarTop - 12 { break }
            app.swipeUp()
        }
        oled.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertEqual(oled.value as? String, "1")
        let color = app.descendants(matching: .any)["appearance.accent"].firstMatch
        tap(color, in: app)
        XCTAssertTrue(app.buttons["Sliders"].waitForExistence(timeout: 3) || app.segmentedControls.buttons["Sliders"].exists)
        capture("Native full accent picker", app)
    }

    func testCustomAccentQueueAndStreamCopyScreenshots() {
        var app = launch(["--ui-screen=queue-output-cleanup", "--ui-dark-appearance", "--ui-accent=white"])
        XCTAssertTrue(app.staticTexts["Valid WebM Fixture"].firstMatch.waitForExistence(timeout: 8))
        capture("White accent completed download bar", app)
        app.terminate()
        app = launch(["--ui-screen=configuration", "--ui-dark-appearance", "--ui-accent=white"])
        let summary = app.staticTexts["Stream copy / merge"]
        for _ in 0..<12 where !summary.isHittable { app.swipeUp() }
        XCTAssertTrue(summary.isHittable)
        capture("White accent stream copy summary", app)
    }

    func testNonMediaOutputIgnoresSponsorBlockDefaults() {
        let app = launch(["--ui-screen=sponsorblock-fast", "--ui-dark-appearance"])
        for mode in ["Subtitles Only", "Thumbnail Only"] {
            for _ in 0..<5 { app.swipeDown() }
            app.buttons["configuration.output"].tap()
            app.buttons["configuration.mode." + mode].tap()
            let review = scrollUntilHittable("configuration.review", in: app)
            XCTAssertTrue(review.isEnabled)
            XCTAssertFalse(app.staticTexts["configuration.review.unavailableReason"].exists)
            capture("\(mode) ready despite SponsorBlock defaults", app)
        }
    }

    func testHistoryReadOnlyAndConfigureExistingMissingOutput() {
        var app = launch(["--ui-screen=history-apple-unsupported", "--ui-light-appearance"])
        for _ in 0..<10 where !app.buttons["Delete history record"].isHittable { app.swipeUp() }
        XCTAssertTrue(app.buttons["Delete history record"].isHittable)
        for title in ["Share", "Open saved file", "Download again", "Copy source URL", "Delete downloaded file",
                      "Save a copy to Photos", "Reprocess saved file"] { XCTAssertFalse(app.buttons[title].exists) }
        XCTAssertFalse(app.buttons["output.section.Verified output"].exists)
        capture("History bookkeeping with only record deletion", app)
        app.terminate()
        app = launch(["--ui-screen=configure-existing-missing", "--ui-light-appearance"])
        tap(app.buttons["download.analyze"], in: app)
        XCTAssertTrue(app.buttons["configuration.output"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.alerts["File unavailable"].exists)
        capture("Configure retained URL with missing old output", app)
    }

    func testQueueOutputCleanupKeepsSharingAndFoldsDetails() {
        let app = launch(["--ui-screen=queue-output-cleanup", "--ui-dark-appearance"])
        app.staticTexts["Valid WebM Fixture"].firstMatch.tap()
        tap(app.buttons["Open output details"], in: app)
        XCTAssertTrue(app.buttons["output.share"].waitForExistence(timeout: 4))
        capture("Queue output primary share and folded information", app)
        let verified = scrollUntilHittable("output.section.Verified output", in: app)
        verified.tap()
        capture("Expanded verified output", app)
        for _ in 0..<10 where !app.buttons["Delete history record"].isHittable { app.swipeUp() }
        XCTAssertTrue(app.buttons["Delete history record"].isHittable)
        for title in ["Open saved file", "Save a copy to Photos", "Reprocess saved file", "Thumbnail"] {
            XCTAssertFalse(app.buttons[title].exists)
        }
        XCTAssertTrue(app.buttons["Delete downloaded file"].exists)
        let copy = app.buttons["output.copySource"]
        tap(copy, in: app)
        XCTAssertTrue(copy.label.contains("Copied"))
        capture("Copied source feedback", app)
        let restored = NSPredicate { _, _ in copy.label.contains("Copy source URL") }
        expectation(for: restored, evaluatedWith: copy)
        waitForExpectations(timeout: 5)
    }

    func testTechnicalDetailsFullRowAndEmbeddedThumbnailMenu() {
        checkTechnicalDetailsAndThumbnail(["--ui-light-appearance"])
    }

    func testTechnicalDetailsAndThumbnailDarkLargeText() {
        checkTechnicalDetailsAndThumbnail(["--ui-dark-appearance", "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityLarge"])
    }

    private func checkTechnicalDetailsAndThumbnail(_ arguments: [String]) {
        let app = launch(arguments + ["--ui-screen=configuration"])
        scrollUntilHittable("configuration.advanced", in: app).tap()
        let details = scrollUntilHittable("configuration.technicalDetails", in: app)
        XCTAssertGreaterThanOrEqual(details.frame.height, 48)
        details.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).tap()
        XCTAssertEqual(details.value as? String, "Expanded")
        details.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertEqual(details.value as? String, "Collapsed")
        details.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.5)).tap()
        XCTAssertEqual(details.value as? String, "Expanded")
        capture("Technical details full-row control", app)
        details.tap()
        let thumbnail = scrollUntilHittable("configuration.thumbnail.behavior", in: app)
        XCTAssertGreaterThanOrEqual(thumbnail.frame.height, 48)
        thumbnail.tap()
        XCTAssertTrue(app.buttons["Include Thumbnail"].waitForExistence(timeout: 3))
        app.buttons["Include Thumbnail"].tap()
        XCTAssertTrue(thumbnail.label.contains("Include Thumbnail"))
        capture("Embedded thumbnail with flexible row height", app)
        thumbnail.tap()
        app.buttons["Thumbnail only"].tap()
        let imageOnly = scrollUntilHittable("configuration.thumbnail.behavior", in: app)
        imageOnly.tap()
        XCTAssertTrue(app.buttons["Include Thumbnail"].isEnabled)
        app.buttons["Include Thumbnail"].tap()
        scrollUntilHittable("configuration.thumbnail.behavior", in: app).tap()
        app.buttons["Off"].tap()
    }

    func testManualClipboardPreviewStaysInSettings() {
        let app = launch(["--ui-light-appearance"])
        selectWorkspaceTab("Settings", in: app)
        tap(app.buttons["App opening & clipboard"], in: app)
        tap(app.buttons["clipboard.check"], in: app)
        XCTAssertTrue(app.staticTexts["Supported link found"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.navigationBars["App opening & clipboard"].exists)
        capture("Clipboard preview stays in Settings", app)
        tap(app.buttons["clipboard.open"], in: app)
        XCTAssertTrue(app.buttons["download.analyze"].waitForExistence(timeout: 4))
        XCTAssertFalse(app.otherElements["metadata.sheet"].exists)
    }

    func testManualClipboardReportsEmptyAndUnsupported() {
        for (kind, result) in [("empty", "clipboard.empty"), ("unsupported", "clipboard.unsupported")] {
            let app = launch(["--ui-clipboard=\(kind)", "--ui-dark-appearance"])
            selectWorkspaceTab("Settings", in: app)
            tap(app.buttons["App opening & clipboard"], in: app)
            tap(app.buttons["clipboard.check"], in: app)
            XCTAssertTrue(app.staticTexts[result].waitForExistence(timeout: 4))
            XCTAssertFalse(app.buttons["clipboard.open"].exists)
            capture("Clipboard \(kind) feedback", app)
            app.terminate()
        }
    }

    func testDuplicateMenuOpensWithAndWithoutKeyboard() {
        let app = launch(["--ui-light-appearance"])
        selectWorkspaceTab("Settings", in: app)
        tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Download defaults")).firstMatch, in: app)
        let menu = app.buttons["settings.downloads.duplicates"]
        tap(menu, in: app)
        XCTAssertTrue(app.buttons["Ask"].waitForExistence(timeout: 3))
        app.buttons["Ask"].tap()
        let filename = app.textFields["settings.downloads.filename"]
        tap(filename, in: app)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        // Do not dismiss the keyboard first: the menu must work on this tap.
        menu.tap()
        XCTAssertTrue(app.buttons["Add number"].waitForExistence(timeout: 3))
        app.buttons["Add number"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3))
        XCTAssertTrue(menu.label.contains("Add number") || (menu.value as? String)?.contains("Add number") == true)
        capture("Working duplicate menu after keyboard dismissal", app)
    }

    func testExtraFilesFoldPreservesSelectionAndChapterHelpExplainsActions() {
        let app = launch(["--ui-screen=configuration", "--ui-light-appearance", "--ui-reduce-motion"])
        let extras = app.buttons["configuration.extraFiles"]
        tap(extras, in: app)
        XCTAssertEqual(extras.value as? String, "Expanded")
        let toggle = app.switches["Metadata JSON"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 3))
        let before = toggle.value as? String
        toggle.tap()
        XCTAssertNotEqual(toggle.value as? String, before)
        let after = toggle.value as? String
        extras.tap()
        XCTAssertEqual(extras.value as? String, "Collapsed")
        XCTAssertFalse(toggle.exists)
        extras.tap()
        XCTAssertEqual(toggle.value as? String, after)
        capture("Expanded extra files", app)
        extras.tap()
        tap(app.buttons["configuration.chapters.info"], in: app)
        XCTAssertTrue(app.navigationBars["Chapter options"].waitForExistence(timeout: 4))
        capture("Chapter help", app)
        app.buttons["Done"].tap()
        XCTAssertFalse(app.textFields["configuration.trim.start"].exists)
        XCTAssertFalse(app.staticTexts["Source image"].exists)
    }

    func testSponsorBlockSettingsKeepsExplanationsInInfoSheet() {
        let app = launch(["--ui-light-appearance", "--ui-reduce-motion"])
        selectWorkspaceTab("Settings", in: app)
        tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "SponsorBlock")).firstMatch, in: app)
        let enabled = app.switches["sponsorblock.enabled"]
        XCTAssertTrue(enabled.waitForExistence(timeout: 3))
        if enabled.value as? String != "1" {
            let control = enabled.switches.firstMatch
            if control.exists { control.tap() } else { enabled.tap() }
        }
        XCTAssertTrue(app.buttons["sponsorblock.category.sponsor.action"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Illucet sends only")).firstMatch.exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "All supported categories")).firstMatch.exists)
        capture("SponsorBlock controls", app)
        app.buttons["settings.sponsorblock.info"].tap()
        XCTAssertTrue(app.navigationBars["About SponsorBlock"].waitForExistence(timeout: 3))
        capture("SponsorBlock help", app)
        app.buttons["Done"].tap()
        XCTAssertTrue(enabled.exists)
    }

    func testCompactDownloadOptionsKeepLabelsAndAdvancedChoices() {
        checkCompactOptions(["--ui-light-appearance"])
    }

    func testCompactDownloadOptionsDarkLargeText() {
        checkCompactOptions(["--ui-dark-appearance", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityLarge"])
    }

    private func checkCompactOptions(_ arguments: [String]) {
        let app = launch(arguments + ["--ui-screen=configuration"])
        XCTAssertTrue(app.buttons["configuration.output"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Video encoding"].exists)
        XCTAssertTrue(app.staticTexts["Video quality"].exists)
        XCTAssertTrue(app.staticTexts["File format"].exists)
        capture("Compact labeled download options", app)
        tap(app.buttons["configuration.output"], in: app)
        app.buttons["configuration.mode.Audio Only"].tap()
        XCTAssertTrue(app.staticTexts["Video quality"].waitForNonExistence(timeout: 3))
        tap(app.buttons["configuration.output"], in: app)
        app.buttons["configuration.mode.Video + Audio"].tap()
        scrollUntilHittable("configuration.advanced", in: app).tap()
        XCTAssertTrue(app.buttons["configuration.source.video"].waitForExistence(timeout: 4))
        _ = scrollUntilHittable("configuration.source.video", in: app)
        capture("Expanded video source", app)
        let encoding = scrollUntilHittable("configuration.encoding.video", in: app)
        encoding.tap()
        app.buttons["H.264"].tap()
        scrollUntilHittable("configuration.advanced", in: app, initiallyScrollDown: true).tap()
        XCTAssertTrue(app.staticTexts["Video encoding"].waitForNonExistence(timeout: 4))
        capture("Collapsed advanced selection summary", app)
        scrollUntilHittable("configuration.advanced", in: app).tap()
        XCTAssertTrue(encoding.label.contains("H.264") || (encoding.value as? String)?.contains("H.264") == true)
    }

    func testSettingsReselectionAndPreferenceBackup() {
        checkSettingsReselectionAndPreferenceBackup(appearance: "--ui-light-appearance")
    }

    func testSettingsReselectionAndPreferenceBackupDark() {
        checkSettingsReselectionAndPreferenceBackup(appearance: "--ui-dark-appearance")
    }

    func testPreferencesFileBackupRoundTrip() {
        let app = launch(["--ui-light-appearance", "--ui-reduce-motion"])
        selectWorkspaceTab("Settings", in: app)
        tap(app.buttons["settings.preferences"], in: app)
        tap(app.buttons["preferences.export"], in: app)
        let save = app.buttons["DOCPicker.actionButton"]
        XCTAssertTrue(save.waitForExistence(timeout: 8))
        XCTAssertEqual(save.label, "Save")
        let uniqueName = "Illucet-Test-\(UUID().uuidString)"
        let filename = app.textFields["DOCPicker.filenameTextField"]
        filename.tap()
        let existing = filename.value as? String ?? ""
        filename.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count) + uniqueName)
        capture("Save preferences file panel", app)
        save.tap()
        XCTAssertTrue(app.staticTexts["Preferences saved."].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Last saved"].waitForExistence(timeout: 4))
        capture("Preferences last successful save", app)
        tap(app.buttons["preferences.import"], in: app)
        let backup = app.cells.matching(NSPredicate(format: "label CONTAINS %@", uniqueName)).firstMatch
        XCTAssertTrue(backup.waitForExistence(timeout: 8))
        capture("Import preferences file panel", app)
        backup.tap()
        XCTAssertTrue(app.alerts["Replace preferences?"].waitForExistence(timeout: 8))
        app.alerts["Replace preferences?"].buttons["Import"].tap()
        XCTAssertTrue(app.staticTexts["Preferences imported."].waitForExistence(timeout: 8))
        capture("Preferences restored from exported file", app)
    }

    private func checkSettingsReselectionAndPreferenceBackup(appearance: String) {
        let app = launch([appearance, "--ui-reduce-motion"])
        selectWorkspaceTab("Settings", in: app)
        tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Storage")).firstMatch, in: app)
        XCTAssertTrue(app.navigationBars["Storage"].waitForExistence(timeout: 4))
        selectWorkspaceTab("Settings", in: app)
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 4))
        tap(app.buttons["settings.preferences"], in: app)
        XCTAssertTrue(app.buttons["preferences.export"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons["preferences.import"].exists)
        capture("Preference backup controls", app)
        selectWorkspaceTab("Settings", in: app)
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 4))
        capture("Filled settings icons", app)
        scrollUntilHittable("Home Quick Start", in: app, initiallyScrollDown: true).tap()
        XCTAssertTrue(app.navigationBars["Home Quick Start"].waitForExistence(timeout: 4))
        tap(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "quick.settings.preset.")).firstMatch, in: app)
        XCTAssertTrue(app.navigationBars["Edit preset"].waitForExistence(timeout: 4))
        selectWorkspaceTab("Settings", in: app)
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 4))
        let sponsorBlock = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "SponsorBlock")).firstMatch
        for _ in 0..<6 where !sponsorBlock.isHittable || sponsorBlock.frame.minY < app.navigationBars.firstMatch.frame.maxY {
            app.swipeDown()
        }
        XCTAssertTrue(sponsorBlock.isHittable)
        capture("Plain SponsorBlock shield and filled icons", app)
    }

    func testIndependentDownloadFlowCombinations() {
        for skipDetails in [false, true] {
            for skipReview in [false, true] {
                let flags = (skipDetails ? ["--ui-skip-details"] : []) + (skipReview ? ["--ui-skip-review"] : [])
                let app = launch(flags)
                XCTAssertEqual(app.buttons["download.analyze"].label, skipDetails ? "Configure download" : "Analyze")
                app.buttons["download.analyze"].tap()
                if !skipDetails {
                    XCTAssertTrue(app.navigationBars["Media found"].waitForExistence(timeout: 6))
                    tap(app.buttons["metadata.configure"], in: app)
                }
                XCTAssertTrue(app.navigationBars["Download options"].waitForExistence(timeout: 6))
                let submit = app.buttons["configuration.review"]
                tap(submit, in: app)
                if skipReview {
                    XCTAssertTrue(app.navigationBars["Queue"].waitForExistence(timeout: 6))
                    XCTAssertFalse(app.otherElements["confirmation.sheet"].exists)
                } else {
                    XCTAssertTrue(app.otherElements["confirmation.sheet"].waitForExistence(timeout: 6))
                }
                capture("Flow details-\(skipDetails) review-\(skipReview)", app)
                app.terminate()
            }
        }
    }

    func testInstantQuickStartClipboardAndInvalidRecovery() {
        for (clipboard, clear, invalid) in [("valid", true, false), ("unsupported", true, true), ("empty", true, true), ("unsupported", false, false)] {
            let app = launch(["--ui-instant-quick-start", "--ui-clipboard=\(clipboard)"])
            if clear { app.buttons["download.clear"].tap() }
            tap(app.buttons["download.quick.D1000000-0000-0000-0000-000000000005"], in: app)
            if invalid {
                XCTAssertTrue(app.textFields["download.urlField"].isHittable)
                XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 4))
                XCTAssertFalse(app.buttons["Paste and Continue"].exists)
            } else {
                XCTAssertTrue(app.navigationBars["Queue"].waitForExistence(timeout: 6))
                XCTAssertFalse(app.otherElements["quick.confirmation.sheet"].exists)
            }
            capture("Instant Quick Start clipboard-\(clipboard) clear-\(clear)", app)
            app.terminate()
        }
    }

    func testLargeSubtitlePickerSearchAndSelectionStayCompact() {
        let app = launch(["--ui-screen=configuration-large-subtitles"])
        XCTAssertTrue(app.navigationBars["Download options"].waitForExistence(timeout: 6))
        let choose = app.buttons["configuration.subtitle.choose"]
        tap(choose, in: app)
        XCTAssertTrue(app.navigationBars["Subtitles"].waitForExistence(timeout: 5))
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap(); search.typeText("English")
        let first = app.buttons["configuration.subtitle.subtitle-000000000000000000000000.subtitle-format-000000000000000000000000"]
        XCTAssertTrue(first.waitForExistence(timeout: 6))
        first.tap()
        capture("Searchable subtitles", app)
        if !app.buttons["Done"].isHittable {
            (app.buttons["Close"].exists ? app.buttons["Close"] : app.buttons["Cancel"]).tap()
        }
        app.buttons["Done"].tap()
        XCTAssertTrue(choose.waitForExistence(timeout: 3))
        XCTAssertTrue(choose.label.contains("1 selected"))
        choose.tap()
        XCTAssertTrue(first.waitForExistence(timeout: 4))
        XCTAssertEqual(first.value as? String, "Selected")
    }

    func testNavigationSettingsAndCopyableVersions() {
        let app = launch(["--ui-light-appearance", "--ui-reduce-motion"])
        if UIDevice.current.userInterfaceIdiom == .phone { XCTAssertFalse(app.tabBars.firstMatch.exists) }
        capture("Home with four presets", app)
        selectWorkspaceTab("Settings", in: app)
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 4))
        XCTAssertFalse(app.staticTexts["Your personal media workspace"].exists)
        let updates = app.buttons["settings.updates"]
        let storage = app.buttons["settings.storage"]
        for _ in 0..<8 where !updates.isHittable { app.swipeUp() }
        XCTAssertTrue(updates.isHittable)
        XCTAssertFalse(app.staticTexts["Active yt-dlp · Updates and retained versions"].exists)
        XCTAssertLessThanOrEqual(updates.frame.height, storage.frame.height + 4)
        capture("Simplified Settings", app)
        tap(app.buttons["settings.updates"], in: app)
        let version = app.descendants(matching: .any)["updates.runningYTDLP"].firstMatch
        XCTAssertTrue(version.waitForExistence(timeout: 4))
        let original = version.value as? String
        version.press(forDuration: 0.6)
        XCTAssertEqual(version.value as? String, "Copied")
        let reset = NSPredicate(format: "value == %@", original ?? "")
        expectation(for: reset, evaluatedWith: version)
        waitForExpectations(timeout: 4)
        capture("Updater version rows", app)
    }

    func testHighlightTraversesAndReversesAcrossAllTabs() {
        let app = launch(["--ui-dark-appearance"])
        for tab in ["Settings", "Download", "Queue", "History", "Settings", "Queue", "Download"] {
            selectWorkspaceTab(tab, in: app)
            let identifier = "navigation." + tab.lowercased()
            XCTAssertTrue(app.buttons[identifier].isSelected)
        }
        capture("Fixed-duration highlight after full-width and adjacent switches", app)
    }

    func testTabBarScrubsAcrossTabsAndStillAcceptsTaps() {
        checkTabBarScrubbing(["--ui-light-appearance"])
    }

    func testTabBarScrubbingWithReduceMotionAndLargeText() {
        checkTabBarScrubbing(["--ui-dark-appearance", "--ui-reduce-motion",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityLarge"])
    }

    private func checkTabBarScrubbing(_ arguments: [String]) {
        let app = launch(arguments)
        for (source, target) in [("Download", "Settings"), ("Settings", "Queue"),
                                 ("Queue", "History"), ("History", "Download")] {
            let start = app.buttons["navigation." + source.lowercased()]
            let end = app.buttons["navigation." + target.lowercased()]
            XCTAssertTrue(start.isSelected)
            start.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.1, thenDragTo: end.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)),
                       withVelocity: .slow, thenHoldForDuration: 0.2)
            let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == YES"), object: end)
            XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 3), .completed)
        }
        selectWorkspaceTab("Settings", in: app)
        tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Storage")).firstMatch, in: app)
        XCTAssertTrue(app.navigationBars["Storage"].waitForExistence(timeout: 3))
        let settings = app.buttons["navigation.settings"]
        // A small scrub that ends on the current tab must not act as a reselect tap.
        settings.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: settings.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5)))
        XCTAssertTrue(app.navigationBars["Storage"].exists)
        settings.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 3))
        capture("Tab scrubbing and normal tap reselection", app)
    }

    func testTabBarDragAwayCancelsSelection() {
        let app = launch(["--ui-light-appearance"])
        let download = app.buttons["navigation.download"]
        let settings = app.buttons["navigation.settings"]
        let outside = settings.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .withOffset(CGVector(dx: 0, dy: -120))
        download.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: outside, withVelocity: .slow, thenHoldForDuration: 0.2)
        XCTAssertTrue(download.isSelected)
        selectWorkspaceTab("Queue", in: app)
        XCTAssertTrue(app.buttons["navigation.queue"].isSelected)
        capture("Dragging away cancels without blocking subsequent taps", app)
    }

    func testDarkLargeTextTabsRemainAccessible() {
        let app = launch(["--ui-dark-appearance", "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityLarge"])
        for tab in ["Queue", "History", "Settings", "Download"] {
            selectWorkspaceTab(tab, in: app)
        }
        capture("Dark large-text Home", app)
        selectWorkspaceTab("Settings", in: app)
        capture("Dark large-text Settings", app)
    }

    private func launch(_ arguments: [String]) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-polish-reset"] + arguments
        app.launch()
        XCTAssertTrue(waitForWorkspaceShell(app, timeout: 15))
        return app
    }
    private func tap(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<14 {
            if element.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(element.waitForExistence(timeout: 4))
        XCTAssertTrue(element.isHittable)
        element.tap()
    }
    private func capture(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
