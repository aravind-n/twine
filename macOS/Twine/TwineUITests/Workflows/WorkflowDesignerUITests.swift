import XCTest

extension TwineUITests {
    @MainActor
    func testSavedWorkflowHoverDeleteRequiresConfirmation() throws {
        let (app, file) = try makeWorkflowDeletionApp()
        app.launch()
        defer { app.terminate() }
        let tile = app.buttons["workflowChoice-custom-4001-1"]
        XCTAssertTrue(tile.waitForExistence(timeout: 10), app.debugDescription)
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 1100, height: 850))
        let delete = app.buttons["workflowDelete-custom-4001-1"]
        let confirmation = app.sheets.firstMatch
        app.buttons["workflowChoice-Adversarial"].hover()
        XCTAssertFalse(delete.exists)
        XCTAssertFalse(app.buttons["workflowDelete-adversarial"].exists)
        app.buttons["workflowChoice-Adversarial"].rightClick()
        XCTAssertFalse(app.menuItems["Delete Workflow…"].exists)
        tile.hover()
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.click()
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.buttons["workflowEditType"].exists)
        confirmation.buttons["Cancel"].click()
        XCTAssertTrue(confirmation.waitForNonExistence(timeout: 5))
        XCTAssertTrue(tile.exists)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        tile.rightClick()
        XCTAssertTrue(app.menuItems["Delete Workflow…"].waitForExistence(timeout: 5))
        app.menuItems["Delete Workflow…"].click()
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.buttons["Cancel"].click()
        XCTAssertTrue(confirmation.waitForNonExistence(timeout: 5))
        tile.hover()
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.click()
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.buttons["Delete"].click()
        XCTAssertTrue(tile.waitForNonExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(app.buttons["workflowChoice-Adversarial"].exists)
    }

    @MainActor
    private func makeWorkflowDeletionApp() throws -> (XCUIApplication, URL) {
        let folder = try makeTestFolder(prefix: "TwineWorkflowDeletion")
        let app = try makeApp(lastOpenFolder: folder)
        let configRoot = try XCTUnwrap(app.launchEnvironment["XDG_CONFIG_HOME"])
        let workflows = URL(filePath: configRoot).appending(path: "twine/workflows")
        try FileManager.default.createDirectory(at: workflows, withIntermediateDirectories: true)
        let file = workflows.appending(path: "delete_me.toml")
        try """
        schema_version = 2
        id = 4001
        version = 1
        [definition]
        name = "Delete me"
        description = "Test workflow deletion."
        [[definition.roles]]
        id = "agent"
        name = "Agent"
        instructions = "Complete the task."
        [definition.graph]
        edges = []
        """.write(to: file, atomically: true, encoding: .utf8)
        return (app, file)
    }

    @MainActor
    func testWorkflowDesignerKeyboardEntryValidationAndBuiltinCopy() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "TwineDesignerUI-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let app = try makeApp(lastOpenFolder: folder)
        app.launch()
        defer { app.terminate() }
        func item(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
        XCTAssertTrue(item("workflowCreateOwn").waitForExistence(timeout: 10), app.debugDescription)
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 1000, height: 720))
        checkEmptyGraphEntry(in: app)

        item("workflowChoice-Adversarial").click()
        XCTAssertTrue(item("workflowEditType").waitForExistence(timeout: 5))
        app.typeKey("e", modifierFlags: [.command, .shift])
        XCTAssertTrue(item("designerName").waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(item("designerName").value as? String, "Adversarial copy")
        item("designerName").click()
        app.typeKey("a", modifierFlags: .command)
        app.typeText("Keyboard review")
        let ready = expectation(
            for: NSPredicate { _, _ in item("designerSave").isEnabled },
            evaluatedWith: nil)
        wait(for: [ready], timeout: 10)
        attachScreenshot(of: app, named: "Workflow designer with roles and instructions")
        app.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(item("designerName").waitForNonExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(item("workflowEditType").waitForExistence(timeout: 5))
        app.buttons["Back"].click()
        let custom = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'workflowChoice-custom-'"))
            .firstMatch
        XCTAssertTrue(custom.waitForExistence(timeout: 5), app.debugDescription)
        app.scrollViews["newTabChoices"].scroll(byDeltaX: 0, deltaY: -400)
        custom.click()
        XCTAssertTrue(item("workflowEditType").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Keyboard review"].exists, app.debugDescription)
        app.buttons["newWorkflow"].click()
        item("workflowChoice-Terminal").click()
        app.menuBars.menuBarItems["File"].click()
        XCTAssertFalse(app.menuItems["New workflow graph…"].isEnabled)
        app.typeKey(.escape, modifierFlags: [])
    }

    @MainActor
    private func checkEmptyGraphEntry(in app: XCUIApplication) {
        func item(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
        app.buttons["newWorkflow"].click()
        XCTAssertTrue(app.buttons["workflowTab-2"].waitForExistence(timeout: 5))
        app.buttons["workflowTab-1"].click()
        app.menuBars.menuBarItems["File"].click()
        XCTAssertTrue(app.menuItems["New workflow graph…"].isEnabled)
        app.menuItems["New workflow graph…"].click()
        XCTAssertTrue(item("designerName").waitForExistence(timeout: 5), app.debugDescription)
        // XCTest's Option-Command-N event stalls on this Mac. Check creation through the menu
        // in the selected tab, then exercise the Edit and Save shortcuts.
        XCTAssertFalse(item("designerSave").isEnabled)
        app.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(item("designerName").exists)
        app.typeText("My workflow")
        XCTAssertEqual(item("designerName").value as? String, "My workflow")
        app.buttons["Back"].click()
        XCTAssertTrue(item("designerName").waitForNonExistence(timeout: 5))
    }
}
