import XCTest

extension TwineUITests {
    @MainActor
    func testSwiftSyntaxHighlightingPreservesUnicodeCRLFEditingAndUndo() throws {
        let folder = try makeTestFolder(prefix: "TwineSyntaxUITests")
        let file = folder.appending(path: "Greeting.swift")
        let source = swiftSyntaxFixture
        try Data(source.utf8).write(to: file)
        let app = try launchSyntaxEditor(folder: folder, appearance: "Light")
        defer { app.terminate() }
        openSyntaxFile(file, in: app)
        let text = app.textViews["fileText"]
        waitForSyntaxText(source, in: text)
        assertSyntaxLanguage("Swift", in: app)
        XCTAssertFalse(app.staticTexts["fileEdited"].exists)
        let gutter = app.staticTexts["fileLineNumbers"]
        XCTAssertTrue(gutter.waitForExistence(timeout: 3))
        XCTAssertEqual(gutter.value as? String, "8 lines")
        attachScreenshot(of: app, named: "Light native Swift highlighting with Unicode and CRLF")

        selectSyntaxLine(4, in: app)
        text.typeText("let repetitions = 7")
        let edited = source.replacingOccurrences(of: "let repetitions = 42", with: "let repetitions = 7")
        waitForSyntaxText(edited, in: text)
        XCTAssertTrue(app.staticTexts["fileEdited"].waitForExistence(timeout: 3))
        XCTAssertEqual(try Data(contentsOf: file), Data(source.utf8))
        XCTAssertEqual(gutter.value as? String, "8 lines")

        text.typeKey("z", modifierFlags: .command)
        waitForSyntaxText(source, in: text)
        XCTAssertFalse(app.staticTexts["fileEdited"].exists)
        text.typeKey("z", modifierFlags: [.command, .shift])
        waitForSyntaxText(edited, in: text)
        app.typeKey("s", modifierFlags: .command)
        waitForSyntaxSave(in: app)
        XCTAssertEqual(try Data(contentsOf: file), Data(edited.utf8))
        attachScreenshot(of: app, named: "Swift highlighting after native editing and save")

        text.typeKey("z", modifierFlags: .command)
        waitForSyntaxText(source, in: text)
        XCTAssertTrue(app.staticTexts["fileEdited"].waitForExistence(timeout: 3))
        app.typeKey("s", modifierFlags: .command)
        waitForSyntaxSave(in: app)
        XCTAssertEqual(try Data(contentsOf: file), Data(source.utf8))
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(fileTab(file, in: app).waitForNonExistence(timeout: 3))
        openSyntaxFile(file, in: app)
        waitForSyntaxText(source, in: text)
        assertSyntaxLanguage("Swift", in: app)
        XCTAssertFalse(app.staticTexts["fileEdited"].exists)
    }

    @MainActor
    func testSyntaxLanguageOverridesStayWithTheirFileTabs() throws {
        let folder = try makeTestFolder(prefix: "TwineSyntaxUITests")
        let json = folder.appending(path: "settings.json")
        let unknown = folder.appending(path: "source.custom")
        let jsonSource = """
            {
              "name": "Twine",
              "enabled": true,
              "count": 42,
              "missing": null
            }
            """
        let swiftSource = "// File without a recognized extension\nlet message = \"Hello\"\nlet count = 42\n"
        try jsonSource.write(to: json, atomically: true, encoding: .utf8)
        try swiftSource.write(to: unknown, atomically: true, encoding: .utf8)
        let app = try launchSyntaxEditor(folder: folder, appearance: "Dark")
        defer { app.terminate() }
        openSyntaxFile(json, in: app)
        let text = app.textViews["fileText"]
        waitForSyntaxText(jsonSource, in: text)
        assertSyntaxLanguage("JSON", in: app)
        attachScreenshot(of: app, named: "Dark native JSON highlighting")
        selectSyntaxLanguage("Plain Text", in: app)
        assertSyntaxLanguage("Plain Text", in: app)
        XCTAssertFalse(app.staticTexts["fileEdited"].exists)
        waitForSyntaxText(jsonSource, in: text)
        attachScreenshot(of: app, named: "Dark JSON file with Plain Text override")

        openSyntaxFile(unknown, in: app)
        waitForSyntaxText(swiftSource, in: text)
        assertSyntaxLanguage("Plain Text", in: app)
        selectSyntaxLanguage("Swift", in: app)
        assertSyntaxLanguage("Swift", in: app)
        XCTAssertFalse(app.staticTexts["fileEdited"].exists)
        attachScreenshot(of: app, named: "Dark Swift override for an unknown extension")

        fileTab(json, in: app).click()
        waitForSyntaxText(jsonSource, in: text)
        assertSyntaxLanguage("Plain Text", in: app)
        selectSyntaxLanguage("Automatic", in: app)
        assertSyntaxLanguage("JSON", in: app)
        XCTAssertFalse(app.staticTexts["fileEdited"].exists)
        fileTab(unknown, in: app).click()
        waitForSyntaxText(swiftSource, in: text)
        assertSyntaxLanguage("Swift", in: app)
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(fileTab(unknown, in: app).waitForNonExistence(timeout: 3))
        waitForSyntaxText(jsonSource, in: text)
        assertSyntaxLanguage("JSON", in: app)
        XCTAssertEqual(try String(contentsOf: json, encoding: .utf8), jsonSource)
        XCTAssertEqual(try String(contentsOf: unknown, encoding: .utf8), swiftSource)
    }

    @MainActor
    func testHTMLSyntaxHighlightingPreservesSourceEditingAndCSSDetection() throws {
        let folder = try makeTestFolder(prefix: "TwineSyntaxUITests")
        let html = folder.appending(path: "index.html")
        let css = folder.appending(path: "styles.css")
        let source = htmlSyntaxFixture
        let cssSource = "/* Native CSS highlighting */\n.greeting { color: #2563eb; font-size: 24px; }\n"
        try source.write(to: html, atomically: true, encoding: .utf8)
        try cssSource.write(to: css, atomically: true, encoding: .utf8)
        let app = try launchSyntaxEditor(folder: folder, appearance: "Light")
        defer { app.terminate() }
        XCTAssertTrue(fileRow(html, in: app).waitForExistence(timeout: 3))
        fileRow(html, in: app).click()
        XCTAssertTrue(app.staticTexts["Hello Twine"].waitForExistence(timeout: 5))
        app.radioButtons["Source"].click()
        let text = app.textViews["fileText"]
        XCTAssertTrue(text.waitForExistence(timeout: 3))
        waitForSyntaxText(source, in: text)
        assertSyntaxLanguage("HTML", in: app)
        XCTAssertFalse(app.staticTexts["fileEdited"].exists)
        attachScreenshot(of: app, named: "Light native HTML tags attributes strings and comments")

        try editHTMLSourceAndVerifyPreview(source, file: html, in: app)
        openSyntaxFile(css, in: app)
        waitForSyntaxText(cssSource, in: text)
        assertSyntaxLanguage("CSS", in: app)
        attachScreenshot(of: app, named: "Light native CSS selectors properties and values")
        selectSyntaxLanguage("Plain Text", in: app)
        assertSyntaxLanguage("Plain Text", in: app)
        selectSyntaxLanguage("Automatic", in: app)
        assertSyntaxLanguage("CSS", in: app)
        waitForSyntaxText(cssSource, in: text)
        XCTAssertFalse(app.staticTexts["fileEdited"].exists)
        XCTAssertEqual(try String(contentsOf: css, encoding: .utf8), cssSource)
    }

    @MainActor
    private func editHTMLSourceAndVerifyPreview(_ source: String, file: URL, in app: XCUIApplication) throws {
        let text = app.textViews["fileText"]
        let originalLine = "  <h1 class=\"greeting\" data-count=\"42\">Hello Twine</h1>"
        let editedLine = "  <h1 class=\"greeting edited\" data-count=\"7\">Hello HTML</h1>"
        let edited = source.replacingOccurrences(of: originalLine, with: editedLine)
        selectSyntaxLine(9, in: app)
        text.typeText(editedLine)
        waitForSyntaxText(edited, in: text)
        XCTAssertTrue(app.staticTexts["fileEdited"].waitForExistence(timeout: 3))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), source)
        text.typeKey("z", modifierFlags: .command)
        waitForSyntaxText(source, in: text)
        XCTAssertFalse(app.staticTexts["fileEdited"].exists)
        text.typeKey("z", modifierFlags: [.command, .shift])
        waitForSyntaxText(edited, in: text)
        app.typeKey("s", modifierFlags: .command)
        waitForSyntaxSave(in: app)
        XCTAssertEqual(try Data(contentsOf: file), Data(edited.utf8))
        attachScreenshot(of: app, named: "HTML highlighting after editing attributes and saving")
        app.radioButtons["Preview"].click()
        XCTAssertTrue(app.staticTexts["Hello HTML"].waitForExistence(timeout: 5))
        app.radioButtons["Source"].click()
        waitForSyntaxText(edited, in: text)
        assertSyntaxLanguage("HTML", in: app)
    }

    @MainActor
    private func launchSyntaxEditor(folder: URL, appearance: String) throws -> XCUIApplication {
        let app = try makeApp(lastOpenFolder: folder)
        app.launchEnvironment["TWINE_TEST_APPEARANCE"] = appearance
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 1_000, height: 700))
        XCTAssertTrue(sidebarToggle(in: app).waitForExistence(timeout: 10))
        return app
    }

    private var swiftSyntaxFixture: String {
        [
            "import Foundation",
            "// Unicode before the edited token: 🌲 café",
            "let greeting = \"🌲 café\"",
            "let repetitions = 42",
            "if repetitions > 0 {",
            "    let message = greeting.uppercased()",
            "}",
            "",
        ].joined(separator: "\r\n")
    }

    private var htmlSyntaxFixture: String {
        """
        <!DOCTYPE html>
        <html lang="en">
        <head>
          <title>Twine syntax</title>
          <link rel="stylesheet" href="styles.css">
        </head>
        <body>
          <!-- Unicode remains untouched: 🌲 café -->
          <h1 class="greeting" data-count="42">Hello Twine</h1>
          <p>Native source editing &amp; preview.</p>
        </body>
        </html>

        """
    }

    @MainActor
    private func openSyntaxFile(_ file: URL, in app: XCUIApplication) {
        XCTAssertTrue(fileRow(file, in: app).waitForExistence(timeout: 3))
        fileRow(file, in: app).click()
        XCTAssertTrue(app.textViews["fileText"].waitForExistence(timeout: 3))
    }

    @MainActor
    private func selectSyntaxLine(_ number: Int, in app: XCUIApplication) {
        app.buttons["goToLine"].click()
        let line = app.textFields["lineNumber"]
        XCTAssertTrue(line.waitForExistence(timeout: 3))
        line.click()
        line.typeKey("a", modifierFlags: .command)
        line.typeText(String(number))
        app.buttons["confirmGoToLine"].click()
    }

    @MainActor
    private func selectSyntaxLanguage(_ language: String, in app: XCUIApplication) {
        app.menuButtons["fileSyntaxLanguage"].click()
        // Open the Picker submenu with the keyboard so its screen position does not matter.
        let submenu = app.menuItems["Syntax language"].firstMatch
        XCTAssertTrue(submenu.waitForExistence(timeout: 3), app.debugDescription)
        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.rightArrow, modifierFlags: [])
        let option = submenu.menuItems[language]
        XCTAssertTrue(option.waitForExistence(timeout: 3), app.debugDescription)
        app.typeText(language)
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(submenu.waitForNonExistence(timeout: 3), app.debugDescription)
    }

    @MainActor
    private func assertSyntaxLanguage(_ language: String, in app: XCUIApplication) {
        let menu = app.menuButtons["fileSyntaxLanguage"]
        XCTAssertTrue(menu.waitForExistence(timeout: 3), app.debugDescription)
        let selected = expectation(for: NSPredicate(format: "value == %@", language), evaluatedWith: menu)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 3), .completed, app.debugDescription)
    }

    @MainActor
    private func waitForSyntaxText(_ expected: String, in text: XCUIElement) {
        let changed = expectation(for: NSPredicate { _, _ in text.value as? String == expected }, evaluatedWith: nil)
        wait(for: [changed], timeout: 3)
    }

    @MainActor
    private func waitForSyntaxSave(in app: XCUIApplication) {
        let saved = expectation(
            for: NSPredicate { _, _ in !app.staticTexts["fileEdited"].exists }, evaluatedWith: nil)
        wait(for: [saved], timeout: 3)
    }
}
