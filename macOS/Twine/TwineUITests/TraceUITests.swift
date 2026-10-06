import AppKit
import XCTest

extension TwineUITests {
    @MainActor
    func testTraceViewModesPreserveSelectionAndCollapsedState() throws {
        let folder = try traceFolder()
        let app = try makeApp(lastOpenFolder: folder)
        app.launchEnvironment["SHELL"] = "/bin/bash"
        app.launch()
        defer { app.terminate() }
        let header = app.buttons["tracesHeader"]
        XCTAssertTrue(header.waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["workflowChoice-Terminal"].click()
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 1000, height: 800))
        app.typeText("echo ready > trace-mode-ready\r")
        waitForFile(folder.appending(path: "trace-mode-ready"), containing: "ready", in: app)
        header.click()
        let step = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'traceSpan-' AND label CONTAINS 'trace-mode-ready'")
        ).firstMatch
        XCTAssertTrue(step.waitForExistence(timeout: 10), app.debugDescription)
        let mode = app.descendants(matching: .any).matching(identifier: "traceViewMode").firstMatch
        let disclosure = app.buttons["tracesDisclosure"]
        XCTAssertTrue(disclosure.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertLessThanOrEqual(header.frame.maxX, mode.frame.minX)
        XCTAssertLessThanOrEqual(mode.frame.maxX, disclosure.frame.minX)
        XCTAssertLessThan(mode.frame.height, header.frame.height / 2)

        selectTraceViewMode("In Depth", in: app)
        XCTAssertTrue(app.staticTexts["Select a step"].waitForExistence(timeout: 5))
        XCTAssertFalse(step.isSelected)
        XCTAssertFalse(app.textViews["terminalHistoryText"].exists)
        selectTraceViewMode("Overview", in: app)
        XCTAssertFalse(step.isSelected)
        XCTAssertFalse(app.buttons["closeTraceDetails"].exists)

        selectTraceViewMode("In Depth", in: app)
        disclosure.click()
        XCTAssertEqual(header.label, "Traces, collapsed")
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.4)).click()
        app.typeText("echo typed")
        XCTAssertEqual(header.label, "Traces, collapsed")
        app.typeText(" > trace-mode-typed\r")
        waitForFile(folder.appending(path: "trace-mode-typed"), containing: "typed", in: app)
        XCTAssertEqual(header.label, "Traces, collapsed")
        header.click()
        XCTAssertTrue(app.staticTexts["Select a step"].waitForExistence(timeout: 5))
        selectTraceViewMode("Overview", in: app)
        XCTAssertFalse(app.buttons["closeTraceDetails"].exists)

        step.click()
        XCTAssertTrue(app.buttons["closeTraceDetails"].waitForExistence(timeout: 5))
        selectTraceViewMode("In Depth", in: app)
        XCTAssertTrue(step.isSelected)
        selectTraceViewMode("Overview", in: app)
        XCTAssertTrue(step.isSelected)
        XCTAssertTrue(app.buttons["closeTraceDetails"].exists)
    }

    @MainActor
    func selectTraceViewMode(_ mode: String, in app: XCUIApplication) {
        let control = app.descendants(matching: .any).matching(identifier: "traceViewMode").firstMatch
        XCTAssertTrue(control.waitForExistence(timeout: 5), app.debugDescription)
        let choice = control.descendants(matching: .any).matching(NSPredicate(format: "label == %@", mode)).firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 5), app.debugDescription)
        choice.click()
    }

    @MainActor
    func testTracesExpandSelectCopyAndKeepTheTimelineVisible() throws {
        try checkTraces(appearance: "Light")
    }

    @MainActor
    func testTracesInDarkAppearance() throws {
        try checkTraces(appearance: "Dark")
    }

    @MainActor
    private func checkTraces(appearance: String) throws {
        let folder = try traceFolder()
        let app = try makeApp(lastOpenFolder: folder)
        app.launchEnvironment["TWINE_TEST_APPEARANCE"] = appearance
        app.launchEnvironment["SHELL"] = "/bin/sh"
        app.launch()
        defer { app.terminate() }
        let header = app.buttons["tracesHeader"]
        XCTAssertTrue(header.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(header.label, "Traces, collapsed")
        app.buttons["workflowChoice-Terminal"].click()
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 900, height: 620))
        attachWindow(in: app, name: "\(appearance), Traces collapsed")
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
        attachWindow(in: app, name: "\(appearance), Traces expanded with details")

        // At the supported minimum width the lane contracts to its role symbol.
        sidebarToggle(in: app).click()
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 400, height: 620))
        XCTAssertTrue(span.isHittable, app.debugDescription)
        XCTAssertTrue(close.isHittable, app.debugDescription)
        XCTAssertLessThan(span.frame.maxX, close.frame.minX)
        attachWindow(in: app, name: "\(appearance), Traces and details at minimum width")
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
        app.launchEnvironment["SHELL"] = "/bin/sh"
        app.launch()
        defer { app.terminate() }
        let header = app.buttons["tracesHeader"]
        XCTAssertTrue(header.waitForExistence(timeout: 10))
        app.buttons["workflowChoice-Terminal"].click()
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

    private func traceFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "TwineTraceUITests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }
}
