import XCTest

extension TwineUITests {
    @MainActor
    func testMarkdownPreviewSourceSaveReloadAndLocalLinks() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "TwineMarkdown-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "README.MD")
        let next = folder.appending(path: "next.MARKDOWN")
        let source = "# Initial preview\n\n**Bold text**\n\n[Next page](next.MARKDOWN)"
        try source.write(to: file, atomically: true, encoding: .utf8)
        try "# Linked preview\n\n| Name | Value |\n| --- | --- |\n| Item | 42 |".write(
            to: next, atomically: true, encoding: .utf8)
        let app = try makeApp(lastOpenFolder: folder)
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 1000, height: 680))
        XCTAssertTrue(fileRow(file, in: app).waitForExistence(timeout: 5))
        fileRow(file, in: app).click()
        XCTAssertTrue(app.staticTexts["Initial preview"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Bold text"].exists)
        XCTAssertFalse(app.buttons["goToLine"].isEnabled)
        try verifyMarkdownSourceAndSave(app: app, file: file, source: source)
        try verifyMarkdownDirtyBufferSurvivesReload(app: app, file: file)
        let link = app.links["Next page"]
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        link.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertTrue(app.staticTexts["Linked preview"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["42"].exists)
        XCTAssertTrue(fileTab(file, in: app).exists)
        XCTAssertTrue(fileTab(next, in: app).exists)
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = "Markdown preview"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        try FileManager.default.removeItem(at: next)
        XCTAssertTrue(app.staticTexts["File Deleted or Moved"].waitForExistence(timeout: 3))
        app.terminate()
    }

    @MainActor
    private func verifyMarkdownSourceAndSave(app: XCUIApplication, file: URL, source: String) throws {
        app.radioButtons["Source"].click()
        let text = app.textViews["fileText"]
        XCTAssertTrue(text.waitForExistence(timeout: 3))
        XCTAssertEqual(text.value as? String, source)
        XCTAssertTrue(app.buttons["goToLine"].isEnabled)
        text.click()
        text.typeKey("a", modifierFlags: .command)
        let saved = "# Saved edits\n\n[Next page](next.MARKDOWN)"
        text.typeText(saved)
        app.radioButtons["Preview"].click()
        XCTAssertTrue(app.staticTexts["Saved edits"].waitForExistence(timeout: 5))
        app.radioButtons["Source"].click()
        XCTAssertEqual(text.value as? String, saved)
        let clean = expectation(for: NSPredicate { _, _ in !app.staticTexts["fileEdited"].exists }, evaluatedWith: nil)
        wait(for: [clean], timeout: 3)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), saved)
        app.radioButtons["Preview"].click()
        XCTAssertTrue(app.staticTexts["Saved edits"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func verifyMarkdownDirtyBufferSurvivesReload(app: XCUIApplication, file: URL) throws {
        app.radioButtons["Source"].click()
        let text = app.textViews["fileText"]
        text.click()
        text.typeKey("a", modifierFlags: .command)
        text.typeText("# Unsaved source")
        try "# Disk update\n\n[Next page](next.MARKDOWN)".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertTrue(app.staticTexts["File Changed on Disk"].waitForExistence(timeout: 3))
        clickDialogButton("Cancel", in: app)
        app.radioButtons["Preview"].click()
        XCTAssertTrue(app.staticTexts["Disk update"].waitForExistence(timeout: 3))
        app.radioButtons["Source"].click()
        XCTAssertEqual(text.value as? String, "# Unsaved source")
        text.click()
        text.typeKey("z", modifierFlags: .command)
        let refreshed = expectation(
            for: NSPredicate { _, _ in text.value as? String == "# Disk update\n\n[Next page](next.MARKDOWN)" },
            evaluatedWith: nil)
        wait(for: [refreshed], timeout: 3)
        app.radioButtons["Preview"].click()
    }
}
