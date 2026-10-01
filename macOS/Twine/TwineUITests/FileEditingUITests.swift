import AppKit
import XCTest

extension TwineUITests {
    @MainActor
    func testFileEditingUndoSaveAndConflictChoices() throws {
        let (app, file) = try openEditableFile()
        let text = app.textViews["fileText"]
        replaceText("my edits", in: text)
        XCTAssertTrue(app.staticTexts["fileEdited"].waitForExistence(timeout: 2))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "original")
        text.typeKey("z", modifierFlags: .command)
        XCTAssertEqual(text.value as? String, "original")
        text.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertEqual(text.value as? String, "my edits")
        app.typeKey("s", modifierFlags: .command)
        waitForSaved(app)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "my edits")
        text.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["fileEdited"].waitForExistence(timeout: 2))
        XCTAssertEqual(text.value as? String, "original")
        try "external".write(to: file, atomically: true, encoding: .utf8)
        app.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["File Changed on Disk"].waitForExistence(timeout: 3))
        clickDialogButton("Cancel", in: app)
        XCTAssertEqual(text.value as? String, "original")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "external")
        app.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(app.buttons["Reload"].waitForExistence(timeout: 3))
        clickDialogButton("Reload", in: app)
        waitForText("external", in: text)
        XCTAssertFalse(app.staticTexts["fileEdited"].exists)
        try verifyOverwrite(app: app, text: text, file: file)
        app.terminate()
    }

    @MainActor
    func testUnsavedChangesSurviveWatcherAndCancelledClose() throws {
        let (app, file) = try openEditableFile()
        let text = app.textViews["fileText"]
        replaceText("unsaved", in: text)
        try "disk update".write(to: file, atomically: true, encoding: .utf8)
        // Polling continues while dirty. Undo must then pick up the already-seen disk change.
        let marker = file.deletingLastPathComponent().appending(path: "watcher-marker")
        try "marker".write(to: marker, atomically: true, encoding: .utf8)
        XCTAssertTrue(fileRow(marker, in: app).waitForExistence(timeout: 3))
        XCTAssertEqual(text.value as? String, "unsaved")
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.buttons["Discard Changes"].waitForExistence(timeout: 3))
        clickDialogButton("Cancel", in: app)
        XCTAssertEqual(text.value as? String, "unsaved")
        text.click()
        text.typeKey("z", modifierFlags: .command)
        waitForText("disk update", in: text)
        replaceText("another edit", in: text)
        app.windows.firstMatch.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(app.buttons["Discard Changes"].waitForExistence(timeout: 3))
        clickDialogButton("Cancel", in: app)
        XCTAssertTrue(text.exists)
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.buttons["Discard Changes"].waitForExistence(timeout: 3))
        clickDialogButton("Discard Changes", in: app)
        XCTAssertTrue(app.buttons["workflowTab-1"].waitForExistence(timeout: 3))
        XCTAssertFalse(text.exists)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "disk update")
        fileRow(marker, in: app).click()
        XCTAssertTrue(text.waitForExistence(timeout: 3))
        text.click()
        text.typeKey("z", modifierFlags: .command)
        XCTAssertEqual(text.value as? String, "marker")
        replaceText("marker edited", in: text)
        text.typeKey("z", modifierFlags: .command)
        XCTAssertEqual(text.value as? String, "marker")
        app.terminate()
    }

    @MainActor
    private func verifyOverwrite(app: XCUIApplication, text: XCUIElement, file: URL) throws {
        replaceText("keep mine", in: text)
        try "another disk update".write(to: file, atomically: true, encoding: .utf8)
        app.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(app.buttons["Overwrite"].waitForExistence(timeout: 3))
        clickDialogButton("Overwrite", in: app)
        waitForSaved(app)
        XCTAssertEqual(text.value as? String, "keep mine")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "keep mine")
        replaceText("recreated", in: text)
        try FileManager.default.removeItem(at: file)
        app.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(app.buttons["Overwrite"].waitForExistence(timeout: 3))
        clickDialogButton("Overwrite", in: app)
        waitForSaved(app)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "recreated")
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = "Text editor after conflict resolution"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    private func openEditableFile() throws -> (XCUIApplication, URL) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "TwineEdits-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "edit.txt")
        try "original".write(to: file, atomically: true, encoding: .utf8)
        let app = try makeApp(lastOpenFolder: folder)
        app.launch()
        XCTAssertTrue(app.buttons["sidebarToggle"].waitForExistence(timeout: 10))
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 900, height: 620))
        XCTAssertTrue(fileRow(file, in: app).waitForExistence(timeout: 3))
        fileRow(file, in: app).click()
        XCTAssertTrue(app.textViews["fileText"].waitForExistence(timeout: 3))
        return (app, file)
    }

    @MainActor
    private func clickDialogButton(_ title: String, in app: XCUIApplication) {
        for query in [app.dialogs.buttons, app.sheets.buttons, app.windows.buttons] {
            let button = query[title].firstMatch
            if button.exists {
                button.click()
                return
            }
        }
        XCTFail("Dialog button not found: \(title)\n\(app.debugDescription)")
    }

    @MainActor
    private func replaceText(_ replacement: String, in text: XCUIElement) {
        text.click()
        text.typeKey("a", modifierFlags: .command)
        text.typeText(replacement)
    }

    @MainActor
    private func waitForText(_ expected: String, in text: XCUIElement) {
        let changed = expectation(for: NSPredicate { _, _ in text.value as? String == expected }, evaluatedWith: nil)
        wait(for: [changed], timeout: 3)
    }

    @MainActor
    private func waitForSaved(_ app: XCUIApplication) {
        let saved = expectation(
            for: NSPredicate { _, _ in !app.staticTexts["fileEdited"].exists }, evaluatedWith: nil)
        wait(for: [saved], timeout: 3)
    }
}
