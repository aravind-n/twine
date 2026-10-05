import XCTest

extension TwineUITests {
    @MainActor
    func testSettingsPopupLoadsSavesAndProtectsUnsavedChanges() throws {
        let configHome = try makeTestFolder(prefix: "TwineSettingsUITests")
        let file = configHome.appending(path: "twine/config.toml")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = "# My settings\n[terminal.colors]\nblue = '#123456'\nbrblue = '#abcdef'\n"
        try original.write(to: file, atomically: true, encoding: .utf8)
        let app = try makeApp()
        app.launchEnvironment["XDG_CONFIG_HOME"] = configHome.path
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Welcome to Twine"].waitForExistence(timeout: 10))
        app.menuBars.menuBarItems["Twine"].click()
        let item = app.menuBars.menuItems["Settings…"]
        XCTAssertTrue(item.waitForExistence(timeout: 3))
        item.click()
        let settings = app.sheets.firstMatch
        let text = settings.textViews["fileText"]
        XCTAssertTrue(text.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(text.value as? String, original)
        let saved = "# Edited\n[terminal.colors]\nmagenta = '#654321'\nbrblack = '#222222'\n"
        text.click()
        text.typeKey("a", modifierFlags: .command)
        text.typeText(saved)
        app.typeKey("s", modifierFlags: .command)
        waitForFile(file, containing: "# Edited", in: app)
        waitForSave(in: app)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), saved)
        text.typeKey("a", modifierFlags: .command)
        text.typeText("# Unsaved\n")
        app.typeKey(",", modifierFlags: .command)
        XCTAssertEqual(text.value as? String, "# Unsaved\n")
        XCTAssertEqual(app.sheets.count, 1)
        XCTAssertEqual(app.windows.matching(identifier: "Settings").count, 0)
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.buttons["Discard Changes"].waitForExistence(timeout: 3))
        clickDialogButton("Cancel", in: app)
        XCTAssertEqual(text.value as? String, "# Unsaved\n")
        try verifySettingsConflictAndReopen(app: app, settings: settings, text: text, file: file)
    }

    @MainActor
    private func verifySettingsConflictAndReopen(
        app: XCUIApplication, settings: XCUIElement, text: XCUIElement, file: URL
    ) throws {
        let external = "# External change\n"
        try external.write(to: file, atomically: true, encoding: .utf8)
        app.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(app.buttons["Reload"].waitForExistence(timeout: 3))
        clickDialogButton("Reload", in: app)
        let reloaded = expectation(
            for: NSPredicate { _, _ in text.value as? String == external }, evaluatedWith: nil)
        wait(for: [reloaded], timeout: 3)
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(settings.waitForNonExistence(timeout: 3))
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        XCTAssertEqual(text.value as? String, external)
        text.click()
        text.typeKey("a", modifierFlags: .command)
        text.typeText("# Quit should keep these edits\n")
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.buttons["Discard Changes"].waitForExistence(timeout: 3), app.debugDescription)
        clickDialogButton("Cancel", in: app)
        waitForQuitConfirmationToClose(in: app)
        XCTAssertEqual(text.value as? String, "# Quit should keep these edits\n")
        app.menuBars.menuBarItems["Twine"].click()
        let quit = app.menuItems["Quit Twine"]
        XCTAssertTrue(quit.isEnabled, app.debugDescription)
        quit.click()
        XCTAssertTrue(app.buttons["Discard Changes"].waitForExistence(timeout: 3), app.debugDescription)
        app.typeKey(.escape, modifierFlags: [])
        waitForQuitConfirmationToClose(in: app)
        XCTAssertTrue(settings.exists)
        XCTAssertEqual(text.value as? String, "# Quit should keep these edits\n")
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.buttons["Discard Changes"].waitForExistence(timeout: 3))
        clickDialogButton("Discard Changes", in: app)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10), "Discarding Settings must allow quit")
        app.launch()
        XCTAssertTrue(app.staticTexts["Welcome to Twine"].waitForExistence(timeout: 10))
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10), "Clean Settings must allow quit")
    }

    @MainActor
    private func waitForQuitConfirmationToClose(in app: XCUIApplication) {
        let closed = expectation(
            for: NSPredicate { _, _ in
                !app.dialogs.buttons["Discard Changes"].exists && !app.sheets.buttons["Discard Changes"].exists
            }, evaluatedWith: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 3), .completed, app.debugDescription)
    }
}
