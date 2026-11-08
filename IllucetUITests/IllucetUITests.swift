import XCTest

@MainActor
final class IllucetUITests: XCTestCase {
    func testQueueTabStatusBadgesInLightMode() { verifyQueueTabStatusBadges(dark: false) }
    func testQueueTabStatusBadgesInDarkMode() { verifyQueueTabStatusBadges(dark: true) }

    func testQueueAttentionBadgeFollowsCustomAccent() {
        for (appearance, accent) in [("--ui-dark-appearance", "--ui-accent=white"),
                                     ("--ui-light-appearance", "--ui-accent=black")] {
            let app = launchApp(arguments: ["--ui-polish-reset", appearance, accent,
                "--ui-screen=queue-badge-attention"])
            XCTAssertEqual(app.buttons["navigation.queue"].value as? String, "Needs attention")
            keepScreenshot(app, name: "Queue attention badge follows \(accent) \(appearance)")
            app.terminate()
        }
    }

    private func verifyQueueTabStatusBadges(dark: Bool) {
        let appearance = dark ? "--ui-dark-appearance" : "--ui-light-appearance"
        for (state, value) in [("attention", "Needs attention"), ("downloading", "Downloading"),
                               ("completed", "New downloads completed")] {
            let app = launchApp(arguments: ["--ui-polish-reset", appearance, "--ui-screen=queue-badge-" + state])
            let queue = app.buttons["navigation.queue"]
            if queue.exists { XCTAssertEqual(queue.value as? String, value) }
            keepScreenshot(app, name: "Queue badge \(state) \(dark ? "dark" : "light")")
            selectWorkspaceTab("Queue", in: app)
            XCTAssertTrue(app.navigationBars["Queue"].waitForExistence(timeout: 3))
            if state == "completed" {
                selectWorkspaceTab("History", in: app)
                if queue.exists { XCTAssertEqual(queue.value as? String, "") }
                keepScreenshot(app, name: "Queue completion acknowledged \(dark ? "dark" : "light")")
            }
            app.terminate()
        }
    }

    func testFirstRunOnboardingExplainsCoreExperienceAndCanSkipNotifications() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-screen=onboarding", "--pip-fast-text"]
        app.launch()
        XCTAssertTrue(app.buttons["pip.skip"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["pip.dialogue"].label.contains("Welcome to Illucet"))
        app.buttons["pip.skip"].tap()
        XCTAssertTrue(app.buttons["pip.skip"].waitForNonExistence(timeout: 4))
        XCTAssertTrue(waitForWorkspaceShell(app, timeout: 4))
    }

    func testQueueAndHistoryEmptyActionsReachRealDownloadControls() {
        let app = launchApp(arguments: ["--ui-empty-state"])

        selectWorkspaceTab("Queue", in: app)
        XCTAssertTrue(
            app.otherElements["queue.empty"].waitForExistence(timeout: 3)
        )
        XCTAssertTrue(app.buttons["queue.empty.primary"].exists)
        XCTAssertTrue(app.buttons["queue.empty.secondary"].exists)
        app.buttons["queue.empty.secondary"].tap()
        XCTAssertTrue(
            app.staticTexts["Quick start"]
                .waitForExistence(timeout: 4)
        )

        selectWorkspaceTab("History", in: app)
        XCTAssertTrue(
            app.otherElements["history.empty"].waitForExistence(timeout: 3)
        )
        XCTAssertTrue(app.buttons["history.empty.primary"].exists)
        XCTAssertTrue(app.buttons["history.empty.secondary"].exists)
        app.buttons["history.empty.primary"].tap()
        XCTAssertTrue(
            app.textFields["download.urlField"]
                .waitForExistence(timeout: 4)
        )
        XCTAssertTrue(app.buttons["download.clear"].exists)
    }

    func testFourTabsAndPrimaryEmptyStatesOpen() {
        let app = launchApp()
        XCTAssertTrue(waitForWorkspaceShell(app))
        selectWorkspaceTab("Queue", in: app)
        XCTAssertTrue(app.navigationBars["Queue"].waitForExistence(timeout: 2))
        selectWorkspaceTab("History", in: app)
        XCTAssertTrue(
            app.navigationBars["History"].waitForExistence(timeout: 2)
        )
        selectWorkspaceTab("Settings", in: app)
        XCTAssertTrue(
            app.navigationBars["Settings"].waitForExistence(timeout: 2)
        )
    }

    func testURLPasteClearAnalyzeAndAllPrimaryModes() {
        let app = launchApp()
        XCTAssertTrue(app.staticTexts["Start with a link"].exists)
        XCTAssertTrue(
            app.staticTexts[
                "A video, a track, or a whole playlist"
            ].exists
        )
        let URLField = app.textFields["download.urlField"]
        XCTAssertTrue(URLField.waitForExistence(timeout: 3))

        let clearButton = app.buttons["download.clear"]
        XCTAssertTrue(clearButton.waitForExistence(timeout: 3))
        clearButton.tap()
        XCTAssertTrue(clearButton.waitForNonExistence(timeout: 2))
        XCTAssertEqual(URLField.value as? String, "https://youtu.be/…")
        app.buttons["download.paste"].tap()
        XCTAssertTrue(clearButton.waitForExistence(timeout: 2))
        app.buttons["download.analyze"].tap()

        XCTAssertTrue(
            app.otherElements["metadata.sheet"].waitForExistence(timeout: 5)
        )
        app.buttons["metadata.configure"].tap()
        XCTAssertTrue(
            app.otherElements["configuration.sheet"].waitForExistence(
                timeout: 3
            )
        )
        XCTAssertFalse(app.staticTexts["Playlist & batch"].exists)

        for mode in ["Video + Audio", "Audio Only", "Video Only"] {
            app.buttons["configuration.output"].tap()
            let button = app.buttons["configuration.mode.\(mode)"]
            XCTAssertTrue(button.waitForExistence(timeout: 2))
            button.tap()
        }
        XCTAssertTrue(app.buttons["configuration.review"].exists)
    }

    func testDownloadOptionsShowOnlyEffectiveArtworkCropControls() {
        let app = launchApp(arguments: ["--ui-screen=configuration"])
        XCTAssertTrue(
            app.otherElements["configuration.sheet"].waitForExistence(
                timeout: 4
            )
        )

        let crop = app.switches["Crop square for audio artwork"]
        XCTAssertFalse(crop.exists)

        app.buttons["configuration.output"].tap()
        app.buttons["configuration.mode.Video Only"].tap()
        XCTAssertFalse(crop.exists)

        app.buttons["configuration.output"].tap()
        app.buttons["configuration.mode.Audio Only"].tap()
        app.buttons["configuration.advanced"].tap()
        let outputFormat = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Audio encoding")
        ).firstMatch
        for _ in 0..<4 where !outputFormat.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(outputFormat.waitForExistence(timeout: 3))
        outputFormat.tap()
        XCTAssertTrue(app.buttons["MP3"].waitForExistence(timeout: 2))
        app.buttons["MP3"].tap()

        let behavior = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Behavior")
        ).firstMatch
        for _ in 0..<8 where !behavior.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(behavior.waitForExistence(timeout: 3))
        XCTAssertFalse(crop.exists)

        behavior.tap()
        let embed = app.buttons["Embed when supported"].firstMatch
        XCTAssertTrue(
            embed.waitForExistence(timeout: 2)
        )
        embed.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        ).tap()
        XCTAssertTrue(crop.waitForExistence(timeout: 3))
    }

    func testEmptyQuickStartRecoveryContinuesRetainedPresetManuallyAndFromClipboard() {
        let manualApp = launchApp(
            arguments: ["--ui-clipboard=unsupported"]
        )
        let manualURLField = manualApp.textFields["download.urlField"]
        manualApp.buttons["download.clear"].tap()
        let manualPreset = manualApp.buttons[
            "download.quick.D1000000-0000-0000-0000-000000000005"
        ]
        XCTAssertTrue(manualPreset.waitForExistence(timeout: 3))
        manualPreset.tap()

        XCTAssertTrue(
            manualApp.staticTexts[
                "download.quickRecovery.guidance"
            ].waitForExistence(timeout: 2)
        )
        XCTAssertTrue(
            manualApp.keyboards.firstMatch.waitForExistence(timeout: 3)
        )
        XCTAssertFalse(manualApp.alerts.firstMatch.exists)
        XCTAssertFalse(
            manualApp.buttons["Paste and Continue"].exists
        )

        manualURLField.typeText("https://youtu.be/dQw4w9WgXcQ")
        manualApp.buttons["download.analyze"].tap()
        XCTAssertTrue(
            manualApp.otherElements["quick.confirmation.sheet"]
                .waitForExistence(timeout: 6)
        )
        XCTAssertTrue(manualApp.staticTexts["Best audio"].exists)
        XCTAssertTrue(manualApp.staticTexts["Audio Only"].exists)
        manualApp.terminate()

        let clipboardApp = launchApp()
        clipboardApp.buttons["download.clear"].tap()
        let clipboardPreset = clipboardApp.buttons[
            "download.quick.D1000000-0000-0000-0000-000000000005"
        ]
        XCTAssertTrue(clipboardPreset.waitForExistence(timeout: 3))
        clipboardPreset.tap()

        let pasteAndContinue = clipboardApp.buttons[
            "Paste and Continue"
        ].firstMatch
        XCTAssertTrue(pasteAndContinue.waitForExistence(timeout: 3))
        XCTAssertFalse(
            clipboardApp.otherElements["quick.confirmation.sheet"].exists
        )
        pasteAndContinue.tap()
        XCTAssertTrue(
            clipboardApp.otherElements["quick.confirmation.sheet"]
                .waitForExistence(timeout: 6)
        )
        XCTAssertTrue(clipboardApp.staticTexts["Best audio"].exists)
        XCTAssertTrue(clipboardApp.staticTexts["Audio Only"].exists)
    }

    func testUnusedDownloadSpaceDismissesKeyboardWithoutCancellingRecovery() {
        let app = launchApp(arguments: ["--ui-clipboard=unsupported", "--ui-reduce-motion"])
        app.buttons["download.clear"].tap()
        let preset = app.buttons[
            "download.quick.D1000000-0000-0000-0000-000000000005"
        ]
        XCTAssertTrue(preset.waitForExistence(timeout: 3))
        preset.tap()
        XCTAssertTrue(
            app.keyboards.firstMatch.waitForExistence(timeout: 3)
        )

        let unusedSpace = app.descendants(matching: .any).matching(
            identifier: "download.unusedSpace"
        ).firstMatch
        XCTAssertTrue(unusedSpace.waitForExistence(timeout: 3))
        tapUnusedWorkspaceSpace(unusedSpace, in: app)
        XCTAssertTrue(
            app.keyboards.firstMatch.waitForNonExistence(timeout: 3)
        )

        let paste = app.buttons["download.paste"]
        XCTAssertTrue(paste.isHittable)
        paste.tap()
        XCTAssertTrue(
            app.buttons["download.clear"].waitForExistence(timeout: 2)
        )
        app.buttons["download.analyze"].tap()
        XCTAssertTrue(
            app.otherElements["quick.confirmation.sheet"]
                .waitForExistence(timeout: 6)
        )
        XCTAssertTrue(app.staticTexts["Best audio"].exists)
    }

    func testConfigurationKeyboardDismissalPreservesControlsAndBlankTaps() throws {
        let app = launchApp(arguments: ["--ui-screen=configuration", "--ui-reduce-motion"])
        XCTAssertTrue(
            app.otherElements["configuration.sheet"].waitForExistence(
                timeout: 4
            )
        )

        let filename = app.textFields["configuration.filename"]
        for _ in 0..<12 where !filename.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(filename.waitForExistence(timeout: 3))
        XCTAssertTrue(filename.isHittable)
        filename.tap()
        XCTAssertTrue(
            app.keyboards.firstMatch.waitForExistence(timeout: 3)
        )

        if UIDevice.current.userInterfaceIdiom == .pad {
            let visibleKeyboard = NSPredicate { _, _ in
                app.keyboards.firstMatch.frame.intersects(app.windows.firstMatch.frame)
            }
            let visible = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: visibleKeyboard, object: app)], timeout: 3)
            if visible != .completed {
                throw XCTSkip("The iPad simulator exposes only an off-screen keyboard preview; software-keyboard dismissal cannot be verified.")
            }
        }

        if UIDevice.current.userInterfaceIdiom == .phone {
            let destination = app.buttons["configuration.destination.menu"]
            XCTAssertTrue(destination.waitForExistence(timeout: 3))
            XCTAssertTrue(destination.isHittable)
            destination.tap()
            XCTAssertTrue(app.buttons["Illucet"].waitForExistence(timeout: 3))
            app.buttons["Illucet"].tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3))
            filename.tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        }
        // The short iPad sheet viewport can scroll these controls out of view
        // when its keyboard appears. Test blank-space dismissal here; the
        // duplicate-menu test covers same-tap controls with the iPad keyboard.
        let unusedSpace = app.descendants(matching: .any).matching(
            identifier: "configuration.unusedSpace"
        ).firstMatch
        XCTAssertTrue(unusedSpace.waitForExistence(timeout: 3))
        tapUnusedWorkspaceSpace(unusedSpace, in: app)
        XCTAssertTrue(
            app.keyboards.firstMatch.waitForNonExistence(timeout: 3)
        )
    }

    func testNonDownloadKeyboardDismissalPreservesSameTapControls() {
        let quickApp = launchApp(arguments: ["--ui-reduce-motion"])
        quickApp.buttons["download.managePresets"].tap()
        XCTAssertTrue(
            quickApp.navigationBars["Home Quick Start"]
                .waitForExistence(timeout: 4)
        )
        quickApp.buttons["quick.settings.add"].tap()
        scrollUntilHittable("New Preset", type: .staticText, in: quickApp).tap()
        XCTAssertTrue(
            quickApp.navigationBars["Edit preset"].waitForExistence(
                timeout: 4
            )
        )
        let name = quickApp.textFields["quick.editor.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        name.tap()
        XCTAssertTrue(
            quickApp.keyboards.firstMatch.waitForExistence(timeout: 3)
        )
        let mode = quickApp.segmentedControls["quick.editor.mode"]
        mode.buttons["Audio Only"].tap()
        XCTAssertTrue(quickApp.keyboards.firstMatch.waitForNonExistence(timeout: 3))
        XCTAssertTrue(
            quickApp.staticTexts["Video codec"].waitForNonExistence(
                timeout: 3
            )
        )
        let quickUnused = quickApp.descendants(matching: .any).matching(
            identifier: "quick.editor.unusedSpace"
        ).firstMatch
        XCTAssertTrue(quickUnused.waitForExistence(timeout: 3))
        tapUnusedWorkspaceSpace(quickUnused, in: quickApp)
        XCTAssertTrue(
            quickApp.keyboards.firstMatch.waitForNonExistence(timeout: 3)
        )
        quickApp.terminate()

        let settingsApp = launchApp(arguments: ["--ui-reduce-motion"])
        selectWorkspaceTab("Settings", in: settingsApp)
        let defaults = settingsApp.staticTexts["Download defaults"]
        XCTAssertTrue(defaults.waitForExistence(timeout: 3))
        defaults.tap()
        XCTAssertTrue(
            settingsApp.navigationBars["Download defaults"]
                .waitForExistence(timeout: 4)
        )
        let filename = settingsApp.textFields[
            "settings.downloads.filename"
        ]
        for _ in 0..<12 where !filename.isHittable {
            settingsApp.swipeUp()
        }
        XCTAssertTrue(filename.waitForExistence(timeout: 3))
        filename.tap()
        XCTAssertTrue(
            settingsApp.keyboards.firstMatch.waitForExistence(timeout: 3)
        )
        let settingsUnused = settingsApp.descendants(matching: .any).matching(
            identifier: "settings.downloads.unusedSpace"
        ).firstMatch
        XCTAssertTrue(settingsUnused.waitForExistence(timeout: 3))
        tapUnusedWorkspaceSpace(settingsUnused, in: settingsApp)
        XCTAssertTrue(
            settingsApp.keyboards.firstMatch.waitForNonExistence(timeout: 3)
        )
    }

    func testBestAudioQuickStartUsesCompactFlowAndQueuesAudioConfiguration() {
        let app = launchApp()
        XCTAssertFalse(app.buttons["download.openQueue"].exists)
        let audioPreset = app.buttons[
            "download.quick.D1000000-0000-0000-0000-000000000005"
        ]
        XCTAssertTrue(audioPreset.waitForExistence(timeout: 3))
        audioPreset.tap()

        XCTAssertTrue(
            app.otherElements["quick.confirmation.sheet"]
                .waitForExistence(timeout: 6)
        )
        XCTAssertTrue(app.staticTexts["Best audio"].exists)
        XCTAssertTrue(app.staticTexts["Audio Only"].exists)
        XCTAssertFalse(app.staticTexts["MP3 Audio"].exists)
        XCTAssertFalse(app.otherElements["configuration.sheet"].exists)
        app.buttons["quick.confirm.download"].tap()

        XCTAssertTrue(
            app.navigationBars["Queue"].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            app.staticTexts["Audio Only"].waitForExistence(timeout: 5)
        )
    }

    func testQuickStartPresetManagerAndDensityPreviewRespond() {
        let app = launchApp()
        app.buttons["download.managePresets"].tap()
        XCTAssertTrue(
            app.navigationBars["Home Quick Start"]
                .waitForExistence(timeout: 4)
        )
        for name in [
            "Best video", "Best audio", "Compatible video", "Thumbnail",
        ] {
            XCTAssertTrue(app.staticTexts[name].exists)
        }
        app.buttons["quick.settings.add"].tap()
        XCTAssertTrue(
            app.staticTexts["New Preset"].waitForExistence(timeout: 3)
        )
        scrollUntilHittable("New Preset", type: .staticText, in: app).tap()
        XCTAssertTrue(
            app.navigationBars["Edit preset"].waitForExistence(timeout: 4)
        )
        let modePicker = app.segmentedControls["quick.editor.mode"]
        XCTAssertTrue(modePicker.waitForExistence(timeout: 2))
        modePicker.buttons["Audio Only"].tap()
        XCTAssertTrue(
            app.staticTexts["Video codec"].waitForNonExistence(timeout: 2)
        )
        XCTAssertTrue(app.staticTexts["Audio codec"].exists)
        let savePreset = app.buttons["quick.editor.save"]
        for _ in 0..<8 where !savePreset.isHittable || savePreset.frame.maxY > app.windows.firstMatch.frame.maxY - 120 {
            app.swipeUp()
        }
        XCTAssertTrue(savePreset.waitForExistence(timeout: 3))
        let floatingBar = app.otherElements["navigation.floatingBar"]
        if floatingBar.exists { XCTAssertLessThan(savePreset.frame.maxY, floatingBar.frame.minY) }
        savePreset.tap()
        XCTAssertTrue(
            app.navigationBars["Home Quick Start"]
                .waitForExistence(timeout: 4)
        )

        selectWorkspaceTab("Settings", in: app)
        XCTAssertTrue(
            app.navigationBars["Settings"].waitForExistence(timeout: 4)
        )
        let appearance = app.staticTexts["Interface"]
        for _ in 0..<6 where !appearance.isHittable { app.swipeUp() }
        XCTAssertTrue(appearance.waitForExistence(timeout: 3))
        appearance.tap()
        XCTAssertTrue(
            app.navigationBars["Interface"].waitForExistence(timeout: 4)
        )
        let density = app.segmentedControls["appearance.cardDensity"]
        XCTAssertTrue(density.waitForExistence(timeout: 3))
        density.buttons["Compact"].tap()
        let firstPreviewTitle = app.staticTexts["City Walk — 1080p"]
        if !firstPreviewTitle.exists {
            app.swipeUp()
        }
        XCTAssertTrue(
            firstPreviewTitle
                .waitForExistence(timeout: 4)
        )
        XCTAssertTrue(
            app.staticTexts["Studio Session"].waitForExistence(timeout: 2)
        )
        let preview = app.descendants(matching: .any)[
            "appearance.cardPreview"
        ]
        XCTAssertTrue(preview.waitForExistence(timeout: 3))
        XCTAssertEqual(preview.value as? String, "Compact")
    }

    func testUpdaterRunningVersionsStayReadableInLightAndDark() {
        for appearance in ["light", "dark"] {
            let app = launchApp(arguments: ["--ui-screen=updater", "--ui-empty-state", "--ui-\(appearance)-appearance"])
            let version = app.descendants(matching: .any)["updates.runningYTDLP"].firstMatch
            XCTAssertTrue(version.waitForExistence(timeout: 5))
            let running = version.value as? String ?? ""
            XCTAssertNotNil(running.range(of: #"^\d{4}\.\d{2}\.\d{2}(?:\.\d+)?$"#, options: .regularExpression))
            XCTAssertTrue(app.descendants(matching: .any)["updates.runningEJS"].firstMatch.exists)
            XCTAssertTrue(app.buttons["updates.check"].exists)
            XCTAssertFalse(app.buttons["updates.test"].exists)
            XCTAssertFalse(app.buttons["updates.install"].exists)
            let profile = app.descendants(matching: .any)["updates.activeProfile"].firstMatch
            XCTAssertEqual(profile.value as? String, "Bundled (Nightly)")
            XCTAssertFalse(app.buttons["updates.rollback"].exists)
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Updater \(appearance)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            app.terminate()
        }
    }

    func testUpdaterInstalledProfileOffersRestoreIndependentlyOfChosenChannel() {
        let app = launchApp(arguments: ["--ui-screen=updater", "--ui-empty-state", "--ui-update-installed",
                                        "--ui-dark-appearance"])
        let profile = app.descendants(matching: .any)["updates.activeProfile"].firstMatch
        XCTAssertTrue(profile.waitForExistence(timeout: 5))
        XCTAssertEqual(profile.value as? String, "Installed Master")
        XCTAssertEqual(app.descendants(matching: .any)["updates.runningYTDLP"].firstMatch.value as? String,
                       "2026.11.04.071645")
        let restore = app.buttons["updates.rollback"]
        XCTAssertTrue(restore.exists)
        XCTAssertTrue(restore.isEnabled)
        app.buttons["updates.channel"].tap()
        app.buttons["Stable"].tap()
        XCTAssertEqual(profile.value as? String, "Installed Master")
        XCTAssertTrue(restore.exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Installed Master with Restore bundled version"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testUpdaterMasterSwitchShowsTargetAndRequiresDowngradeConfirmation() {
        let app = launchApp(arguments: ["--ui-screen=updater", "--ui-empty-state", "--ui-update-offer", "--ui-dark-appearance"])
        let install = app.buttons["updates.install"]
        XCTAssertTrue(install.waitForExistence(timeout: 5))
        XCTAssertEqual(install.label, "Switch to Master")
        XCTAssertEqual(app.staticTexts["updates.availableVersion"].label, "2026.11.04.071645")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Updater Master switch"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        install.tap()
        let confirmation = app.alerts["Switch to an older version?"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 3))
        confirmation.buttons["Cancel"].tap()
        app.buttons["updates.channel"].tap()
        XCTAssertTrue(app.buttons["Nightly (Recommended)"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Stable"].exists)
        XCTAssertTrue(app.buttons["Master"].exists)
        app.buttons["Nightly (Recommended)"].tap()
        XCTAssertFalse(install.exists)
    }

    func testUpdaterFullVersionAtAccessibilityTextSize() {
        let app = launchApp(arguments: ["--ui-screen=updater", "--ui-empty-state", "--ui-light-appearance",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"])
        let version = app.descendants(matching: .any)["updates.runningYTDLP"].firstMatch
        XCTAssertTrue(version.waitForExistence(timeout: 5))
        XCTAssertTrue(version.isHittable)
        XCTAssertNotNil((version.value as? String)?.range(of: #"^\d{4}\.\d{2}\.\d{2}(?:\.\d+)?$"#,
                                                          options: .regularExpression))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Updater accessibility text"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testSettingsDestinationsAndUpdateControlsRespond() {
        let app = launchApp()
        selectWorkspaceTab("Settings", in: app)
        let updates = app.buttons["settings.updates"]
        if !updates.exists {
            app.swipeUp()
        }
        XCTAssertTrue(updates.waitForExistence(timeout: 3))
        updates.tap()
        XCTAssertTrue(app.buttons["updates.check"].waitForExistence(timeout: 3))
        let profile = app.descendants(matching: .any)["updates.activeProfile"].firstMatch
        XCTAssertTrue(profile.exists)
        XCTAssertTrue((profile.value as? String)?.hasPrefix("Bundled (") == true)
        XCTAssertFalse(app.buttons["updates.rollback"].exists)
        XCTAssertFalse(app.buttons["updates.test"].exists)
        XCTAssertFalse(app.buttons["updates.install"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Extractor updater"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.navigationBars.buttons.element(boundBy: 0).tap()

        let storage = app.staticTexts["Storage"]
        if !storage.exists {
            app.swipeDown()
        }
        XCTAssertTrue(storage.waitForExistence(timeout: 2))
        storage.tap()
        XCTAssertTrue(app.buttons["Select folder"].waitForExistence(timeout: 2))
        let testAccess = app.buttons["Test folder access"]
        for _ in 0..<3 where !testAccess.isHittable { app.swipeUp() }
        XCTAssertTrue(testAccess.isHittable)
    }

    func testFilesFolderSelectionTestingAndUnavailableRecoveryAreTruthful() {
        let app = launchApp(arguments: ["--ui-folder-picker-fixture"])
        selectWorkspaceTab("Settings", in: app)
        let storage = app.staticTexts["Storage"]
        for _ in 0..<4 where !storage.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(storage.waitForExistence(timeout: 3))
        storage.tap()

        app.buttons["Select folder"].tap()
        XCTAssertTrue(
            app.buttons["Use Test Folder"].waitForExistence(timeout: 3)
        )
        app.buttons["Use Test Folder"].tap()
        let selectedFolder = app.descendants(matching: .any)[
            "storage.filesFolder"
        ]
        XCTAssertTrue(selectedFolder.waitForExistence(timeout: 3))
        XCTAssertTrue(
            waitForElement(
                selectedFolder,
                containing: "Illucet UI Test Files"
            )
        )
        app.buttons["Test folder access"].tap()
        let availableAlert = app.alerts["Folder available"]
        XCTAssertTrue(availableAlert.waitForExistence(timeout: 4))
        XCTAssertTrue(
            availableAlert.staticTexts[
                "Illucet UI Test Files is writable."
            ].exists
        )
        availableAlert.buttons["OK"].tap()
        app.terminate()

        let restored = launchApp(arguments: ["--ui-folder-picker-fixture"])
        selectWorkspaceTab("Settings", in: restored)
        let restoredStorage = restored.staticTexts["Storage"]
        for _ in 0..<4 where !restoredStorage.isHittable {
            restored.swipeUp()
        }
        XCTAssertTrue(restoredStorage.waitForExistence(timeout: 3))
        restoredStorage.tap()
        let restoredFolder = restored.descendants(matching: .any)[
            "storage.filesFolder"
        ]
        XCTAssertTrue(restoredFolder.waitForExistence(timeout: 3))
        XCTAssertTrue(
            waitForElement(
                restoredFolder,
                containing: "Illucet UI Test Files"
            )
        )
        restored.terminate()

        let unavailable = launchApp(
            arguments: ["--ui-folder-unavailable"]
        )
        selectWorkspaceTab("Settings", in: unavailable)
        let unavailableStorage = unavailable.staticTexts["Storage"]
        for _ in 0..<4 where !unavailableStorage.isHittable {
            unavailable.swipeUp()
        }
        XCTAssertTrue(
            unavailableStorage.waitForExistence(timeout: 3)
        )
        unavailableStorage.tap()
        unavailable.buttons["Test folder access"].tap()
        XCTAssertTrue(
            unavailable.alerts["Select the Files folder again"]
                .waitForExistence(timeout: 4)
        )
        unavailable.alerts.buttons["OK"].tap()
        let folderState = unavailable.descendants(matching: .any)[
            "storage.filesFolder"
        ]
        XCTAssertTrue(folderState.waitForExistence(timeout: 3))
        XCTAssertTrue(
            folderState.label.contains("None")
                || String(describing: folderState.value).contains("None")
        )
    }

    func testDocumentsFolderAliasPersistsAndResetsOnlyOnFolderChange() {
        let fixtureArguments = [
            "--ui-folder-picker-fixture",
            "--ui-folder-documents-fixture",
        ]
        let app = launchApp(
            arguments: fixtureArguments + ["--ui-folder-alias-reset"]
        )
        selectWorkspaceTab("Settings", in: app)
        let storage = app.staticTexts["Storage"]
        for _ in 0..<4 where !storage.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(storage.waitForExistence(timeout: 3))
        storage.tap()

        app.buttons["Select folder"].tap()
        XCTAssertTrue(
            app.buttons["Use Documents Folder"]
                .waitForExistence(timeout: 3)
        )
        app.buttons["Use Documents Folder"].tap()
        let aliasOffer = app.alerts["Name this Files folder?"]
        XCTAssertTrue(aliasOffer.waitForExistence(timeout: 4))
        let aliasField = aliasOffer.textFields["Folder alias"]
        XCTAssertTrue(aliasField.waitForExistence(timeout: 2))
        aliasField.tap()
        aliasField.typeText("VLC")
        aliasOffer.buttons["Save alias"].tap()

        let selectedFolder = app.descendants(matching: .any)[
            "storage.filesFolder"
        ]
        XCTAssertTrue(selectedFolder.waitForExistence(timeout: 3))
        XCTAssertTrue(waitForElement(selectedFolder, containing: "VLC"))
        app.buttons["Test folder access"].tap()
        let available = app.alerts["Folder available"]
        XCTAssertTrue(available.waitForExistence(timeout: 4))
        XCTAssertTrue(available.staticTexts["VLC is writable."].exists)
        available.buttons["OK"].tap()
        app.terminate()

        let restored = launchApp(arguments: fixtureArguments)
        selectWorkspaceTab("Settings", in: restored)
        let restoredStorage = restored.staticTexts["Storage"]
        for _ in 0..<4 where !restoredStorage.isHittable {
            restored.swipeUp()
        }
        XCTAssertTrue(restoredStorage.waitForExistence(timeout: 3))
        restoredStorage.tap()
        let restoredFolder = restored.descendants(matching: .any)[
            "storage.filesFolder"
        ]
        XCTAssertTrue(restoredFolder.waitForExistence(timeout: 3))
        XCTAssertTrue(waitForElement(restoredFolder, containing: "VLC"))

        restored.buttons["storage.renameFilesFolder"].tap()
        let rename = restored.alerts["Rename Files folder"]
        XCTAssertTrue(rename.waitForExistence(timeout: 3))
        rename.buttons["Cancel"].tap()

        restored.buttons["Select folder"].tap()
        restored.buttons["Use Documents Folder"].tap()
        XCTAssertFalse(
            restored.alerts["Name this Files folder?"]
                .waitForExistence(timeout: 1)
        )
        XCTAssertTrue(waitForElement(restoredFolder, containing: "VLC"))

        restored.buttons["Select folder"].tap()
        restored.buttons["Use Different Folder"].tap()
        XCTAssertTrue(
            waitForElement(
                restoredFolder,
                containing: "Illucet UI Other Files"
            )
        )

        restored.buttons["Select folder"].tap()
        restored.buttons["Use Documents Folder"].tap()
        let secondOffer = restored.alerts["Name this Files folder?"]
        XCTAssertTrue(secondOffer.waitForExistence(timeout: 4))
        secondOffer.buttons["Keep Documents"].tap()
        XCTAssertTrue(
            waitForElement(restoredFolder, containing: "Documents")
        )
    }

    func testDownloadOptionsFilesAndPhotosFolderSelectionPreservesDestination() {
        let app = launchApp(arguments: [
            "--ui-screen=configuration-files-and-photos",
            "--ui-folder-picker-fixture",
        ])
        let folder = app.buttons["Select Files folder"]
        for _ in 0..<10 where !folder.exists {
            app.swipeUp(velocity: .fast)
        }
        XCTAssertTrue(folder.waitForExistence(timeout: 3))
        folder.tap()
        XCTAssertTrue(
            app.buttons["Use Test Folder"].waitForExistence(timeout: 3)
        )
        app.buttons["Use Test Folder"].tap()
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(
                    format: "label CONTAINS %@",
                    "Files + Photos"
                )
            ).firstMatch.waitForExistence(timeout: 4)
        )
        XCTAssertTrue(
            app.buttons["Illucet UI Test Files"].waitForExistence(timeout: 3)
        )
    }

    func testFinalReviewDestinationChangeIsDirectAndPreservesOutput() {
        let app = launchApp(arguments: [
            "--ui-screen=confirmation",
            "--ui-folder-picker-fixture",
        ])
        XCTAssertTrue(
            app.otherElements["confirmation.sheet"]
                .waitForExistence(timeout: 4)
        )
        XCTAssertTrue(app.staticTexts["Video + Audio"].exists)
        app.buttons["Change"].tap()
        XCTAssertTrue(
            app.buttons["Files + Photos"].waitForExistence(timeout: 3)
        )
        app.buttons["Files + Photos"].tap()
        XCTAssertTrue(
            app.buttons["Use Test Folder"].waitForExistence(timeout: 4)
        )
        app.buttons["Use Test Folder"].tap()
        XCTAssertTrue(app.staticTexts["Files + Photos"].exists)
        XCTAssertTrue(app.staticTexts["Video + Audio"].exists)
        XCTAssertTrue(app.otherElements["confirmation.sheet"].exists)
    }

    func testQuickStartMissingFilesFolderUsesSheetOwnedRecovery() {
        let app = launchApp(arguments: [
            "--ui-screen=quick-confirmation",
            "--ui-quick-files",
            "--ui-folder-picker-fixture",
        ])
        let download = app.buttons["quick.confirm.download"]
        XCTAssertTrue(download.waitForExistence(timeout: 4))
        download.tap()
        XCTAssertTrue(
            app.buttons["Use Test Folder"].waitForExistence(timeout: 4)
        )
        XCTAssertTrue(
            app.otherElements["quick.confirmation.sheet"].exists
        )
    }

    func testPhotosFeedbackAndAppleUnsupportedHistoryAreExplicit() {
        let success = launchApp(arguments: ["--ui-screen=photos-success"])
        XCTAssertTrue(
            success.alerts["Saved to Photos"].waitForExistence(timeout: 4)
        )
        XCTAssertTrue(
            success.staticTexts["The verified output was saved to Photos."]
                .exists
        )
        success.terminate()

        let incompatible = launchApp(
            arguments: ["--ui-screen=photos-incompatible"]
        )
        let review = incompatible.buttons["configuration.review"]
        for _ in 0..<12 where !review.isHittable {
            incompatible.swipeUp()
        }
        XCTAssertTrue(review.waitForExistence(timeout: 3))
        XCTAssertTrue(review.isHittable)
        review.tap()
        XCTAssertTrue(
            incompatible.alerts["Couldn’t complete that"]
                .waitForExistence(timeout: 4)
        )
        XCTAssertTrue(
            incompatible.staticTexts.matching(
                NSPredicate(
                    format: "label CONTAINS %@",
                    "Photos accepts images and compatible MP4 or MOV video"
                )
            ).firstMatch.waitForExistence(timeout: 4)
        )
        incompatible.terminate()

        let history = launchApp(
            arguments: ["--ui-screen=history-apple-unsupported"]
        )
        XCTAssertTrue(
            history.staticTexts["history.playbackUnavailable"]
                .waitForExistence(timeout: 4)
        )
        XCTAssertTrue(
            history.staticTexts.matching(
                NSPredicate(
                    format: "label CONTAINS %@",
                    "This downloaded file is valid"
                )
            ).firstMatch.exists
        )
        XCTAssertTrue(
            history.staticTexts.matching(
                NSPredicate(
                    format: "label CONTAINS %@",
                    "A compatible app may be able to open it"
                )
            ).firstMatch.exists
        )
    }

    func testSponsorBlockGlobalDefaultsAndQuickStartPolicyAreEditable() {
        let app = launchApp()
        selectWorkspaceTab("Settings", in: app)
        let sponsorBlock = app.staticTexts["SponsorBlock"].firstMatch
        XCTAssertTrue(sponsorBlock.waitForExistence(timeout: 4))
        sponsorBlock.tap()
        XCTAssertTrue(
            app.navigationBars["SponsorBlock"]
                .waitForExistence(timeout: 4)
        )
        let enabled = app.switches["sponsorblock.enabled"]
        XCTAssertTrue(enabled.exists)
        setSwitch(enabled, to: true)
        let sponsor = app.buttons["sponsorblock.category.sponsor.action"]
        XCTAssertTrue(sponsor.waitForExistence(timeout: 3))
        sponsor.tap()
        XCTAssertFalse(app.buttons["Ask"].exists)
        XCTAssertFalse(app.buttons["Keep"].exists)
        app.buttons["Off"].tap()
        XCTAssertTrue(app.buttons["settings.sponsorblock.info"].exists)
        XCTAssertFalse(app.switches["sponsorblock.category.sponsor"].exists)
        setSwitch(enabled, to: false)

        app.navigationBars.buttons.element(boundBy: 0).tap()
        selectWorkspaceTab("Download", in: app)
        app.buttons["download.managePresets"].tap()
        XCTAssertTrue(
            app.navigationBars["Home Quick Start"]
                .waitForExistence(timeout: 4)
        )
        app.staticTexts["Best video"].tap()
        XCTAssertTrue(
            app.navigationBars["Edit preset"].waitForExistence(timeout: 4)
        )
        let presetEnabled = app.switches["sponsorblock.enabled"]
        for _ in 0..<8 where !presetEnabled.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(presetEnabled.waitForExistence(timeout: 3))
        setSwitch(presetEnabled, to: true)
        let presetSponsor = app.buttons["sponsorblock.category.sponsor.action"]
        for _ in 0..<4 where !presetSponsor.isHittable { app.swipeUp() }
        XCTAssertTrue(presetSponsor.waitForExistence(timeout: 3))
        let activePolicyWarning = app.staticTexts[
            "quick.editor.sponsorblock.review"
        ]
        for _ in 0..<10 where !activePolicyWarning.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(
            activePolicyWarning.waitForExistence(timeout: 3)
        )
    }

    private func setSwitch(_ element: XCUIElement, to isOn: Bool) {
        let expectedValue = isOn ? "1" : "0"
        if element.value as? String != expectedValue {
            element.coordinate(
                withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)
            ).tap()
        }
        XCTAssertEqual(element.value as? String, expectedValue)
    }

    func testSponsorBlockCategoryCardsAndIndividualOverrides() {
        let app = launchApp(arguments: ["--ui-screen=sponsorblock"])
        let loaded = app.staticTexts["sponsorblock.preview.loaded"]
        for _ in 0..<14 where !loaded.isHittable { app.swipeUp() }
        XCTAssertTrue(loaded.waitForExistence(timeout: 4))
        XCTAssertFalse(app.buttons["sponsorblock.category.outro.segments"].exists)
        XCTAssertFalse(app.switches["sponsorblock.segment.fixture-sponsor-001.included"].exists)
        let sponsor = app.buttons["sponsorblock.category.sponsor.action"]
        for _ in 0..<5 where !sponsor.isHittable { app.swipeUp() }
        sponsor.tap()
        XCTAssertTrue(app.buttons["Category default (Remove)"].exists)
        XCTAssertFalse(app.buttons["Remove"].exists)
        XCTAssertFalse(app.buttons["Ask"].exists)
        XCTAssertFalse(app.buttons["Keep"].exists)
        app.buttons["Off"].tap()
        let edit = app.buttons["sponsorblock.category.sponsor.segments"]
        edit.tap()
        XCTAssertTrue(app.navigationBars["Sponsor"].waitForExistence(timeout: 3))
        let segment = app.buttons["sponsorblock.segment.fixture-sponsor-001.action"]
        segment.tap()
        XCTAssertTrue(app.buttons["Category default (Off)"].exists)
        XCTAssertFalse(app.buttons["Off"].exists)
        app.buttons["Mark as Chapter"].tap()
        let editorScreenshot = XCTAttachment(screenshot: app.screenshot())
        editorScreenshot.name = "SponsorBlock individual override"
        editorScreenshot.lifetime = .keepAlways
        add(editorScreenshot)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["1 individual override"].waitForExistence(timeout: 3))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Grouped SponsorBlock categories"
        attachment.lifetime = .keepAlways
        add(attachment)
        let filler = app.buttons["sponsorblock.category.filler.action"]
        // Keep the gesture inside the centered configuration sheet on iPad.
        // A partially clipped menu can still report itself as hittable.
        let sheet = app.otherElements["configuration.sheet"]
        sheet.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
            .press(forDuration: 0.05, thenDragTo:
                sheet.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)))
        for _ in 0..<6 where !filler.isHittable { sheet.swipeUp() }
        filler.tap()
        XCTAssertTrue(app.buttons["Category default (Off)"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["Off"].exists)
        app.buttons["Category default (Off)"].tap()
        let review = app.buttons["configuration.review"]
        for _ in 0..<8 where !review.isHittable { app.swipeUp() }
        XCTAssertTrue(review.isEnabled)
    }

    func testSponsorBlockEmptyResultIsCompactAndAllowsDownload() {
        let app = launchApp(arguments: ["--ui-screen=sponsorblock-empty"])
        let message = app.staticTexts["sponsorblock.preview.empty"]
        for _ in 0..<14 where !message.isHittable { app.swipeUp() }
        XCTAssertEqual(message.label, "No SponsorBlock segments found for this video.")
        XCTAssertFalse(app.buttons["sponsorblock.category.sponsor.action"].exists)
        XCTAssertFalse(app.buttons["sponsorblock.category.filler.action"].exists)
        XCTAssertTrue(app.buttons["configuration.review"].isEnabled)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "SponsorBlock empty result"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testSponsorBlockLoadedBlockerIsActionableAndExclusionRecovers() {
        let app = launchApp(arguments: [
            "--ui-screen=sponsorblock-loaded-blocker",
        ])
        let loaded = app.staticTexts["sponsorblock.preview.loaded"]
        for _ in 0..<14 where !loaded.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(loaded.waitForExistence(timeout: 4))

        let review = app.buttons["configuration.review"]
        let reason = app.staticTexts[
            "configuration.review.unavailableReason"
        ]
        for _ in 0..<14 where !reason.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(reason.waitForExistence(timeout: 3))
        XCTAssertTrue(
            reason.label.contains("outside the analyzed media duration")
        )
        XCTAssertFalse(
            reason.label.contains("Wait for SponsorBlock segment review")
        )
        XCTAssertFalse(review.isEnabled)

        let edit = app.buttons["sponsorblock.category.sponsor.segments"]
        for _ in 0..<10 where !edit.isHittable { app.swipeDown() }
        edit.tap()
        let invalid = app.buttons["sponsorblock.segment.fixture-outside-001.action"]
        XCTAssertTrue(invalid.waitForExistence(timeout: 3))
        invalid.tap()
        app.buttons["Off"].tap()
        app.buttons["Done"].tap()

        for _ in 0..<12 where !review.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(review.isEnabled)
        XCTAssertFalse(reason.exists)
    }

    func testSponsorBlockAccurateAndFastModesExplainBoundaryTruth() {
        let app = launchApp(arguments: ["--ui-screen=sponsorblock-fast"])
        let removalMode = app.segmentedControls[
            "sponsorblock.removalMode"
        ]
        for _ in 0..<12 where !removalMode.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(removalMode.waitForExistence(timeout: 4))
        XCTAssertTrue(removalMode.buttons["Accurate"].isSelected)
        let fast = removalMode.buttons["Fast (Keyframe-Aligned)"]
        XCTAssertTrue(fast.isEnabled)
        fast.tap()
        XCTAssertTrue(
            app.staticTexts["sponsorblock.fast.warning"]
                .waitForExistence(timeout: 3)
        )
    }

    func testSponsorBlockLookupFailureBlocksRequiredRemovalButAllowsOptionalFallback() {
        let required = launchApp(arguments: [
            "--ui-sponsorblock-failure",
            "--ui-screen=sponsorblock-failure-required",
        ])
        let requiredTruth = required.staticTexts[
            "sponsorblock.failure.required"
        ]
        for _ in 0..<12 where !requiredTruth.isHittable {
            required.swipeUp()
        }
        XCTAssertTrue(requiredTruth.waitForExistence(timeout: 4))
        XCTAssertFalse(required.buttons["configuration.review"].isEnabled)
        required.terminate()

        let optional = launchApp(arguments: [
            "--ui-sponsorblock-failure",
            "--ui-screen=sponsorblock-failure-optional",
        ])
        let optionalTruth = optional.staticTexts[
            "sponsorblock.failure.optional"
        ]
        for _ in 0..<12 where !optionalTruth.isHittable {
            optional.swipeUp()
        }
        XCTAssertTrue(optionalTruth.waitForExistence(timeout: 4))
        XCTAssertTrue(optional.buttons["configuration.review"].isEnabled)
    }

    func testHistoryShowsVerifiedSponsorBlockApplicationAndAdjustedFastRanges() {
        let app = launchApp(arguments: [
            "--ui-screen=sponsorblock-history",
        ])
        let record = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "history.record."
            )
        ).firstMatch
        XCTAssertTrue(record.waitForExistence(timeout: 4))
        record.tap()
        let result = app.staticTexts["history.sponsorblock.result"]
            .firstMatch
        for _ in 0..<12 where !result.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(result.waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["Verified changes applied"].exists)
        XCTAssertTrue(app.staticTexts["Fast (Keyframe-Aligned)"].exists)
        XCTAssertTrue(
            app.staticTexts[
                "Fast mode adjusted one or more requested boundaries to verified keyframes."
            ].exists
        )
    }

    func testAccessibilityLargeTextLaunchDoesNotCrash() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing",
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityLarge",
        ]
        app.launch()
        XCTAssertTrue(
            waitForWorkspaceShell(app)
        )
        XCTAssertTrue(app.textFields["download.urlField"].exists)
    }

    func testAnalyzedSourceDisablesOnlyUnsatisfiedModesWithExplanation() {
        let app = launchApp(
            arguments: ["--ui-screen=configuration-video-only-source"]
        )
        XCTAssertTrue(
            app.otherElements["configuration.sheet"].waitForExistence(
                timeout: 4
            )
        )

        app.buttons["configuration.output"].tap()
        let combined = app.buttons["configuration.mode.Video + Audio"]
        let audioOnly = app.buttons["configuration.mode.Audio Only"]
        let videoOnly = app.buttons["configuration.mode.Video Only"]
        XCTAssertTrue(combined.exists)
        XCTAssertFalse(combined.isEnabled)
        XCTAssertTrue(audioOnly.exists)
        XCTAssertFalse(audioOnly.isEnabled)
        XCTAssertTrue(videoOnly.exists)
        XCTAssertTrue(videoOnly.isEnabled)
        XCTAssertTrue(combined.label.contains("no usable audio"))
        XCTAssertTrue(audioOnly.label.contains("no usable audio"))

        let review = app.buttons["configuration.review"]
        XCTAssertFalse(review.isEnabled)
        XCTAssertTrue(
            app.descendants(matching: .any)[
                "configuration.review.unavailableReason"
            ].waitForExistence(timeout: 3)
        )
        videoOnly.tap()
        XCTAssertTrue(review.isEnabled)
    }

    func testThumbnailOnlyConfigurationHidesMediaControls() {
        let app = launchApp(
            arguments: ["--ui-polish-reset", "--ui-light-appearance", "--ui-screen=configuration-thumbnail"]
        )
        XCTAssertTrue(
            app.otherElements["configuration.sheet"].waitForExistence(
                timeout: 4
            )
        )
        XCTAssertTrue(
            app.staticTexts["Only the selected image will be downloaded"]
                .exists
        )
        XCTAssertTrue(
            app.staticTexts["Thumbnail only — no media streams"].exists
        )
        let crop = app.switches["Crop output to square"]
        for _ in 0..<4 where !crop.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(crop.waitForExistence(timeout: 3))
        XCTAssertEqual(crop.value as? String, "0")
        keepScreenshot(app, name: "Standalone thumbnail preserves full image by default")
        XCTAssertFalse(
            app.buttons["configuration.mode.Video + Audio"].exists
        )
        let review = app.buttons["configuration.review"]
        XCTAssertTrue(review.exists)
        XCTAssertTrue(review.isEnabled)
        review.tap()
        XCTAssertTrue(
            app.otherElements["confirmation.sheet"].waitForExistence(
                timeout: 4
            )
        )
        XCTAssertTrue(app.staticTexts["Thumbnail Only"].exists)
        XCTAssertTrue(app.staticTexts["Preserve full image"].exists)
    }

    func testThumbnailOnlyCanExplicitlyCropInDarkMode() {
        let app = launchApp(arguments: ["--ui-polish-reset", "--ui-dark-appearance", "--ui-screen=configuration-thumbnail"])
        let crop = app.switches["Crop output to square"]
        for _ in 0..<4 where !crop.isHittable { app.swipeUp() }
        XCTAssertTrue(crop.waitForExistence(timeout: 3))
        XCTAssertEqual(crop.value as? String, "0")
        keepScreenshot(app, name: "Thumbnail crop default off dark")
        crop.tap()
        XCTAssertEqual(crop.value as? String, "1")
        app.buttons["configuration.review"].tap()
        XCTAssertTrue(app.otherElements["confirmation.sheet"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["Square"].exists)
        keepScreenshot(app, name: "Explicit square crop remains available dark")
    }

    func testFailedThumbnailOnlyIdentityStaysTruthfulInQueueAndHistory() {
        let app = launchApp(arguments: ["--ui-screen=output-truth"])
        XCTAssertTrue(
            app.navigationBars["Queue"].waitForExistence(timeout: 4)
        )
        XCTAssertTrue(app.staticTexts["Thumbnail Only"].exists)
        XCTAssertTrue(
            app.images[
                "queue.job.81314000-0000-0000-0000-000000000001.outputTypeIcon"
            ].exists
        )

        app.staticTexts["Failed Thumbnail Fixture"].tap()
        XCTAssertTrue(
            app.navigationBars["Job details"].waitForExistence(timeout: 4)
        )
        XCTAssertTrue(app.staticTexts["Thumbnail Only"].exists)
        app.buttons["Done"].tap()

        selectWorkspaceTab("History", in: app)
        XCTAssertTrue(
            app.navigationBars["History"].waitForExistence(timeout: 4)
        )
        XCTAssertTrue(
            app.buttons[
                "Failed Thumbnail Fixture, Failed, Thumbnail Only"
            ].waitForExistence(timeout: 3)
        )
        app.buttons["history.filters"].tap()
        app.buttons["Video + Audio"].tap()
        XCTAssertTrue(app.staticTexts["No matches"].waitForExistence(timeout: 3))
        app.buttons["Clear filters"].tap()

        let record = app.buttons[
            "Failed Thumbnail Fixture, Failed, Thumbnail Only"
        ]
        XCTAssertTrue(record.waitForExistence(timeout: 3))
        record.tap()
        XCTAssertTrue(
            app.navigationBars["Output details"].waitForExistence(timeout: 4)
        )
        XCTAssertTrue(app.staticTexts["Thumbnail Only"].exists)
    }

    func testSubtitlesOnlySelectionRequiresExactTracksAndReviewsWithoutMedia() {
        let app = launchApp(arguments: ["--ui-screen=configuration"])
        XCTAssertTrue(
            app.otherElements["configuration.sheet"].waitForExistence(
                timeout: 4
            )
        )
        app.buttons["configuration.output"].tap()
        let subtitlesOnly = app.buttons["configuration.mode.Subtitles Only"]
        for _ in 0..<4 where !subtitlesOnly.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(subtitlesOnly.isEnabled)
        subtitlesOnly.tap()
        XCTAssertTrue(
            app.staticTexts["Subtitles only — no media streams"]
                .waitForExistence(timeout: 3)
        )
        XCTAssertFalse(app.staticTexts["Preset"].exists)
        XCTAssertFalse(app.staticTexts["Video quality"].exists)
        XCTAssertFalse(app.buttons["configuration.thumbnail"].exists)

        let review = app.buttons["configuration.review"]
        XCTAssertTrue(review.exists)
        XCTAssertTrue(review.isEnabled)
        let choose = app.buttons["configuration.subtitle.choose"]
        for _ in 0..<6 where !choose.isHittable { app.swipeUp() }
        choose.tap()
        let manual = app.buttons[
            "configuration.subtitle.subtitle-111111111111111111111111.subtitle-format-111111111111111111111111"
        ]
        for _ in 0..<5 where !manual.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(manual.waitForExistence(timeout: 3))
        XCTAssertEqual(manual.value as? String, "Selected")
        manual.tap()
        XCTAssertEqual(manual.value as? String, "Not selected")
        manual.tap()
        app.buttons["Done"].tap()
        for _ in 0..<5 where !review.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(review.isEnabled)
        review.tap()

        XCTAssertTrue(
            app.otherElements["confirmation.sheet"].waitForExistence(
                timeout: 4
            )
        )
        XCTAssertTrue(app.staticTexts["Subtitles Only"].exists)
        XCTAssertTrue(app.staticTexts["1 deterministic title-based files"].exists)
        XCTAssertTrue(app.staticTexts["None"].exists)
        XCTAssertTrue(app.staticTexts["Illucet"].exists)
        XCTAssertTrue(app.buttons["confirmation.start"].isEnabled)
    }

    func testEffectiveOutputTransitionsNeverExposeTwoActiveModes() {
        let app = launchApp(arguments: ["--ui-screen=configuration"])
        XCTAssertTrue(
            app.otherElements["configuration.sheet"].waitForExistence(
                timeout: 4
            )
        )
        let output = app.buttons["configuration.output"]
        XCTAssertTrue(output.label.contains("Video + Audio"))
        output.tap()
        let videoAndAudio = app.buttons[
            "configuration.mode.Video + Audio"
        ]
        let subtitles = app.buttons[
            "configuration.mode.Subtitles Only"
        ]
        subtitles.tap()
        XCTAssertTrue(output.label.contains("Subtitles Only"))
        XCTAssertFalse(output.label.contains("Video + Audio"))
        output.tap()

        videoAndAudio.tap()
        XCTAssertTrue(output.label.contains("Video + Audio"))
        XCTAssertFalse(output.label.contains("Subtitles Only"))
        app.terminate()

        let thumbnailApp = launchApp(
            arguments: ["--ui-screen=configuration-thumbnail"]
        )
        XCTAssertTrue(
            thumbnailApp.staticTexts["Thumbnail only — no media streams"]
                .waitForExistence(timeout: 3)
        )
        XCTAssertFalse(
            thumbnailApp.buttons["configuration.mode.Video + Audio"].exists
        )
        XCTAssertFalse(
            thumbnailApp.buttons["configuration.mode.Subtitles Only"].exists
        )
    }

    func testQueueUsesFullTransferRangeAndSeparateProcessingRange() {
        let app = launchApp(arguments: ["--ui-screen=queue-stage-progress"])
        let prefix = "queue.job.81314000-0000-0000-0000-000000000001."
        let percent = app.staticTexts[prefix + "stagePercent"]
        XCTAssertTrue(percent.waitForExistence(timeout: 5))
        let full = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == '100%'"), object: percent)
        XCTAssertEqual(XCTWaiter.wait(for: [full], timeout: 5), .completed)
        let processing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == '40%'"), object: percent)
        XCTAssertEqual(XCTWaiter.wait(for: [processing], timeout: 10), .completed)
        XCTAssertEqual(app.staticTexts[prefix + "stage"].label, "Converting")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Separate current-stage progress"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testQueueProgressLayoutStaysStable() {
        checkQueueProgressLayout(arguments: ["--ui-light-appearance"])
    }

    func testQueueProgressLayoutStaysStableWithLargeText() {
        checkQueueProgressLayout(arguments: ["--ui-dark-appearance",
            "-UIPreferredContentSizeCategoryName", UIContentSizeCategory.accessibilityLarge.rawValue])
    }

    private func checkQueueProgressLayout(arguments: [String]) {
        let app = launchApp(arguments: arguments + ["--ui-screen=queue-progress-stability"])
        let prefix = "queue.job.81314000-0000-0000-0000-000000000001."
        let pause = app.buttons[prefix + "pause"]
        let eta = app.staticTexts[prefix + "remainingETA"]
        XCTAssertTrue(pause.waitForExistence(timeout: 5))
        XCTAssertTrue(eta.exists)
        if arguments.contains(UIContentSizeCategory.accessibilityLarge.rawValue) {
            XCTAssertGreaterThan(eta.frame.height, 20, "The accessibility text-size override must actually enlarge the caption")
        }
        let initial = pause.frame
        var labels = Set<String>()
        for _ in 0..<8 {
            Thread.sleep(forTimeInterval: 0.6)
            labels.insert(eta.label)
            XCTAssertEqual(pause.frame.minY, initial.minY, accuracy: 1)
            XCTAssertEqual(pause.frame.height, initial.height, accuracy: 1)
            XCTAssertTrue(eta.isHittable)
        }
        XCTAssertGreaterThan(labels.count, 1, "The fixture must exercise changing estimates")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Stable changing download metrics"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testQueueProcessingStageHidesRetainedTransferMetrics() {
        let app = launchApp(
            arguments: ["--ui-screen=queue-processing-truth"]
        )
        XCTAssertTrue(
            app.navigationBars["Queue"].waitForExistence(timeout: 4)
        )
        let jobID = "81314000-0000-0000-0000-000000000001"
        let stage = app.staticTexts["queue.job.\(jobID).stage"]
        XCTAssertTrue(stage.waitForExistence(timeout: 3))
        XCTAssertEqual(stage.label, "Verifying output")
        XCTAssertFalse(
            app.staticTexts["queue.job.\(jobID).transferBytes"].exists
        )
        XCTAssertFalse(
            app.staticTexts["queue.job.\(jobID).transferSpeed"].exists
        )
        XCTAssertFalse(
            app.staticTexts["queue.job.\(jobID).remainingETA"].exists
        )

        let progressScreenshot = XCTAttachment(screenshot: app.screenshot())
        progressScreenshot.name = "Processing stage hides stale transfer data"
        progressScreenshot.lifetime = .keepAlways
        add(progressScreenshot)

        app.staticTexts["Processing Metrics Fixture"].tap()
        XCTAssertTrue(
            app.navigationBars["Job details"].waitForExistence(timeout: 4)
        )
        XCTAssertTrue(app.staticTexts["Verifying output"].exists)
        XCTAssertFalse(app.staticTexts["Average speed"].exists)
        XCTAssertFalse(app.staticTexts["Download ETA"].exists)
    }

    func testPartialExportHistoryKeepsDestinationResults() {
        checkPartialExportHistory(appearance: "--ui-light-appearance")
    }

    func testPartialExportHistoryKeepsDestinationResultsInDarkMode() {
        checkPartialExportHistory(appearance: "--ui-dark-appearance")
    }

    private func checkPartialExportHistory(appearance: String) {
        let app = launchApp(arguments: ["--ui-screen=history-export-recovery", appearance])
        XCTAssertTrue(app.navigationBars["Output details"].waitForExistence(timeout: 5))
        let results = app.staticTexts["Save results"]
        let retry = app.buttons["Retry export"]
        for _ in 0..<5 where !retry.isHittable { app.swipeUp() }
        app.swipeUp()
        XCTAssertTrue(results.isHittable)
        XCTAssertTrue(app.staticTexts["Files: saved"].exists)
        XCTAssertTrue(app.staticTexts["D2-retained.png"].exists)
        XCTAssertTrue(app.staticTexts["Photos: permission denied. Allow access in Settings, then retry export."].exists)
        XCTAssertTrue(app.buttons["Open Settings"].exists)
        XCTAssertTrue(retry.isHittable)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Partial Files and Photos export " + appearance
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testCompletedJobDetailsHideRetainedRunningMetrics() {
        checkCompletedJobDetails(appearance: "--ui-light-appearance")
    }

    func testCompletedJobDetailsHideRetainedRunningMetricsInDarkMode() {
        checkCompletedJobDetails(appearance: "--ui-dark-appearance")
    }

    private func checkCompletedJobDetails(appearance: String) {
        let app = launchApp(arguments: ["--ui-screen=queue-completed-details", appearance])
        XCTAssertTrue(app.navigationBars["Queue"].waitForExistence(timeout: 4))
        for title in ["Completed Media Fixture", "Completed Subtitles Fixture"] {
            let row = app.staticTexts[title]
            XCTAssertTrue(row.waitForExistence(timeout: 4))
            row.tap()
            XCTAssertTrue(app.navigationBars["Job details"].waitForExistence(timeout: 4))
            XCTAssertTrue(app.staticTexts["Completed"].exists)
            for stale in ["Stream 140", "Time remaining", "Processing", "Average speed", "Not started"] {
                XCTAssertFalse(app.staticTexts[stale].exists, stale)
            }
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = title + " details"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            app.buttons["Done"].tap()
        }
    }

    func testTransferSlotWaitingControlsInLightMode() {
        checkTransferSlotWaiting(appearance: "--ui-light-appearance")
    }

    func testTransferSlotWaitingControlsInDarkMode() {
        checkTransferSlotWaiting(appearance: "--ui-dark-appearance")
    }

    private func checkTransferSlotWaiting(appearance: String) {
        let app = launchApp(arguments: ["--ui-screen=queue-slot-wait", appearance])
        XCTAssertTrue(app.staticTexts["Waiting"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Pause"].exists)
        XCTAssertTrue(app.buttons["Prioritize"].exists)
        for title in ["Pause", "Prioritize", "Cancel"] {
            XCTAssertLessThan(app.buttons[title].frame.height, 60, "Oversized queue action: \(title)")
        }
        XCTAssertFalse(app.staticTexts["Downloading"].exists)
        let bytes = app.staticTexts.matching(NSPredicate(format: "identifier ENDSWITH %@", ".transferBytes")).firstMatch
        XCTAssertTrue(bytes.exists)
        XCTAssertTrue(bytes.label.contains("73.4"), bytes.label)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Transfer slot waiting queue"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.staticTexts["Waiting Transfer Fixture"].tap()
        XCTAssertTrue(app.navigationBars["Job details"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["Waiting"].exists)
        XCTAssertTrue(app.buttons["Pause"].exists)
        XCTAssertTrue(app.buttons["Prioritize"].exists)
        let details = XCTAttachment(screenshot: app.screenshot())
        details.name = "Transfer slot waiting details"
        details.lifetime = .keepAlways
        add(details)
    }

    func testSavedOutputAccessInLightMode() {
        checkSavedOutputAccess(appearance: "--ui-light-appearance")
    }

    func testSavedOutputAccessInDarkMode() {
        checkSavedOutputAccess(appearance: "--ui-dark-appearance")
    }

    private func checkSavedOutputAccess(appearance: String) {
        for mode in ["relocated", "external", "revoked"] {
            let app = launchApp(arguments: ["--ui-screen=output-access-" + mode, appearance])
            let title = mode == "relocated" ? "Retained Output Fixture" : "External Output Fixture"
            XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 5))
            app.staticTexts[title].firstMatch.tap()
            let open = app.buttons["Open output details"]
            for _ in 0..<6 where !open.isHittable { app.swipeUp() }
            XCTAssertTrue(open.isHittable)
            open.tap()
            XCTAssertTrue(app.navigationBars["Output details"].waitForExistence(timeout: 4))
            if mode == "revoked" {
                XCTAssertTrue(app.buttons["output.reauthorize"].waitForExistence(timeout: 5))
                XCTAssertTrue(app.staticTexts["history.playbackUnavailable"].label.contains("Choose the saved folder"))
                XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", "Choose the saved folder to restore access.")).count, 1)
                XCTAssertFalse(app.images["Saved thumbnail preview"].exists)
            } else {
                XCTAssertTrue(app.images["Saved thumbnail preview"].waitForExistence(timeout: 5))
                XCTAssertFalse(app.buttons["output.reauthorize"].exists)
                let share = app.buttons["output.share"]
                for _ in 0..<6 where !share.isHittable { app.swipeUp() }
                XCTAssertTrue(share.isHittable)
            }
            keepScreenshot(app, name: "Saved output " + mode + " " + appearance)
            if mode == "external" {
                app.buttons["output.share"].tap()
                let close = app.buttons["Close"]
                XCTAssertTrue(close.waitForExistence(timeout: 6))
                keepScreenshot(app, name: "External output share " + appearance)
                close.tap()
                XCTAssertTrue(app.navigationBars["Output details"].waitForExistence(timeout: 4))
                XCTAssertTrue(app.buttons["output.share"].waitForExistence(timeout: 5))
                XCTAssertTrue(app.images["Saved thumbnail preview"].exists)
                XCTAssertFalse(app.buttons["output.reauthorize"].exists)
            }
            app.terminate()
        }
        let settings = launchApp(arguments: ["--ui-tab=settings", appearance])
        let row = settings.descendants(matching: .any).matching(identifier: "settings.storage").firstMatch
        for _ in 0..<5 where !row.isHittable { settings.swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let measured = XCTNSPredicateExpectation(predicate: NSPredicate(format: "NOT label CONTAINS 'Calculating' AND NOT label CONTAINS 'Updating'"), object: row)
        XCTAssertEqual(XCTWaiter.wait(for: [measured], timeout: 8), .completed)
        XCTAssertFalse(row.label.contains("Zero kB"), row.label)
        keepScreenshot(settings, name: "Measured Settings storage " + appearance)
    }

    func testBackgroundWaitingAndCleanupControlsInLightMode() {
        checkBackgroundWaitingAndCleanup(appearance: "--ui-light-appearance")
    }

    func testBackgroundWaitingAndCleanupControlsInDarkMode() {
        checkBackgroundWaitingAndCleanup(appearance: "--ui-dark-appearance")
    }

    private func checkBackgroundWaitingAndCleanup(appearance: String) {
        let prefix = "queue.job.81314000-0000-0000-0000-000000000001."
        let waiting = launchApp(arguments: ["--ui-screen=queue-background-wait", appearance])
        let stage = waiting.staticTexts[prefix + "stage"]
        XCTAssertTrue(stage.waitForExistence(timeout: 5))
        XCTAssertEqual(stage.label, "Waiting for background time")
        XCTAssertTrue(waiting.staticTexts["Waiting"].exists)
        for title in ["Pause", "Cancel"] {
            XCTAssertTrue(waiting.buttons[title].isHittable)
            XCTAssertLessThan(waiting.buttons[title].frame.height, 60)
        }
        for suffix in ["stagePercent", "transferSpeed", "remainingETA"] {
            XCTAssertFalse(waiting.staticTexts[prefix + suffix].exists)
        }
        keepScreenshot(waiting, name: "Background grant waiting queue " + appearance)
        waiting.staticTexts["Background Time Fixture"].tap()
        XCTAssertTrue(waiting.navigationBars["Job details"].waitForExistence(timeout: 4))
        XCTAssertTrue(waiting.staticTexts["Waiting for background time"].exists)
        let pause = waiting.buttons["job.detail.pause"]
        for _ in 0..<6 where !pause.isHittable { waiting.swipeUp() }
        XCTAssertTrue(pause.isHittable)
        keepScreenshot(waiting, name: "Background grant waiting controls " + appearance)
        waiting.terminate()

        let cleanup = launchApp(arguments: ["--ui-screen=queue-transfer-cleanup", appearance])
        XCTAssertTrue(cleanup.staticTexts["Waiting for transfer cleanup. Reopen Illucet if it does not finish."].waitForExistence(timeout: 5))
        XCTAssertFalse(cleanup.buttons["Retry"].exists)
        XCTAssertTrue(cleanup.buttons["Cancel"].isHittable)
        keepScreenshot(cleanup, name: "Transfer cleanup queue " + appearance)
        cleanup.staticTexts["Transfer Cleanup Fixture"].tap()
        XCTAssertTrue(cleanup.navigationBars["Job details"].waitForExistence(timeout: 4))
        let retry = cleanup.buttons["job.detail.retry"]
        for _ in 0..<6 where !retry.isHittable { cleanup.swipeUp() }
        XCTAssertTrue(retry.exists)
        XCTAssertFalse(retry.isEnabled)
        XCTAssertTrue(cleanup.buttons["job.detail.cancel"].isHittable)
        keepScreenshot(cleanup, name: "Transfer cleanup controls " + appearance)
    }

    private func keepScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testSubtitlesOnlyIdentityStaysTruthfulAcrossTerminalLifecycle() {
        let app = launchApp(
            arguments: ["--ui-screen=subtitles-output-truth"]
        )
        XCTAssertTrue(
            app.navigationBars["Queue"].waitForExistence(timeout: 4)
        )
        XCTAssertGreaterThanOrEqual(
            app.staticTexts.matching(
                NSPredicate(format: "label == %@", "Subtitles Only")
            ).count,
            2
        )
        XCTAssertTrue(
            app.images[
                "queue.job.81500000-0000-0000-0000-000000000001.outputTypeIcon"
            ].exists
        )
        app.staticTexts["Failed Subtitles Fixture"].tap()
        XCTAssertTrue(
            app.navigationBars["Job details"].waitForExistence(timeout: 4)
        )
        XCTAssertTrue(app.staticTexts["Subtitles Only"].exists)
        XCTAssertTrue(app.staticTexts["Subtitle format"].exists)
        XCTAssertFalse(app.staticTexts["Format IDs"].exists)
        app.buttons["Done"].tap()

        selectWorkspaceTab("History", in: app)
        XCTAssertTrue(
            app.navigationBars["History"].waitForExistence(timeout: 4)
        )
        let failed = app.buttons[
            "Failed Subtitles Fixture, Failed, Subtitles Only"
        ]
        let completed = app.buttons[
            "Completed Subtitles Fixture, Completed, Subtitles Only"
        ]
        XCTAssertTrue(failed.waitForExistence(timeout: 3))
        XCTAssertTrue(completed.exists)
        completed.tap()
        XCTAssertTrue(
            app.navigationBars["Output details"].waitForExistence(timeout: 4)
        )
        XCTAssertTrue(app.staticTexts["Verified subtitle files"].exists)
        XCTAssertTrue(
            app.staticTexts[
                "No video, audio, or media probe belongs to this request."
            ].exists
        )
        XCTAssertTrue(app.staticTexts["Subtitle outputs"].exists)
        XCTAssertTrue(
            app.staticTexts[
                "Completed Subtitles Fixture.en.manual.11111111-11111111.vtt"
            ].exists
        )
    }

    func testDuplicateAskPresentsEveryRealResolution() {
        let app = launchApp(arguments: ["--ui-screen=duplicate"])
        XCTAssertTrue(
            app.buttons["Replace Existing File"].waitForExistence(
                timeout: 4
            )
        )
        XCTAssertTrue(app.buttons["Keep Both — Add Number"].exists)
        XCTAssertTrue(app.buttons["Keep Both — Add Video ID"].exists)
        XCTAssertTrue(app.buttons["Skip This Download"].exists)
        app.buttons["Skip This Download"].tap()
        XCTAssertTrue(
            app.buttons["Replace Existing File"].waitForNonExistence(
                timeout: 2
            )
        )
    }

    func testCompletedShareRequestPresentsSystemActivitySheet() {
        let app = launchApp(arguments: ["--ui-screen=share"])
        let activitySheet = app.otherElements[
            "share.sheet.00000000-0000-0000-0000-000000000200"
        ]
        XCTAssertTrue(
            activitySheet.waitForExistence(timeout: 5)
        )
        let close = app.buttons["Close"]
        XCTAssertTrue(close.waitForExistence(timeout: 2))
        close.tap()
        XCTAssertTrue(activitySheet.waitForNonExistence(timeout: 3))
    }

    func testDuplicateQuestionsArePresentedInFIFOOrder() {
        let app = launchApp(arguments: ["--ui-screen=duplicate-queue"])
        for filename in [
            "Alpha Existing.mp4",
            "Beta Existing.mp4",
            "Gamma Existing.mp4",
        ] {
            let message = app.staticTexts.matching(
                NSPredicate(
                    format: "label CONTAINS %@",
                    filename
                )
            ).firstMatch
            XCTAssertTrue(
                message.waitForExistence(timeout: 4),
                "Expected duplicate question for \(filename)"
            )
            app.buttons["Keep Both — Add Number"].tap()
        }
        XCTAssertTrue(
            app.buttons["Replace Existing File"].waitForNonExistence(
                timeout: 3
            )
        )
    }

    func testShareRequestsArePresentedInFIFOOrder() {
        let app = launchApp(arguments: ["--ui-screen=share-queue"])
        let jobIDs = [
            "00000000-0000-0000-0000-000000000200",
            "00000000-0000-0000-0000-000000000201",
            "00000000-0000-0000-0000-000000000202",
        ]
        for (index, jobID) in jobIDs.enumerated() {
            let sheet = app.otherElements[
                "share.sheet.\(jobID.uppercased())"
            ]
            XCTAssertTrue(
                sheet.waitForExistence(timeout: 5),
                "Expected share request \(jobID)"
            )
            let close = app.buttons["Close"]
            XCTAssertTrue(close.waitForExistence(timeout: 3))
            close.tap()
            if index + 1 < jobIDs.count {
                let next = app.otherElements[
                    "share.sheet.\(jobIDs[index + 1].uppercased())"
                ]
                XCTAssertTrue(
                    next.waitForExistence(timeout: 5),
                    "Expected next share request"
                )
            }
        }
    }

    func testPlaylistSelectionConfigReviewAndQueueFlowResponds() {
        let app = launchApp(arguments: ["--ui-screen=playlist"])
        XCTAssertTrue(
            app.otherElements["playlist.sheet"].waitForExistence(
                timeout: 5
            )
        )
        XCTAssertTrue(
            app.scrollViews["playlist.step.selection"].exists
        )
        XCTAssertTrue(app.buttons["playlist.continue"].exists)
        app.buttons["playlist.continue"].tap()

        XCTAssertTrue(
            app.scrollViews["playlist.step.options"]
                .waitForExistence(timeout: 4)
        )
        let audioMode = app.buttons["playlist.mode.Audio Only"]
        XCTAssertTrue(audioMode.waitForExistence(timeout: 3))
        audioMode.tap()
        for _ in 0..<5 where !app.buttons["playlist.review"].exists {
            app.swipeUp()
        }
        XCTAssertTrue(
            app.buttons["playlist.review"].waitForExistence(timeout: 3)
        )
        app.buttons["playlist.review"].tap()

        XCTAssertTrue(
            app.scrollViews["playlist.step.review"]
                .waitForExistence(timeout: 4)
        )
        XCTAssertTrue(app.staticTexts["Audio Only"].exists)
        for _ in 0..<4 where !app.buttons["playlist.start"].exists {
            app.swipeUp()
        }
        XCTAssertTrue(
            app.buttons["playlist.start"].waitForExistence(timeout: 3)
        )
        app.buttons["playlist.start"].tap()

        XCTAssertTrue(
            app.navigationBars["Queue"].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            app.staticTexts["Illucet Road Trip Mix"]
                .waitForExistence(timeout: 5)
        )
    }

    func testGroupedBatchAndDownloadArchiveAreInteractive() {
        let app = launchApp(arguments: ["--ui-screen=batch-queue"])
        let batch = app.otherElements[
            "queue.batch.B6000000-0000-0000-0000-000000000001"
        ]
        XCTAssertTrue(batch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Complete with issues"].exists)
        XCTAssertTrue(app.staticTexts["Never Gonna Give You Up"].exists)
        XCTAssertTrue(app.buttons["queue.archive"].exists)
        app.buttons["queue.archive"].tap()

        XCTAssertTrue(
            app.otherElements["archive.sheet"].waitForExistence(
                timeout: 4
            )
        )
        let archived = app.otherElements[
            "archive.entry.dQw4w9WgXcQ"
        ]
        XCTAssertTrue(archived.waitForExistence(timeout: 3))
        let remove = app.buttons["archive.remove.dQw4w9WgXcQ"]
        XCTAssertTrue(remove.exists)
        remove.tap()
        XCTAssertTrue(archived.waitForNonExistence(timeout: 3))
    }

    func testCellularQuestionOffersEveryRequiredDecision() {
        let app = launchApp(arguments: ["--ui-screen=cellular"])
        XCTAssertTrue(
            app.buttons["Continue Once"].waitForExistence(timeout: 4)
        )
        XCTAssertTrue(app.buttons["Always Allow Cellular"].exists)
        XCTAssertTrue(app.buttons["Wait for Wi-Fi"].exists)
        XCTAssertTrue(app.buttons["Cancel Download"].exists)
        app.buttons["Wait for Wi-Fi"].tap()
        XCTAssertTrue(
            app.buttons["Continue Once"].waitForNonExistence(timeout: 3)
        )
    }

    func testRuntimeProofInspectionShowsEveryCheckFailureFirstWithEvidence() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-screen=runtime-proof-inspection"]
        app.launch()
        XCTAssertTrue(
            app.navigationBars["Diagnostics"].waitForExistence(timeout: 4)
        )

        let summaryText = "14 PASS • 1 FAIL • 1 BLOCKED"
        let summary = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "label CONTAINS %@ OR value CONTAINS %@",
                summaryText,
                summaryText
            )
        ).firstMatch
        for _ in 0..<8 where !summary.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(summary.waitForExistence(timeout: 3))

        let failure = app.descendants(matching: .any)[
            "diagnostics.stage0.check.fixture-late-failure"
        ]
        for _ in 0..<3 where !failure.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(failure.waitForExistence(timeout: 3))
        XCTAssertTrue(
            app.staticTexts[
                "This failure began after the old 12-row cutoff."
            ].exists
        )
        XCTAssertTrue(
            app.descendants(matching: .any)[
                "diagnostics.stage0.check.fixture-late-blocked"
            ].exists
        )

        let finalPass = app.descendants(matching: .any)[
            "diagnostics.stage0.check.fixture-pass-14"
        ]
        for _ in 0..<18 where !finalPass.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(finalPass.waitForExistence(timeout: 3))
        XCTAssertTrue(
            app.staticTexts["Deterministic passing evidence 14."].exists
        )
    }

    private func launchApp() -> XCUIApplication {
        launchApp(arguments: [])
    }

    private func waitForElement(
        _ element: XCUIElement,
        containing text: String,
        timeout: TimeInterval = 3
    ) -> Bool {
        let predicate = NSPredicate { value, _ in
            guard let element = value as? XCUIElement else { return false }
            return element.label.contains(text)
                || String(describing: element.value).contains(text)
        }
        let expectation = XCTNSPredicateExpectation(
            predicate: predicate,
            object: element
        )
        return XCTWaiter.wait(
            for: [expectation],
            timeout: timeout
        ) == .completed
    }

    private func waitForElementValue(
        _ element: XCUIElement,
        differingFrom originalValue: String?,
        timeout: TimeInterval = 3
    ) -> Bool {
        let predicate = NSPredicate { value, _ in
            guard let element = value as? XCUIElement else { return false }
            return element.value as? String != originalValue
        }
        let expectation = XCTNSPredicateExpectation(
            predicate: predicate,
            object: element
        )
        return XCTWaiter.wait(
            for: [expectation],
            timeout: timeout
        ) == .completed
    }

    private func launchApp(arguments: [String]) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"] + arguments
        app.launch()
        XCTAssertTrue(
            waitForWorkspaceShell(app)
        )
        return app
    }
}
