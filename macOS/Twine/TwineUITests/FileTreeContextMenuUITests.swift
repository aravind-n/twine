import AppKit
import XCTest

extension TwineUITests {
    @MainActor
    func testFileTreeContextMenusTargetClickedRowsAndPreserveEdits() throws {
        let folder = try makeTestFolder(prefix: "TwineFileMenu")
        let nested = folder.appending(path: "nested folder")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let first = folder.appending(path: "first.txt")
        let file = nested.appending(path: "hello '🌲.txt")
        let link = folder.appending(path: "shortcut")
        try "first".write(to: first, atomically: true, encoding: .utf8)
        try "second".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        let app = try makeApp(lastOpenFolder: folder)
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 900, height: 620))
        let firstRow = fileRow(first, in: app)
        XCTAssertTrue(firstRow.waitForExistence(timeout: 5))
        firstRow.click()
        let text = app.textViews["fileText"]
        XCTAssertTrue(text.waitForExistence(timeout: 3))
        text.click()
        text.typeKey("a", modifierFlags: .command)
        text.typeText("unsaved first")

        let directory = fileRow(nested, in: app)
        directory.rightClick()
        XCTAssertTrue(app.menuItems["Expand Folder"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.menuItems["Open in Finder"].exists)
        XCTAssertFalse(app.menuItems["Open in Twine"].exists)
        XCTAssertEqual(directory.value as? String, "Collapsed")
        app.menuItems["Expand Folder"].click()
        let row = fileRow(file, in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        verifyFileMenu(app: app, file: file, row: row, text: text)
        verifyFolderMenus(app: app, folder: folder, directory: directory, row: row, link: link)
        fileTab(first, in: app).click()
        let preserved = expectation(
            for: NSPredicate { _, _ in text.value as? String == "unsaved first" }, evaluatedWith: nil)
        wait(for: [preserved], timeout: 3)
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "first")
        app.terminate()
    }

    @MainActor
    private func verifyFileMenu(app: XCUIApplication, file: URL, row: XCUIElement, text: XCUIElement) {
        for (action, expected) in [
            ("Copy Path", file.path),
            ("Copy Relative Path", "nested folder/hello '🌲.txt"),
            ("Copy File Name", file.lastPathComponent),
        ] {
            chooseFileAction(action, row: row, app: app)
            XCTAssertEqual(NSPasteboard.general.string(forType: .string), expected)
            XCTAssertEqual(text.value as? String, "unsaved first")
            XCTAssertFalse(fileTab(file, in: app).exists)
        }

        row.rightClick()
        XCTAssertTrue(app.menuItems["Open in Twine"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.menuItems["Open with Default App"].exists)
        XCTAssertTrue(app.menuItems["Reveal in Finder"].exists)
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = "File right-click menu"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.menuItems["Open in Twine"].click()
        let loaded = expectation(for: NSPredicate { _, _ in text.value as? String == "second" }, evaluatedWith: nil)
        wait(for: [loaded], timeout: 3)
    }

    @MainActor
    private func verifyFolderMenus(
        app: XCUIApplication, folder: URL, directory: XCUIElement, row: XCUIElement, link: URL
    ) {
        let text = app.textViews["fileText"]
        chooseFileAction("Collapse Folder", row: directory, app: app)
        XCTAssertTrue(row.waitForNonExistence(timeout: 3))
        XCTAssertTrue(text.exists)
        chooseFileAction("Copy Relative Path", row: fileRow(link, in: app), app: app)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "shortcut")

        let root = fileRow(folder, in: app)
        chooseFileAction("Copy Relative Path", row: root, app: app)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), ".")
        chooseFileAction("Collapse Folder", row: root, app: app)
        XCTAssertTrue(directory.waitForNonExistence(timeout: 3))
        XCTAssertTrue(text.exists)
        chooseFileAction("Expand Folder", row: root, app: app)
        XCTAssertTrue(directory.waitForExistence(timeout: 3))
        XCTAssertEqual(directory.value as? String, "Collapsed")
    }

    @MainActor
    private func chooseFileAction(_ title: String, row: XCUIElement, app: XCUIApplication) {
        row.rightClick()
        let item = app.menuItems[title]
        XCTAssertTrue(item.waitForExistence(timeout: 2), app.debugDescription)
        item.click()
    }
}
