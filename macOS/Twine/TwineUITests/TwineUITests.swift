//
//  TwineUITests.swift
//  TwineUITests
//
//  Created by Aravind Nidadavolu on 9/26/26.
//

import Darwin
import SQLite3
import XCTest

final class TwineUITests: XCTestCase {

    override func setUpWithError() throws {
        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false
    }

    @MainActor
    func testFirstLaunchShowsStartPage() throws {
        let app = try makeApp()
        app.launch()

        XCTAssertTrue(app.staticTexts["Welcome to Twine"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Open Folder…"].exists)
        XCTAssertTrue(app.staticTexts["Folders you open appear here."].exists)
        app.menuBars.menuBarItems["File"].click()
        XCTAssertTrue(app.menuItems["New Window"].exists)
        app.typeKey(.escape, modifierFlags: [])
    }

    @MainActor
    func testRelaunchOpensLastFolderAndReturnsToStartPage() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "TwineUITests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: folder)
        }
        let app = try makeApp(lastOpenFolder: folder)
        app.launch()

        let toggle = sidebarToggle(in: app)
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.buttons["Start Page"].exists)
        // The window's accessibility title also includes the subtitle, the folder's path.
        XCTAssertTrue(app.windows.firstMatch.title.hasPrefix(folder.lastPathComponent), app.debugDescription)
        XCTAssertFalse(app.staticTexts["Welcome to Twine"].exists, app.debugDescription)

        // The reopened folder's terminal takes typing without a click.
        let marker = folder.appending(path: "typed-marker")
        app.typeText("touch \(marker.lastPathComponent)\r")
        let typed = expectation(
            for: NSPredicate { _, _ in FileManager.default.fileExists(atPath: marker.path) }, evaluatedWith: nil)
        wait(for: [typed], timeout: 10)

        closeFolder(in: app)
        XCTAssertTrue(app.staticTexts["Welcome to Twine"].waitForExistence(timeout: 10), app.debugDescription)
        let recent = recentFolder(folder.lastPathComponent, in: app)
        XCTAssertTrue(recent.waitForExistence(timeout: 10), app.debugDescription)

        recent.click()
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), app.debugDescription)

        closeFolder(in: app)
        XCTAssertTrue(app.staticTexts["Welcome to Twine"].waitForExistence(timeout: 10), app.debugDescription)
    }

    @MainActor
    func closeFolder(in app: XCUIApplication) {
        app.menuBars.menuBarItems["File"].click()
        app.menuItems["Close Folder"].click()
    }

    @MainActor
    func testMissingLastFolderIsExplainedAndCanBeRemoved() throws {
        let missing = FileManager.default.temporaryDirectory.appending(path: "TwineUITests-\(UUID().uuidString)")
        let app = try makeApp(lastOpenFolder: missing)
        app.launch()

        // macOS exposes a text's string as its accessibility value.
        let explanation = app.staticTexts.matching(
            NSPredicate(format: "value CONTAINS %@", "because it can't be found")
        ).firstMatch
        XCTAssertTrue(explanation.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(recentFolder(missing.lastPathComponent, in: app).exists, app.debugDescription)

        recentFolder(missing.lastPathComponent, in: app).hover()
        app.buttons["Remove from Recent Folders"].firstMatch.click()
        XCTAssertTrue(
            app.staticTexts["Folders you open appear here."].waitForExistence(timeout: 10),
            app.debugDescription
        )
        XCTAssertFalse(explanation.exists, app.debugDescription)
    }

    @MainActor
    func testDraftChoicesAndTypingKeepThePromptUsable() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "TwineUITests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let app = try makeApp(lastOpenFolder: folder)
        app.launch()
        XCTAssertTrue(app.buttons["newWorkflow"].waitForExistence(timeout: 10), app.debugDescription)
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 900, height: 620))
        let terminalChoice = app.buttons["workflowChoice-Terminal"]
        XCTAssertTrue(terminalChoice.waitForExistence(timeout: 10), app.debugDescription)
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = "New workflow choices"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        terminalChoice.click()
        app.typeText("printf '%s' chosen > chosen.txt\r")
        let chosen = expectation(
            for: NSPredicate { _, _ in
                (try? String(contentsOf: folder.appending(path: "chosen.txt"), encoding: .utf8)) == "chosen"
            }, evaluatedWith: nil
        )
        wait(for: [chosen], timeout: 10)

        app.buttons["newWorkflow"].click()
        let coordinatorChoice = app.buttons["workflowChoice-Coordinator"]
        XCTAssertTrue(coordinatorChoice.waitForExistence(timeout: 10), app.debugDescription)
        coordinatorChoice.click()
        let start = app.descendants(matching: .any).matching(identifier: "workflowStart").firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["Back"].click()
        app.typeText("printf '%s' typed > typed.txt\r")
        let typed = expectation(
            for: NSPredicate { _, _ in
                (try? String(contentsOf: folder.appending(path: "typed.txt"), encoding: .utf8)) == "typed"
            }, evaluatedWith: nil
        )
        wait(for: [typed], timeout: 10)
        XCTAssertTrue(coordinatorChoice.waitForNonExistence(timeout: 10), app.debugDescription)

        app.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(terminalChoice.waitForExistence(timeout: 10), app.debugDescription)
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(terminalChoice.waitForNonExistence(timeout: 10), app.debugDescription)
        app.terminate()
    }

    @MainActor
    func testFooterTracksBranchSelectionAndFrozenExitTime() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "TwineUITests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: folder.appending(path: ".git/objects"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: folder.appending(path: ".git/refs/heads"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let head = folder.appending(path: ".git/HEAD")
        try "ref: refs/heads/footer-initial\n".write(to: head, atomically: true, encoding: .utf8)
        let app = try makeApp(lastOpenFolder: folder)
        app.launch()
        XCTAssertTrue(app.buttons["newWorkflow"].waitForExistence(timeout: 10), app.debugDescription)
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 900, height: 620))
        XCTAssertTrue(app.staticTexts["footer-initial"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Draft"].waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["workflowChoice-Terminal"].click()
        XCTAssertTrue(app.staticTexts["Running"].waitForExistence(timeout: 10), app.debugDescription)
        app.typeText("exit\r")
        XCTAssertTrue(app.staticTexts["Exited"].waitForExistence(timeout: 10), app.debugDescription)
        let elapsed = app.staticTexts["workflowElapsed"]
        let frozen = elapsed.value as? String
        XCTAssertNotNil(frozen)
        app.buttons["newWorkflow"].click()
        XCTAssertTrue(app.staticTexts["Draft"].waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["workflowTab-1"].click()
        XCTAssertTrue(app.staticTexts["Exited"].waitForExistence(timeout: 10), app.debugDescription)
        try "ref: refs/heads/footer-updated\n".write(to: head, atomically: true, encoding: .utf8)
        XCTAssertTrue(app.staticTexts["footer-updated"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(elapsed.value as? String, frozen)
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = "Status footer"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.terminate()
    }

    @MainActor
    func testQuitStopsShellAndDescendant() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "TwineUITests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: folder)
        }
        let app = try makeApp(lastOpenFolder: folder)
        app.launch()
        XCTAssertTrue(app.buttons["workflowTab-1"].waitForExistence(timeout: 10))

        let shellFile = folder.appending(path: "shell.pid")
        let descendantFile = folder.appending(path: "descendant.pid")
        defer {
            for file in [shellFile, descendantFile] {
                if let processID = readProcessID(in: file), processExists(processID) {
                    _ = kill(processID, SIGKILL)
                }
            }
        }

        // Replace the user's login shell so the commands below work with fish, zsh, and bash.
        app.typeText("exec /bin/sh\r")
        app.typeText("echo $$ > shell.pid\r")
        let shellID = try waitForProcessID(in: shellFile)
        app.typeText("trap '' HUP; (trap '' HUP; while :; do sleep 1; done) & echo $! > descendant.pid\r")
        let descendantID = try waitForProcessID(in: descendantFile)

        app.menuBars.menuBarItems["Twine"].click()
        app.menuItems["Quit Twine"].click()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
        XCTAssertTrue(waitForProcessExit(shellID), "shell survived app quit")
        XCTAssertTrue(waitForProcessExit(descendantID), "descendant survived app quit")
    }

    @MainActor
    func testLaunchPerformance() throws {
        let app = try makeApp()
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            app.launch()
        }
    }

    /// An app that keeps its data in a fresh temporary directory, deleted when the test ends, so each
    /// test starts clean and never touches the real data directory. `lastOpenFolder` seeds the data
    /// as if that folder was open when Twine last quit.
    @MainActor
    func makeApp(lastOpenFolder: URL? = nil) throws -> XCUIApplication {
        let dataDirectory = FileManager.default.temporaryDirectory.appending(path: "TwineUITests-\(UUID().uuidString)")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: dataDirectory)
            UserDefaults.standard.removePersistentDomain(forName: dataDirectory.lastPathComponent)
        }
        if let lastOpenFolder {
            try seedDatabase(in: dataDirectory, lastOpenFolder: lastOpenFolder.path(percentEncoded: false))
        }
        let app = XCUIApplication()
        // A fresh core database also needs a fresh window. Ignore AppKit's saved window state,
        // including an empty window list left by a unit-test host or a previous UI test.
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["TWINE_DATA_DIRECTORY"] = dataDirectory.path(percentEncoded: false)
        // Remember preferences across this app's relaunches without inheriting the user's saved zoom.
        app.launchEnvironment["TWINE_TEST_PREFERENCES_SUITE"] = dataDirectory.lastPathComponent
        return app
    }

    /// Writes the database an earlier launch would leave, in the first migration's schema. Twine applies
    /// any later migrations when it opens it.
    private func seedDatabase(in directory: URL, lastOpenFolder path: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var database: OpaquePointer?
        defer { sqlite3_close(database) }
        let sql = """
            CREATE TABLE recent_folders (
                path TEXT PRIMARY KEY NOT NULL,
                last_opened_at INTEGER NOT NULL,
                is_open INTEGER NOT NULL DEFAULT 0 CHECK (is_open IN (0, 1))
            ) STRICT;
            INSERT INTO recent_folders VALUES ('\(path.replacingOccurrences(of: "'", with: "''"))', 1, 1);
            PRAGMA user_version = 1;
            """
        let file = directory.appending(path: "twine.db").path(percentEncoded: false)
        guard sqlite3_open(file, &database) == SQLITE_OK, sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK
        else {
            throw SeedError(message: String(cString: sqlite3_errmsg(database)))
        }
    }

    /// The start page's card for the recent folder named `name`. A card is one button whose label
    /// starts with the folder's name.
    @MainActor
    private func recentFolder(_ name: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
    }

    @MainActor
    private func waitForProcessID(in file: URL) throws -> pid_t {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let processID = readProcessID(in: file) {
                return processID
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return try XCTUnwrap(readProcessID(in: file), "Timed out waiting for a PID in \(file.path)")
    }

    private func readProcessID(in file: URL) -> pid_t? {
        guard
            let contents = try? String(contentsOf: file, encoding: .utf8),
            let processID = pid_t(contents.trimmingCharacters(in: .whitespacesAndNewlines)),
            processID > 0
        else { return nil }
        return processID
    }

    private func waitForProcessExit(_ processID: pid_t) -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while processExists(processID) && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        return !processExists(processID)
    }

    private func processExists(_ processID: pid_t) -> Bool {
        kill(processID, 0) == 0 || errno != ESRCH
    }
}

private struct SeedError: Error {
    let message: String
}
