import XCTest

extension TwineUITests {
    @MainActor
    func testTraceExitScrollsTheTerminalAndKeepsItMountedAfterResize() throws {
        let folder = try makeTestFolder(prefix: "TwineHistoryUITests")
        let app = try makeApp(lastOpenFolder: folder)
        app.launchEnvironment["SHELL"] = "/bin/sh"
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["workflowTab-1"].waitForExistence(timeout: 10))
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 1000, height: 760))
        app.typeText("printf 'FINAL_HISTORY\\n'; echo ready > history-ready; exit 0\r")
        waitForFile(folder.appending(path: "history-ready"), containing: "ready", in: app)
        app.buttons["tracesHeader"].click()
        let span = app.buttons["traceSpan-1"]
        XCTAssertTrue(span.waitForExistence(timeout: 10), app.debugDescription)
        span.click()
        let jump = app.buttons["traceJump-2"]
        XCTAssertTrue(jump.waitForExistence(timeout: 10), app.debugDescription)
        jump.click()
        XCTAssertFalse(app.textViews["terminalHistoryText"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["traceScrollUnavailable"].exists)
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 500, height: 620))
        XCTAssertFalse(app.textViews["terminalHistoryText"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["terminalMinimap"].exists)
        attachScreenshot(of: app, named: "Trace exit in the mounted terminal after resize")
    }

    @MainActor
    func testTraceJumpBringsAHiddenBentoAgentIntoViewAndReturnsToItsLiveShell() throws {
        let folder = try makeTestFolder(prefix: "TwineHistoryUITests")
        let app = try makeApp(lastOpenFolder: folder)
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["workflowTab-1"].waitForExistence(timeout: 10))
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 1100, height: 760))
        openTestWorkflow(agents: 4, in: app)
        let subtabs = (1...4).map { app.buttons["agentSubtab-\($0)"] }
        XCTAssertTrue(subtabs[3].waitForExistence(timeout: 10), app.debugDescription)
        let processIDs = try startShells(in: subtabs, folder: folder, app: app)
        defer { processIDs.forEach(endProcessIfRunning) }
        subtabs[0].click()
        app.radioGroups["agentLayout"].radioButtons["Bento"].click()
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 500, height: 620))
        app.buttons["tracesHeader"].click()
        let workerSpan = app.buttons["traceSpan-4"]
        XCTAssertTrue(workerSpan.waitForExistence(timeout: 10), app.debugDescription)
        workerSpan.click()
        let jump = app.buttons["traceJump-4"]
        XCTAssertTrue(jump.waitForExistence(timeout: 5), app.debugDescription)
        jump.click()
        XCTAssertFalse(app.textViews["terminalHistoryText"].exists)
        assertAgentHasKeyboard(3, subtabs: subtabs, in: app)
        XCTAssertEqual(app.buttons["workflowTab-2"].value as? String, "Selected")
        // Trace navigation selects the live agent, so input goes directly to its shell.
        app.typeText("echo $TWINE_AGENT > returned-to-live\r")
        waitForFile(folder.appending(path: "returned-to-live"), containing: "agent3", in: app)
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 950, height: 720))
        XCTAssertFalse(app.textViews["terminalHistoryText"].exists)
        attachScreenshot(of: app, named: "Trace point in the selected live Bento agent")
    }

    /// Tiled Bento panes show no subtabs, so the focused pane names the agent with the keyboard.
    @MainActor
    private func assertAgentHasKeyboard(_ index: Int, subtabs: [XCUIElement], in app: XCUIApplication) {
        if subtabs[index].exists {
            XCTAssertEqual(subtabs[index].value as? String, "Selected", app.debugDescription)
        } else {
            XCTAssertEqual(app.menuButtons["agentPane-\(index + 1)"].value as? String, "Focused", app.debugDescription)
        }
    }
}
