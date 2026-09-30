import AppKit
import XCTest

extension TwineUITests {
    @MainActor
    func testTracesExpandSelectCopyAndKeepTheTimelineVisible() throws {
        let folder = try traceFolder()
        let app = try makeApp(lastOpenFolder: folder)
        app.launch()
        defer { app.terminate() }
        let header = app.buttons["tracesHeader"]
        XCTAssertTrue(header.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(header.label, "Traces, collapsed")
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 900, height: 620))
        header.click()
        XCTAssertEqual(header.label, "Traces, expanded")
        let span = app.buttons["traceSpan-1"]
        XCTAssertTrue(span.waitForExistence(timeout: 10), app.debugDescription)
        span.click()
        let close = app.buttons["closeTraceDetails"]
        XCTAssertTrue(close.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(span.isHittable)
        NSPasteboard.general.clearContents()
        app.buttons["copyTraceLog"].click()
        let copied = expectation(
            for: NSPredicate { _, _ in
                NSPasteboard.general.string(forType: .string)?.contains("[start]") == true
            }, evaluatedWith: nil)
        wait(for: [copied], timeout: 5)
        XCTAssertTrue(NSPasteboard.general.string(forType: .string)?.contains("Terminal — Shell") == true)

        // At the supported minimum width the lane contracts to its role symbol.
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 400, height: 620))
        XCTAssertTrue(span.isHittable, app.debugDescription)
        XCTAssertTrue(close.isHittable, app.debugDescription)
        XCTAssertLessThan(span.frame.maxX, close.frame.minX)
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = "Traces and details at minimum width"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        close.click()
        XCTAssertTrue(close.waitForNonExistence(timeout: 5))
        XCTAssertTrue(span.isHittable)
        header.click()
        XCTAssertTrue(span.waitForNonExistence(timeout: 5))
        XCTAssertEqual(header.label, "Traces, collapsed")
    }

    @MainActor
    func testTraceHistorySurvivesRelaunch() throws {
        let app = try makeApp(lastOpenFolder: traceFolder())
        app.launch()
        defer { app.terminate() }
        let header = app.buttons["tracesHeader"]
        XCTAssertTrue(header.waitForExistence(timeout: 10))
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 900, height: 620))
        header.click()
        XCTAssertTrue(app.buttons["traceSpan-1"].waitForExistence(timeout: 10))
        app.menuBars.menuBarItems["Twine"].click()
        app.menuItems["Quit Twine"].click()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
        app.launch()
        XCTAssertTrue(header.waitForExistence(timeout: 10))
        XCTAssertEqual(header.label, "Traces, collapsed")
        header.click()
        let historical = app.buttons["traceSpan-1"]
        XCTAssertTrue(historical.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.buttons["traceSpan-2"].exists, app.debugDescription)
        historical.click()
        XCTAssertTrue(app.buttons["closeTraceDetails"].waitForExistence(timeout: 5))
        let ending = app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "Twine quit")).firstMatch
        XCTAssertTrue(ending.waitForExistence(timeout: 5), app.debugDescription)
    }

    @MainActor
    func testTracesWithoutAWorkflowShowHelpfulEmptyState() throws {
        let app = try makeApp(lastOpenFolder: traceFolder())
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["workflowTab-1"].waitForExistence(timeout: 10))
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 900, height: 620))
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["No Open Tabs"].waitForExistence(timeout: 5))
        app.buttons["tracesHeader"].click()
        XCTAssertTrue(app.staticTexts["No traces yet"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.buttons["copyTraceLog"].exists)
    }

    private func traceFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "TwineTraceUITests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }
}
