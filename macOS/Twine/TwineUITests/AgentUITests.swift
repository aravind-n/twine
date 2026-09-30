import Darwin
import XCTest

extension TwineUITests {
    /// Starts a stub `pi` from the new-tab card, types to it, and cancels it.
    @MainActor
    func testSingleAgentStartsWithThePromptTakesInputAndCancels() throws {
        let folder = try makeFolder()
        // The UI test runner is sandboxed, and macOS won't let Twine execute a script that it wrote.
        // So the runner only writes the script's text, and Twine's own shell installs the executable.
        try """
        echo $$ > agent.pid
        printf '%s|%s' "$1" "$2" > agent-args.txt
        echo STUB-AGENT-READY
        read line
        printf '%s' "$line" > agent-input.txt
        trap '' HUP
        while :; do sleep 1; done
        """.write(to: folder.appending(path: "stub.txt"), atomically: true, encoding: .utf8)
        let harnesses = folder.appending(path: "bin")
        let app = try makeApp(lastOpenFolder: folder)
        app.launchEnvironment["TWINE_HARNESS_PATH"] = "\(harnesses.path(percentEncoded: false)):/bin:/usr/bin"
        app.launch()
        XCTAssertTrue(app.buttons["workflowTab-1"].waitForExistence(timeout: 10), app.debugDescription)
        // The trace panel leaves less space for the prompt form at the minimum content height.
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 520, height: 302))
        element("workflowChoice-Terminal", in: app).click()
        // Plain commands, since the login shell may be fish rather than a POSIX shell.
        app.typeText("mkdir bin; printf '#!/bin/sh\\n' > bin/pi; cat stub.txt >> bin/pi; chmod +x bin/pi\r")
        let installed = expectation(
            for: NSPredicate { _, _ in
                FileManager.default.isExecutableFile(atPath: harnesses.appending(path: "pi").path)
            }, evaluatedWith: nil)
        wait(for: [installed], timeout: 10)

        app.buttons["newWorkflow"].click()
        XCTAssertTrue(app.buttons["workflowTab-2"].waitForExistence(timeout: 10), app.debugDescription)
        chooseHarness("pi", in: app)
        let prompt = element("agentPrompt", in: app)
        XCTAssertTrue(prompt.waitForExistence(timeout: 10), app.debugDescription)
        attachAgentWindow(in: app, name: "Single agent prompt")
        prompt.click()
        prompt.typeText("fix the bug")
        element("agentStart", in: app).click()

        waitForFile(folder.appending(path: "agent-args.txt"), containing: "--|fix the bug")
        XCTAssertTrue(app.staticTexts["Running"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(element("newTabChoices", in: app).waitForNonExistence(timeout: 10), app.debugDescription)
        attachAgentWindow(in: app, name: "Running single agent")
        let pid = try XCTUnwrap(
            pid(in: folder.appending(path: "agent.pid")), "The agent should have recorded its process ID")

        app.typeText("typed input\r")
        waitForFile(folder.appending(path: "agent-input.txt"), containing: "typed input")

        app.typeKey(".", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["Cancelled"].waitForExistence(timeout: 10), app.debugDescription)
        let stopped = expectation(for: NSPredicate { _, _ in kill(pid, 0) != 0 }, evaluatedWith: nil)
        wait(for: [stopped], timeout: 10)
        XCTAssertTrue(app.buttons["workflowTab-2"].exists, "Cancelling keeps the workflow open")
        attachAgentWindow(in: app, name: "Cancelled single agent")
        app.terminate()
    }

    /// A harness that isn't installed is explained on the card, and the draft is left alone.
    @MainActor
    func testSingleAgentWithAMissingHarnessShowsAMessageAndKeepsTheDraft() throws {
        let folder = try makeFolder()
        let harnesses = try makeEmptyDirectory()
        let app = try makeApp(lastOpenFolder: folder)
        app.launchEnvironment["TWINE_HARNESS_PATH"] = harnesses.path(percentEncoded: false)
        app.launch()
        XCTAssertTrue(app.buttons["workflowTab-1"].waitForExistence(timeout: 10), app.debugDescription)

        chooseHarness("pi", in: app)
        let prompt = element("agentPrompt", in: app)
        XCTAssertTrue(prompt.waitForExistence(timeout: 10), app.debugDescription)
        prompt.click()
        prompt.typeText("hello")
        element("agentStart", in: app).click()

        let failure = app.staticTexts["agentStartFailure"]
        XCTAssertTrue(failure.waitForExistence(timeout: 10), app.debugDescription)
        // SwiftUI puts the message in the element's value, not its label.
        let message = failure.value as? String ?? ""
        XCTAssertTrue(message.contains("wasn't found on your PATH"), message)
        XCTAssertTrue(app.staticTexts["Draft"].exists, "The tab is still a draft")
        XCTAssertTrue(element("agentPrompt", in: app).exists, "The prompt is kept so another harness can be tried")
        attachAgentWindow(in: app, name: "Missing harness message")
        app.terminate()
    }

    /// Picks `harness` from the Single agent tile's menu.
    @MainActor
    private func chooseHarness(_ harness: String, in app: XCUIApplication) {
        let tile = element("workflowChoice-Single agent", in: app)
        XCTAssertTrue(tile.waitForExistence(timeout: 10), app.debugDescription)
        tile.click()
        let item = app.menuItems[harness]
        XCTAssertTrue(item.waitForExistence(timeout: 5), app.debugDescription)
        item.click()
    }

    /// Menus and text fields report different element types, so match on the identifier alone.
    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    private func attachAgentWindow(in app: XCUIApplication, name: String) {
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "TwineAgentUITests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    /// A directory with no harnesses in it.
    private func makeEmptyDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "TwineHarnesses-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func waitForFile(_ file: URL, containing text: String) {
        let written = expectation(
            for: NSPredicate { _, _ in
                (try? String(contentsOf: file, encoding: .utf8)) == text
            }, evaluatedWith: nil)
        wait(for: [written], timeout: 10)
    }

    private func pid(in file: URL) -> pid_t? {
        (try? String(contentsOf: file, encoding: .utf8))
            .flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
}
