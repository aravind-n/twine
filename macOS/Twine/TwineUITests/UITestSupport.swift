import Darwin
import XCTest

/// Helpers for tests that drive shells in a folder. UI tests run only in CI, so their waits explain
/// what they found when they time out.
extension TwineUITests {
    /// Disk persistence precedes live reload; wait until the editor finishes both before interacting.
    @MainActor
    func waitForSave(in app: XCUIApplication) {
        let button = app.buttons["saveFile"].firstMatch
        let saved = expectation(
            for: NSPredicate { _, _ in
                button.exists && button.label == "Save"
            }, evaluatedWith: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 10), .completed, app.debugDescription)
    }

    /// Scope dialog buttons to onscreen controls so Touch Bar duplicates cannot intercept clicks.
    @MainActor
    func clickDialogButton(_ title: String, in app: XCUIApplication) {
        for query in [app.dialogs.buttons, app.sheets.buttons, app.windows.buttons] {
            let button = query[title].firstMatch
            if button.exists {
                button.click()
                return
            }
        }
        XCTFail("Dialog button not found: \(title)\n\(app.debugDescription)")
    }

    /// Restrict the system control's label to toolbars so file rows cannot match it.
    @MainActor
    func sidebarToggleButtons(in app: XCUIApplication) -> XCUIElementQuery {
        app.toolbars.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Sidebar"))
    }

    @MainActor
    func sidebarToggle(in app: XCUIApplication) -> XCUIElement {
        sidebarToggleButtons(in: app).firstMatch
    }

    /// A new folder under the temporary directory, deleted when the test ends.
    func makeTestFolder(prefix: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    /// Waits for a shell to write `text` into `file`, and fails with the file's contents and the
    /// accessibility tree if it doesn't.
    @MainActor
    func waitForFile(
        _ file: URL, containing text: String, in app: XCUIApplication,
        file sourceFile: StaticString = #filePath, line: UInt = #line
    ) {
        let written = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                (try? String(contentsOf: file, encoding: .utf8).contains(text)) == true
            }, object: nil)
        guard XCTWaiter.wait(for: [written], timeout: 10) != .completed else { return }
        let contents = (try? String(contentsOf: file, encoding: .utf8)).map { "\"\($0)\"" } ?? "missing"
        XCTFail(
            "\(file.lastPathComponent) never contained \"\(text)\"; it is \(contents)\n\(app.debugDescription)",
            file: sourceFile, line: line)
    }

    /// The process ID a shell wrote into `file`.
    @MainActor
    func writtenProcessID(
        in file: URL, app: XCUIApplication, sourceFile: StaticString = #filePath, line: UInt = #line
    ) throws -> pid_t {
        waitForFile(file, containing: "\n", in: app, file: sourceFile, line: line)
        let contents = try String(contentsOf: file, encoding: .utf8)
        return try XCTUnwrap(
            pid_t(contents.trimmingCharacters(in: .whitespacesAndNewlines)),
            "\(file.lastPathComponent) holds \"\(contents)\", not a process ID", file: sourceFile, line: line)
    }

    /// Whether the process is gone, or goes within five seconds.
    func processEnds(_ processID: pid_t) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while processIsRunning(processID) && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        return !processIsRunning(processID)
    }

    func endProcessIfRunning(_ processID: pid_t) {
        if processIsRunning(processID) { _ = kill(processID, SIGKILL) }
    }

    /// Opens a workflow whose agents run shells, from the debug-only File menu.
    @MainActor
    func openTestWorkflow(agents: Int, in app: XCUIApplication) {
        app.menuBars.menuBarItems["File"].click()
        let menu = app.menuBars.menuItems["New Test Workflow"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5), app.debugDescription)
        menu.hover()
        let item = menu.menuItems[agents == 1 ? "1 Agent" : "\(agents) Agents"]
        XCTAssertTrue(item.waitForExistence(timeout: 5), app.debugDescription)
        item.click()
    }

    /// Replaces each agent's login shell with `sh`, tags it with a variable, and returns its PID.
    @MainActor
    func startShells(in subtabs: [XCUIElement], folder: URL, app: XCUIApplication) throws -> [pid_t] {
        var processIDs: [pid_t] = []
        for (index, subtab) in subtabs.enumerated() {
            subtab.click()
            waitUntilSelected(subtab, in: app)
            app.typeText("exec /bin/sh\r")
            app.typeText("TWINE_AGENT=agent\(index); echo $$ > agent\(index).pid\r")
            processIDs.append(try writtenProcessID(in: folder.appending(path: "agent\(index).pid"), app: app))
        }
        XCTAssertEqual(Set(processIDs).count, subtabs.count, "Each agent needs its own shell")
        return processIDs
    }

    @MainActor
    func waitUntilSelected(_ element: XCUIElement, in app: XCUIApplication) {
        let selected = expectation(for: NSPredicate(format: "value == 'Selected'"), evaluatedWith: element)
        let result = XCTWaiter.wait(for: [selected], timeout: 5)
        XCTAssertEqual(result, .completed, "\(element) wasn't selected\n\(app.debugDescription)")
    }

    @MainActor
    func attachScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func processIsRunning(_ processID: pid_t) -> Bool { kill(processID, 0) == 0 || errno != ESRCH }
}
