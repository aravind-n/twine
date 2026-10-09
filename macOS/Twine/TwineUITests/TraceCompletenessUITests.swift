import SQLite3
import XCTest

extension TwineUITests {
    @MainActor
    func testLegacyTraceEventsKeepLoadedPagesWhenThePanelRefreshes() throws {
        let folder = try makeTestFolder(prefix: "TwineTraceCompletenessUITests")
        let app = try makeApp(lastOpenFolder: folder)
        app.launchEnvironment["SHELL"] = "/bin/sh"
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["tracesHeader"].waitForExistence(timeout: 10))
        app.buttons["workflowChoice-Terminal"].click()
        app.terminate()
        try seedLongTraceLog(app)
        app.launch()
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 1100, height: 900))
        let header = app.buttons["tracesHeader"]
        XCTAssertTrue(header.waitForExistence(timeout: 10))
        header.click()
        let step = app.buttons["traceSpan-1000"]
        XCTAssertTrue(step.waitForExistence(timeout: 10), app.debugDescription)
        step.click()
        selectTraceViewMode("In Depth", in: app)
        let fallback = app.descendants(matching: .any).matching(identifier: "traceRecordedEventsFallback").firstMatch
        XCTAssertTrue(fallback.waitForExistence(timeout: 10), app.debugDescription)
        let log = app.scrollViews["traceEventLog"]
        let last = log.staticTexts.matching(NSPredicate(format: "value == 'Recorded event 260'")).firstMatch
        let more = app.buttons["More events"]
        log.hover()
        log.scroll(byDeltaX: 0, deltaY: -30_000)
        XCTAssertTrue(more.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(more.isHittable, app.debugDescription)
        more.click()
        XCTAssertTrue(more.waitForNonExistence(timeout: 5), app.debugDescription)
        log.scroll(byDeltaX: 0, deltaY: -30_000)
        XCTAssertTrue(last.waitForExistence(timeout: 5), app.debugDescription)

        // A real process ending publishes a new revision while the legacy log is open.
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.2)).click()
        app.typeText("echo ready > trace-refresh-ready; exit\r")
        waitForFile(folder.appending(path: "trace-refresh-ready"), containing: "ready", in: app)
        let stopped = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH 'terminalStatus-'"))
            .firstMatch
        XCTAssertTrue(stopped.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(last.isHittable, app.debugDescription)
        XCTAssertFalse(more.exists, app.debugDescription)

        // Opening the panel starts the same event refresh used for live revisions.
        header.click()
        header.click()
        XCTAssertTrue(fallback.waitForExistence(timeout: 10), app.debugDescription)
        log.hover()
        log.scroll(byDeltaX: 0, deltaY: -30_000)
        XCTAssertFalse(more.exists, app.debugDescription)
        XCTAssertTrue(last.exists, app.debugDescription)
        XCTAssertTrue(step.isSelected)
        attachWindow(in: app, name: "Legacy trace retains all 260 loaded events after refresh")
    }

    @MainActor
    private func seedLongTraceLog(_ app: XCUIApplication) throws {
        let directory = try XCTUnwrap(app.launchEnvironment["TWINE_DATA_DIRECTORY"])
        var database: OpaquePointer?
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_open("\(directory)/twine.db", &database), SQLITE_OK)
        var sql = """
            PRAGMA foreign_keys = ON;
            INSERT INTO trace_lanes (id, workflow_id, lane_key, name, is_agent, role, harness)
            VALUES (1000, 1, 'legacy-agent', 'Agent', 1, 'agent', 'codex');
            INSERT INTO trace_spans (id, lane_id, title, started_at, ended_at, status, work_span)
            VALUES (1000, 1000, 'Long saved agent trace', 100, 500, 'exited', 1);
            """
        for index in 1...260 {
            sql += """
                INSERT INTO trace_events (workflow_id, span_id, timestamp, kind, message)
                VALUES (1, 1000, \(100 + index), 'workflowEvent', 'Recorded event \(index)');
                """
        }
        XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK, String(cString: sqlite3_errmsg(database)))
    }
}
