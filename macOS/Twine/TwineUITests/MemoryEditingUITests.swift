import AppKit
import SQLite3
import XCTest

extension TwineUITests {
    @MainActor
    func testSQLiteMemoryMarkdownRendersWithoutAnEditAction() throws {
        let fixture = try makeTestFolder(prefix: "TwineSQLiteMemoryUI")
        let folder = fixture.appending(path: "folder")
        let codex = fixture.appending(path: "codex")
        for directory in [folder, codex] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let file = codex.appending(path: "memories_1.sqlite")
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &database), SQLITE_OK)
        XCTAssertEqual(
            sqlite3_exec(
                database,
                """
                CREATE TABLE stage1_outputs(
                    thread_id TEXT, raw_memory TEXT, rollout_summary TEXT, generated_at INTEGER);
                INSERT INTO stage1_outputs VALUES('test','# Database memory\n\n**Locally extracted**',NULL,100);
                """, nil, nil, nil), SQLITE_OK)
        sqlite3_close(database)
        let original = try Data(contentsOf: file)
        let app = try makeApp(lastOpenFolder: folder)
        app.launchEnvironment["CODEX_HOME"] = codex.path
        app.launchEnvironment["CODEX_SQLITE_HOME"] = codex.path
        app.launchEnvironment["CLAUDE_CONFIG_DIR"] = fixture.appending(path: "claude").path
        app.launchEnvironment["TWINE_MEMORY_INSPECTION_KIND"] = "rawMemory"
        app.launchEnvironment["TWINE_MEMORY_INSPECTION_SCOPE"] = "global"
        app.launch()
        defer { app.terminate() }
        if !app.buttons["memoryEntry-outline"].waitForExistence(timeout: 10) { sidebarToggle(in: app).click() }
        app.buttons["memoryEntry-outline"].click()
        XCTAssertTrue(app.staticTexts["Database memory"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Locally extracted"].exists)
        XCTAssertFalse(app.buttons["editMemoryMarkdown"].exists)
        app.radioButtons["Markdown"].click()
        XCTAssertTrue(app.textViews["memoryText"].waitForExistence(timeout: 5))
        XCTAssertTrue((app.textViews["memoryText"].value as? String)?.contains("**Locally extracted**") == true)
        XCTAssertEqual(try Data(contentsOf: file), original)
        attachScreenshot(of: app, named: "SQLite extraction remains read-only")
    }

    @MainActor
    func testCodexMemoryMarkdownRenderingLinksEditingAndConflict() throws {
        try verifyMemoryEditing(claude: false)
    }

    @MainActor
    func testClaudeMemoryMarkdownRenderingLinksEditingAndConflict() throws {
        try verifyMemoryEditing(claude: true)
    }

    @MainActor
    private func verifyMemoryEditing(claude: Bool) throws {
        let fixture = try openMemoryEditingFixture(claude: claude)
        let app = fixture.app
        let topic = fixture.topic
        let original = fixture.original
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Readable memory"].waitForExistence(timeout: 10), app.debugDescription)
        app.radioButtons["Markdown"].click()
        XCTAssertTrue(app.textViews["memoryText"].waitForExistence(timeout: 5))
        XCTAssertTrue((app.textViews["memoryText"].value as? String)?.contains("**Useful advice**") == true)
        app.radioButtons["Preview"].click()
        XCTAssertTrue(app.links["Related note"].waitForExistence(timeout: 5))
        app.links["Related note"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertTrue(app.staticTexts["Linked memory"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["name: hidden metadata"].exists)
        attachScreenshot(of: app, named: claude ? "Claude rendered memory" : "Codex rendered memory")
        XCTAssertTrue(app.buttons["editMemoryMarkdown"].waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["editMemoryMarkdown"].click()
        let text = app.textViews["fileText"]
        XCTAssertTrue(text.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(text.value as? String, original)
        XCTAssertEqual(staticTextValue(app.staticTexts["fileSaveStatus"]), "Autosave")
        XCTAssertFalse(app.buttons["saveMemoryFile"].exists)
        replaceMemoryText("# Saved memory\n\nUseful edited advice.\n", in: text)
        waitForSave(in: app)
        XCTAssertEqual(try String(contentsOf: topic, encoding: .utf8), "# Saved memory\n\nUseful edited advice.\n")
        app.buttons["memoryEntry-outline"].click()
        XCTAssertTrue(app.staticTexts["Saved memory"].waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["editMemoryMarkdown"].click()
        try verifyMemoryConflict(in: app, text: text, file: topic)
    }

    @MainActor
    private func verifyMemoryConflict(in app: XCUIApplication, text: XCUIElement, file: URL) throws {
        try "# Harness update\n".write(to: file, atomically: true, encoding: .utf8)
        replaceMemoryText("# Pending edit\n", in: text)
        app.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["File Changed on Disk"].waitForExistence(timeout: 5))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "# Harness update\n")
        clickDialogButton("Reload", in: app)
        XCTAssertEqual(text.value as? String, "# Harness update\n")
        XCTAssertFalse(app.staticTexts["fileEdited"].exists)
    }

    @MainActor
    private func replaceMemoryText(_ replacement: String, in text: XCUIElement) {
        text.click()
        text.typeKey("a", modifierFlags: .command)
        text.typeText(replacement)
    }

    @MainActor
    private func openMemoryEditingFixture(claude: Bool) throws -> MemoryEditingFixture {
        let fixture = try makeTestFolder(prefix: "TwineMemoryEditing")
        let folder = fixture.appending(path: "folder")
        let codex = fixture.appending(path: "codex")
        let claudeHome = fixture.appending(path: "claude")
        let root = claude ? claudeHome.appending(path: "projects/twine-test/memory") : codex.appending(path: "memories")
        for directory in [folder, root] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try "# Readable memory\n\n**Useful advice**\n\n[Related note](topic.md)\n".write(
            to: root.appending(path: "MEMORY.md"), atomically: true, encoding: .utf8)
        let topic = root.appending(path: "topic.md")
        let original = "---\nname: hidden metadata\n---\n# Linked memory\n\n- Keep this useful.\n"
        try original.write(to: topic, atomically: true, encoding: .utf8)
        let app = try makeApp(lastOpenFolder: folder)
        app.launchEnvironment["CODEX_HOME"] = codex.path
        app.launchEnvironment["CODEX_SQLITE_HOME"] = codex.path
        app.launchEnvironment["CLAUDE_CONFIG_DIR"] = claudeHome.path
        app.launchEnvironment["CLAUDE_CODE_PROJECT_DIR_NAME"] = "twine-test"
        app.launch()
        if !app.buttons["memoryEntry-outline"].waitForExistence(timeout: 10) { sidebarToggle(in: app).click() }
        app.buttons["memoryEntry-outline"].click()
        if !claude { app.buttons["memoryScope-global"].click() }
        return MemoryEditingFixture(app: app, topic: topic, original: original)
    }
}

private struct MemoryEditingFixture {
    let app: XCUIApplication
    let topic: URL
    let original: String
}
