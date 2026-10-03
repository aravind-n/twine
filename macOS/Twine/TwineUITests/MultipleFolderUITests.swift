import Darwin
import XCTest

extension TwineUITests {
    @MainActor
    func testFolderWindowsKeepShellsAndCommandsIndependent() throws {
        let first = try makeTestFolder(prefix: "Twine first folder")
        let second = try makeTestFolder(prefix: "Twine second folder")
        let app = try makeApp(lastOpenFolder: first)
        app.launch()
        let firstWindow = folderWindow(first, in: app)
        XCTAssertTrue(firstWindow.waitForExistence(timeout: 10), app.debugDescription)
        app.typeText("exec /bin/sh\r")
        app.typeText("TWINE_WINDOW=first; echo $$ > shell.pid\r")
        let firstPID = try writtenProcessID(in: first.appending(path: "shell.pid"), app: app)
        defer { endProcessIfRunning(firstPID) }

        chooseFolder(second, in: app)
        let secondWindow = folderWindow(second, in: app)
        XCTAssertTrue(secondWindow.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(app.windows.count, 2)
        app.typeText("exec /bin/sh\r")
        app.typeText("TWINE_WINDOW=second; echo $$ > shell.pid\r")
        let secondPID = try writtenProcessID(in: second.appending(path: "shell.pid"), app: app)
        defer { endProcessIfRunning(secondPID) }
        XCTAssertNotEqual(firstPID, secondPID)
        app.typeText("printf '%s' $TWINE_WINDOW > second.txt\r")
        waitForFile(second.appending(path: "second.txt"), containing: "second", in: app)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.appending(path: "second.txt").path))

        focusFolderWindow(firstWindow, in: app)
        app.typeText("printf '%s' $TWINE_WINDOW > first.txt\r")
        waitForFile(first.appending(path: "first.txt"), containing: "first", in: app)
        app.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(firstWindow.buttons["workflowChoice-Terminal"].waitForExistence(timeout: 10))
        XCTAssertFalse(secondWindow.buttons["workflowChoice-Terminal"].exists)
        app.typeKey("w", modifierFlags: .command)

        focusFolderWindow(secondWindow, in: app)
        secondWindow.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(secondWindow.waitForNonExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(processEnds(secondPID), "Closing the second window must stop its shell")
        XCTAssertEqual(kill(firstPID, 0), 0, "The first window's shell must survive")
        focusFolderWindow(firstWindow, in: app)
        app.typeText("echo $$ > surviving.pid\r")
        XCTAssertEqual(try writtenProcessID(in: first.appending(path: "surviving.pid"), app: app), firstPID)
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
        XCTAssertTrue(processEnds(firstPID))
    }

    @MainActor
    func testOpeningAnOpenFolderFocusesItsWindowIncludingSymlinks() throws {
        let folder = try makeTestFolder(prefix: "Twine duplicate folder")
        let links = try makeTestFolder(prefix: "Twine links")
        let link = links.appending(path: "alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        let app = try makeApp(lastOpenFolder: folder)
        app.launch()
        let window = folderWindow(folder, in: app)
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        chooseFolder(link, in: app)
        XCTAssertEqual(app.windows.count, 1, app.debugDescription)
        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["Welcome to Twine"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.windows.count, 2)
        let recent = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", folder.lastPathComponent))
            .firstMatch
        XCTAssertTrue(recent.waitForExistence(timeout: 10))
        recent.click()
        app.typeText("printf '%s' focused > focused.txt\r")
        waitForFile(folder.appending(path: "focused.txt"), containing: "focused", in: app)
        XCTAssertEqual(app.windows.count, 2, "The empty window remains available; no duplicate folder window opens")
        app.terminate()
    }

    @MainActor
    func testRelaunchRestoresAllFolderWindowsAndLeavesClosedFoldersClosed() throws {
        let first = try makeTestFolder(prefix: "Twine restore first")
        let second = try makeTestFolder(prefix: "Twine restore second")
        let app = try makeApp(lastOpenFolder: first)
        app.launch()
        XCTAssertTrue(folderWindow(first, in: app).waitForExistence(timeout: 10))
        chooseFolder(second, in: app)
        XCTAssertTrue(folderWindow(second, in: app).waitForExistence(timeout: 10))
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
        app.launch()
        let firstWindow = folderWindow(first, in: app)
        let secondWindow = folderWindow(second, in: app)
        XCTAssertTrue(firstWindow.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(secondWindow.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(app.windows.count, 2)
        focusFolderWindow(firstWindow, in: app)
        firstWindow.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(firstWindow.waitForNonExistence(timeout: 10))
        focusFolderWindow(secondWindow, in: app)
        app.typeText("printf '%s' remaining > remaining.txt\r")
        waitForFile(second.appending(path: "remaining.txt"), containing: "remaining", in: app)
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
        app.launch()
        XCTAssertTrue(folderWindow(second, in: app).waitForExistence(timeout: 10))
        XCTAssertEqual(app.windows.count, 1, app.debugDescription)
        XCTAssertFalse(folderWindow(first, in: app).exists)
        app.terminate()
    }

    @MainActor
    private func folderWindow(_ folder: URL, in app: XCUIApplication) -> XCUIElement {
        app.windows.matching(NSPredicate(format: "title BEGINSWITH %@", folder.lastPathComponent)).firstMatch
    }

    @MainActor
    func testClosingAnUnavailableRestoredFolderKeepsItClosedOnRelaunch() throws {
        let missing = try makeTestFolder(prefix: "Twine restore missing")
        let available = try makeTestFolder(prefix: "Twine restore available")
        let app = try makeApp(lastOpenFolder: missing)
        app.launch()
        XCTAssertTrue(folderWindow(missing, in: app).waitForExistence(timeout: 10))
        chooseFolder(available, in: app)
        XCTAssertTrue(folderWindow(available, in: app).waitForExistence(timeout: 10))
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
        try FileManager.default.removeItem(at: missing)
        app.launch()
        XCTAssertTrue(folderWindow(available, in: app).waitForExistence(timeout: 10))
        let explanation = app.staticTexts.matching(
            NSPredicate(format: "value CONTAINS %@", "because it can't be found")
        ).firstMatch
        XCTAssertTrue(explanation.waitForExistence(timeout: 10), app.debugDescription)
        let unavailable = app.windows.matching(NSPredicate(format: "title == %@", "Twine")).firstMatch
        XCTAssertTrue(unavailable.waitForExistence(timeout: 10))
        focusFolderWindow(unavailable, in: app)
        unavailable.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(unavailable.waitForNonExistence(timeout: 10))
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
        app.launch()
        XCTAssertTrue(folderWindow(available, in: app).waitForExistence(timeout: 10))
        XCTAssertEqual(app.windows.count, 1)
        XCTAssertFalse(explanation.exists)
        app.terminate()
    }

    @MainActor
    private func focusFolderWindow(_ window: XCUIElement, in app: XCUIApplication) {
        let name = window.title.components(separatedBy: " – ").first ?? window.title
        app.menuBars.menuBarItems["Window"].click()
        let item = app.menuItems.matching(NSPredicate(format: "title BEGINSWITH %@", name)).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), app.debugDescription)
        item.click()
    }

    /// Drive the real folder picker, including paths containing spaces.
    @MainActor
    private func chooseFolder(_ folder: URL, in app: XCUIApplication) {
        app.typeKey("o", modifierFlags: .command)
        let picker = app.sheets.firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 10), app.debugDescription)
        app.typeKey("g", modifierFlags: [.command, .shift])
        app.typeText(folder.path + "\r")
        let open = picker.buttons["Open"]
        XCTAssertTrue(open.waitForExistence(timeout: 5), app.debugDescription)
        open.click()
        XCTAssertTrue(picker.waitForNonExistence(timeout: 10), app.debugDescription)
    }
}
