import XCTest

@MainActor
extension XCTestCase {
    /// Adaptive iPad tabs can live in a top bar or sidebar instead of UITabBar.
    func selectWorkspaceTab(
        _ name: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if let control = workspaceTabControls(name, in: app).first(where: \.isHittable) {
            control.tap()
            dismissWorkspaceSidebar(in: app)
            return
        }
        let sidebarToggle = app.buttons.matching(NSPredicate(
            format: "label CONTAINS[c] 'sidebar' OR identifier CONTAINS[c] 'sidebar'"
        )).allElementsBoundByIndex.first(where: \.isHittable)
        sidebarToggle?.tap()
        let appeared = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                self.workspaceTabControls(name, in: app).contains(where: \.isHittable)
            },
            object: app
        )
        guard XCTWaiter.wait(for: [appeared], timeout: 3) == .completed,
              let control = workspaceTabControls(name, in: app).first(where: \.isHittable)
        else {
            attachWorkspaceFailure(app, context: "Missing tab: \(name)")
            XCTFail("The \(name) workspace tab is not accessible.", file: file, line: line)
            return
        }
        control.tap()
        dismissWorkspaceSidebar(in: app)
    }

    private func dismissWorkspaceSidebar(in app: XCUIApplication) {
        // An adaptive sidebar can overlay the selected workspace after a tab
        // selection. Close it before interacting with the workspace beneath it.
        let hide = app.buttons.matching(NSPredicate(
            format: "identifier == 'ToggleSidebar' AND label == 'Hide Sidebar'"
        )).allElementsBoundByIndex.first(where: \.isHittable)
        hide?.tap()
    }

    func waitForWorkspaceShell(
        _ app: XCUIApplication,
        timeout: TimeInterval = 8
    ) -> Bool {
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                let content = app.descendants(matching: .any).matching(NSPredicate(
                    format: "identifier IN %@",
                    ["tab.download", "tab.queue", "tab.history", "tab.settings"]
                )).firstMatch
                return content.exists || self.workspaceTabControls("Download", in: app)
                    .contains(where: \.exists)
            },
            object: app
        )
        return XCTWaiter.wait(for: [ready], timeout: timeout) == .completed
    }

    func waitForWorkspaceGeometry(
        _ app: XCUIApplication,
        portrait: Bool,
        timeout: TimeInterval = 8
    ) -> Bool {
        let window = app.windows.firstMatch
        var previousFrame: CGRect?
        let settled = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                guard window.exists else { return false }
                let frame = window.frame
                guard !frame.isEmpty, !frame.isInfinite,
                      portrait ? frame.height > frame.width : frame.width > frame.height
                else {
                    previousFrame = nil
                    return false
                }
                // Device orientation changes before the app finishes resizing.
                // Require two matching window snapshots before querying controls.
                defer { previousFrame = frame }
                return previousFrame == frame
            },
            object: app
        )
        let ready = XCTWaiter.wait(for: [settled], timeout: timeout) == .completed
        if !ready {
            attachWorkspaceFailure(
                app,
                context: "Window did not settle in \(portrait ? "portrait" : "landscape")"
            )
        }
        return ready
    }

    @discardableResult
    func scrollUntilHittable(
        _ identifier: String,
        type: XCUIElement.ElementType = .button,
        in app: XCUIApplication,
        maximumSwipes: Int = 12,
        initiallyScrollDown: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let targets = app.descendants(matching: type).matching(identifier: identifier)
        var scrollDown = initiallyScrollDown
        var previousContentFrame: CGRect?
        var reversedAtBoundary = false
        for swipe in 0...maximumSwipes {
            let matches = targets.allElementsBoundByIndex
            // Prefer the scroll view that owns the target; a landscape iPad
            // also has a sidebar, and an app-wide swipe can scroll that instead.
            let owners = app.scrollViews.containing(type, identifier: identifier)
                .allElementsBoundByIndex.filter(\.isHittable)
            let candidates = owners.isEmpty
                ? app.scrollViews.allElementsBoundByIndex.filter(\.isHittable)
                : owners
            let scrollView = candidates.max(by: {
                $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
            })
            let viewport = workspaceViewport(in: app, scrollView: scrollView)
            if matches.contains(where: {
                workspaceTargetIsVisible($0, in: viewport) && $0.isHittable
            }), let target = settledWorkspaceTarget(targets, in: app, scrollView: scrollView) {
                return target
            }
            guard swipe < maximumSwipes else { break }

            let content = scrollView?.children(matching: .other).firstMatch
            let contentFrame = content?.exists == true ? content?.frame : nil
            let targetFrame = matches.map(\.frame).first(where: {
                !$0.isEmpty && !$0.isInfinite
                    && $0.maxX > viewport.minX && $0.minX < viewport.maxX
            })
            if let targetFrame {
                scrollDown = targetFrame.midY < viewport.midY
            } else if let contentFrame, contentFrame == previousContentFrame,
                      !reversedAtBoundary {
                // Lazy rows can disappear from accessibility entirely. If a
                // swipe no longer moves content, search back from that edge.
                scrollDown.toggle()
                reversedAtBoundary = true
            }
            previousContentFrame = contentFrame
            let surface = scrollView ?? app
            // Full-element swipes can jump over a short landscape viewport.
            // Drag only within the uncovered content area and stop near the
            // target; controls are still located and tapped through XCTest.
            let maximumDistance = viewport.height * 0.35
            let desiredDistance = targetFrame.map { viewport.midY - $0.midY }
                ?? (scrollDown ? maximumDistance : -maximumDistance)
            let distance = (scrollDown ? 1.0 : -1.0)
                * min(maximumDistance, max(24, abs(desiredDistance)))
            let origin = surface.coordinate(withNormalizedOffset: .zero)
            let bounds = surface.frame
            let start = origin.withOffset(CGVector(
                dx: viewport.midX - bounds.minX,
                dy: viewport.midY - bounds.minY - distance / 2
            ))
            let end = origin.withOffset(CGVector(
                dx: viewport.midX - bounds.minX,
                dy: viewport.midY - bounds.minY + distance / 2
            ))
            start.press(
                forDuration: 0.05, thenDragTo: end,
                withVelocity: .slow, thenHoldForDuration: 0.1
            )
        }
        attachWorkspaceFailure(app, context: "Unreachable control: \(identifier)")
        XCTFail("Expected a reachable control: \(identifier)", file: file, line: line)
        return targets.firstMatch
    }

    func tapUnusedWorkspaceSpace(
        _ marker: XCUIElement,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let frame = marker.frame
        var visible = frame.intersection(workspaceViewport(in: app, scrollView: nil))
        if marker.elementType == .scrollView {
            let content = marker.children(matching: .other).firstMatch
            if content.exists, !content.frame.isEmpty {
                visible = visible.intersection(content.frame)
            }
        }
        // Keyboard dismissal needs a tap in actual content, not in a covered
        // tab bar or the full-window scroll view's status/navigation area.
        let keyboard = app.keyboards.firstMatch
        if keyboard.exists, keyboard.frame.intersects(visible) {
            visible.size.height = max(0, keyboard.frame.minY - visible.minY)
        }
        guard !visible.isEmpty, !visible.isNull, !visible.isInfinite else {
            attachWorkspaceFailure(app, context: "No visible unused space: \(marker.identifier)")
            XCTFail("The unused-space marker has no visible content area.", file: file, line: line)
            return
        }
        marker.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
            dx: visible.maxX - min(16, visible.width * 0.05) - frame.minX,
            dy: visible.minY + min(12, visible.height * 0.05) - frame.minY
        )).tap()
    }

    private func workspaceViewport(
        in app: XCUIApplication,
        scrollView: XCUIElement?
    ) -> CGRect {
        let window = app.windows.firstMatch.frame
        var viewport = scrollView?.frame.intersection(window) ?? window
        // A SwiftUI scroll view extends under navigation and tab bars. Its
        // full frame therefore includes areas where a tap can hit a bar.
        let bars = app.navigationBars.allElementsBoundByIndex
            + app.tabBars.allElementsBoundByIndex
        for bar in bars {
            // Covered workspace bars remain in the accessibility tree beneath
            // sheets, but cannot obstruct controls in the presented sheet.
            guard bar.isHittable else { continue }
            let frame = bar.frame
            guard !frame.isEmpty, frame.intersects(viewport),
                  frame.minX <= viewport.midX, frame.maxX >= viewport.midX
            else { continue }
            if frame.midY < window.midY {
                let top = max(viewport.minY, frame.maxY)
                viewport = CGRect(
                    x: viewport.minX, y: top,
                    width: viewport.width, height: max(0, viewport.maxY - top)
                )
            } else {
                viewport.size.height = max(0, min(viewport.maxY, frame.minY) - viewport.minY)
            }
        }
        return viewport.insetBy(dx: 4, dy: 12)
    }

    private func workspaceTargetIsVisible(_ target: XCUIElement, in viewport: CGRect) -> Bool {
        let frame = target.frame
        guard !frame.isEmpty, !frame.isInfinite, !viewport.isEmpty,
              viewport.contains(CGPoint(x: frame.midX, y: frame.midY))
        else { return false }
        // Fit ordinary controls entirely between the bars. A control taller
        // than the viewport still needs an unobscured center and a real hit.
        return frame.height > viewport.height
            || (frame.minY >= viewport.minY && frame.maxY <= viewport.maxY)
    }

    private func settledWorkspaceTarget(
        _ targets: XCUIElementQuery,
        in app: XCUIApplication,
        scrollView: XCUIElement?
    ) -> XCUIElement? {
        var previousFrame: CGRect?
        var result: XCUIElement?
        let settled = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                let viewport = self.workspaceViewport(in: app, scrollView: scrollView)
                guard let target = targets.allElementsBoundByIndex.first(where: {
                    self.workspaceTargetIsVisible($0, in: viewport) && $0.isHittable
                }) else {
                    previousFrame = nil
                    return false
                }
                let frame = target.frame
                defer { previousFrame = frame }
                guard previousFrame == frame else { return false }
                result = target
                return true
            },
            object: app
        )
        return XCTWaiter.wait(for: [settled], timeout: 3) == .completed ? result : nil
    }

    func attachWorkspaceScreenshot(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func attachWorkspaceFailure(_ app: XCUIApplication, context: String) {
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = context
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        attachWorkspaceScreenshot(app, named: context)
    }

    private func workspaceTabControls(
        _ name: String,
        in app: XCUIApplication
    ) -> [XCUIElement] {
        // UIKit can retain hidden adaptive-tab representations while the sidebar
        // is visible. Resolve all matches and let the caller choose a hittable
        // element, instead of letting a single subscript choose a hidden one.
        let icon = [
            "Download": "arrow.down.circle", "Queue": "list.bullet.rectangle",
            "History": "clock.arrow.circlepath", "Settings": "gearshape",
        ][name] ?? name
        return app.buttons.matching(identifier: "navigation." + name.lowercased()).allElementsBoundByIndex
            + app.tabBars.buttons.matching(identifier: name).allElementsBoundByIndex
            + app.buttons.matching(identifier: name).allElementsBoundByIndex
            + app.cells.matching(identifier: name).allElementsBoundByIndex
            + app.cells.matching(identifier: icon).allElementsBoundByIndex
            + app.cells.containing(.staticText, identifier: name).allElementsBoundByIndex
            + app.collectionViews.staticTexts.matching(identifier: name).allElementsBoundByIndex
    }
}
