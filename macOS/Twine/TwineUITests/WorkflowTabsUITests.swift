import Darwin
import XCTest

extension TwineUITests {
    @MainActor
    func testWorkflowTabsPreserveIndependentShellsAndCloseTheirProcesses() throws {
        let folder = try workflowFolder()
        let app = try makeApp(lastOpenFolder: folder)
        app.launch()
        let first = app.buttons["workflowTab-1"]
        XCTAssertTrue(first.waitForExistence(timeout: 10), app.debugDescription)
        app.typeText("exec /bin/sh\r")
        app.typeText("TWINE_VALUE=first; echo $$ > first.pid\r")
        let firstPID = try workflowPID(folder.appending(path: "first.pid"))
        defer { killIfAlive(firstPID) }

        app.buttons["newWorkflow"].click()
        let second = app.buttons["workflowTab-2"]
        XCTAssertTrue(second.waitForExistence(timeout: 10), app.debugDescription)
        app.typeText("exec /bin/sh\r")
        app.typeText("TWINE_VALUE=second; echo $$ > second.pid\r")
        let focusScreenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        focusScreenshot.name = "Second workflow after typing"
        focusScreenshot.lifetime = .keepAlways
        add(focusScreenshot)
        let secondPID = try workflowPID(folder.appending(path: "second.pid"))
        defer { killIfAlive(secondPID) }
        XCTAssertNotEqual(firstPID, secondPID)

        first.click()
        app.typeText("{ echo $$; echo $TWINE_VALUE; } > switched.txt\r")
        let switchedFile = folder.appending(path: "switched.txt")
        waitForWorkflowFile(switchedFile, containing: "first")
        let switched = try String(contentsOf: switchedFile, encoding: .utf8)
        XCTAssertEqual(switched.split(separator: "\n").first, String(firstPID)[...])
        XCTAssertEqual(first.value as? String, "Selected")

        // Hover exposes the close control without selecting the inactive workflow.
        second.hover()
        let close = app.buttons["closeWorkflow-2"]
        XCTAssertTrue(close.waitForExistence(timeout: 5), app.debugDescription)
        close.click()
        XCTAssertTrue(second.waitForNonExistence(timeout: 5))
        XCTAssertTrue(workflowProcessExits(secondPID))
        XCTAssertEqual(first.value as? String, "Selected")
        app.typeText("touch survivor\r")
        waitForWorkflowFile(folder.appending(path: "survivor"))

        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(first.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["No Open Tabs"].waitForExistence(timeout: 5))
        XCTAssertTrue(workflowProcessExits(firstPID))
        app.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(app.buttons["workflowTab-3"].waitForExistence(timeout: 5))
        app.terminate()
    }

    @MainActor
    func testOverflowKeepsEachNewSelectedTabVisibleAndCanCloseDuringStartup() throws {
        let folder = try workflowFolder()
        let app = try makeApp(lastOpenFolder: folder)
        app.launch()
        XCTAssertTrue(app.buttons["workflowTab-1"].waitForExistence(timeout: 10))
        resizeWorkflowWindow(app.windows.firstMatch, width: 520)
        for id in 2...10 {
            app.buttons["newWorkflow"].click()
            let selected = app.buttons["workflowTab-\(id)"]
            XCTAssertTrue(selected.waitForExistence(timeout: 5), app.debugDescription)
            let visible = expectation(for: NSPredicate { _, _ in selected.isHittable }, evaluatedWith: nil)
            wait(for: [visible], timeout: 5)
            XCTAssertEqual(selected.value as? String, "Selected")
        }
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = "Workflow overflow in a narrow window"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        // Rapid creation and closure also exercises commands queued during shell startup.
        for _ in 0..<5 {
            app.typeKey("t", modifierFlags: .command)
            app.typeKey("w", modifierFlags: .command)
        }
        app.buttons["Start Page"].click()
        XCTAssertTrue(app.staticTexts["Welcome to Twine"].waitForExistence(timeout: 10))
        app.terminate()
    }

    @MainActor
    func testClosingTheWindowStopsItsWorkflowShell() throws {
        let folder = try workflowFolder()
        let app = try makeApp(lastOpenFolder: folder)
        app.launch()
        XCTAssertTrue(app.buttons["workflowTab-1"].waitForExistence(timeout: 10))
        app.typeText("exec /bin/sh\r")
        app.typeText("echo $$ > window.pid\r")
        let processID = try workflowPID(folder.appending(path: "window.pid"))
        defer { killIfAlive(processID) }
        app.windows.firstMatch.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(workflowProcessExits(processID), "The shell survived window closure")
        app.terminate()
    }

    private func workflowFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "TwineWorkflowUITests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    @MainActor
    private func waitForWorkflowFile(_ file: URL, containing text: String? = nil) {
        let written = expectation(
            for: NSPredicate { _, _ in
                guard FileManager.default.fileExists(atPath: file.path) else { return false }
                guard let text else { return true }
                return (try? String(contentsOf: file, encoding: .utf8).contains(text)) == true
            }, evaluatedWith: nil)
        wait(for: [written], timeout: 10)
    }

    @MainActor
    private func workflowPID(_ file: URL) throws -> pid_t {
        waitForWorkflowFile(file)
        return try XCTUnwrap(
            pid_t(String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    private func workflowProcessExits(_ processID: pid_t) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while processIsAlive(processID) && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        return !processIsAlive(processID)
    }

    private func processIsAlive(_ processID: pid_t) -> Bool { kill(processID, 0) == 0 || errno != ESRCH }

    private func killIfAlive(_ processID: pid_t) {
        if processIsAlive(processID) { _ = kill(processID, SIGKILL) }
    }

    @MainActor
    private func resizeWorkflowWindow(_ window: XCUIElement, width: CGFloat) {
        let rightEdge = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5))
            .withOffset(CGVector(dx: -1, dy: 0))
        let target = window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: width - 1, dy: window.frame.height / 2))
        rightEdge.click(forDuration: 0.2, thenDragTo: target)
    }
}
