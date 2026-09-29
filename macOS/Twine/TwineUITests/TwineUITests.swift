//
//  TwineUITests.swift
//  TwineUITests
//
//  Created by Aravind Nidadavolu on 9/26/26.
//

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
        XCTAssertFalse(app.menuItems["New Window"].exists)
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

        // Only the folder's window has the Start Page toolbar button.
        let startPageButton = app.buttons["Start Page"].firstMatch
        XCTAssertTrue(startPageButton.waitForExistence(timeout: 10), app.debugDescription)
        // The window's accessibility title also includes the subtitle, the folder's path.
        XCTAssertTrue(app.windows.firstMatch.title.hasPrefix(folder.lastPathComponent), app.debugDescription)
        XCTAssertFalse(app.staticTexts["Welcome to Twine"].exists, app.debugDescription)

        startPageButton.click()
        XCTAssertTrue(app.staticTexts["Welcome to Twine"].waitForExistence(timeout: 10), app.debugDescription)
        let recent = recentFolder(folder.lastPathComponent, in: app)
        XCTAssertTrue(recent.waitForExistence(timeout: 10), app.debugDescription)

        recent.click()
        XCTAssertTrue(startPageButton.waitForExistence(timeout: 10), app.debugDescription)

        app.menuBars.menuBarItems["File"].click()
        app.menuItems["Close Folder"].click()
        XCTAssertTrue(app.staticTexts["Welcome to Twine"].waitForExistence(timeout: 10), app.debugDescription)
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

        app.buttons["Remove from Recent Folders"].firstMatch.click()
        XCTAssertTrue(
            app.staticTexts["Folders you open appear here."].waitForExistence(timeout: 10),
            app.debugDescription
        )
        XCTAssertFalse(explanation.exists, app.debugDescription)
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
    private func makeApp(lastOpenFolder: URL? = nil) throws -> XCUIApplication {
        let dataDirectory = FileManager.default.temporaryDirectory.appending(path: "TwineUITests-\(UUID().uuidString)")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: dataDirectory)
        }
        if let lastOpenFolder {
            try seedDatabase(in: dataDirectory, lastOpenFolder: lastOpenFolder.path(percentEncoded: false))
        }
        let app = XCUIApplication()
        app.launchEnvironment["TWINE_DATA_DIRECTORY"] = dataDirectory.path(percentEncoded: false)
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
}

private struct SeedError: Error {
    let message: String
}
