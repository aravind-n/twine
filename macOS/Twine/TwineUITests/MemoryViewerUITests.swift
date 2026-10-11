import AppKit
import XCTest

extension TwineUITests {
    @MainActor
    func testMemoryDockClaudeScopesNarrowNavigationAndHiddenTerminal() throws {
        let fixture = try makeTestFolder(prefix: "TwineClaudeMemoryUI")
        let folder = fixture.appending(path: "folder")
        let codex = fixture.appending(path: "codex")
        let claude = fixture.appending(path: "claude")
        let autoMemory = claude.appending(path: "projects/twine-test/memory")
        for directory in [folder, codex.appending(path: "memories"), autoMemory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let files = [
            codex.appending(path: "memories/MEMORY.md"): "# Codex global memory\n",
            claude.appending(path: "CLAUDE.md"): "# Claude global instructions\n",
            folder.appending(path: "CLAUDE.local.md"): "# Claude folder instructions\n",
            autoMemory.appending(path: "MEMORY.md"): "# Claude folder auto-memory index\n",
            autoMemory.appending(path: "topic.md"): "# Claude learned topic\n",
        ]
        for (file, contents) in files { try contents.write(to: file, atomically: true, encoding: .utf8) }
        let app = try makeApp(lastOpenFolder: folder)
        app.launchEnvironment["CODEX_HOME"] = codex.path
        app.launchEnvironment["CODEX_SQLITE_HOME"] = codex.path
        app.launchEnvironment["CLAUDE_CONFIG_DIR"] = claude.path
        app.launchEnvironment["CLAUDE_CODE_PROJECT_DIR_NAME"] = "twine-test"
        app.launchEnvironment["SHELL"] = "/bin/bash"
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["workflowChoice-Terminal"].waitForExistence(timeout: 10))
        app.buttons["workflowChoice-Terminal"].click()
        app.typeText("printf ready > workflow-ready\r")
        waitForFile(folder.appending(path: "workflow-ready"), containing: "ready", in: app)
        if !app.buttons["memoryEntry-outline"].exists { sidebarToggle(in: app).click() }
        app.buttons["memoryEntry-outline"].click()
        let contents = app.textViews["memoryText"]
        XCTAssertTrue(app.staticTexts["Claude folder auto-memory index"].waitForExistence(timeout: 10))
        app.typeText("touch memory-leaked-command\r")
        app.buttons["sidebarSection-sessions"].click()
        app.typeText("printf returned > workflow-returned\r")
        waitForFile(folder.appending(path: "workflow-returned"), containing: "returned", in: app)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appending(path: "memory-leaked-command").path))
        app.buttons["memoryEntry-outline"].click()
        app.radioButtons["Markdown"].click()
        verifyClaudeMemoryFiltersAndNarrowNavigation(in: app, contents: contents)
        for (file, original) in files { XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), original) }
    }

    @MainActor
    private func verifyClaudeMemoryFiltersAndNarrowNavigation(in app: XCUIApplication, contents: XCUIElement) {
        app.popUpButtons["memoryHarness"].click()
        app.menuItems["Claude Code"].click()
        app.buttons["memoryScope-global"].click()
        app.popUpButtons["memoryHarness"].click()
        app.menuItems["Claude Code"].click()
        waitForMemory("Claude global instructions", in: contents)
        app.buttons["memoryScope-folder"].click()
        XCTAssertTrue(app.popUpButtons["memoryHarness"].value as? String == "Claude Code")
        waitForMemory("Claude folder auto-memory index", in: contents)
        app.popUpButtons["memoryKind"].click()
        app.menuItems["Learned memory"].click()
        waitForMemory("Claude learned topic", in: contents)
        app.buttons["memoryScope-otherFolder"].click()
        XCTAssertTrue(app.popUpButtons["memoryWorkspace"].exists)
        XCTAssertTrue(app.staticTexts["No matching sources"].exists)
        app.buttons["memoryScope-folder"].click()
        waitForMemory("Claude learned topic", in: contents)
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 900, height: 620))
        app.typeKey("=", modifierFlags: .command)
        app.typeKey("=", modifierFlags: .command)
        for scope in ["folder", "global", "otherFolder"] {
            XCTAssertTrue(app.buttons["memoryScope-\(scope)"].isHittable)
        }
        XCTAssertTrue(app.buttons["refreshMemories"].isHittable)
        XCTAssertTrue(app.buttons["memorySourceInfo"].isHittable)
        attachScreenshot(of: app, named: "Claude memory dock at 125 percent")
        sidebarToggle(in: app).click()
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 520, height: 620))
        XCTAssertTrue(app.buttons["memorySourceInfo"].isHittable)
        XCTAssertTrue(app.radioButtons["Preview"].isHittable)
        attachScreenshot(of: app, named: "Compact memory reader in a narrow window")
    }

    @MainActor
    private func waitForMemory(_ marker: String, in contents: XCUIElement) {
        XCTAssertTrue(contents.waitForExistence(timeout: 10))
        let loaded = expectation(
            for: NSPredicate { _, _ in (contents.value as? String)?.contains(marker) == true }, evaluatedWith: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 5), .completed)
    }

    @MainActor
    func testMemoryDockReadRefreshAndLeaveSourcesUnchanged() throws {
        let fixture = FileManager.default.temporaryDirectory.appending(path: "TwineMemoryUI-\(UUID())")
        let folder = fixture.appending(path: "folder")
        let codex = fixture.appending(path: "codex")
        let memory = codex.appending(path: "memories/MEMORY.md")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: memory.deletingLastPathComponent(), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture) }
        try "# Local memory\nOriginal memory marker\n".write(to: memory, atomically: true, encoding: .utf8)
        let app = try makeApp(lastOpenFolder: folder)
        app.launchEnvironment["CODEX_HOME"] = codex.path
        app.launchEnvironment["CODEX_SQLITE_HOME"] = codex.path
        app.launchEnvironment["CLAUDE_CONFIG_DIR"] = fixture.appending(path: "claude").path
        app.launch()
        if !app.buttons["memoryEntry-outline"].waitForExistence(timeout: 10) { sidebarToggle(in: app).click() }
        app.buttons["memoryEntry-outline"].click()
        app.buttons["memoryScope-global"].click()
        XCTAssertTrue(app.staticTexts["Local memory"].waitForExistence(timeout: 10))
        let contents = app.textViews["memoryText"]
        try verifyReadOnlyMemory(in: app, file: memory)
        app.buttons["memoryEntry-outline"].click()
        XCTAssertFalse(app.buttons["memoryScope-global"].exists)
        XCTAssertEqual(app.buttons["memoryEntry-outline"].value as? String, "Collapsed")
        XCTAssertGreaterThan(app.buttons["memoryEntry-outline"].frame.minY, app.windows.firstMatch.frame.maxY - 65)
        XCTAssertTrue((contents.value as? String)?.contains("Original memory marker") == true)
        let outline = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        outline.name = "Collapsed memories keep the Codex reader open"
        outline.lifetime = .keepAlways
        add(outline)
        try "# Local memory\nUpdated memory marker\n".write(to: memory, atomically: true, encoding: .utf8)
        app.buttons["memoryEntry-outline"].click()
        XCTAssertLessThan(app.buttons["memoryEntry-outline"].frame.minY, app.windows.firstMatch.frame.minY + 200)
        app.buttons["refreshMemories"].click()
        let refreshed = expectation(
            for: NSPredicate { _, _ in
                (contents.value as? String)?.contains("Updated memory marker") == true
            }, evaluatedWith: nil)
        wait(for: [refreshed], timeout: 5)
        app.buttons["memoryEntry-outline"].click()
        let refreshedOutline = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        refreshedOutline.name = "Refreshed memory dock"
        refreshedOutline.lifetime = .keepAlways
        add(refreshedOutline)
        app.buttons["sidebarSection-sessions"].click()
        XCTAssertTrue(app.buttons["workflowTab-1"].waitForExistence(timeout: 5))
        app.terminate()
    }

    @MainActor
    private func verifyReadOnlyMemory(in app: XCUIApplication, file: URL) throws {
        let toolbar = app.descendants(matching: .any).matching(identifier: "memoryReaderToolbar").firstMatch
        XCTAssertGreaterThan(toolbar.frame.height, 0)
        XCTAssertLessThanOrEqual(toolbar.frame.height, 46)
        XCTAssertTrue(app.buttons["memorySourceInfo"].exists)
        app.radioButtons["Markdown"].click()
        let contents = app.textViews["memoryText"]
        XCTAssertTrue(contents.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue((contents.value as? String)?.contains("Original memory marker") == true)
        contents.click()
        app.typeText("should not edit")
        app.typeKey("s", modifierFlags: .command)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "# Local memory\nOriginal memory marker\n")
    }
}
