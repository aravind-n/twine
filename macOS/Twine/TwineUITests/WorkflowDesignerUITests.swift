import XCTest

extension TwineUITests {
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
        app.buttons["newWorkflow"].click()
        XCTAssertTrue(app.buttons["workflowTab-2"].waitForExistence(timeout: 5))
        app.buttons["workflowTab-1"].click()
        // Both drafts stay mounted; only the selected one owns the designer command.
        // The shell owns focus here. The shortcut must open the designer without typing into it.
        app.typeKey("n", modifierFlags: [.command, .option])
        XCTAssertTrue(item("designerName").waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(item("designerError-name").waitForExistence(timeout: 5))
        XCTAssertFalse(item("designerSave").isEnabled)
        app.typeText("My workflow")
        XCTAssertEqual(item("designerName").value as? String, "My workflow")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(item("designerName").waitForNonExistence(timeout: 5))

        item("workflowChoice-Adversarial").click()
        XCTAssertTrue(item("workflowEditType").waitForExistence(timeout: 5))
        app.typeKey("e", modifierFlags: [.command, .shift])
        XCTAssertTrue(item("designerName").waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(item("designerName").value as? String, "Adversarial copy")
        app.typeKey("a", modifierFlags: .command)
        app.typeText("Keyboard review")
        let ready = expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: item("designerSave"))
        wait(for: [ready], timeout: 10)
        attachScreenshot(of: app, named: "Workflow designer with roles and instructions")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(item("designerName").waitForNonExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(item("workflowChoice-Adversarial").waitForExistence(timeout: 5))
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
        XCTAssertFalse(app.menuItems["Create Workflow Type…"].isEnabled)
        app.typeKey(.escape, modifierFlags: [])
    }
}
