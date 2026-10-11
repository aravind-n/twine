import AppKit
import XCTest

extension TwineUITests {
    @MainActor
    func testFileTreeLoadsLazilyAndViewerTracksDiskChanges() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "TwineFiles-\(UUID().uuidString)")
        let nested = folder.appending(path: "nested")
        let empty = folder.appending(path: "empty")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let file = nested.appending(path: "hello.txt")
        try "first\nsecond\nthird\n".write(to: file, atomically: true, encoding: .utf8)
        let app = try makeApp(lastOpenFolder: folder)
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 900, height: 620))
        XCTAssertTrue(sidebarToggle(in: app).waitForExistence(timeout: 10))
        let root = fileRow(folder, in: app)
        XCTAssertTrue(root.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(root.label, folder.lastPathComponent)
        XCTAssertEqual(root.value as? String, "Expanded")
        XCTAssertEqual(root.frame.height, 27, accuracy: 1)
        XCTAssertFalse(app.staticTexts["sidebarFolderName"].exists)
        let directory = fileRow(nested, in: app)
        XCTAssertTrue(directory.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertGreaterThanOrEqual(app.scrollViews["fileTree"].frame.width, 245)
        XCTAssertFalse(fileRow(file, in: app).exists)
        fileRow(empty, in: app).click()
        XCTAssertTrue(app.staticTexts["Empty folder"].waitForExistence(timeout: 3))
        directory.click()
        let row = fileRow(file, in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        row.click()
        let text = app.textViews["fileText"]
        XCTAssertTrue(text.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertEqual(text.value as? String, "first\nsecond\nthird\n")
        verifyRootExpansion(app: app, root: root, directory: directory, row: row, text: text)
        verifySelection(app: app, text: text)
        try "first\nupdated\nthird\n".write(to: file, atomically: true, encoding: .utf8)
        let updated = expectation(
            for: NSPredicate { _, _ in
                text.value as? String == "first\nupdated\nthird\n"
            }, evaluatedWith: nil)
        wait(for: [updated], timeout: 2)
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = "File explorer and text viewer"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        try verifyFileTransitions(app: app, file: file, row: row, text: text)
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.buttons["workflowTab-1"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["closeFile"].exists)
        app.terminate()
    }

    @MainActor
    private func verifyRootExpansion(
        app: XCUIApplication, root: XCUIElement, directory: XCUIElement, row: XCUIElement, text: XCUIElement
    ) {
        root.click()
        XCTAssertEqual(root.value as? String, "Collapsed")
        XCTAssertTrue(directory.waitForNonExistence(timeout: 3))
        XCTAssertFalse(row.exists)
        XCTAssertTrue(text.exists, "Collapsing the root should keep the selected file open")
        root.click()
        XCTAssertTrue(directory.waitForExistence(timeout: 3))
        XCTAssertEqual(directory.value as? String, "Collapsed")
        directory.click()
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        app.menuButtons["filesActions"].click()
        app.menuItems["Collapse All"].click()
        XCTAssertEqual(root.value as? String, "Collapsed")
        XCTAssertTrue(directory.waitForNonExistence(timeout: 3))
        XCTAssertTrue(text.exists)
        root.click()
        XCTAssertTrue(directory.waitForExistence(timeout: 3))
        XCTAssertEqual(directory.value as? String, "Collapsed")
        directory.click()
        XCTAssertTrue(row.waitForExistence(timeout: 3))
    }

    @MainActor
    private func verifySelection(app: XCUIApplication, text: XCUIElement) {
        app.buttons["goToLine"].click()
        let line = app.textFields["lineNumber"]
        XCTAssertTrue(line.waitForExistence(timeout: 3))
        line.click()
        line.typeKey("a", modifierFlags: .command)
        line.typeText("2")
        app.buttons["confirmGoToLine"].click()
        NSPasteboard.general.clearContents()
        text.typeKey("c", modifierFlags: .command)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "second")
    }

    @MainActor
    private func verifyFileTransitions(app: XCUIApplication, file: URL, row: XCUIElement, text: XCUIElement) throws {
        let renamed = file.deletingLastPathComponent().appending(path: "renamed.txt")
        try FileManager.default.moveItem(at: file, to: renamed)
        XCTAssertTrue(app.staticTexts["File Deleted or Moved"].waitForExistence(timeout: 2))
        let renamedRow = fileRow(renamed, in: app)
        XCTAssertTrue(renamedRow.waitForExistence(timeout: 2))
        XCTAssertFalse(row.exists)
        renamedRow.click()
        XCTAssertTrue(text.waitForExistence(timeout: 2))
        try Data([0, 1, 2, 3]).write(to: renamed)
        XCTAssertTrue(app.staticTexts["Binary File"].waitForExistence(timeout: 2))
        try Data(repeating: 65, count: 2 * 1024 * 1024 + 1).write(to: renamed)
        XCTAssertTrue(app.staticTexts["File Too Large"].waitForExistence(timeout: 2))
        try FileManager.default.removeItem(at: renamed)
        XCTAssertTrue(app.staticTexts["File Deleted or Moved"].waitForExistence(timeout: 2))
    }
    @MainActor
    func fileRow(_ path: URL, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier == %@", "fileRow-\(path.path)")).firstMatch
    }

    @MainActor
    func fileTab(_ path: URL, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier == %@", "fileTab-\(path.path)")).firstMatch
    }

}
