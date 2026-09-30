import XCTest

extension TwineUITests {
    @MainActor
    func testHTMLPreviewSourceReloadAndLocalLinks() throws {
        let folder = try makeHTMLFolder()
        let file = folder.appending(path: "index.html")
        let source = "<h1>Initial preview</h1><a href='next.HTM?mode=example#section'>Next page</a>"
        try source.write(to: file, atomically: true, encoding: .utf8)
        try """
        <h1>Linked preview</h1><p id='section'></p>
        <script>document.getElementById('section').textContent = location.search + location.hash;</script>
        """.write(to: folder.appending(path: "next.HTM"), atomically: true, encoding: .utf8)
        let app = try makeApp(lastOpenFolder: folder)
        app.launch()
        XCTAssertTrue(app.buttons["sidebarToggle"].waitForExistence(timeout: 10))
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 1000, height: 680))
        app.buttons["sidebarToggle"].click()
        XCTAssertTrue(fileRow(file, in: app).waitForExistence(timeout: 3))
        fileRow(file, in: app).click()
        XCTAssertTrue(app.staticTexts["Initial preview"].waitForExistence(timeout: 5), app.debugDescription)
        try verifyHTMLSourceAndReload(app: app, file: file, source: source)
        try source.write(to: file, atomically: true, encoding: .utf8)
        app.radioButtons["Preview"].click()
        XCTAssertTrue(app.links["Next page"].waitForExistence(timeout: 5))
        app.links["Next page"].click()
        XCTAssertTrue(app.staticTexts["Linked preview"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["?mode=example#section"].waitForExistence(timeout: 3))
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = "HTML preview"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        try FileManager.default.removeItem(at: folder.appending(path: "next.HTM"))
        XCTAssertTrue(app.staticTexts["File Deleted or Moved"].waitForExistence(timeout: 3))
        app.terminate()
    }

    private func makeHTMLFolder() throws -> URL {
        let base = FileManager.default.temporaryDirectory.appending(path: "TwineHTML-\(UUID().uuidString)")
        let real = base.appending(path: "real")
        try FileManager.default.createDirectory(at: real.appending(path: "site"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        let alias = base.appending(path: "alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
        return alias.appending(path: "site")
    }

    @MainActor
    private func verifyHTMLSourceAndReload(app: XCUIApplication, file: URL, source: String) throws {
        app.radioButtons["Source"].click()
        let text = app.textViews["fileText"]
        XCTAssertTrue(text.waitForExistence(timeout: 3))
        XCTAssertEqual(text.value as? String, source)
        text.click()
        text.typeKey("a", modifierFlags: .command)
        text.typeText("<h1>Unsaved source</h1>")
        app.radioButtons["Preview"].click()
        XCTAssertTrue(app.staticTexts["Initial preview"].waitForExistence(timeout: 5))
        try "<h1>Updated preview</h1>".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertTrue(app.staticTexts["Updated preview"].waitForExistence(timeout: 3))
        app.radioButtons["Source"].click()
        XCTAssertEqual(text.value as? String, "<h1>Unsaved source</h1>")
        text.click()
        text.typeKey("z", modifierFlags: .command)
        let refreshed = expectation(
            for: NSPredicate { _, _ in text.value as? String == "<h1>Updated preview</h1>" }, evaluatedWith: nil)
        wait(for: [refreshed], timeout: 3)
    }
}
