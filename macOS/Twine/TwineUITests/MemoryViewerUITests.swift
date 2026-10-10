import AppKit
import XCTest

extension TwineUITests {
    @MainActor
    func testMemoryOutlineClaudeScopesNarrowNavigationAndHiddenTerminal() throws {
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
        app.buttons["closeMemories"].click()
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
        app.popUpButtons["memoryScope"].click()
        app.menuItems["Global"].click()
        waitForMemory("Claude global instructions", in: contents)
        app.popUpButtons["memoryScope"].click()
        app.menuItems["This folder"].click()
        waitForMemory("Claude folder auto-memory index", in: contents)
        app.popUpButtons["memoryKind"].click()
        app.menuItems["Learned memory"].click()
        waitForMemory("Claude learned topic", in: contents)
        sidebarToggle(in: app).click()
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 520, height: 620))
        let sources = app.buttons["showMemorySources"]
        XCTAssertTrue(sources.waitForExistence(timeout: 5))
        XCTAssertTrue(sources.isHittable)
        sources.click()
        XCTAssertTrue(contents.waitForNonExistence(timeout: 5))
        app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND (label CONTAINS %@ OR value CONTAINS %@)",
                "memorySource-", "topic.md", "topic.md")
        ).firstMatch.click()
        waitForMemory("Claude learned topic", in: contents)
        app.typeKey("=", modifierFlags: .command)
        app.typeKey("=", modifierFlags: .command)
        XCTAssertTrue(sources.isHittable)
        XCTAssertTrue(app.buttons["refreshMemories"].isHittable)
        attachScreenshot(of: app, named: "Claude learned memory in a narrow window at 125 percent")
    }

    @MainActor
    private func waitForMemory(_ marker: String, in contents: XCUIElement) {
        XCTAssertTrue(contents.waitForExistence(timeout: 10))
        let loaded = expectation(
            for: NSPredicate { _, _ in (contents.value as? String)?.contains(marker) == true }, evaluatedWith: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 5), .completed)
    }

    @MainActor
    func testMemoryOutlineReadRefreshAndLeaveSourcesUnchanged() throws {
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
        XCTAssertTrue(app.staticTexts["Local memory"].waitForExistence(timeout: 10))
        app.radioButtons["Markdown"].click()
        let contents = app.textViews["memoryText"]
        XCTAssertTrue(contents.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue((contents.value as? String)?.contains("Original memory marker") == true)
        contents.click()
        app.typeText("should not edit")
        app.typeKey("s", modifierFlags: .command)
        XCTAssertEqual(try String(contentsOf: memory, encoding: .utf8), "# Local memory\nOriginal memory marker\n")
        app.buttons["memoryEntry-outline"].click()
        XCTAssertTrue(app.staticTexts["Global"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["CODEX"].exists)
        XCTAssertTrue(app.staticTexts["MEMORY.md"].firstMatch.exists)
        XCTAssertTrue((contents.value as? String)?.contains("Original memory marker") == true)
        let outline = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        outline.name = "Codex memory source outline"
        outline.lifetime = .keepAlways
        add(outline)
        try "# Local memory\nUpdated memory marker\n".write(to: memory, atomically: true, encoding: .utf8)
        app.buttons["refreshMemories"].click()
        let refreshed = expectation(
            for: NSPredicate { _, _ in
                (contents.value as? String)?.contains("Updated memory marker") == true
            }, evaluatedWith: nil)
        wait(for: [refreshed], timeout: 5)
        app.buttons["memoryEntry-outline"].click()
        let refreshedOutline = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        refreshedOutline.name = "Refreshed memory source outline"
        refreshedOutline.lifetime = .keepAlways
        add(refreshedOutline)
        app.buttons["closeMemories"].click()
        XCTAssertTrue(app.buttons["workflowTab-1"].waitForExistence(timeout: 5))
        app.terminate()
    }
}
