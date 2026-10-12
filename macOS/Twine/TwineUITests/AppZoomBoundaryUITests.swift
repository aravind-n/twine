import AppKit
import XCTest

extension TwineUITests {
    @MainActor
    func testZoomBoundsKeepSplitDraggingAndSmallWindowsUsable() throws {
        let folder = try makeTestFolder(prefix: "TwineZoomBoundaryUITests")
        let app = try makeApp(lastOpenFolder: folder)
        app.launchEnvironment["SHELL"] = "/bin/bash"
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["workflowTab-1"].waitForExistence(timeout: 10))
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 1400, height: 950))
        sidebarToggle(in: app).click()
        app.buttons["workflowChoice-Terminal"].click()
        app.typeKey("d", modifierFlags: .command)
        XCTAssertTrue(app.buttons["closeTerminalPane-2"].waitForExistence(timeout: 5))
        for _ in 0..<5 { app.typeKey("=", modifierFlags: .command) }
        assertZoomedDividerTracksPointer(in: app)
        attachScreenshot(of: app, named: "Split terminals at 200 percent")
        for _ in 0..<10 { app.typeKey("-", modifierFlags: .command) }
        assertZoomedDividerTracksPointer(in: app)
        app.typeKey("0", modifierFlags: .command)
        app.buttons["closeTerminalPane-2"].click()
        XCTAssertTrue(app.buttons["closeTerminalPane-2"].waitForNonExistence(timeout: 5), app.debugDescription)
        app.buttons["splitTerminalDown"].click()
        XCTAssertTrue(app.buttons["closeTerminalPane-3"].waitForExistence(timeout: 5))
        // A tall window's bottom edge can be covered by the Dock. Shrink from the top first.
        let window = app.windows.firstMatch
        let topEdge = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0))
            .withOffset(CGVector(dx: 0, dy: 1))
        topEdge.click(
            forDuration: 0.2, thenDragTo: topEdge.withOffset(CGVector(dx: 0, dy: window.frame.height - 302)))
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 400, height: 302))
        let size = app.windows.firstMatch.frame.size
        XCTAssertEqual(size.width, 400, accuracy: 2)
        XCTAssertEqual(size.height, 302, accuracy: 2)
        for _ in 0..<5 { app.typeKey("=", modifierFlags: .command) }
        XCTAssertEqual(app.windows.firstMatch.frame.height, size.height, accuracy: 2)
        XCTAssertTrue(app.buttons["newWorkflow"].isHittable)
        app.typeText("stty size > small-size\r")
        waitForFile(folder.appending(path: "small-size"), containing: " ", in: app)
        let rows = try String(contentsOf: folder.appending(path: "small-size"), encoding: .utf8)
            .split(whereSeparator: \.isWhitespace).first.flatMap { Int($0) }
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(rows), 2)
        app.typeKey("]", modifierFlags: .command)
        app.typeText("stty size > other-size\r")
        waitForFile(folder.appending(path: "other-size"), containing: " ", in: app)
        let otherRows = try String(contentsOf: folder.appending(path: "other-size"), encoding: .utf8)
            .split(whereSeparator: \.isWhitespace).first.flatMap { Int($0) }
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(otherRows), 2)
        attachScreenshot(of: app, named: "Minimum window at 200 percent")
        verifySmallTracePane(in: app, windowHeight: size.height)
        verifySmallSidebar(in: app)
    }

    @MainActor
    private func verifySmallSidebar(in app: XCUIApplication) {
        app.typeKey("0", modifierFlags: .command)
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 1100, height: 302))
        sidebarToggle(in: app).click()
        for _ in 0..<5 { app.typeKey("=", modifierFlags: .command) }
        let sidebar = app.scrollViews["sidebarViewport"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons["sidebarSection-files"].isHittable)
        sidebar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .scroll(byDeltaX: 0, deltaY: -800)
        let memories = app.buttons["memoryEntry-outline"]
        XCTAssertTrue(memories.isHittable, app.debugDescription)
        memories.click()
        sidebar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .scroll(byDeltaX: 0, deltaY: -800)
        let search = app.textFields["memorySearch"]
        XCTAssertTrue(search.waitForExistence(timeout: 5), app.debugDescription)
        for _ in 0..<8 {
            if search.isHittable, sidebar.frame.contains(search.frame) { break }
            sidebar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .scroll(byDeltaX: 0, deltaY: 100)
        }
        XCTAssertTrue(sidebar.frame.contains(search.frame), app.debugDescription)
        XCTAssertTrue(search.isHittable, app.debugDescription)
        search.click()
        search.typeText("memory")
        attachScreenshot(of: app, named: "Scrollable sidebar at minimum height and 200 percent")
    }

    @MainActor
    private func verifySmallTracePane(in app: XCUIApplication, windowHeight: CGFloat) {
        let viewport = app.scrollViews["workspaceViewport"]
        XCTAssertTrue(viewport.exists, app.debugDescription)
        let traces = app.buttons["tracesHeader"]
        XCTAssertTrue(traces.isHittable)
        // Workflow scrolling keeps the separate Traces header and footer accessible.
        viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5))
            .scroll(byDeltaX: 0, deltaY: -800)
        XCTAssertTrue(traces.isHittable)
        XCTAssertTrue(app.staticTexts["workflowStatus"].isHittable)
        traces.click()
        let body = app.scrollViews["tracesBody"]
        XCTAssertTrue(body.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(body.isHittable, app.debugDescription)
        XCTAssertTrue(traces.isHittable)
        XCTAssertTrue(app.buttons["tracesDisclosure"].isHittable, app.debugDescription)
        let viewMode = app.menuButtons["traceViewMode"]
        XCTAssertTrue(viewMode.isHittable, app.debugDescription)
        viewMode.click()
        app.menuItems["In Depth"].click()
        viewMode.click()
        app.menuItems["Overview"].click()
        XCTAssertTrue(app.staticTexts["workflowStatus"].isHittable)
        attachScreenshot(of: app, named: "Minimum window with Traces open at 200 percent")
        traces.click()
        XCTAssertTrue(body.waitForNonExistence(timeout: 5), app.debugDescription)
        for _ in 0..<10 { app.typeKey("-", modifierFlags: .command) }
        XCTAssertTrue(app.buttons["newWorkflow"].isHittable)
        XCTAssertEqual(app.windows.firstMatch.frame.height, windowHeight, accuracy: 2)
    }

    @MainActor
    private func assertZoomedDividerTracksPointer(in app: XCUIApplication) {
        let divider = app.descendants(matching: .any).matching(identifier: "columnDivider").firstMatch
        XCTAssertTrue(divider.waitForExistence(timeout: 5))
        let initial = divider.frame.midX
        let center = divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        // CI displays can clamp the requested window width. Keep the drag within the
        // panes' minimum widths at 200 percent, while still checking physical pointer tracking.
        center.click(forDuration: 0.1, thenDragTo: center.withOffset(CGVector(dx: 20, dy: 0)))
        XCTAssertEqual(divider.frame.midX - initial, 20, accuracy: 3)
    }
}
