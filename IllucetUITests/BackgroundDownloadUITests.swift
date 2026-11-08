import XCTest

/// Live, explicitly enabled simulator proof using the normal app and actual Home
/// transition. No fixture mode, injected execution grant or foreground reactivation.
@MainActor
final class BackgroundDownloadUITests: XCTestCase {
    func testAuthorizedVideoCompletesWithoutReopening() throws {
        try runAuthorizedVideo(waitForNativeOwnership: true)
    }

    func testAuthorizedVideoCompletesWhenBackgroundedDuringPreparation() throws {
        try runAuthorizedVideo(waitForNativeOwnership: false)
    }

    private func runAuthorizedVideo(waitForNativeOwnership: Bool) throws {
        let env = ProcessInfo.processInfo.environment
        guard env["ILLUCET_BACKGROUND_LIVE"] == "1" else {
            throw XCTSkip("Requires a separate authorized background-live invocation")
        }
        #if !targetEnvironment(simulator)
        throw XCTSkip("This proof is authorized for Simulator only")
        #else
        continueAfterFailure = false
        let configPath = try XCTUnwrap(env["ILLUCET_AUTHORIZED_LIVE_TEST_CONFIG_PATH"])
        let config = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: Data(contentsOf: URL(filePath: configPath)), format: nil) as? [String: Any])
        XCTAssertEqual(config["LiveTestsEnabled"] as? Bool, true)
        let source = try XCTUnwrap(config["StandardVideoURL"] as? String)
        var stateURL = URL(filePath: try XCTUnwrap(env["ILLUCET_BACKGROUND_APP_STATE_PATH"]))
        var containersURL = stateURL
        for _ in 0..<5 { containersURL.deleteLastPathComponent() }
        let receiptURL = URL(filePath: try XCTUnwrap(env["ILLUCET_BACKGROUND_RECEIPT_PATH"]))
        func state() throws -> [String: Any] {
            if !FileManager.default.fileExists(atPath: stateURL.path) {
                // Xcode may relocate this app's preserved container at launch.
                // Follow only Illucet's named snapshot, without opening the app.
                let candidates = try FileManager.default.contentsOfDirectory(at: containersURL,
                    includingPropertiesForKeys: nil).map {
                        $0.appending(path: "Library/Application Support/Illucet/IllucetState.json")
                    }.filter { FileManager.default.fileExists(atPath: $0.path) }
                XCTAssertEqual(candidates.count, 1, "Require one unambiguous Illucet snapshot")
                stateURL = try XCTUnwrap(candidates.first)
            }
            return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any])
        }
        func jobs() throws -> [[String: Any]] { try state()["jobs"] as? [[String: Any]] ?? [] }
        let originalIDs = Set(try jobs().compactMap { $0["id"] as? String })
        let app = XCUIApplication()
        app.launchArguments = ["--pip-fast-text"]
        app.launch()
        if app.buttons["pip.skip"].waitForExistence(timeout: 3) {
            app.buttons["pip.skip"].tap()
        }
        selectWorkspaceTab("Download", in: app)
        if app.buttons["download.clear"].exists { app.buttons["download.clear"].tap() }
        let input = app.descendants(matching: .any)["download.urlField"].firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.tap()
        input.typeText(source)
        if app.buttons["clipboard.tip.dismiss"].exists { app.buttons["clipboard.tip.dismiss"].tap() }
        app.buttons["download.analyze"].tap()
        let configure = app.buttons["metadata.configure"]
        XCTAssertTrue(configure.waitForExistence(timeout: 90))
        scrollUntilHittable("metadata.configure", in: app)
        configure.tap()
        let advanced = app.buttons["configuration.advanced"]
        scrollUntilHittable("configuration.advanced", in: app)
        advanced.tap()
        func selectOriginalSource(_ identifier: String) {
            scrollUntilHittable(identifier, in: app).tap()
            let menu = app.collectionViews.firstMatch
            let exact = menu.buttons.matching(NSPredicate(format: "label ENDSWITH %@", " · Source 18")).firstMatch
            // Native menus lazily expose only nearby items. Scroll within the
            // menu, rather than treating an offscreen identity as unavailable.
            for _ in 0..<10 where !exact.exists || !exact.isHittable {
                XCTAssertTrue(menu.exists)
                let start = menu.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.45))
                let end = menu.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.15))
                start.press(forDuration: 0.05, thenDragTo: end)
            }
            XCTAssertTrue(exact.exists && exact.isHittable, "The exact original source must be available")
            exact.tap()
        }
        selectOriginalSource("configuration.source.video")
        selectOriginalSource("configuration.source.audio")
        let review = app.buttons["configuration.review"]
        scrollUntilHittable("configuration.review", in: app, maximumSwipes: 24)
        review.tap()
        let start = app.buttons["confirmation.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        scrollUntilHittable("confirmation.start", in: app)
        start.tap()

        var current: [String: Any]?
        let startLimit = Date.now.addingTimeInterval(90)
        repeat {
            current = try jobs().first { !originalIDs.contains($0["id"] as? String ?? "") }
            if current?["state"] as? String == "running",
               !waitForNativeOwnership || !(current?["activeTransferDescriptors"] as? [[String: Any]] ?? []).isEmpty { break }
            RunLoop.current.run(until: .now.addingTimeInterval(0.2))
        } while Date.now < startLimit
        var job = try XCTUnwrap(current)
        XCTAssertEqual(job["state"] as? String, "running", "Must background an unfinished job")
        if waitForNativeOwnership {
            XCTAssertFalse((job["activeTransferDescriptors"] as? [[String: Any]] ?? []).isEmpty,
                           "Wait for actual native transfer ownership before pressing Home")
        }
        let backgroundedAtStage = job["stage"] ?? "unknown"
        let jobID = try XCTUnwrap(job["id"] as? String)
        let configuration = try XCTUnwrap(job["configuration"] as? [String: Any])
        XCTAssertEqual(configuration["selectedVideoFormatID"] as? String, "18")
        XCTAssertEqual(configuration["selectedAudioFormatID"] as? String, "18")
        let beforeHome = (job["progress"] as? [String: Any])?["bytesDownloaded"] as? Int64 ?? 0
        XCUIDevice.shared.press(.home)
        let homeAt = Date.now
        let background = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.state == .runningBackground || app.state == .runningBackgroundSuspended
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [background], timeout: 5), .completed)
        var observations: [[String: Any]] = []
        let deadline = Date.now.addingTimeInterval(180)
        repeat {
            XCTAssertNotEqual(app.state, .runningForeground, "Never reopen the app to finish")
            if let updated = try jobs().first(where: { $0["id"] as? String == jobID }) { job = updated }
            let progress = job["progress"] as? [String: Any] ?? [:]
            observations.append(["secondsAfterHome": Date.now.timeIntervalSince(homeAt),
                "state": job["state"] ?? "unknown", "stage": job["stage"] ?? "",
                "bytesDownloaded": progress["bytesDownloaded"] ?? 0])
            if ["completed", "failed", "needsAttention", "cancelled"].contains(job["state"] as? String ?? "") { break }
            RunLoop.current.run(until: .now.addingTimeInterval(1))
        } while Date.now < deadline
        let receipt: [String: Any] = ["jobID": jobID, "formatID": "18",
            "bytesBeforeHome": beforeHome, "observations": observations,
            "backgroundedAtStage": backgroundedAtStage, "waitedForNativeOwnership": waitForNativeOwnership,
            "retryCount": job["retryCount"] ?? NSNull(),
            "finalState": job["state"] ?? "unknown", "errorCode": job["errorCode"] ?? NSNull(),
            "outputURL": job["outputURL"] ?? NSNull(), "appReopened": false]
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
            .write(to: receiptURL, options: .atomic)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "Home after background download"; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertEqual(job["state"] as? String, "completed", "Background completion must be persisted before reopening")
        XCTAssertGreaterThan((job["progress"] as? [String: Any])?["bytesDownloaded"] as? Int64 ?? 0, beforeHome)
        let file = URL(string: try XCTUnwrap(job["outputURL"] as? String))!
        let size = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        XCTAssertEqual(size.isRegularFile, true)
        XCTAssertGreaterThan(size.fileSize ?? 0, 0)
        #endif
    }
}
