import Foundation
import SQLite3
import XCTest

extension TwineUITests {
    /// An app that keeps its data in a fresh temporary directory, deleted when the test ends, so each
    /// test starts clean and never touches the real data directory. `lastOpenFolder` seeds the data
    /// as if that folder was open when Twine last quit.
    @MainActor
    func makeApp(lastOpenFolder: URL? = nil, dataDirectory: URL? = nil) throws -> XCUIApplication {
        let dataDirectory =
            dataDirectory
            ?? FileManager.default.temporaryDirectory.appending(path: "TwineUITests-\(UUID().uuidString)")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: dataDirectory)
            UserDefaults.standard.removePersistentDomain(forName: dataDirectory.lastPathComponent)
        }
        if let lastOpenFolder {
            try seedDatabase(in: dataDirectory, lastOpenFolder: lastOpenFolder.path(percentEncoded: false))
        }
        let app = makeTestApplication()
        // A fresh core database also needs a fresh window. Ignore AppKit's saved window state,
        // including an empty window list left by a unit-test host or a previous UI test.
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["TWINE_DATA_DIRECTORY"] = dataDirectory.path(percentEncoded: false)
        // Remember preferences across this app's relaunches without inheriting the user's saved zoom.
        app.launchEnvironment["TWINE_PREFERENCES_SUITE"] = dataDirectory.lastPathComponent
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
}

private struct SeedError: Error {
    let message: String
}
