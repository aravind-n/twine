import Foundation
import XCTest

extension TwineUITests {
    @MainActor
    func testUpdaterInstallsSignedArchiveAndStopsShell() throws {
        let fixture = try updaterFixture()
        let folder = try makeTestFolder(prefix: "TwineUpdate")
        let app = try updaterApp(fixture: fixture, folder: folder)
        app.launch()
        app.activate()
        let terminal = app.buttons["workflowChoice-Terminal"].firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 10), app.debugDescription)
        terminal.click()
        XCTAssertTrue(app.scrollViews["newTabChoices"].waitForNonExistence(timeout: 5), app.debugDescription)
        app.typeText("exec /bin/sh\r")
        app.typeText("echo $$ > update-shell.pid\r")
        let shell = try writtenProcessID(in: folder.appending(path: "update-shell.pid"), app: app)
        defer { endProcessIfRunning(shell) }

        checkForUpdate(in: app)
        let install = app.buttons["Install Update"].firstMatch
        XCTAssertTrue(install.waitForExistence(timeout: 15), app.debugDescription)
        install.click()
        let relaunch = app.buttons["Install and Relaunch"].firstMatch
        XCTAssertTrue(relaunch.waitForExistence(timeout: 60), app.debugDescription)
        relaunch.click()
        waitForInstalledUpdate(fixture: fixture)
        XCTAssertTrue(processEnds(shell), "The shell survived update installation")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30), app.debugDescription)
        app.activate()
        let build = app.staticTexts["buildNumber"].firstMatch
        let relaunched = expectation(for: NSPredicate(format: "value ENDSWITH %@", "(2)"), evaluatedWith: build)
        XCTAssertEqual(XCTWaiter.wait(for: [relaunched], timeout: 15), .completed, app.debugDescription)
        XCTAssertTrue(app.buttons["workflowTab-1"].waitForExistence(timeout: 10), app.debugDescription)
        app.typeText("printf updated > updated-app-runs\r")
        waitForFile(folder.appending(path: "updated-app-runs"), containing: "updated", in: app)
        quitUpdaterApp(app)
    }

    @MainActor
    func testUpdaterRejectsInvalidSignature() throws {
        let fixture = try updaterFixture()
        let app = try updaterApp(fixture: fixture, feed: "invalid.xml")
        app.launch()
        checkForUpdate(in: app)
        let install = app.buttons["Install Update"].firstMatch
        XCTAssertTrue(install.waitForExistence(timeout: 15), app.debugDescription)
        install.click()
        let error = app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "improperly signed")).firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 60), app.debugDescription)
        XCTAssertEqual(try installedBuild(fixture: fixture), "1")
        XCTAssertEqual(app.state, .runningForeground)
        clickDialogButton("Cancel Update", in: app)
        quitUpdaterApp(app)
    }

    @MainActor
    func testUpdaterSavesAutomaticUpdateChoiceOnQuit() throws {
        let fixture = try updaterFixture()
        let app = try updaterApp(fixture: fixture)
        app.launch()
        checkForUpdate(in: app)
        let checkbox = app.checkBoxes["Automatically download and install updates in the future"].firstMatch
        XCTAssertTrue(checkbox.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertEqual(String(describing: checkbox.value ?? ""), "0")
        checkbox.click()
        quitUpdaterApp(app)
        let configHome = try XCTUnwrap(app.launchEnvironment["XDG_CONFIG_HOME"])
        let source = try String(
            contentsOf: URL(filePath: configHome).appending(path: "twine/config.toml"), encoding: .utf8)
        XCTAssertTrue(source.contains("automatically_install = true"), source)
        XCTAssertTrue(source.contains("# Preserve this comment"), source)
        XCTAssertEqual(try installedBuild(fixture: fixture), "1")
    }

    @MainActor
    func testUpdaterAutomaticallyInstallsOnQuit() throws {
        let fixture = try updaterFixture()
        let app = try updaterApp(fixture: fixture, automaticallyInstall: true)
        let ready = fixture.appending(path: "ready-\(UUID().uuidString)")
        app.launchEnvironment["TWINE_TEST_UPDATE_BACKGROUND"] = "1"
        app.launchEnvironment["TWINE_TEST_UPDATE_READY_PATH"] = ready.path
        app.launch()
        checkForUpdate(in: app)
        let staged = expectation(
            for: NSPredicate { _, _ in FileManager.default.fileExists(atPath: ready.path) }, evaluatedWith: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [staged], timeout: 60), .completed, app.debugDescription)
        XCTAssertFalse(app.buttons["Install Update"].firstMatch.exists, app.debugDescription)
        XCTAssertEqual(try installedBuild(fixture: fixture), "1")
        quitUpdaterApp(app)
        waitForInstalledUpdate(fixture: fixture)
    }

    @MainActor
    func testUpdaterKeepsUnsavedChangesWhenUpdateQuitIsCancelled() throws {
        let fixture = try updaterFixture()
        let folder = try makeTestFolder(prefix: "TwineUpdateEdits")
        let file = folder.appending(path: "edit.txt")
        try "original".write(to: file, atomically: true, encoding: .utf8)
        let app = try updaterApp(fixture: fixture, folder: folder, automaticallyInstall: true)
        let ready = fixture.appending(path: "ready-\(UUID().uuidString)")
        app.launchEnvironment["TWINE_TEST_UPDATE_BACKGROUND"] = "1"
        app.launchEnvironment["TWINE_TEST_UPDATE_READY_PATH"] = ready.path
        app.launch()
        XCTAssertTrue(fileRow(file, in: app).waitForExistence(timeout: 10), app.debugDescription)
        fileRow(file, in: app).click()
        let text = app.textViews["fileText"]
        XCTAssertTrue(text.waitForExistence(timeout: 5), app.debugDescription)
        text.click()
        text.typeKey("a", modifierFlags: .command)
        text.typeText("unsaved update edit")
        checkForUpdate(in: app)
        let staged = expectation(
            for: NSPredicate { _, _ in FileManager.default.fileExists(atPath: ready.path) }, evaluatedWith: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [staged], timeout: 60), .completed, app.debugDescription)
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.buttons["Discard Changes"].waitForExistence(timeout: 5), app.debugDescription)
        clickDialogButton("Cancel", in: app)
        XCTAssertEqual(text.value as? String, "unsaved update edit")
        XCTAssertEqual(try installedBuild(fixture: fixture), "1")
        text.click()
        text.typeKey("s", modifierFlags: .command)
        waitForFile(file, containing: "unsaved update edit", in: app)
        waitForSave(in: app)
        quitUpdaterApp(app)
        waitForInstalledUpdate(fixture: fixture)
    }

    private func updaterFixture() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["TWINE_UPDATER_FIXTURE"] else {
            throw XCTSkip("Run make test-updater-macos to prepare the signed local update fixture")
        }
        return URL(filePath: path)
    }

    @MainActor
    private func updaterApp(
        fixture: URL, folder: URL? = nil, feed: String = "valid.xml", automaticallyInstall: Bool = false
    ) throws -> XCUIApplication {
        let dataPath = try XCTUnwrap(ProcessInfo.processInfo.environment["TWINE_UPDATER_DATA_DIRECTORY"])
        let app = try makeApp(lastOpenFolder: folder, dataDirectory: URL(filePath: dataPath))
        let port = try String(contentsOf: fixture.appending(path: "port"), encoding: .utf8)
        app.launchEnvironment["TWINE_TEST_UPDATE_FEED_URL"] = "http://127.0.0.1:\(port)/\(feed)"
        let configPath = try XCTUnwrap(ProcessInfo.processInfo.environment["TWINE_UPDATER_CONFIG_HOME"])
        let configHome = URL(filePath: configPath)
        let directory = configHome.appending(path: "twine")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = """
            # Preserve this comment
            [updates]
            automatically_check = true
            automatically_install = \(automaticallyInstall)
            channel = "stable"

            """
        try source.write(to: directory.appending(path: "config.toml"), atomically: true, encoding: .utf8)
        app.launchEnvironment["XDG_CONFIG_HOME"] = configHome.path
        addTeardownBlock { @MainActor in app.terminate() }
        return app
    }

    @MainActor
    private func checkForUpdate(in app: XCUIApplication) {
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        app.menuBars.menuBarItems["Twine"].click()
        let item = app.menuItems["Check for Updates…"].firstMatch
        let available = expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: item)
        XCTAssertEqual(XCTWaiter.wait(for: [available], timeout: 10), .completed, app.debugDescription)
        item.click()
    }

    @MainActor
    private func quitUpdaterApp(_ app: XCUIApplication) {
        app.menuBars.menuBarItems["Twine"].click()
        app.menuItems["Quit Twine"].click()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 30), app.debugDescription)
    }

    private func installedBuild(fixture: URL) throws -> String? {
        let data = try Data(contentsOf: fixture.appending(path: "Applications/Twine.app/Contents/Info.plist"))
        let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        return info?["CFBundleVersion"] as? String
    }

    private func waitForInstalledUpdate(fixture: URL) {
        let installed = expectation(
            for: NSPredicate { _, _ in (try? self.installedBuild(fixture: fixture)) == "2" }, evaluatedWith: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [installed], timeout: 30), .completed, "Sparkle did not replace the app")
    }
}
