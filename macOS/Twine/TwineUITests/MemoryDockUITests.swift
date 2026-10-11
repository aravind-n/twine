import AppKit
import XCTest

extension TwineUITests {
    @MainActor
    func testMemoryDockArrowNavigationKeepsFocusAfterRendering() throws {
        let app = try openMemoryDockFixture()
        defer { app.terminate() }
        app.buttons["memoryEntry-outline"].click()
        app.buttons["memoryScope-folder"].click()
        app.typeKey(.rightArrow, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["Global Codex memory"].waitForExistence(timeout: 5))
        app.typeKey(.rightArrow, modifierFlags: [])
        XCTAssertTrue(app.popUpButtons["memoryWorkspace"].waitForExistence(timeout: 5))
        app.popUpButtons["memoryWorkspace"].click()
        app.menuItems["project-b"].click()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "topic-00.md")).firstMatch.click()
        XCTAssertTrue(app.staticTexts["Project B topic 0"].waitForExistence(timeout: 5))
        app.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["Project B topic 1"].waitForExistence(timeout: 5))
        app.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["Project B topic 2"].waitForExistence(timeout: 5))
        app.typeText(" ")
        app.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["Project B topic 3"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testMemoryDockOtherWorkspacesRememberNavigationAcrossRelaunch() throws {
        let app = try openMemoryDockFixture()
        defer { app.terminate() }
        app.buttons["memoryEntry-outline"].click()
        app.buttons["memoryScope-otherFolder"].click()
        app.popUpButtons["memoryWorkspace"].click()
        app.menuItems["project-b"].click()
        app.popUpButtons["memoryHarness"].click()
        app.menuItems["Claude Code"].click()
        let topic = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "topic-20.md")).firstMatch
        let list = app.descendants(matching: .any).matching(identifier: "memorySources").firstMatch
        for _ in 0..<12 {
            if topic.exists && topic.isHittable { break }
            list.scroll(byDeltaX: 0, deltaY: -160)
        }
        XCTAssertTrue(topic.isHittable)
        topic.click()
        XCTAssertTrue(app.staticTexts["Project B topic 20"].waitForExistence(timeout: 5))
        for _ in 0..<2 {
            app.buttons["memoryScope-global"].click()
            XCTAssertTrue(app.staticTexts["Global Codex memory"].waitForExistence(timeout: 5))
            app.buttons["memoryScope-otherFolder"].click()
            XCTAssertTrue(app.staticTexts["Project B topic 20"].waitForExistence(timeout: 5))
            XCTAssertTrue(topic.isHittable, "Returning to a location must restore its source-list position")
        }
        let search = app.textFields["memorySearch"]
        search.click()
        search.typeText("topic-2")
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["Project B topic 20"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.popUpButtons["memoryWorkspace"].value as? String, "project-b")
        XCTAssertEqual(app.popUpButtons["memoryHarness"].value as? String, "Claude Code")
        XCTAssertEqual(search.value as? String, "topic-2")
        app.buttons["memorySourceInfo"].click()
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "project-b/memory/topic-20.md"))
                .firstMatch.waitForExistence(timeout: 3))
        attachScreenshot(of: app, named: "Other workspace source and restored navigation")
    }

    @MainActor
    private func openMemoryDockFixture() throws -> XCUIApplication {
        let fixture = try makeTestFolder(prefix: "TwineMemoryDockUI")
        let folder = fixture.appending(path: "folder")
        let codex = fixture.appending(path: "codex")
        let claude = fixture.appending(path: "claude")
        for directory in [folder, codex.appending(path: "memories")] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try "# Global Codex memory\n".write(
            to: codex.appending(path: "memories/MEMORY.md"), atomically: true, encoding: .utf8)
        for project in ["project-a", "project-b"] {
            let root = claude.appending(path: "projects/\(project)/memory")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for number in 0..<30 {
                let name = String(format: "topic-%02d.md", number)
                try "# Project \(project == "project-b" ? "B" : "A") topic \(number)\n".write(
                    to: root.appending(path: name), atomically: true, encoding: .utf8)
            }
        }
        let app = try makeApp(lastOpenFolder: folder)
        app.launchEnvironment["CODEX_HOME"] = codex.path
        app.launchEnvironment["CODEX_SQLITE_HOME"] = codex.path
        app.launchEnvironment["CLAUDE_CONFIG_DIR"] = claude.path
        app.launchEnvironment["CLAUDE_CODE_PROJECT_DIR_NAME"] = "current-project"
        app.launch()
        if !app.buttons["memoryEntry-outline"].waitForExistence(timeout: 10) { sidebarToggle(in: app).click() }
        return app
    }
}
