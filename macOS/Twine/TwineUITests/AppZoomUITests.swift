import AppKit
import XCTest

extension TwineUITests {
    @MainActor
    func testZoomReflowsTerminalAndScalesEditorPopoverAndSheet() throws {
        let folder = try makeTestFolder(prefix: "TwineZoomUITests")
        let file = folder.appending(path: "zoom.txt")
        try "first\nsecond\n".write(to: file, atomically: true, encoding: .utf8)
        let app = try makeApp(lastOpenFolder: folder)
        app.launchEnvironment["SHELL"] = "/bin/bash"
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["workflowTab-1"].waitForExistence(timeout: 10))
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 1100, height: 800))
        app.buttons["workflowChoice-Terminal"].click()
        app.typeText("stty size > original-size\r")
        waitForFile(folder.appending(path: "original-size"), containing: " ", in: app)
        let traces = app.buttons["tracesHeader"]
        let originalHeight = traces.frame.height
        app.typeKey("=", modifierFlags: .command)
        app.typeKey("+", modifierFlags: [.command, .shift])
        attachScreenshot(of: app, named: "Workspace after both zoom shortcuts")
        waitForZoomHeight(originalHeight * 1.25, of: traces)
        app.typeText("stty size > zoomed-size\r")
        waitForFile(folder.appending(path: "zoomed-size"), containing: " ", in: app)
        let original = try terminalSize(in: folder.appending(path: "original-size"))
        let zoomed = try terminalSize(in: folder.appending(path: "zoomed-size"))
        XCTAssertLessThan(zoomed[0], original[0])
        XCTAssertLessThan(zoomed[1], original[1])
        attachScreenshot(of: app, named: "Workspace and terminal at 125 percent")

        fileRow(file, in: app).click()
        let text = app.textViews["fileText"]
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        text.click()
        text.typeKey("a", modifierFlags: .command)
        text.typeText("unsaved edits")
        app.typeKey("-", modifierFlags: .command)
        XCTAssertEqual(text.value as? String, "unsaved edits")
        text.typeKey("z", modifierFlags: .command)
        XCTAssertEqual(text.value as? String, "first\nsecond\n")
        verifyZoomPopoverAndSheet(in: app)
        verifyDesignerAtMaximumZoom(in: app)
    }

    @MainActor
    private func verifyDesignerAtMaximumZoom(in app: XCUIApplication) {
        app.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(app.buttons["workflowTab-2"].waitForExistence(timeout: 5))
        for _ in 0..<5 { app.typeKey("=", modifierFlags: .command) }
        app.typeKey("n", modifierFlags: [.command, .option])
        let name = app.textFields["designerName"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertTrue(name.isHittable)
        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(cancel.isHittable)
        name.typeText("Zoomed workflow")
        XCTAssertEqual(name.value as? String, "Zoomed workflow")
        attachScreenshot(of: app, named: "Workflow designer at 200 percent")
        cancel.click()
        XCTAssertTrue(name.waitForNonExistence(timeout: 5))
    }

    @MainActor
    private func verifyZoomPopoverAndSheet(in app: XCUIApplication) {
        app.typeKey("0", modifierFlags: .command)
        app.buttons["goToLine"].click()
        let line = app.textFields["lineNumber"]
        XCTAssertTrue(line.waitForExistence(timeout: 5))
        let lineHeight = line.frame.height
        line.click()
        app.typeKey("=", modifierFlags: .command)
        app.typeKey("=", modifierFlags: .command)
        waitForZoomHeight(lineHeight * 1.25, of: line)
        line.typeText("2")
        app.buttons["confirmGoToLine"].click()
        app.descendants(matching: .any).matching(identifier: "sessionsActions").firstMatch.click()
        app.menuItems["New Session"].click()
        let sessionName = app.textFields["sessionName"]
        XCTAssertTrue(sessionName.waitForExistence(timeout: 5))
        let sheetHeight = sessionName.frame.height
        sessionName.click()
        app.typeKey("0", modifierFlags: .command)
        waitForZoomHeight(sheetHeight / 1.25, of: sessionName)
        attachScreenshot(of: app, named: "Session sheet follows interface zoom")
        app.buttons["Cancel"].click()
    }

    @MainActor
    func testZoomIsSharedByNewWindowsAndRememberedAfterRelaunch() throws {
        let app = try makeApp()
        app.launch()
        defer { app.terminate() }
        let title = app.staticTexts["Welcome to Twine"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        let height = title.frame.height
        app.menuBars.menuBarItems["View"].click()
        app.menuItems["Zoom In"].click()
        waitForZoomHeight(height * 1.1, of: title)
        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(app.windows.element(boundBy: 1).waitForExistence(timeout: 5))
        for window in app.windows.allElementsBoundByIndex {
            waitForZoomHeight(height * 1.1, of: window.staticTexts["Welcome to Twine"])
        }
        app.terminate()
        app.launch()
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        waitForZoomHeight(height * 1.1, of: title)
        app.typeKey("0", modifierFlags: .command)
        waitForZoomHeight(height, of: title)
    }

    private func terminalSize(in file: URL) throws -> [Int] {
        try String(contentsOf: file, encoding: .utf8).split(whereSeparator: \.isWhitespace).map {
            try XCTUnwrap(Int($0))
        }
    }

    @MainActor
    private func waitForZoomHeight(_ height: CGFloat, of element: XCUIElement) {
        let resized = expectation(
            for: NSPredicate { _, _ in abs(element.frame.height - height) < 2 }, evaluatedWith: nil)
        XCTAssertEqual(
            XCTWaiter.wait(for: [resized], timeout: 5), .completed,
            "Expected \(height) points, observed \(element.frame.height) for \(element)")
    }
}
