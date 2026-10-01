import SQLite3
import XCTest

extension TwineUITests {
    @MainActor
    func testActivityTracksShareStartOrderAndFocusSevenSteps() throws {
        let folder = try makeTestFolder(prefix: "TwineSequenceUITests")
        let app = try makeApp(lastOpenFolder: folder)
        app.launchEnvironment["SHELL"] = "/bin/sh"
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["tracesHeader"].waitForExistence(timeout: 10))
        app.buttons["workflowChoice-Terminal"].click()
        app.terminate()
        try seedSequenceHistory(app)
        app.launch()
        XCTAssertTrue(app.buttons["tracesHeader"].waitForExistence(timeout: 10))
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 1280, height: 760))
        app.buttons["tracesHeader"].click()
        let range = app.staticTexts["traceFocusRange"]
        XCTAssertTrue(range.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'traceFocusSpan-'")).count, 7)

        let points = (100...114).map { app.buttons["traceSpan-\($0)"] }
        XCTAssertTrue(points[14].waitForExistence(timeout: 5), app.debugDescription)
        let frames = points.map(\.frame)
        // Includes a two-hour pause and an exact timestamp tie on different agents.
        for index in 1..<frames.count {
            XCTAssertGreaterThan(frames[index].midX, frames[index - 1].midX)
            XCTAssertEqual(frames[index].midX - frames[index - 1].midX, frames[1].midX - frames[0].midX, accuracy: 1)
        }
        XCTAssertEqual(abs(frames[1].midY - frames[0].midY), 18, accuracy: 1)
        points[7].click()
        XCTAssertTrue(app.buttons["closeTraceDetails"].waitForExistence(timeout: 5))
        XCTAssertEqual(range.value as? String, "5–11 of 16")
        XCTAssertTrue(app.buttons["traceFocusSpan-104"].exists)
        XCTAssertTrue(app.buttons["traceFocusSpan-110"].exists)
        XCTAssertFalse(app.buttons["traceFocusSpan-103"].exists)
        attachWindow(in: app, name: "Activity, compact agent tracks and seven-step focus")

        app.buttons["nextTraceStep"].click()
        XCTAssertEqual(range.value as? String, "6–12 of 16")
        app.buttons["previousTraceStep"].click()
        XCTAssertEqual(range.value as? String, "5–11 of 16")
        points[0].click()
        XCTAssertEqual(range.value as? String, "1–7 of 16")
        XCTAssertFalse(app.buttons["previousTraceStep"].isEnabled)
        points[14].click()
        XCTAssertEqual(range.value as? String, "10–16 of 16")

        // The resumed shell is on a fourth track, below the overview viewport.
        app.buttons["nextTraceStep"].click()
        XCTAssertFalse(app.buttons["nextTraceStep"].isEnabled)
        XCTAssertTrue(app.buttons["traceSpan-115"].isHittable, app.debugDescription)
        app.buttons["traceFocusSpan-114"].click()
        XCTAssertTrue(points[14].isHittable, app.debugDescription)

        verifySequenceAtMinimumWidth(app)
    }

    @MainActor
    private func verifySequenceAtMinimumWidth(_ app: XCUIApplication) {
        app.buttons["sidebarToggle"].click()
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 400, height: 620))
        XCTAssertTrue(app.buttons["traceSpan-114"].isHittable, app.debugDescription)
        XCTAssertTrue(app.buttons["traceFocusSpan-114"].isHittable, app.debugDescription)
        XCTAssertTrue(app.buttons["closeTraceDetails"].isHittable)
        attachWindow(in: app, name: "Activity, selected step at minimum width")
    }

    /// Historical core records exercise the real read path without relying on live harness timing.
    @MainActor
    private func seedSequenceHistory(_ app: XCUIApplication) throws {
        let directory = try XCTUnwrap(app.launchEnvironment["TWINE_DATA_DIRECTORY"])
        var database: OpaquePointer?
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_open("\(directory)/twine.db", &database), SQLITE_OK)
        var sql = """
            PRAGMA foreign_keys = ON;
            DELETE FROM trace_events;
            DELETE FROM trace_spans;
            DELETE FROM trace_lanes;
            INSERT INTO trace_lanes (id, workflow_id, lane_key, name, is_agent, role, harness) VALUES
                (100, 1, 'sequence-coordinator', 'Coordinator', 1, 'coordinator', 'codex'),
                (101, 1, 'sequence-implementer', 'Implementer', 1, 'implementer', 'codex'),
                (102, 1, 'sequence-reviewer', 'Reviewer', 1, 'reviewer', 'codex');
            """
        for index in 0..<15 {
            let start = index * 1_000 + (index >= 7 ? 7_200_000 : 0)
            // Steps 7 and 8 start together on different tracks.
            let timestamp = index == 6 ? 7_207_000 : start
            let title = index == 7 ? "Refine selection" : "Step \(index + 1)"
            let status = index == 7 ? "failed" : "exited"
            sql += """
                INSERT INTO trace_spans (id, lane_id, title, started_at, ended_at, status)
                VALUES (\(100 + index), \(100 + index % 3), '\(title)', \(timestamp), \(timestamp + 500), '\(status)');
                INSERT INTO trace_events (workflow_id, span_id, timestamp, kind, message)
                VALUES (1, \(100 + index), \(timestamp), 'workflowEvent', 'Recorded step \(index + 1)');
                """
        }
        XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK, String(cString: sqlite3_errmsg(database)))
    }
}
