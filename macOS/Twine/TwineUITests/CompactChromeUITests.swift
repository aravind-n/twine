import AppKit
import XCTest

extension TwineUITests {
    @MainActor
    func testCompactFolderChromeKeepsExpandedTracesAndNativeTabs() throws {
        for appearance in ["Light", "Dark"] {
            let folder = try makeTestFolder(prefix: "TwineCompactChrome")
            let app = try makeApp(lastOpenFolder: folder)
            app.launchEnvironment["TWINE_TEST_APPEARANCE"] = appearance
            app.launchEnvironment["SHELL"] = "/bin/sh"
            app.launch()
            XCTAssertTrue(app.buttons["workflowTab-1"].waitForExistence(timeout: 10), app.debugDescription)
            app.buttons["workflowChoice-Terminal"].click()
            resizeWindow(app.windows.firstMatch, to: CGSize(width: 1100, height: 850))
            let viewport = app.scrollViews["workspaceViewport"]
            let header = app.buttons["tracesHeader"]
            let footer = chromeElement("statusFooter", in: app)
            let panel = chromeElement("tracesPanel", in: app)
            let tab = app.buttons["workflowTab-1"]
            XCTAssertLessThanOrEqual(tab.frame.maxY, viewport.frame.minY + 1, app.debugDescription)
            XCTAssertTrue(app.toolbars.buttons["newWorkflow"].isHittable, app.debugDescription)
            XCTAssertFalse(app.staticTexts["WORKFLOWS"].exists)
            XCTAssertEqual(header.frame.height, 32, accuracy: 1)
            XCTAssertEqual(panel.frame.height, 32, accuracy: 1)
            // AX reports the text bounds; its center verifies the allocated 20-point footer.
            XCTAssertEqual(footer.frame.midY - panel.frame.maxY, 14, accuracy: 1)
            XCTAssertEqual(viewport.frame.maxY - footer.frame.midY, 16, accuracy: 1)
            assertFolderPathCopy(folder, in: app)

            app.menuBars.menuBarItems["View"].click()
            app.menuItems["Show Traces"].click()
            XCTAssertTrue(app.radioGroups["traceViewMode"].waitForExistence(timeout: 5))
            XCTAssertEqual(header.frame.height, 48, accuracy: 1)
            XCTAssertEqual(panel.frame.height, 272, accuracy: 1)
            assertExpandedTraceDetail(in: app)
            attachWindow(in: app, name: "Compact chrome, full Overview, \(appearance)")
            selectTraceViewMode("In Depth", in: app)
            XCTAssertEqual(header.frame.height, 48, accuracy: 1)
            XCTAssertEqual(panel.frame.height, 432, accuracy: 1)
            attachWindow(in: app, name: "Compact chrome, full In Depth, \(appearance)")
            header.click()
            XCTAssertTrue(app.radioGroups["traceViewMode"].waitForNonExistence(timeout: 5))
            XCTAssertEqual(header.frame.height, 32, accuracy: 1)

            openTestWorkflow(agents: 3, in: app)
            XCTAssertTrue(app.buttons["agentSubtab-1"].waitForExistence(timeout: 10))
            XCTAssertEqual(chromeElement("agentSubtabStrip", in: app).frame.height, 30, accuracy: 1)
            app.radioGroups["agentLayout"].radioButtons["Bento"].click()
            XCTAssertTrue(app.buttons["agentSubtab-1"].waitForNonExistence(timeout: 5))
            XCTAssertFalse(app.staticTexts["TERMINAL"].exists)
            attachWindow(in: app, name: "Compact chrome, Bento and closed capsule, \(appearance)")
            app.terminate()
        }
    }

    @MainActor
    private func assertExpandedTraceDetail(in app: XCUIApplication) {
        let step = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'traceSpan-' ")).firstMatch
        XCTAssertTrue(step.waitForExistence(timeout: 10))
        step.click()
        XCTAssertTrue(app.buttons["copyTraceLog"].waitForExistence(timeout: 5))
        XCTAssertEqual(
            app.buttons["copyTraceLog"].frame.midY - chromeElement("traceDetailPanel", in: app).frame.minY,
            24, accuracy: 1, "The opened detail header keeps its original 48 points")
    }

    @MainActor
    private func assertFolderPathCopy(_ folder: URL, in app: XCUIApplication) {
        let path = app.buttons["folderLocation"]
        XCTAssertEqual(path.value as? String, folder.path)
        path.click()
        let copy = app.buttons["copyFolderPath"]
        XCTAssertTrue(copy.waitForExistence(timeout: 5), app.debugDescription)
        copy.click()
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), folder.path)
        app.typeKey(.escape, modifierFlags: [])
    }

    @MainActor
    func testTitlebarOverflowSelectsWorkflowsAndFilesAtNarrowWidths() throws {
        let folder = try makeTestFolder(prefix: "TwineOverflow")
        let file = folder.appending(path: "A long file name to exercise titlebar overflow.txt")
        try "Saved content".write(to: file, atomically: true, encoding: .utf8)
        let app = try makeApp(lastOpenFolder: folder)
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["workflowTab-1"].waitForExistence(timeout: 10))
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 900, height: 620))
        for _ in 0..<5 { app.typeKey("t", modifierFlags: .command) }
        let overflow = chromeElement("workspaceTabOverflow", in: app)
        XCTAssertTrue(overflow.waitForExistence(timeout: 10), app.debugDescription)
        overflow.click()
        let first = app.menuItems["overflowWorkflow-1"]
        XCTAssertTrue(first.waitForExistence(timeout: 5), app.debugDescription)
        first.click()
        XCTAssertEqual(app.buttons["workflowTab-1"].value as? String, "Selected")
        fileRow(file, in: app).click()
        XCTAssertTrue(chromeElement("fileTab-\(file.path)", in: app).waitForExistence(timeout: 5), app.debugDescription)
        overflow.click()
        XCTAssertTrue(chromeElement("overflowFile-\(file.path)", in: app).exists)
        app.menuItems["overflowWorkflow-1"].click()
        overflow.click()
        chromeElement("overflowFile-\(file.path)", in: app).click()
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(chromeElement("fileTab-\(file.path)", in: app).waitForNonExistence(timeout: 5))
        sidebarToggle(in: app).click()
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 400, height: 500))
        XCTAssertTrue(overflow.isHittable, app.debugDescription)
        XCTAssertTrue(app.buttons["newWorkflow"].isHittable, app.debugDescription)
        XCTAssertLessThanOrEqual(overflow.frame.maxY, app.scrollViews["workspaceViewport"].frame.minY + 1)
        attachWindow(in: app, name: "Narrow titlebar retains one row and open-tabs menu")
    }

    @MainActor
    func verifyCompactRunToolbar(in app: XCUIApplication) {
        sidebarToggle(in: app).click()
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 400, height: 620))
        for percent in [100, 200] {
            if percent == 200 { for _ in 0..<5 { app.typeKey("=", modifierFlags: .command) } }
            XCTAssertTrue(app.buttons["workflowCancel"].isHittable, app.debugDescription)
            XCTAssertTrue(app.buttons["newWorkflow"].isHittable, app.debugDescription)
            XCTAssertTrue(app.menuButtons["workspaceTabOverflow"].isHittable, app.debugDescription)
            XCTAssertLessThanOrEqual(
                app.buttons["workflowCancel"].frame.maxY, app.scrollViews["workspaceViewport"].frame.minY + 1)
            attachWindow(in: app, name: "Active workflow at 400 points and \(percent) percent")
        }
        app.typeKey("0", modifierFlags: .command)
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 1000, height: 720))
        sidebarToggle(in: app).click()
    }

    @MainActor
    private func chromeElement(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@", id)).firstMatch
    }
}
