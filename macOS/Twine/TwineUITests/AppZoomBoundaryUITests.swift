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
        app.buttons["sidebarToggle"].click()
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
        app.typeKey("d", modifierFlags: [.command, .shift])
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
        verifySmallViewportScrolling(in: app, windowHeight: size.height)
    }

    @MainActor
    private func verifySmallViewportScrolling(in app: XCUIApplication, windowHeight: CGFloat) {
        let viewport = app.scrollViews["workspaceViewport"]
        XCTAssertTrue(viewport.exists, app.debugDescription)
        let traces = app.buttons["tracesHeader"]
        XCTAssertFalse(traces.isHittable)
        // Scroll in the window margin, where a terminal won't consume the wheel event.
        viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5))
            .scroll(byDeltaX: 0, deltaY: -800)
        XCTAssertTrue(traces.isHittable)
        XCTAssertTrue(app.staticTexts["workflowStatus"].isHittable)
        attachScreenshot(of: app, named: "Minimum window scrolled to its footer")
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
        center.click(forDuration: 0.1, thenDragTo: center.withOffset(CGVector(dx: 60, dy: 0)))
        XCTAssertEqual(divider.frame.midX - initial, 60, accuracy: 8)
    }
}
