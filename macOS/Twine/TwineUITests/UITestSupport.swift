import Darwin
import XCTest

/// Helpers for tests that drive shells in a folder. UI tests run only in CI, so their waits explain
/// what they found when they time out.
extension TwineUITests {
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

    @MainActor
    func attachScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func processIsRunning(_ processID: pid_t) -> Bool { kill(processID, 0) == 0 || errno != ESRCH }
}
