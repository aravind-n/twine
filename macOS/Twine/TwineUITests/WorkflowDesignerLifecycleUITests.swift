import XCTest

extension TwineUITests {
    @MainActor
    func testCustomWorkflowCreationVersionPersistenceAndInteractiveRun() throws {
        let app = try workflowRunApp()
        defer { app.terminate() }
        func item(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
        func replace(_ id: String, with text: String) {
            item(id).click()
            app.typeKey("a", modifierFlags: .command)
            app.typeText(text)
        }
        func save() {
            let ready = expectation(for: NSPredicate { _, _ in item("designerSave").isEnabled }, evaluatedWith: nil)
            wait(for: [ready], timeout: 10)
            app.typeKey("s", modifierFlags: .command)
            XCTAssertTrue(item("workflowEditType").waitForExistence(timeout: 10), app.debugDescription)
        }
        app.buttons["newWorkflow"].click()
        XCTAssertTrue(item("workflowCreateOwn").waitForExistence(timeout: 5))
        item("workflowCreateOwn").click()
        replace("designerName", with: "Write a draft")
        app.buttons["Add your first agent"].click()
        replace("graphAgentName", with: "Writer")
        replace("graphAgentInstructions", with: "Write a clear draft and summarize the result.")
        app.buttons["Done"].click()
        save()
        item("workflowEditType").click()
        replace("designerName", with: "Write and check")
        save()
        app.buttons["Back"].click()
        let custom = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'workflowChoice-custom-'"))
            .firstMatch
        XCTAssertTrue(custom.waitForExistence(timeout: 5))
        let versionTwo = custom.identifier
        XCTAssertTrue(versionTwo.hasSuffix("-2"))
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["newWorkflow"].waitForExistence(timeout: 10))
        app.buttons["newWorkflow"].click()
        XCTAssertTrue(item(versionTwo).waitForExistence(timeout: 10))
        item(versionTwo).click()
        let harness = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'roleHarness-'")
        ).firstMatch
        XCTAssertTrue(harness.waitForExistence(timeout: 5))
        harness.click()
        app.menuItems["pi"].click()
        item("workflowStart").click()
        XCTAssertTrue(item("workflowMarkDone").waitForExistence(timeout: 10))
        completeRole(in: app, summary: "Draft is ready", task: "Write a short release note")
        XCTAssertTrue(app.staticTexts["Completed"].waitForExistence(timeout: 10), app.debugDescription)
    }
}
