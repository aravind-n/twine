import XCTest

extension TwineUITests {
    @MainActor
    func testFileMenuCanOpenWindowsAndFoldersAfterClosingLastWindow() throws {
        let folder = try makeTestFolder(prefix: "Twine menu reopen")
        let app = try makeApp()
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(app.staticTexts["Welcome to Twine"].waitForExistence(timeout: 10))
        window.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(window.waitForNonExistence(timeout: 10))
        XCTAssertEqual(app.state, .runningForeground)

        app.menuBars.menuBarItems["File"].click()
        let newWindow = app.menuItems["New Window"]
        let openFolder = app.menuItems["Open Folder…"]
        XCTAssertTrue(newWindow.isEnabled)
        XCTAssertTrue(openFolder.isEnabled)
        XCTAssertFalse(app.menuItems["New Workflow"].isEnabled)
        XCTAssertFalse(app.menuItems["Close Folder"].isEnabled)
        XCTAssertFalse(app.menuItems["Save"].isEnabled)
        newWindow.click()
        XCTAssertTrue(app.staticTexts["Welcome to Twine"].waitForExistence(timeout: 10))
        window.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(window.waitForNonExistence(timeout: 10))

        app.typeKey("o", modifierFlags: .command)
        let picker = app.sheets.firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(app.windows.count, 1)
        picker.buttons["Cancel"].click()
        XCTAssertTrue(picker.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Welcome to Twine"].exists)
        window.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(window.waitForNonExistence(timeout: 10))

        app.menuBars.menuBarItems["File"].click()
        app.menuItems["Open Folder…"].click()
        XCTAssertTrue(picker.waitForExistence(timeout: 10), app.debugDescription)
        app.typeKey("g", modifierFlags: [.command, .shift])
        app.typeText(folder.path + "\r")
        picker.buttons["Open"].click()
        XCTAssertTrue(picker.waitForNonExistence(timeout: 10))
        XCTAssertTrue(app.buttons["workflowTab-1"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.windows.count, 1)
        app.typeText("printf reopened > reopened.txt\r")
        waitForFile(folder.appending(path: "reopened.txt"), containing: "reopened", in: app)
        app.terminate()
    }
}
