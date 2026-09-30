import XCTest

extension TwineUITests {
    @MainActor
    func testTraceExitReplaysRecordedOutputAndKeepsItsWrappingAfterResize() throws {
        let folder = try makeTestFolder(prefix: "TwineHistoryUITests")
        let app = try makeApp(lastOpenFolder: folder)
        app.launchEnvironment["SHELL"] = "/bin/sh"
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["workflowTab-1"].waitForExistence(timeout: 10))
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 1000, height: 760))
        let command = [
            "printf '\\r\\033[2K%s%s\\n' FINAL_ HISTORY;",
            "i=0; while [ $i -lt 12 ]; do printf 1234567890; i=$((i+1)); done;",
            "printf '\\n'; echo ready > history-ready; exit 0\r",
        ].joined(separator: " ")
        app.typeText(command)
        waitForFile(folder.appending(path: "history-ready"), containing: "ready", in: app)
        app.buttons["tracesHeader"].click()
        let span = app.buttons["traceSpan-1"]
        XCTAssertTrue(span.waitForExistence(timeout: 10), app.debugDescription)
        span.click()
        let jump = app.buttons["traceJump-2"]
        XCTAssertTrue(jump.waitForExistence(timeout: 10), app.debugDescription)
        jump.click()
        let history = app.textViews["terminalHistoryText"]
        XCTAssertTrue(history.waitForExistence(timeout: 10), app.debugDescription)
        let snapshot = try XCTUnwrap(history.value as? String)
        XCTAssertTrue(
            snapshot.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == "FINAL_HISTORY" },
            snapshot)
        XCTAssertTrue(snapshot.contains(String(repeating: "1234567890", count: 6)), snapshot)
        XCTAssertFalse(snapshot.contains("\u{1B}"), "Escape sequences must be interpreted before display")
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 500, height: 620))
        XCTAssertEqual(history.value as? String, snapshot)
        attachScreenshot(of: app, named: "Recorded output at process exit after window resize")
        app.buttons["returnToLive"].click()
        XCTAssertTrue(history.waitForNonExistence(timeout: 5))
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
        let workerSpan = app.buttons["traceSpan-5"]
        XCTAssertTrue(workerSpan.waitForExistence(timeout: 10), app.debugDescription)
        workerSpan.click()
        let jump = app.buttons["traceJump-5"]
        XCTAssertTrue(jump.waitForExistence(timeout: 5), app.debugDescription)
        jump.click()
        let history = app.textViews["terminalHistoryText"]
        XCTAssertTrue(history.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(subtabs[3].value as? String, "Selected")
        XCTAssertEqual(app.buttons["workflowTab-2"].value as? String, "Selected")
        history.click()
        app.typeText("touch must-not-reach-live\r")
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 950, height: 720))
        XCTAssertTrue(history.exists)
        // Give all four panes room, so changing focus doesn't collapse the historical pane.
        app.buttons["tracesHeader"].click()
        // Another pane can remain live while history is open. Return must refocus the history's agent.
        let livePane = app.menuButtons["agentPane-1"]
        XCTAssertTrue(livePane.waitForExistence(timeout: 5), app.debugDescription)
        livePane.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .withOffset(CGVector(dx: 0, dy: 80)).click()
        XCTAssertEqual(subtabs[0].value as? String, "Selected")
        XCTAssertTrue(history.exists)
        history.click()
        attachScreenshot(of: app, named: "Trace output in the selected Bento agent")
        XCTAssertTrue(app.buttons["returnToLive"].isHittable, app.debugDescription)
        app.buttons["returnToLive"].click()
        XCTAssertTrue(history.waitForNonExistence(timeout: 5))
        XCTAssertEqual(subtabs[3].value as? String, "Selected")
        app.typeText("echo $TWINE_AGENT > returned-to-live\r")
        waitForFile(folder.appending(path: "returned-to-live"), containing: "agent3", in: app)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appending(path: "must-not-reach-live").path))
    }
}
