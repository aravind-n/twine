import AppKit
import XCTest

extension TwineUITests {
    @MainActor
    func testAutosaveSettingsApplyToOpenTabsAndCommandSSavesExplicitly() throws {
        let (app, file) = try openEditableFile(editorSettings: "[editor]\nautosave = false\n")
        defer { app.terminate() }
        let text = app.textViews["fileText"]
        XCTAssertEqual(staticTextValue(app.staticTexts["fileSaveStatus"]), "⌘S to save")
        XCTAssertFalse(app.buttons["saveFile"].exists)
        replaceText("manual save", in: text)
        verifyNoAutosave(file: file, original: "original")
        app.typeKey("s", modifierFlags: .command)
        waitForSave(in: app)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "manual save")

        updateAutosaveSettings("[editor]\nautosave = true\nautosave_delay_ms = 60000\n", in: app)
        XCTAssertEqual(staticTextValue(app.staticTexts["fileSaveStatus"]), "Autosave")
        replaceText("save before timeout", in: text)
        verifyNoAutosave(file: file, original: "manual save")
        app.typeKey("s", modifierFlags: .command)
        waitForSave(in: app)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "save before timeout")

        replaceText("pending edit", in: text)
        updateAutosaveSettings("[editor]\nautosave = true\nautosave_delay_ms = 50\n", in: app)
        waitForDiskText("pending edit", in: file)
        replaceText("automatic again", in: text)
        waitForSave(in: app)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "automatic again")
    }

    @MainActor
    private func updateAutosaveSettings(_ source: String, in app: XCUIApplication) {
        app.typeKey(",", modifierFlags: .command)
        let sheet = app.sheets.firstMatch
        let text = sheet.textViews["fileText"]
        XCTAssertTrue(text.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(sheet.buttons["saveFile"].exists)
        replaceText(source, in: text)
        app.typeKey("s", modifierFlags: .command)
        let saved = expectation(
            for: NSPredicate { _, _ in
                !sheet.staticTexts["fileEdited"].exists
                    && staticTextValue(sheet.staticTexts["fileSaveStatus"]) != "Saving…"
            }, evaluatedWith: nil)
        wait(for: [saved], timeout: 5)
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 3))
    }

    private func verifyNoAutosave(file: URL, original: String) {
        let changed = expectation(
            for: NSPredicate { _, _ in (try? String(contentsOf: file, encoding: .utf8)) != original },
            evaluatedWith: nil)
        changed.isInverted = true
        wait(for: [changed], timeout: 1)
    }

    @MainActor
    func testFileEditingUndoSaveAndConflictChoices() throws {
        let (app, file) = try openEditableFile()
        let text = app.textViews["fileText"]
        XCTAssertEqual(staticTextValue(app.staticTexts["fileSaveStatus"]), "Autosave")
        XCTAssertFalse(app.buttons["saveFile"].exists)
        replaceText("my edits", in: text)
        waitForSaved(app)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "my edits")
        text.typeKey("z", modifierFlags: .command)
        XCTAssertEqual(text.value as? String, "original")
        waitForSaved(app)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "original")
        text.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertEqual(text.value as? String, "my edits")
        waitForSaved(app)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "my edits")
        text.typeKey("z", modifierFlags: .command)
        try "external".write(to: file, atomically: true, encoding: .utf8)
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
        XCTAssertTrue(app.staticTexts["File Changed on Disk"].waitForExistence(timeout: 3))
        clickDialogButton("Cancel", in: app)
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
        // A disk conflict pauses autosave and protects this buffer on close.
        try "new disk update".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertTrue(app.staticTexts["File Changed on Disk"].waitForExistence(timeout: 3))
        clickDialogButton("Cancel", in: app)
        app.windows.firstMatch.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(app.buttons["Discard Changes"].waitForExistence(timeout: 3))
        clickDialogButton("Cancel", in: app)
        XCTAssertTrue(text.exists)
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.buttons["Discard Changes"].waitForExistence(timeout: 3))
        clickDialogButton("Discard Changes", in: app)
        XCTAssertTrue(app.buttons["workflowTab-1"].waitForExistence(timeout: 3))
        XCTAssertFalse(text.exists)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "new disk update")
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
    func testFileTabsPreserveEditsAndIndependentUndo() throws {
        let (app, first) = try openEditableFile()
        let second = first.deletingLastPathComponent().appending(path: "second.txt")
        try "second".write(to: second, atomically: true, encoding: .utf8)
        let text = app.textViews["fileText"]
        replaceText("first edited", in: text)
        XCTAssertTrue(fileTab(first, in: app).exists)
        XCTAssertTrue(app.buttons["newWorkflow"].exists)
        app.buttons["workflowTab-1"].click()
        XCTAssertTrue(text.waitForNonExistence(timeout: 3))
        waitForDiskText("first edited", in: first)
        fileTab(first, in: app).click()
        waitForText("first edited", in: text)
        XCTAssertTrue(fileRow(second, in: app).waitForExistence(timeout: 3))
        fileRow(second, in: app).click()
        waitForText("second", in: text)
        replaceText("second edited", in: text)
        fileTab(first, in: app).click()
        waitForDiskText("second edited", in: second)
        waitForText("first edited", in: text)
        text.typeKey("z", modifierFlags: .command)
        waitForText("original", in: text)
        fileTab(second, in: app).click()
        waitForText("second edited", in: text)
        text.typeKey("z", modifierFlags: .command)
        waitForText("second", in: text)
        fileRow(first, in: app).click()
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier == %@", "fileTab-\(first.path)")).count, 1)
        replaceText("unsaved first", in: text)
        fileTab(second, in: app).click()
        waitForDiskText("unsaved first", in: first)
        waitForSaved(app)
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(fileTab(second, in: app).waitForNonExistence(timeout: 3))
        waitForText("unsaved first", in: text)
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(fileTab(first, in: app).waitForNonExistence(timeout: 3))
        XCTAssertTrue(text.waitForNonExistence(timeout: 3))
        app.terminate()
    }

    @MainActor
    func testFileLineNumbersFollowWrappingScrollingAndEdits() throws {
        let (app, file) = try openEditableFile()
        let text = app.textViews["fileText"]
        let rows = (1...80).map { "\($0): 🌲 " + String(repeating: "wrapped text ", count: 10) }
        let source = rows.joined(separator: "\r\n") + "\r\n"
        try source.write(to: file, atomically: true, encoding: .utf8)
        waitForText(source, in: text)
        let gutter = app.staticTexts["fileLineNumbers"]
        XCTAssertTrue(gutter.waitForExistence(timeout: 3))
        XCTAssertEqual(gutter.value as? String, "81 lines")
        attachGutterScreenshot(app, name: "Line numbers with wrapping and CRLF")
        app.buttons["goToLine"].click()
        let line = app.textFields["lineNumber"]
        XCTAssertTrue(line.waitForExistence(timeout: 3))
        line.click()
        line.typeKey("a", modifierFlags: .command)
        line.typeText("80")
        app.buttons["confirmGoToLine"].click()
        NSPasteboard.general.clearContents()
        text.typeKey("c", modifierFlags: .command)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), rows[79])
        attachGutterScreenshot(app, name: "Line numbers after scrolling to the final line")
        replaceText("first\nsecond\n", in: text)
        XCTAssertEqual(gutter.value as? String, "3 lines")
        text.typeKey("z", modifierFlags: .command)
        waitForText(source, in: text)
        XCTAssertEqual(gutter.value as? String, "81 lines")
        app.terminate()
    }

    @MainActor
    private func attachGutterScreenshot(_ app: XCUIApplication, name: String) {
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
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
    private func openEditableFile(editorSettings: String? = nil) throws -> (XCUIApplication, URL) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "TwineEdits-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "edit.txt")
        try "original".write(to: file, atomically: true, encoding: .utf8)
        let app = try makeApp(lastOpenFolder: folder)
        if let editorSettings {
            let configHome = try makeTestFolder(prefix: "TwineAutosaveConfig")
            let configFile = configHome.appending(path: "twine/config.toml")
            try FileManager.default.createDirectory(
                at: configFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try editorSettings.write(to: configFile, atomically: true, encoding: .utf8)
            app.launchEnvironment["XDG_CONFIG_HOME"] = configHome.path
        }
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 900, height: 620))
        XCTAssertTrue(sidebarToggle(in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(fileRow(file, in: app).waitForExistence(timeout: 3))
        fileRow(file, in: app).click()
        XCTAssertTrue(app.textViews["fileText"].waitForExistence(timeout: 3))
        return (app, file)
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

    private func waitForDiskText(_ expected: String, in file: URL) {
        let saved = expectation(
            for: NSPredicate { _, _ in (try? String(contentsOf: file, encoding: .utf8)) == expected },
            evaluatedWith: nil)
        wait(for: [saved], timeout: 3)
    }
}
