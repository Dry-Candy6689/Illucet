import XCTest
import ImageIO

@MainActor
final class BulkImportUITests: XCTestCase {
    /// Runs the normal app and real extraction/transfers on an isolated simulator.
    func testAuthorizedMixedSiteBulkDownloads() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["ILLUCET_MIXED_BULK_LIVE"] == "1")
        #if !targetEnvironment(simulator)
        throw XCTSkip("Requires the isolated simulator live-test setup")
        #else
        continueAfterFailure = false
        let samplesURL = URL(filePath: try XCTUnwrap(environment["ILLUCET_MIXED_BULK_SAMPLES"]))
        let samples = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: samplesURL)) as? [[String: String]])
        let urls = samples.compactMap { $0["url"] }
        XCTAssertEqual(urls.count, samples.count)
        XCTAssertGreaterThan(Set(samples.compactMap { $0["site"] }).count, 1)
        XCTAssertEqual(Set(samples.compactMap { $0["kind"] }), ["image", "video"])
        var stateURL = URL(filePath: try XCTUnwrap(environment["ILLUCET_MIXED_BULK_STATE"]))
        var containersURL = stateURL
        for _ in 0..<5 { containersURL.deleteLastPathComponent() }
        func snapshot() throws -> [String: Any] {
            if !FileManager.default.fileExists(atPath: stateURL.path) {
                let candidates = try FileManager.default.contentsOfDirectory(at: containersURL, includingPropertiesForKeys: nil)
                    .map { $0.appending(path: "Library/Application Support/Illucet/IllucetState.json") }
                    .filter { FileManager.default.fileExists(atPath: $0.path) }
                XCTAssertEqual(candidates.count, 1)
                stateURL = try XCTUnwrap(candidates.first)
            }
            return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any])
        }
        let priorBatchIDs = Set((try snapshot()["batches"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String })
        func ariaTransfers() -> Int {
            let file = stateURL.deletingLastPathComponent().appending(path: "Diagnostics.json")
            guard let data = try? Data(contentsOf: file),
                  let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return 0 }
            return entries.filter { $0["event"] as? String == "aria2_transfer_started" }.count
        }
        let priorAriaTransfers = ariaTransfers()
        let app = XCUIApplication()
        app.launchArguments = ["--pip-fast-text"]
        app.launch()
        if app.buttons["pip.skip"].waitForExistence(timeout: 2) { app.buttons["pip.skip"].tap() }
        selectWorkspaceTab("Download", in: app)
        XCTAssertTrue(app.buttons["download.bulkImport"].waitForExistence(timeout: 15))
        app.buttons["download.bulkImport"].tap()
        let text = app.textViews["bulk.text"]
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        text.tap(); text.typeText(urls.joined(separator: "\n"))
        let scan = app.buttons["bulk.scan"]
        XCTAssertTrue(scan.isHittable, "Find links must stay reachable while editing a long import.")
        capture("After - Find links above keyboard", app)
        scan.tap()
        XCTAssertTrue(app.buttons["bulk.analyze"].waitForExistence(timeout: 5))
        capture("Before - Real mixed-site links", app)
        app.buttons["bulk.analyze"].tap()
        // List creates the queue button only once it scrolls into view.
        // Wait for analysis through its visible item count first.
        XCTAssertTrue(app.staticTexts["\(urls.count) selected items"].waitForExistence(timeout: 120))
        scrollUntilHittable("bulk.download", in: app).tap()
        XCTAssertTrue(app.navigationBars["Queue"].waitForExistence(timeout: 12))
        capture("After - Real mixed batch queued", app)

        var batch: [String: Any]?
        var jobs: [[String: Any]] = []
        let deadline = Date().addingTimeInterval(240)
        repeat {
            let state = try snapshot()
            batch = (state["batches"] as? [[String: Any]] ?? []).first { !priorBatchIDs.contains($0["id"] as? String ?? "") }
            let items = batch?["items"] as? [[String: Any]] ?? []
            let ids = Set(items.compactMap { $0["jobID"] as? String })
            jobs = (state["jobs"] as? [[String: Any]] ?? []).filter { ids.contains($0["id"] as? String ?? "") }
            if jobs.isEmpty && items.contains(where: { ["failed", "needsAttention", "cancelled"].contains($0["state"] as? String ?? "") }) { break }
            // Let the rest of a continue-on-error batch finish before reporting a failed item.
            if jobs.count == urls.count && jobs.allSatisfy({ ["completed", "failed", "needsAttention", "cancelled"].contains($0["state"] as? String ?? "") }) { break }
            try await Task.sleep(for: .milliseconds(500))
        } while Date() < deadline
        XCTAssertEqual((batch?["items"] as? [[String: Any]])?.count, urls.count)
        XCTAssertEqual(jobs.count, urls.count)
        XCTAssertTrue(jobs.allSatisfy { $0["state"] as? String == "completed" },
            "Mixed batch states: \(jobs.map { $0["state"] as? String ?? "missing" })")
        var receipt: [[String: String]] = []
        for job in jobs {
            let output = try XCTUnwrap((job["outputURL"] as? String).flatMap(URL.init(string:)))
            let values = try output.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            XCTAssertEqual(values.isRegularFile, true); XCTAssertEqual(values.isSymbolicLink, false)
            XCTAssertGreaterThan(values.fileSize ?? 0, 0)
            let configuration = job["configuration"] as? [String: Any]
            if let engine = environment["ILLUCET_MIXED_BULK_ENGINE"] {
                XCTAssertEqual((configuration?["enginePreferences"] as? [String: Any])?["download"] as? String, engine)
            }
            let identity = configuration?["sourceIdentity"] as? [String: Any]
            if identity?["kind"] as? String == "image" {
                let source = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
                XCTAssertNotNil(CGImageSourceCreateImageAtIndex(source, 0, nil))
            } else {
                // Automatic output may preserve Matroska/WebM. Verify the
                // pipeline's native probe; AVFoundation cannot open every
                // supported source container. Decode saved files separately.
                let probe = try XCTUnwrap(job["outputProbe"] as? [String: Any])
                let streams = try XCTUnwrap(probe["streams"] as? [[String: Any]])
                XCTAssertTrue(streams.contains { $0["kind"] as? String == "video"
                    && ($0["disposition"] as? [String: Any])?["attachedPicture"] as? Bool != true })
            }
            receipt.append(["kind": identity?["kind"] as? String ?? "video", "path":output.path])
        }
        let receiptURL = URL(filePath: try XCTUnwrap(environment["ILLUCET_MIXED_BULK_RECEIPT"]))
        try JSONSerialization.data(withJSONObject: receipt).write(to: receiptURL, options: .atomic)
        if let minimum = environment["ILLUCET_MIXED_BULK_MIN_ARIA_TRANSFERS"].flatMap(Int.init) {
            let count = ariaTransfers() - priorAriaTransfers
            XCTAssertGreaterThanOrEqual(count, minimum, "The real batch must execute the embedded aria2 engine.")
            print("ILLUCET_MIXED_ARIA2 actual_transfers=\(count)")
        }
        capture("After - Real mixed batch completed", app)
        selectWorkspaceTab("History", in: app)
        capture("After - Mixed image and video history", app)
        print("ILLUCET_MIXED_BULK completed=\(jobs.count) sites=\(Set(samples.compactMap { $0["site"] }).count) verified=\(jobs.count)")
        #endif
    }
    func testHomeOpensBulkImport() {
        let app=launch()
        let button=app.buttons["download.bulkImport"]
        XCTAssertTrue(button.waitForExistence(timeout:15))
        button.tap()
        XCTAssertTrue(app.textViews["bulk.text"].waitForExistence(timeout:4))
        XCTAssertTrue(app.buttons["bulk.file"].exists)
        capture("After - Home bulk import",app)
    }
    func testMixedLinksPreviewAndItemOptions() {
        let app=launch("bulk-import")
        XCTAssertTrue(app.buttons["bulk.analyze"].waitForExistence(timeout:15))
        XCTAssertTrue(app.staticTexts["Duplicate link"].exists)
        XCTAssertTrue(app.staticTexts["Unsupported website"].exists)
        capture("After - Mixed links",app)
        app.buttons["bulk.analyze"].tap()
        XCTAssertTrue(app.buttons["bulk.download"].waitForExistence(timeout:15))
        capture("After - Mixed media options",app)
        app.buttons.containing(.staticText,identifier:"Sunset by the coast").firstMatch.tap()
        XCTAssertTrue(app.switches["Remove location & camera metadata"].waitForExistence(timeout:4))
        XCTAssertFalse(app.buttons["Maximum quality"].exists)
        capture("After - Image options",app)
    }
    func testEngineSettings() {
        let app=launch("engines")
        XCTAssertTrue(app.buttons["engines.download"].waitForExistence(timeout:15))
        capture("After - Engine settings",app)
        app.buttons["engines.download"].tap()
        app.buttons["aria2"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "aria2 handles public")).firstMatch.waitForExistence(timeout: 4))
        capture("After - aria2 engine and execution limits", app)
    }
    private func launch(_ screen:String?=nil)->XCUIApplication {
        let app=XCUIApplication()
        app.launchArguments=["--ui-testing","--ui-polish-reset","--ui-light-appearance","--ui-reduce-motion"]
        if let screen { app.launchArguments.append("--ui-screen=\(screen)") }
        app.launch()
        return app
    }
    private func capture(_ name:String,_ app:XCUIApplication) {
        let attachment=XCTAttachment(screenshot:app.screenshot()); attachment.name=name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
