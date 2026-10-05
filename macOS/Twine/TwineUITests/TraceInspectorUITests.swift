import XCTest

extension TwineUITests {
    @MainActor
    func testTimelineInspectorShowsNestedCallsFiltersAndSurvivesRelaunch() throws {
        let folder = try inspectorFolder()
        try writeInspectorAgent(in: folder)
        let app = try makeApp(lastOpenFolder: folder)
        app.launchEnvironment["SHELL"] = "/bin/sh"
        app.launchEnvironment["TWINE_HARNESS_PATH"] = "\(folder.path)/bin:/bin:/usr/bin"
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["workflowTab-1"].waitForExistence(timeout: 10))
        inspectorElement("workflowChoice-Terminal", in: app).click()
        app.typeText(
            "mkdir bin; printf '#!/bin/sh\\n' > bin/claude; cat inspector-stub.txt >> bin/claude; chmod +x bin/claude\r"
        )
        let installed = expectation(
            for: NSPredicate { _, _ in
                FileManager.default.isExecutableFile(atPath: folder.appending(path: "bin/claude").path)
            }, evaluatedWith: nil)
        wait(for: [installed], timeout: 10)
        app.buttons["newWorkflow"].click()
        chooseInspectorHarness("claudeCode", displayName: "Claude Code", in: app)
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 1100, height: 900))
        waitForFile(folder.appending(path: "inspector-ready"), containing: "ready", in: app)
        let header = app.buttons["tracesHeader"]
        XCTAssertTrue(header.waitForExistence(timeout: 10))
        header.click()
        XCTAssertFalse(inspectorElement("traceInDepthView", in: app).exists)
        selectInspectorMode("In depth", in: app)
        let call = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'traceActivity-' AND label CONTAINS 'cargo test'")
        ).firstMatch
        XCTAssertTrue(call.waitForExistence(timeout: 10), app.debugDescription)
        call.click()
        XCTAssertTrue(inspectorElement("traceActivityInspector", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["traceActivityJump"].isEnabled)
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "value CONTAINS 'fixture test failure'")).firstMatch.exists)
        attachWindow(in: app, name: "Timeline inspector with parallel subagents and failed nested tool")

        let callID = call.identifier
        let stepID = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH 'traceSpan-' AND label CONTAINS 'Inspect parallel coding work'"
            )
        ).firstMatch.identifier
        checkInspectorFiltersAndScrolling(in: app, call: call)
        checkInspectorRelaunch(in: app, callID: callID, stepID: stepID)
    }

    @MainActor
    private func checkInspectorFiltersAndScrolling(in app: XCUIApplication, call: XCUIElement) {
        let failures = inspectorElement("traceFailuresOnly", in: app)
        failures.click()
        XCTAssertTrue(call.exists)
        XCTAssertFalse(
            app.buttons.matching(
                NSPredicate(format: "identifier BEGINSWITH 'traceActivity-' AND label CONTAINS 'printf final-tool'")
            ).firstMatch.exists)
        failures.click()
        let search = app.textFields["traceActivitySearch"]
        search.click()
        search.typeText("final-tool")
        let final = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'traceActivity-' AND label CONTAINS 'final-tool'")
        ).firstMatch
        XCTAssertTrue(final.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(final.isHittable)
        search.click()
        search.typeKey("a", modifierFlags: .command)
        search.typeKey(.delete, modifierFlags: [])
        app.buttons["closeTraceActivity"].click()
        let chart = inspectorElement("traceActivityTimeline", in: app)
        chart.hover()
        chart.scroll(byDeltaX: 0, deltaY: -700)
        XCTAssertTrue(final.isHittable, app.debugDescription)
        attachWindow(in: app, name: "Scrollable deep timeline reaches the last tool")

    }

    @MainActor
    private func checkInspectorRelaunch(in app: XCUIApplication, callID: String, stepID: String) {
        selectInspectorMode("Standard", in: app)
        XCTAssertFalse(inspectorElement("traceActivityInspector", in: app).exists)
        app.menuBars.menuBarItems["Twine"].click()
        app.menuItems["Quit Twine"].click()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
        app.launch()
        XCTAssertTrue(app.buttons["workflowTab-2"].waitForExistence(timeout: 10))
        app.buttons["workflowTab-2"].click()
        app.buttons["tracesHeader"].click()
        let originalStep = app.buttons[stepID]
        XCTAssertTrue(originalStep.waitForExistence(timeout: 10), app.debugDescription)
        originalStep.click()
        selectInspectorMode("In depth", in: app)
        // Restored windows may be shorter; reveal the deep panel through the outer viewport.
        app.scrollViews["workspaceViewport"].coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5))
            .scroll(byDeltaX: 0, deltaY: -800)
        let search = app.textFields["traceActivitySearch"]
        search.click()
        search.typeText("cargo test")
        let call = app.buttons[callID]
        XCTAssertTrue(call.waitForExistence(timeout: 10), app.debugDescription)
        call.click()
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "value CONTAINS 'fixture test failure'")).firstMatch.exists)
        let inspector = app.scrollViews["traceActivityInspector"]
        inspector.scroll(byDeltaX: 0, deltaY: -600)
        XCTAssertTrue(app.buttons["traceActivityJump"].isHittable, app.debugDescription)
        app.buttons["traceActivityJump"].click()
        XCTAssertTrue(app.textViews["terminalHistoryText"].waitForExistence(timeout: 10), app.debugDescription)
        attachWindow(in: app, name: "Recorded tool details survive relaunch")
    }

    @MainActor
    private func selectInspectorMode(_ mode: String, in app: XCUIApplication) {
        let control = inspectorElement("traceViewMode", in: app)
        XCTAssertTrue(control.waitForExistence(timeout: 5), app.debugDescription)
        let choice = control.descendants(matching: .any).matching(NSPredicate(format: "label == %@", mode)).firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 5), app.debugDescription)
        choice.click()
    }

    @MainActor
    private func inspectorElement(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    private func chooseInspectorHarness(_ harness: String, displayName: String, in app: XCUIApplication) {
        let tile = inspectorElement("workflowChoice-Single agent", in: app)
        XCTAssertTrue(tile.waitForExistence(timeout: 10), app.debugDescription)
        tile.click()
        app.menuItems[displayName].click()
        let model = app.menuItems["harness-\(harness)"].menuItems["Default model"]
        XCTAssertTrue(model.waitForExistence(timeout: 5), app.debugDescription)
        model.click()
    }

    private func inspectorFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(
            path: "TwineInspectorUITests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    private func inspectorEvents() -> [[String: Any]] {
        var events: [[String: Any]] = [
            ["hook_event_name": "UserPromptSubmit", "prompt": "Inspect parallel coding work"],
            ["hook_event_name": "SubagentStart", "agent_id": "review", "agent_type": "Reviewer"],
            ["hook_event_name": "SubagentStart", "agent_id": "tests", "agent_type": "Test runner"],
            [
                "hook_event_name": "PreToolUse", "agent_id": "review", "tool_use_id": "read", "tool_name": "Read",
                "tool_input": ["file_path": "src/main.rs"],
            ],
            [
                "hook_event_name": "PreToolUse", "agent_id": "tests", "tool_use_id": "test", "tool_name": "Bash",
                "tool_input": ["command": "cargo test"],
            ],
            [
                "hook_event_name": "PostToolUse", "agent_id": "review", "tool_use_id": "read", "tool_name": "Read",
                "tool_input": ["file_path": "src/main.rs"], "tool_response": "fn main() {}",
            ],
            [
                "hook_event_name": "PostToolUseFailure", "agent_id": "tests", "tool_use_id": "test",
                "tool_name": "Bash", "tool_input": ["command": "cargo test"], "error": "fixture test failure",
            ],
            [
                "hook_event_name": "SubagentStop", "agent_id": "review", "agent_type": "Reviewer",
                "last_assistant_message": "Review complete",
            ],
            [
                "hook_event_name": "SubagentStop", "agent_id": "tests", "agent_type": "Test runner",
                "last_assistant_message": "Failure reported",
            ],
        ]
        for index in 0..<24 {
            let command = index == 23 ? "printf final-tool" : "printf tool-\(index)"
            for event in ["PreToolUse", "PostToolUse"] {
                events.append([
                    "hook_event_name": event, "tool_use_id": "tool-\(index)", "tool_name": "Bash",
                    "tool_input": ["command": command], "tool_response": "recorded output \(index)",
                ])
            }
        }
        events.append(["hook_event_name": "Stop", "last_assistant_message": "Inspection complete"])
        return events
    }

    private func writeInspectorAgent(in folder: URL) throws {
        let lines =
            try inspectorEvents().map { event in
                var event = event
                event["session_id"] = "inspector-fixture"
                event["prompt_id"] = "inspect"
                return try XCTUnwrap(
                    String(
                        data: JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]), encoding: .utf8))
            }.joined(separator: "\n") + "\n"
        try lines.write(to: folder.appending(path: "inspector-events.jsonl"), atomically: true, encoding: .utf8)
        try #"""
        case "$1" in --help) exit 0 ;; esac
        if [ -f inspector-ready ]; then while :; do sleep 1; done; fi
        while [ "$#" -gt 0 ]; do
            if [ "$1" = --settings ]; then settings="$2"; break; fi
            shift
        done
        hook=$(/usr/bin/plutil -extract hooks.UserPromptSubmit.0.hooks.0.command raw -o - "$settings")
        stty -echo
        printf '❯ Inspect parallel coding work\n'
        while IFS= read -r event; do
            printf '%s' "$event" | /bin/sh -c "$hook"
            printf 'recorded native hook\n'
        done < inspector-events.jsonl
        printf 'ready\n' > inspector-ready
        while :; do sleep 1; done
        """#.write(to: folder.appending(path: "inspector-stub.txt"), atomically: true, encoding: .utf8)
    }
}
