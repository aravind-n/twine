import XCTest

extension TwineUITests {
    @MainActor
    func testReviewGraphCanBeCreatedFromBlankSavedAndReopened() throws {
        let app = try launchGraphDesigner()
        defer { app.terminate() }
        let editor = WorkflowGraphExampleUI(app: app, testCase: self)
        editor.item("workflowCreateOwn").click()
        editor.replace("designerName", with: "UI Adversarial")
        let canvas = editor.item("designerContent")
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.22, dy: 0.35)).doubleClick()
        editor.replace("graphAgentName", with: "Implementer")
        app.buttons["Done"].click()
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.6)).rightClick()
        app.menuItems["Add agent"].click()
        editor.replace("graphAgentName", with: "Reviewer")
        app.buttons["Done"].click()
        // Drag from the receiving port to the sending port. Direction remains Implementer to Reviewer.
        editor.drag(app.buttons["Connect to Reviewer"], to: app.buttons["Connect from Implementer"])
        XCTAssertTrue(app.buttons["Implementer to Reviewer: Work complete"].waitForExistence(timeout: 5))
        editor.drag(app.buttons["Connect from Reviewer"], to: app.buttons["Connect from Implementer"])
        XCTAssertFalse(app.buttons["Reviewer to Implementer: Work complete"].exists)
        editor.drag(app.buttons["Connect to Implementer"], to: app.buttons["Connect to Reviewer"])
        XCTAssertFalse(app.buttons["Reviewer to Implementer: Work complete"].exists)
        editor.drag(app.buttons["Connect from Reviewer"], to: app.buttons["Connect to Implementer"])
        let link = app.buttons["Reviewer to Implementer: Work complete"]
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        link.click()
        let popover = app.popovers.firstMatch
        XCTAssertTrue(popover.waitForExistence(timeout: 5))
        XCTAssertLessThan(abs(popover.frame.midX - link.frame.midX), 350)
        editor.item("graphLinkEvent").click()
        app.menuItems["Changes requested"].click()
        app.buttons["Done"].click()
        editor.saveAndReopen()
        XCTAssertTrue(app.buttons["Implementer to Reviewer: Work complete"].exists)
        XCTAssertTrue(app.buttons["Reviewer to Implementer: Changes requested"].exists)
        XCTAssertFalse(editor.item("graphNode-task").exists)
        XCTAssertFalse(editor.item("graphNode-finish").exists)
    }

    @MainActor
    func testAdversarialGraphCanBeEditedSavedAndReopened() throws {
        let app = try launchGraphDesigner()
        defer { app.terminate() }
        let editor = WorkflowGraphExampleUI(app: app, testCase: self)
        editor.item("workflowChoice-Adversarial").click()
        editor.item("workflowEditType").click()
        XCTAssertTrue(editor.item("graphNode-implementer").waitForExistence(timeout: 5))
        editor.item("graphNode-implementer").click()
        editor.replace("graphAgentInstructions", with: "Complete the task and address review feedback.")
        XCTAssertFalse(editor.item("graphReceive").exists)
        app.buttons["Done"].click()
        editor.saveAndReopen()
        editor.item("graphNode-implementer").click()
        XCTAssertEqual(
            editor.item("graphAgentInstructions").value as? String,
            "Complete the task and address review feedback.")
    }

    @MainActor
    func testCoordinatorGraphCanBeEditedSavedAndReopened() throws {
        let app = try launchGraphDesigner()
        defer { app.terminate() }
        let editor = WorkflowGraphExampleUI(app: app, testCase: self)
        editor.item("workflowChoice-Coordinator").click()
        editor.item("workflowEditType").click()
        for id in ["planner", "worker-1", "worker-2", "coordinator"] {
            XCTAssertTrue(editor.item("graphNode-\(id)").waitForExistence(timeout: 5))
        }
        editor.item("graphNode-coordinator").click()
        XCTAssertTrue(editor.item("graphReceive").waitForExistence(timeout: 5))
        editor.chooseOption("Start as work arrives")
        editor.chooseOption("Wait for every incoming link")
        app.buttons["Done"].click()
        editor.item("graphNode-worker-1").click()
        XCTAssertFalse(editor.item("graphReceive").exists)
        XCTAssertFalse(editor.item("graphCopies").exists)
        editor.replace("graphAgentName", with: "Builder")
        app.buttons["Done"].click()
        editor.item("graphNode-worker-1").rightClick()
        app.menuItems["Duplicate agent"].click()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Builder copy'")).firstMatch.exists)
        editor.saveAndReopen()
        editor.item("graphNode-worker-1").click()
        XCTAssertEqual(editor.item("graphAgentName").value as? String, "Builder")
    }

    @MainActor
    func testGraphNodeDragAndDeleteKeepSettingsAndTextEditingSeparate() throws {
        let app = try launchGraphDesigner()
        defer { app.terminate() }
        let editor = WorkflowGraphExampleUI(app: app, testCase: self)
        editor.item("workflowChoice-Adversarial").click()
        editor.item("workflowEditType").click()
        let node = editor.item("graphNode-implementer")
        XCTAssertTrue(node.waitForExistence(timeout: 5))
        let original = node.frame
        let start = node.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.click(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 60, dy: 45)))
        XCTAssertFalse(app.popovers.firstMatch.exists)
        XCTAssertGreaterThan(abs(node.frame.midX - original.midX), 30)
        node.click()
        XCTAssertTrue(editor.item("graphAgentName").waitForExistence(timeout: 5))
        app.typeKey(.delete, modifierFlags: [])
        XCTAssertTrue(node.waitForNonExistence(timeout: 5), app.debugDescription)
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(node.waitForExistence(timeout: 5))
        node.click()
        editor.replace("graphAgentName", with: "AB")
        app.typeKey(.delete, modifierFlags: [])
        XCTAssertEqual(editor.item("graphAgentName").value as? String, "A")
        XCTAssertTrue(node.exists)
        app.buttons["Done"].click()
    }

    @MainActor
    private func launchGraphDesigner() throws -> XCUIApplication {
        let folder = try makeTestFolder(prefix: "TwineGraphEditor")
        let app = try makeApp(lastOpenFolder: folder)
        app.launch()
        XCTAssertTrue(app.buttons["workflowCreateOwn"].waitForExistence(timeout: 10), app.debugDescription)
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 1200, height: 850))
        return app
    }
}

@MainActor
private struct WorkflowGraphExampleUI {
    let app: XCUIApplication
    let testCase: XCTestCase

    func item(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    func replace(_ id: String, with text: String) {
        let field = item(id)
        XCTAssertTrue(field.waitForExistence(timeout: 5), app.debugDescription)
        field.click()
        app.typeKey("a", modifierFlags: .command)
        app.typeText(text)
    }
    func drag(_ source: XCUIElement, to destination: XCUIElement) {
        source.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .click(
                forDuration: 0.1, thenDragTo: destination.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
    }
    func chooseOption(_ title: String) {
        let option = app.radioButtons.matching(NSPredicate(format: "label ENDSWITH %@", title)).firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 5), app.debugDescription)
        option.click()
    }
    func saveAndReopen() {
        let save = item("designerSave")
        let ready = testCase.expectation(for: NSPredicate { _, _ in save.exists && save.isEnabled }, evaluatedWith: nil)
        testCase.wait(for: [ready], timeout: 10)
        save.click()
        XCTAssertTrue(item("workflowEditType").waitForExistence(timeout: 10), app.debugDescription)
        item("workflowEditType").click()
        XCTAssertTrue(item("designerName").waitForExistence(timeout: 5))
    }
}
