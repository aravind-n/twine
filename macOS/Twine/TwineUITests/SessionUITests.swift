import XCTest

extension TwineUITests {
    @MainActor
    func testSessionsOwnTabsAndRestoreFreshShellsAfterRelaunch() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "TwineSessionUITests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let app = try makeApp(lastOpenFolder: folder)
        app.launch()
        XCTAssertTrue(app.buttons["workflowTab-1"].waitForExistence(timeout: 10), app.debugDescription)
        app.typeText("exec /bin/sh\r")
        app.typeText("TWINE_SESSION_VALUE=original; echo $$ > original.pid\r")
        app.buttons["sidebarToggle"].click()
        XCTAssertTrue(app.scrollViews["fileTree"].waitForExistence(timeout: 5))
        let firstSession = app.buttons["sessionRow-1"]
        XCTAssertTrue(firstSession.exists)
        sessionAction("Rename Session", app: app)
        saveSessionName("First", app: app)
        let renamed = expectation(for: NSPredicate { _, _ in firstSession.label == "First" }, evaluatedWith: nil)
        wait(for: [renamed], timeout: 5)

        app.buttons["newWorkflow"].click()
        XCTAssertTrue(app.buttons["workflowTab-2"].waitForExistence(timeout: 5))
        sessionAction("New Session", app: app)
        saveSessionName("Second", app: app)
        let secondSession = app.buttons["sessionRow-2"]
        XCTAssertTrue(secondSession.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["No Open Tabs"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["workflowTab-1"].exists)
        app.buttons["newWorkflow"].click()
        let secondTab = app.buttons["workflowTab-3"]
        XCTAssertTrue(secondTab.waitForExistence(timeout: 5))
        app.buttons["workflowChoice-Terminal"].click()
        app.typeText("exec /bin/sh\r")
        app.typeText("TWINE_SESSION_VALUE=second; printf '%s' second > second.txt\r")
        waitForSessionFile(folder.appending(path: "second.txt"), containing: "second")
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = "Files and Sessions sidebar"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        firstSession.click()
        XCTAssertTrue(app.buttons["workflowTab-2"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["workflowTab-2"].value as? String, "Selected")
        XCTAssertFalse(secondTab.exists)
        app.buttons["workflowTab-1"].click()
        app.typeText("printf '%s' $TWINE_SESSION_VALUE > preserved.txt\r")
        waitForSessionFile(folder.appending(path: "preserved.txt"), containing: "original")
        secondSession.click()
        XCTAssertTrue(secondTab.waitForExistence(timeout: 5))
        relaunchSession(app: app, folder: folder)
        app.buttons["sidebarToggle"].click()
        XCTAssertTrue(secondSession.waitForExistence(timeout: 5))
        XCTAssertEqual(secondSession.value as? String, "Selected")
        deleteSessions(app: app)
        app.terminate()
    }

    @MainActor
    private func relaunchSession(app: XCUIApplication, folder: URL) {
        app.menuBars.menuBarItems["Twine"].click()
        app.menuItems["Quit Twine"].click()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))

        app.launch()
        XCTAssertTrue(app.buttons["workflowTab-3"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.buttons["workflowTab-1"].exists)
        XCTAssertTrue(app.staticTexts["restoredWorkflowNotice"].waitForExistence(timeout: 5))
        app.typeText("exec /bin/sh\r")
        app.typeText("printf '%s' ${TWINE_SESSION_VALUE-fresh} > fresh.txt\r")
        waitForSessionFile(folder.appending(path: "fresh.txt"), containing: "fresh")
    }

    @MainActor
    private func deleteSessions(app: XCUIApplication) {
        sessionAction("Delete Session", app: app)
        confirmDeleteSession(app: app)
        XCTAssertTrue(app.buttons["sessionRow-2"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["workflowTab-1"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["workflowTab-2"].exists)
        sessionAction("Delete Session", app: app)
        confirmDeleteSession(app: app)
        XCTAssertTrue(app.buttons["sessionRow-1"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["No Open Tabs"].waitForExistence(timeout: 5))
        app.menuBars.menuBarItems["Twine"].click()
        app.menuItems["Quit Twine"].click()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
        app.launch()
        XCTAssertTrue(app.buttons["newWorkflow"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["workflowTab-4"].exists)
        XCTAssertTrue(app.staticTexts["No Open Tabs"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func confirmDeleteSession(app: XCUIApplication) {
        let delete = app.sheets.buttons["Delete"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.click()
    }

    @MainActor
    private func sessionAction(_ title: String, app: XCUIApplication) {
        app.descendants(matching: .any).matching(identifier: "sessionsActions").firstMatch.click()
        app.menuItems[title].click()
    }

    @MainActor
    private func saveSessionName(_ name: String, app: XCUIApplication) {
        let field = app.textFields["sessionName"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), app.debugDescription)
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(name)
        app.buttons["saveSession"].click()
    }

    @MainActor
    private func waitForSessionFile(_ file: URL, containing text: String) {
        let written = expectation(
            for: NSPredicate { _, _ in
                (try? String(contentsOf: file, encoding: .utf8)) == text
            }, evaluatedWith: nil)
        wait(for: [written], timeout: 10)
    }
}
