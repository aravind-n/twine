import XCTest

extension TwineUITests {
    @MainActor
    func testAdversarialHarnessSelectionUserCompletionReviewLoopAndTraces() throws {
        let app = try workflowRunApp()
        defer { app.terminate() }
        func item(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
        app.buttons["newWorkflow"].click()
        XCTAssertTrue(item("workflowChoice-Adversarial").waitForExistence(timeout: 10))
        item("workflowChoice-Adversarial").click()
        for role in ["implementer", "reviewer"] {
            let picker = item("roleHarness-\(role)-0")
            XCTAssertTrue(picker.waitForExistence(timeout: 10), app.debugDescription)
            picker.click()
            app.menuItems["pi"].click()
        }
        item("workflowPrompt").click()
        item("workflowPrompt").typeText("Build a small ")
        app.buttons["workflowTab-1"].click()
        app.buttons["workflowTab-2"].click()
        XCTAssertEqual(item("workflowPrompt").value as? String, "Build a small ")
        // macOS selects the field's contents when focus returns; continue at the end.
        app.typeKey(.rightArrow, modifierFlags: [])
        app.typeText("feature")
        XCTAssertTrue(item("workflowPrompt").exists, "Returning to a launch form keeps typing out of the shell")
        XCTAssertEqual(item("workflowPrompt").value as? String, "Build a small feature")
        item("workflowStart").click()
        XCTAssertTrue(item("workflowMarkDone").waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.buttons["agentSubtab-1"].exists)
        XCTAssertTrue(app.buttons["agentSubtab-2"].exists)
        inspectStage("implement", in: app)

        completeRole(in: app, summary: "Initial implementation")
        attachScreenshot(of: app, named: "Implementer after accepted completion")
        XCTAssertTrue(app.staticTexts["Agent completed"].waitForExistence(timeout: 5), app.debugDescription)
        inspectStage("review", in: app)
        app.buttons["agentSubtab-2"].click()
        XCTAssertTrue(item("workflowMarkDone").waitForExistence(timeout: 10))
        completeRole(in: app, summary: "Fix the edge case", requestChanges: true)
        inspectStage("implement", in: app)
        app.buttons["agentSubtab-1"].click()
        XCTAssertTrue(item("workflowMarkDone").waitForExistence(timeout: 10))
        // The previous reviewer remains completed in its retained, hidden pane. Check this
        // round's new implementer terminal rather than every agent's badge.
        XCTAssertTrue(item("terminalStatus-5").waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(item("terminalStatus-5").value as? String, "Agent exited with code 0")
        completeRole(in: app, summary: "Fixed the edge case")
        app.buttons["agentSubtab-2"].click()
        XCTAssertTrue(item("workflowMarkDone").waitForExistence(timeout: 10))
        completeRole(in: app, summary: "Approved")
        XCTAssertTrue(app.staticTexts["Completed"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(item("workflowCancel").exists)
        XCTAssertTrue(app.staticTexts["Agent completed"].waitForExistence(timeout: 5), app.debugDescription)
        inspectTraceHandoff(in: app)
        inspectSavedHarnesses(in: app)
    }

    @MainActor
    private func inspectSavedHarnesses(in app: XCUIApplication) {
        func item(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
        app.buttons["newWorkflow"].click()
        let choices = app.scrollViews["newTabChoices"]
        XCTAssertTrue(choices.waitForExistence(timeout: 10), app.debugDescription)
        // The expanded Traces panel leaves the graph cards below the first visible choices.
        choices.scroll(byDeltaX: 0, deltaY: -400)
        let choice = item("workflowChoice-Adversarial")
        XCTAssertTrue(choice.waitForExistence(timeout: 10), app.debugDescription)
        choice.click()
        for role in ["implementer", "reviewer"] {
            let picker = item("roleHarness-\(role)-0")
            XCTAssertTrue(picker.waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertEqual(picker.value as? String, "pi")
        }
        attachScreenshot(of: app, named: "Adversarial graph and saved harness choices")
    }

    @MainActor
    private func inspectTraceHandoff(in app: XCUIApplication) {
        func item(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
        item("tracesHeader").click()
        let span = item("traceOverview").buttons.matching(
            NSPredicate(format: "label ENDSWITH %@", "Reviewer: Review · Round 1, Completed")
        ).firstMatch
        XCTAssertTrue(span.waitForExistence(timeout: 10), app.debugDescription)
        span.click()
        let log = app.scrollViews["traceEventLog"]
        XCTAssertTrue(log.waitForExistence(timeout: 5), app.debugDescription)
        let handoff = log.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Handoff delivered: Initial implementation")
        ).firstMatch
        XCTAssertTrue(handoff.waitForExistence(timeout: 10), app.debugDescription)
        log.scroll(byDeltaX: 0, deltaY: -400)
        let completion = log.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Requested changes: Fix the edge case")
        ).firstMatch
        XCTAssertTrue(completion.waitForExistence(timeout: 10), app.debugDescription)
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = "Completed Adversarial workflow and traces"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    private func inspectStage(_ stage: String, in app: XCUIApplication) {
        func item(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
        XCTAssertTrue(item("inspectWorkflowType").waitForExistence(timeout: 10), app.debugDescription)
        item("inspectWorkflowType").click()
        XCTAssertTrue(item("workflowTypeInspector").waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(item("graphStage-\(stage)").value as? String, "Current stage")
        let handoffs = item("graphHandoffs").value as? String ?? ""
        XCTAssertTrue(
            handoffs.contains("Implementer in Implement sends result to Reviewer in Review."), app.debugDescription)
        XCTAssertTrue(
            handoffs.contains("Reviewer in Review sends feedback to Implementer in Implement."), app.debugDescription)
        XCTAssertFalse(item("workflowStart").exists)
        XCTAssertFalse(item("roleHarness-implementer-0").exists)
        attachScreenshot(of: app, named: "Live graph at \(stage)")
        item("closeWorkflowType").click()
        XCTAssertTrue(item("workflowTypeInspector").waitForNonExistence(timeout: 5), app.debugDescription)
    }

    @MainActor
    private func completeRole(in app: XCUIApplication, summary: String, requestChanges: Bool = false) {
        func item(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
        item("workflowMarkDone").click()
        XCTAssertTrue(item("completionSummary").waitForExistence(timeout: 5), app.debugDescription)
        if requestChanges {
            let decision = item("Request changes")
            XCTAssertTrue(decision.waitForExistence(timeout: 5), app.debugDescription)
            decision.click()
        }
        item("completionSummary").click()
        item("completionSummary").typeText(summary)
        item("completionSubmit").click()
        XCTAssertTrue(item("completionSubmit").waitForNonExistence(timeout: 10), app.debugDescription)
    }

    @MainActor
    private func workflowRunApp(appearance: String? = nil) throws -> XCUIApplication {
        let folder = FileManager.default.temporaryDirectory.appending(path: "TwineRunUI-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let bin = folder.appending(path: "bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        // A system binary avoids macOS's restriction on executing scripts written by the
        // sandboxed UI test runner. It exits without signaling, exercising Mark done's fallback.
        try FileManager.default.createSymbolicLink(
            at: bin.appending(path: "pi"),
            withDestinationURL: URL(filePath: "/usr/bin/true"))
        let app = try makeApp(lastOpenFolder: folder)
        app.launchEnvironment["TWINE_TEST_PREFERENCES_SUITE"] = "TwineRunUITests-\(UUID())"
        app.launchEnvironment["TWINE_TEST_APPEARANCE"] = appearance
        app.launchEnvironment["TWINE_HARNESS_PATH"] = "\(folder.path)/bin:/bin:/usr/bin"
        app.launch()
        func item(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
        XCTAssertTrue(item("workflowChoice-Terminal").waitForExistence(timeout: 10))
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 1000, height: 720))
        item("workflowChoice-Terminal").click()
        XCTAssertTrue(item("newTabChoices").waitForNonExistence(timeout: 10), app.debugDescription)
        return app
    }

    @MainActor
    func testCoordinatorGraphsInBothAppearances() throws {
        for appearance in ["Light", "Dark"] {
            let app = try workflowRunApp(appearance: appearance)
            defer { app.terminate() }
            func item(_ id: String) -> XCUIElement {
                app.descendants(matching: .any).matching(identifier: id).firstMatch
            }
            app.buttons["newWorkflow"].click()
            XCTAssertTrue(item("workflowChoice-Coordinator").waitForExistence(timeout: 10))
            attachScreenshot(of: app, named: "Catalog graph previews in \(appearance)")
            item("workflowChoice-Coordinator").click()
            XCTAssertTrue(item("workflowGraph-coordinator").waitForExistence(timeout: 10))
            XCTAssertTrue(item("graphNode-work-worker-1").exists)
            XCTAssertTrue(item("graphNode-work-worker-2").exists)
            let handoffs = item("graphHandoffs").value as? String ?? ""
            XCTAssertTrue(
                handoffs.contains("Coordinator in Split sends assignment to Worker 1 in Work."), app.debugDescription)
            XCTAssertTrue(
                handoffs.contains("Worker 1 in Work sends result to Coordinator in Gather."), app.debugDescription)
            attachScreenshot(of: app, named: "Coordinator launch graph in \(appearance)")
        }
    }

}
