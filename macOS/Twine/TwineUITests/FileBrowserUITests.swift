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
        XCTAssertTrue(app.buttons["sidebarToggle"].waitForExistence(timeout: 10))
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 900, height: 620))
        app.buttons["sidebarToggle"].click()
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
        try verifyReadOnlySelection(app: app, text: text, file: file)
        try "first\nupdated\nthird\n".write(to: file, atomically: true, encoding: .utf8)
        let updated = expectation(
            for: NSPredicate { _, _ in
                text.value as? String == "first\nupdated\nthird\n"
            }, evaluatedWith: nil)
        wait(for: [updated], timeout: 2)
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = "File explorer and read-only viewer"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        try verifyFileTransitions(app: app, file: file, row: row, text: text)
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.buttons["workflowTab-1"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["closeFile"].exists)
        app.terminate()
    }

    @MainActor
    private func verifyReadOnlySelection(app: XCUIApplication, text: XCUIElement, file: URL) throws {
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
        text.typeText("must not edit")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "first\nsecond\nthird\n")
        XCTAssertEqual(text.value as? String, "first\nsecond\nthird\n")
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
    private func fileRow(_ path: URL, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier == %@", "fileRow-\(path.path)")).firstMatch
    }

}
