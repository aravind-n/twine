import XCTest

extension TwineUITests {
    @MainActor
    func testNativeHistoryShowsModelSummaryFullDetailsAndStoragePinAfterRelaunch() throws {
        let folder = try inspectorFolder()
        try writeInspectorAgent(in: folder)
        try writeInspectorNativeHistory(in: folder)
        let app = try makeApp(lastOpenFolder: folder)
        app.launchEnvironment["SHELL"] = "/bin/sh"
        app.launchEnvironment["TWINE_HARNESS_PATH"] = "\(folder.path)/bin:/bin:/usr/bin"
        app.launchEnvironment["CLAUDE_CONFIG_DIR"] = folder.appending(path: "native").path
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["workflowTab-1"].waitForExistence(timeout: 10))
        inspectorElement("workflowChoice-Terminal", in: app).click()
        app.typeText(
            "mkdir bin; printf '#!/bin/sh\\n' > bin/claude; cat inspector-stub.txt >> bin/claude; chmod +x bin/claude\r"
        )
        waitForFile(folder.appending(path: "bin/claude"), containing: "inspector-events", in: app)
        app.buttons["newWorkflow"].click()
        chooseInspectorHarness("claudeCode", displayName: "Claude Code", in: app)
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 1100, height: 900))
        waitForFile(folder.appending(path: "inspector-ready"), containing: "ready", in: app)
        app.buttons["tracesHeader"].click()
        let step = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH 'traceSpan-' AND label CONTAINS 'Inspect parallel coding work'"
            )
        ).firstMatch
        XCTAssertTrue(step.waitForExistence(timeout: 10), app.debugDescription)
        step.click()
        XCTAssertTrue(app.staticTexts["traceStepCounts"].waitForExistence(timeout: 10))
        let inspect = app.buttons["inspectTraceActivity"]
        XCTAssertTrue(inspect.waitForExistence(timeout: 10))
        inspect.click()
        let search = app.textFields["traceActivitySearch"]
        search.click()
        search.typeText("LLM call")
        let call = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH 'traceActivity-' AND label CONTAINS 'LLM call'"
            )
        ).firstMatch
        XCTAssertTrue(call.waitForExistence(timeout: 10), app.debugDescription)
        let callID = call.identifier
        let stepID = step.identifier
        checkNativeModelDetails(in: app, call: call)
        checkNativeHistoryRelaunch(in: app, callID: callID, stepID: stepID)
    }

    @MainActor
    private func checkNativeModelDetails(in app: XCUIApplication, call: XCUIElement) {
        call.click()
        XCTAssertTrue(app.staticTexts["fixture-model"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["120 input tokens"].exists)
        let fullOutput = app.buttons["traceFullOutput"]
        XCTAssertTrue(fullOutput.waitForExistence(timeout: 5), app.debugDescription)
        fullOutput.click()
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(
                    format: "value CONTAINS 'END-OF-FULL-RESPONSE'"
                )
            ).firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["traceStorage"].click()
        let pin = inspectorElement("pinTraceDetails", in: app)
        XCTAssertTrue(pin.waitForExistence(timeout: 10), app.debugDescription)
        pin.click()
        waitForInspectorPin(in: app)
        XCTAssertTrue(app.staticTexts["traceStorageUsage"].exists)
        app.typeKey(.escape, modifierFlags: [])
        attachWindow(in: app, name: "Recovered LLM call with complete streamed response and pinned storage")
    }

    @MainActor
    private func checkNativeHistoryRelaunch(in app: XCUIApplication, callID: String, stepID: String) {
        app.menuBars.menuBarItems["Twine"].click()
        app.menuItems["Quit Twine"].click()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
        app.launch()
        XCTAssertTrue(app.buttons["workflowTab-2"].waitForExistence(timeout: 10))
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 820, height: 576))
        app.buttons["workflowTab-2"].click()
        app.buttons["tracesHeader"].click()
        XCTAssertTrue(app.buttons[stepID].waitForExistence(timeout: 10))
        app.buttons[stepID].click()
        selectTraceViewMode("In Depth", in: app)
        revealInspectorControl(app.textFields["traceActivitySearch"], in: app)
        app.textFields["traceActivitySearch"].click()
        app.textFields["traceActivitySearch"].typeText("LLM call")
        XCTAssertTrue(app.buttons[callID].waitForExistence(timeout: 10))
        app.buttons[callID].click()
        let fullOutput = app.buttons["traceFullOutput"]
        XCTAssertTrue(fullOutput.waitForExistence(timeout: 5))
        // Relaunch may restore a smaller window. Opening the inspector grows the workspace,
        // so expose its controls using the outer scroll view before XCTest scrolls the inspector.
        let viewport = app.scrollViews["tracesBody"]
        let inspector = app.scrollViews["traceActivityInspector"]
        for _ in 0..<6 where !viewport.frame.contains(inspector.frame) {
            viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.5))
                .scroll(byDeltaX: 0, deltaY: -300)
        }
        for _ in 0..<8 where !fullOutput.isHittable {
            inspector.scroll(byDeltaX: 0, deltaY: -400)
        }
        XCTAssertTrue(fullOutput.isHittable, app.debugDescription)
        fullOutput.click()
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(
                    format: "value CONTAINS 'END-OF-FULL-RESPONSE'"
                )
            ).firstMatch.waitForExistence(timeout: 5))
        let storage = app.buttons["traceStorage"]
        revealInspectorControl(storage, in: app)
        storage.click()
        waitForInspectorPin(in: app)
        app.typeKey(.escape, modifierFlags: [])
    }

    @MainActor
    private func waitForInspectorPin(in app: XCUIApplication) {
        let pin = inspectorElement("pinTraceDetails", in: app)
        let pinned = expectation(
            for: NSPredicate { _, _ in
                pin.exists && String(describing: pin.value ?? "") == "1" && pin.isEnabled
            }, evaluatedWith: nil)
        wait(for: [pinned], timeout: 10)
    }

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
        selectTraceViewMode("In Depth", in: app)
        let step = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH 'traceSpan-' AND label CONTAINS 'Inspect parallel coding work'"
            )
        ).firstMatch
        XCTAssertTrue(step.waitForExistence(timeout: 10), app.debugDescription)
        step.click()
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
        let stepID = step.identifier
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
        search.click()
        search.typeText("cargo test")
        XCTAssertTrue(call.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(call.isHittable, app.debugDescription)
        search.click()
        search.typeKey("a", modifierFlags: .command)
        search.typeKey(.delete, modifierFlags: [])
    }

    @MainActor
    private func checkInspectorRelaunch(in app: XCUIApplication, callID: String, stepID: String) {
        selectTraceViewMode("Overview", in: app)
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
        let returnToLive = app.buttons["minimapReturnToLive"]
        XCTAssertTrue(returnToLive.waitForExistence(timeout: 10), app.debugDescription)
        returnToLive.click()
        XCTAssertTrue(returnToLive.waitForNonExistence(timeout: 5), app.debugDescription)
        selectTraceViewMode("In Depth", in: app)
        revealInspectorControl(app.textFields["traceActivitySearch"], in: app)
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
        // Reveal the inspector's bottom within the Traces body too.
        app.scrollViews["tracesBody"].coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
            .scroll(byDeltaX: 0, deltaY: -800)
        XCTAssertTrue(app.buttons["traceActivityJump"].isHittable, app.debugDescription)
        XCTAssertFalse(returnToLive.exists, app.debugDescription)
        app.buttons["traceActivityJump"].click()
        // Retained output is revealed in the mounted terminal, including after relaunch.
        XCTAssertTrue(returnToLive.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.textViews["terminalHistoryText"].exists, app.debugDescription)
        attachWindow(in: app, name: "Recorded tool details survive relaunch")
    }

    @MainActor
    private func revealInspectorControl(_ control: XCUIElement, in app: XCUIApplication) {
        let viewport = app.scrollViews["tracesBody"]
        XCTAssertTrue(control.waitForExistence(timeout: 5), app.debugDescription)
        for _ in 0..<8 {
            if control.isHittable, viewport.frame.contains(control.frame) { break }
            let isAbove = control.frame.minY < viewport.frame.minY
            let delta: CGFloat = isAbove ? 100 : -100
            // The middle can be covered by a nested chart or inspector scroll view.
            viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: isAbove ? 0.01 : 0.99))
                .scroll(byDeltaX: 0, deltaY: delta)
        }
        XCTAssertTrue(viewport.frame.contains(control.frame), app.debugDescription)
        XCTAssertTrue(control.isHittable, app.debugDescription)
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

}
