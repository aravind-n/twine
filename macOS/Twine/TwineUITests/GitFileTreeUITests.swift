import Foundation
import XCTest

extension TwineUITests {
    @MainActor
    func testGitFileTreeShowsPrimaryCheckoutChangesAcrossRepositories() throws {
        let folder = try makeTestFolder(prefix: "TwineGit")
        let desktop = folder.appending(path: "desktop")
        let services = folder.appending(path: "services")
        let api = services.appending(path: "api")
        try makeGitRepository(desktop)
        try makeGitRepository(api)
        let linked = folder.appending(path: "parallel")
        try runGit(desktop, ["worktree", "add", "-b", "parallel", linked.path])
        try runGit(desktop, ["checkout", "-b", "feature/sidebar"])
        let readme = desktop.appending(path: "README.txt")
        try "staged\n".write(to: readme, atomically: true, encoding: .utf8)
        try runGit(desktop, ["add", "README.txt"])
        try "unstaged\n".write(to: readme, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: desktop.appending(path: "deleted.txt"))
        try "new\n".write(to: desktop.appending(path: "new.txt"), atomically: true, encoding: .utf8)
        try "api edit\n".write(to: api.appending(path: "README.txt"), atomically: true, encoding: .utf8)
        let index = try Data(contentsOf: desktop.appending(path: ".git/index"))
        let app = try makeApp(lastOpenFolder: folder)
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 1100, height: 850))
        waitForGit("Contains Git changes", at: desktop, in: app)
        verifyGitDirectoryPresentation(repository: desktop, folder: folder, app: app)
        fileRow(desktop, in: app).click()
        waitForGit("Staged: Modified; Unstaged: Modified", at: readme, in: app)
        waitForGit("Untracked", at: desktop.appending(path: "new.txt"), in: app)
        let deleted = desktop.appending(path: "deleted.txt")
        waitForGit("Unstaged: Deleted", at: deleted, in: app)
        verifyGitFileDetails(readme: readme, deleted: deleted, app: app)
        fileRow(services, in: app).click()
        waitForGit("Contains Git changes", at: api, in: app)
        fileRow(api, in: app).click()
        let apiReadme = api.appending(path: "README.txt")
        waitForGit("Unstaged: Modified", at: apiReadme, in: app)
        fileRow(apiReadme, in: app).click()
        let apiText = app.textViews["fileText"]
        XCTAssertTrue(apiText.waitForExistence(timeout: 5))
        XCTAssertEqual(apiText.value as? String, "api edit\n")
        XCTAssertFalse(gitBadge(linked, in: app).exists)
        XCTAssertEqual(try Data(contentsOf: desktop.appending(path: ".git/index")), index)
        attachWindow(in: app, name: "Git status in Files across repositories")
        try runGit(desktop, ["add", "-A"])
        try runGit(desktop, ["commit", "-m", "changes"])
        XCTAssertTrue(gitBadge(desktop, in: app).waitForNonExistence(timeout: 8))
        XCTAssertTrue(gitBadge(readme, in: app).waitForNonExistence(timeout: 8))
        XCTAssertTrue(fileRow(deleted, in: app).waitForNonExistence(timeout: 8))
        waitForGit("Contains Git changes", at: api, in: app)
        app.terminate()
    }

    @MainActor
    func testGitFileTreeRefreshesConflictsAndUnavailableRepositories() throws {
        let folder = try makeTestFolder(prefix: "TwineGitConflict")
        try makeGitRepository(folder)
        try runGit(folder, ["checkout", "-b", "other"])
        let readme = folder.appending(path: "README.txt")
        try "other\n".write(to: readme, atomically: true, encoding: .utf8)
        try runGit(folder, ["commit", "-am", "other"])
        try runGit(folder, ["checkout", "main"])
        try "main\n".write(to: readme, atomically: true, encoding: .utf8)
        try runGit(folder, ["commit", "-am", "main"])
        try runGit(folder, ["merge", "other"], expectedStatus: 1)
        let app = try makeApp(lastOpenFolder: folder)
        app.launchEnvironment["TWINE_TEST_APPEARANCE"] = "Light"
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        waitForGit("Merge conflict", at: readme, in: app)
        fileRow(readme, in: app).click()
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 700, height: 550))
        XCTAssertTrue(gitBadge(folder, in: app).isHittable)
        XCTAssertTrue(gitBadge(readme, in: app).isHittable)
        attachWindow(in: app, name: "Git conflict in a narrow light window")
        try runGit(folder, ["merge", "--abort"])
        XCTAssertTrue(gitBadge(folder, in: app).waitForNonExistence(timeout: 8))
        try "working tree change\n".write(to: readme, atomically: true, encoding: .utf8)
        waitForGit("Contains Git changes", at: folder, in: app)
        let head = folder.appending(path: ".git/HEAD")
        let savedHead = try Data(contentsOf: head)
        try FileManager.default.removeItem(at: head)
        XCTAssertTrue(gitBadge(folder, in: app).waitForNonExistence(timeout: 8))
        let statusError = app.staticTexts.matching(
            NSPredicate(format: "identifier == %@", "gitStatusError-\(folder.path)")
        ).firstMatch
        XCTAssertTrue(statusError.waitForExistence(timeout: 8))
        XCTAssertTrue(fileRow(readme, in: app).exists)
        try savedHead.write(to: head)
        waitForGit("Contains Git changes", at: folder, in: app)
        waitForGit("Unstaged: Modified", at: readme, in: app)
        XCTAssertTrue(statusError.waitForNonExistence(timeout: 8))
        try runGit(folder, ["checkout", "-b", "fresh-branch"])
        waitForGit("Contains Git changes", at: folder, in: app)
        XCTAssertFalse(app.scrollViews["fileTree"].staticTexts["fresh-branch"].exists)
        app.terminate()
    }

    @MainActor
    private func verifyGitDirectoryPresentation(repository: URL, folder: URL, app: XCUIApplication) {
        app.buttons["sidebarSection-files"].click()
        XCTAssertTrue(fileRow(repository, in: app).waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["sessionRow-1"].exists)
        app.buttons["sidebarSection-files"].click()
        XCTAssertTrue(fileRow(repository, in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(gitBadge(folder, in: app).exists)
        XCTAssertFalse(app.segmentedControls["File navigation"].exists)
        XCTAssertNotEqual(gitBadge(repository, in: app).elementType, .button)
        XCTAssertFalse(app.scrollViews["fileTree"].staticTexts["feature/sidebar"].exists)
        gitBadge(repository, in: app).click()
        XCTAssertFalse(app.staticTexts["Repository status"].exists)
    }

    @MainActor
    private func verifyGitFileDetails(readme: URL, deleted: URL, app: XCUIApplication) {
        fileRow(readme, in: app).click()
        let text = app.textViews["fileText"]
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        XCTAssertEqual(text.value as? String, "unstaged\n")
        gitBadge(readme, in: app).click()
        XCTAssertTrue(app.staticTexts["Git status"].waitForExistence(timeout: 3))
        XCTAssertEqual(text.value as? String, "unstaged\n", "Inspecting status must preserve the editor")
        app.typeKey(.escape, modifierFlags: [])
        fileRow(deleted, in: app).click()
        XCTAssertTrue(app.staticTexts["File Deleted or Moved"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.textViews["fileText"].exists)
    }

    @MainActor
    private func gitBadge(_ path: URL, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", "gitStatus-\(path.path)")
        ).firstMatch
    }

    @MainActor
    private func waitForGit(_ value: String, at path: URL, in app: XCUIApplication) {
        let badge = gitBadge(path, in: app)
        let ready = expectation(
            for: NSPredicate { _, _ in
                badge.exists && (badge.label + (badge.value as? String ?? "")).contains(value)
            },
            evaluatedWith: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 12), .completed, app.debugDescription)
    }

    private func makeGitRepository(_ folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try runGit(folder, ["init", "-b", "main"])
        for name in ["README.txt", "deleted.txt"] {
            try "initial\n".write(to: folder.appending(path: name), atomically: true, encoding: .utf8)
        }
        try runGit(folder, ["add", "."])
        try runGit(folder, ["commit", "-m", "initial"])
    }

    private func runGit(_ folder: URL, _ arguments: [String], expectedStatus: Int32 = 0) throws {
        let process = Process()
        let executable = try XCTUnwrap(ProcessInfo.processInfo.environment["TWINE_TEST_GIT"])
        process.executableURL = URL(filePath: executable)
        process.arguments =
            ["-c", "user.name=Twine Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false"]
            + arguments
        process.currentDirectoryURL = folder
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        let diagnostics =
            String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "Non-UTF-8 error"
        process.waitUntilExit()
        XCTAssertEqual(
            process.terminationStatus, expectedStatus, "git \(arguments.joined(separator: " ")): \(diagnostics)")
    }
}
