import XCTest

extension TwineUITests {
    @MainActor
    func testCustomWorkflowCreationVersionPersistenceAndInteractiveRun() throws {
        let app = try workflowRunApp()
        defer { app.terminate() }
        let designer = WorkflowDesignerUI(app: app)
        app.buttons["newWorkflow"].click()
        XCTAssertTrue(designer.item("workflowCreateOwn").waitForExistence(timeout: 5))
        app.typeKey("d", modifierFlags: [.command, .option])
        XCTAssertTrue(designer.item("designerName").waitForExistence(timeout: 5))
        designer.replace("designerName", with: "Write a draft")
        designer.item("designerAddRole").click()
        designer.replaceFirst("designerRoleName-", with: "Writer")
        designer.replaceFirst("designerRoleInstructions-", with: "Write a clear draft and summarize the result.")
        designer.section("Stages")
        designer.item("designerAddStage").click()
        designer.replaceFirst("designerStageName-", with: "Draft")
        app.checkBoxes["Writer"].click()
        designer.save()
        let versionOne = designer.customChoice.identifier
        XCTAssertTrue(versionOne.hasSuffix("-1"), versionOne)
        designer.customChoice.click()
        designer.item("workflowEditType").click()
        XCTAssertTrue(designer.item("designerName").waitForExistence(timeout: 5))
        designer.replace("designerName", with: "Write and check")
        designer.save()
        let versionTwo = String(versionOne.dropLast()) + "2"
        XCTAssertEqual(designer.customChoice.identifier, versionTwo)

        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["newWorkflow"].waitForExistence(timeout: 10))
        app.buttons["newWorkflow"].click()
        XCTAssertTrue(designer.item(versionTwo).waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(designer.item(versionOne).exists)
        designer.item(versionTwo).click()
        let harness = designer.first("roleHarness-")
        XCTAssertTrue(harness.waitForExistence(timeout: 5))
        harness.click()
        app.menuItems["pi"].click()
        designer.item("workflowStart").click()
        XCTAssertTrue(designer.item("workflowMarkDone").waitForExistence(timeout: 10), app.debugDescription)
        designer.item("inspectWorkflowType").click()
        XCTAssertTrue(app.staticTexts["Version 2"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Write and check"].exists)
        designer.item("closeWorkflowType").click()
        completeRole(in: app, summary: "Draft is ready", task: "Write a short release note")
        XCTAssertTrue(app.staticTexts["Completed"].waitForExistence(timeout: 10), app.debugDescription)
    }

    @MainActor
    func testDesignerStageHandoffAndLoopRepairsWithExampleScreenshots() throws {
        let app = try workflowRunApp(appearance: "Dark")
        defer { app.terminate() }
        let designer = WorkflowDesignerUI(app: app)
        app.buttons["newWorkflow"].click()
        XCTAssertTrue(designer.item("workflowChoice-Adversarial").waitForExistence(timeout: 5))
        designer.item("workflowChoice-Adversarial").click()
        designer.item("workflowEditType").click()
        XCTAssertTrue(designer.item("designerName").waitForExistence(timeout: 5))
        designer.replace("designerName", with: "Implement and review")
        designer.waitUntilValid()
        captureDesigner(app, named: "01-roles-and-instructions")
        let instructions = designer.item("designerRoleInstructions-implementer").value as? String ?? ""
        XCTAssertFalse(instructions.isEmpty)
        designer.replace("designerRoleInstructions-implementer", with: "")
        XCTAssertTrue(designer.item("designerError-roles[0]").waitForExistence(timeout: 5))
        XCTAssertFalse(designer.item("designerSave").isEnabled)
        captureDesigner(app, named: "06-inline-validation")
        designer.replace("designerRoleInstructions-implementer", with: instructions)
        repairDesignerStagesAndHandoffs(designer)
        captureDesigner(app, named: "03-handoffs")
        designer.section("Review loops")
        app.buttons["Remove loop"].click()
        designer.section("Stages")
        XCTAssertTrue(designer.item("designerError-stages[1]").waitForExistence(timeout: 5))
        XCTAssertFalse(designer.item("designerSave").isEnabled)
        designer.section("Review loops")
        designer.item("designerAddLoop").click()
        designer.waitUntilValid()
        captureDesigner(app, named: "04-bounded-review-loop")
        designer.section("Preview")
        XCTAssertTrue(designer.item("graphNode-implement-implementer-1").exists)
        XCTAssertTrue(designer.item("graphNode-review-reviewer-1").exists)
        captureDesigner(app, named: "05-graph-preview")
        designer.save()
        XCTAssertTrue(designer.item("workflowChoice-Adversarial").exists)
        designer.customChoice.click()
        XCTAssertTrue(app.staticTexts["Implement and review"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func repairDesignerStagesAndHandoffs(_ designer: WorkflowDesignerUI) {
        let app = designer.app
        designer.section("Stages")
        captureDesigner(app, named: "02-ordered-stages")
        app.buttons.matching(identifier: "Move down").firstMatch.click()
        designer.section("Review loops")
        XCTAssertTrue(designer.item("designerError-review_loops[0]").waitForExistence(timeout: 5))
        XCTAssertFalse(designer.item("designerSave").isEnabled)
        designer.section("Stages")
        app.buttons.matching(identifier: "Move up").element(boundBy: 1).click()
        designer.waitUntilValid()
        designer.section("Handoffs")
        app.buttons.matching(identifier: "Remove handoff").firstMatch.click()
        designer.section("Stages")
        XCTAssertTrue(designer.item("designerError-stages[1]").waitForExistence(timeout: 5))
        XCTAssertFalse(designer.item("designerSave").isEnabled)
        designer.section("Handoffs")
        designer.item("designerAddHandoff").click()
        designer.waitUntilValid()
    }

    @MainActor
    private func captureDesigner(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.sheets.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

@MainActor
private struct WorkflowDesignerUI {
    let app: XCUIApplication

    func item(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }

    func first(_ prefix: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix)).firstMatch
    }

    var customChoice: XCUIElement { first("workflowChoice-custom-") }

    func replace(_ id: String, with text: String) { replace(item(id), with: text) }

    func replaceFirst(_ prefix: String, with text: String) { replace(first(prefix), with: text) }

    private func replace(_ field: XCUIElement, with text: String) {
        field.click()
        app.typeKey("a", modifierFlags: .command)
        app.typeKey(.delete, modifierFlags: [])
        if !text.isEmpty { app.typeText(text) }
    }

    func section(_ name: String) {
        app.radioButtons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch.click()
    }

    func waitUntilValid() {
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"), object: item("designerSave"))
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed, app.debugDescription)
    }

    func save() {
        waitUntilValid()
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(item("designerName").waitForNonExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(customChoice.waitForExistence(timeout: 5), app.debugDescription)
    }
}
