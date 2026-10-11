import Darwin
import XCTest

extension TwineUITests {
    @MainActor
    func testClaudeMinimapDotsSelectTheirTraceAndScrollToThePrompt() throws {
        let folder = try makeFolder()
        try writeTraceAgent(in: folder)
        let app = try makeApp(lastOpenFolder: folder)
        defer { app.terminate() }
        app.launchEnvironment["SHELL"] = "/bin/sh"
        app.launchEnvironment["TWINE_HARNESS_PATH"] = "\(folder.path)/bin:/bin:/usr/bin"
        // The child must override inherited fullscreen preferences for its own terminal.
        app.launchEnvironment["CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN"] = "0"
        app.launchEnvironment["CLAUDE_CODE_NO_FLICKER"] = "1"
        app.launch()
        XCTAssertTrue(app.buttons["workflowTab-1"].waitForExistence(timeout: 10), app.debugDescription)
        element("workflowChoice-Terminal", in: app).click()
        app.typeText("mkdir bin; printf '#!/bin/sh\\n' > bin/claude; cat stub.txt >> bin/claude; chmod +x bin/claude\r")
        let installed = expectation(
            for: NSPredicate { _, _ in
                FileManager.default.isExecutableFile(atPath: folder.appending(path: "bin/claude").path)
            }, evaluatedWith: nil)
        wait(for: [installed], timeout: 10)
        app.buttons["newWorkflow"].click()
        chooseHarness("claudeCode", displayName: "Claude Code", in: app)
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 1000, height: 800))
        waitForFile(folder.appending(path: "agent-ready"), containing: "1", in: app)
        let map = element("terminalMinimap", in: app)
        XCTAssertTrue(map.waitForExistence(timeout: 10), app.debugDescription)
        map.hover()
        let marker = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'minimapStep-'")).firstMatch
        XCTAssertTrue(marker.waitForExistence(timeout: 10), app.debugDescription)
        let id = marker.identifier.replacingOccurrences(of: "minimapStep-", with: "")
        marker.click()
        XCTAssertTrue(app.buttons["traceSpan-\(id)"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.buttons["minimapReturnToLive"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.textViews["terminalHistoryText"].exists, app.debugDescription)
        attachAgentWindow(in: app, name: "Claude minimap dot and matching prompt trace")
        app.buttons["minimapReturnToLive"].click()
        app.typeText("follow-up\r")
        waitForFile(folder.appending(path: "agent-input"), containing: "follow-up", in: app)
    }

    private func writeTraceAgent(in folder: URL) throws {
        try #"""
        case "$1" in --help) exit 0 ;; esac
        while [ "$#" -gt 0 ]; do
            if [ "$1" = --settings ]; then settings="$2"; break; fi
            shift
        done
        prompt_hook=$(/usr/bin/plutil -extract hooks.UserPromptSubmit.0.hooks.0.command raw -o - "$settings")
        stop_hook=$(/usr/bin/plutil -extract hooks.Stop.0.hooks.0.command raw -o - "$settings")
        stty -echo
        printf 'earlier\n❯ Check output\n──────────\n? for shortcuts\n'
        printf '%s' '{"hook_event_name":"UserPromptSubmit","session_id":"fixture","prompt":"Check output"}' \
            | /bin/sh -c "$prompt_hook"
        i=0
        while [ "$i" -lt 120 ]; do printf 'response-%s\n' "$i"; i=$((i+1)); done
        printf '%s' '{"hook_event_name":"Stop","session_id":"fixture","last_assistant_message":"Checked."}' \
            | /bin/sh -c "$stop_hook"
        printf '%s\n' "$CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN" > agent-ready
        read line
        printf '%s' "$line" > agent-input
        while :; do sleep 1; done
        """#.write(to: folder.appending(path: "stub.txt"), atomically: true, encoding: .utf8)
    }

    /// Verify OSC 10/11 replies through a real agent PTY. UI setup and CI scheduling
    /// make this unsuitable for enforcing a harness's 250 ms startup deadline.
    @MainActor
    func testAgentReceivesTerminalColors() throws {
        let folder = try makeFolder()
        try writeColorProbe(in: folder)
        let app = try makeApp(lastOpenFolder: folder)
        defer { app.terminate() }
        app.launchEnvironment["SHELL"] = "/bin/sh"
        app.launchEnvironment["TWINE_HARNESS_PATH"] = "\(folder.path)/bin:/bin:/usr/bin"
        app.launch()
        XCTAssertTrue(app.buttons["workflowTab-1"].waitForExistence(timeout: 10), app.debugDescription)
        element("workflowChoice-Terminal", in: app).click()
        app.typeText("mkdir bin; printf '#!/bin/sh\\n' > bin/pi; cat stub.txt >> bin/pi; chmod +x bin/pi\r")
        let installed = expectation(
            for: NSPredicate { _, _ in
                FileManager.default.isExecutableFile(atPath: folder.appending(path: "bin/pi").path)
            }, evaluatedWith: nil)
        wait(for: [installed], timeout: 10)
        app.buttons["newWorkflow"].click()
        chooseHarness("pi", in: app)
        let resultFile = folder.appending(path: "color-probe.txt")
        waitForFile(resultFile, containing: "\n", in: app)
        let result = try String(contentsOf: resultFile, encoding: .utf8)
        let attachment = XCTAttachment(string: result)
        attachment.name = "Agent startup color probe"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertTrue(result.hasPrefix("PASS after "), result)
    }

    private func writeColorProbe(in folder: URL) throws {
        try #"""
        use strict;
        use warnings;
        use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);
        $| = 1;
        my $started = clock_gettime(CLOCK_MONOTONIC);
        my $deadline = $started + 5.0;
        print "\e[6n\e]10;?\e\\\e]11;?\e\\\e[?u\e[c";
        my $reply = '';
        my $first_reply;
        my $complete = 0;
        my $finished;
        while (my $remaining = $deadline - clock_gettime(CLOCK_MONOTONIC)) {
            last if $remaining <= 0;
            my $readable = '';
            vec($readable, 0, 1) = 1;
            last unless select($readable, undef, undef, $remaining) > 0;
            last unless sysread(STDIN, my $chunk, 4096);
            $first_reply //= clock_gettime(CLOCK_MONOTONIC);
            $reply .= $chunk;
            if ($reply =~ /\e\]10;rgb:[0-9a-f\/]+(?:\a|\e\\)/i
                && $reply =~ /\e\]11;rgb:[0-9a-f\/]+(?:\a|\e\\)/i) {
                $finished = clock_gettime(CLOCK_MONOTONIC);
                $complete = $finished <= $deadline;
                last;
            }
        }
        open(my $result, '>', 'color-probe.txt') or die $!;
        printf $result "%s after %.1f ms\n", $complete ? 'PASS' : 'TIMEOUT',
            (($finished // clock_gettime(CLOCK_MONOTONIC)) - $started) * 1000;
        printf $result "First reply: %s\nReply (hex): %s\n",
            defined($first_reply) ? sprintf('%.1f ms', ($first_reply - $started) * 1000) : 'none',
            unpack('H*', $reply);
        close($result);
        print "\r\nColor probe complete\r\n";
        sleep 30;
        """#.write(to: folder.appending(path: "probe.pl"), atomically: true, encoding: .utf8)
        try """
        case "$1" in --list-models|--help) exit 0 ;; esac
        stty raw -echo
        exec /usr/bin/perl ./probe.pl

        """.write(
            to: folder.appending(path: "stub.txt"), atomically: true, encoding: .utf8)
    }

    @MainActor
    func testForceQuitPreservesAgentOutputAndCanResumeItsSession() throws {
        let folder = try makeFolder()
        try """
        echo $$ > agent.pid
        echo CRASH-HISTORY
        printf '%s\\n' "$@" > agent-arguments
        read line
        echo "$line" > resumed-input
        """.write(to: folder.appending(path: "stub.txt"), atomically: true, encoding: .utf8)
        let app = try makeApp(lastOpenFolder: folder)
        defer { app.terminate() }
        app.launchEnvironment["SHELL"] = "/bin/sh"
        app.launchEnvironment["TWINE_HARNESS_PATH"] = "\(folder.path)/bin:/bin:/usr/bin"
        app.launch()
        XCTAssertTrue(app.buttons["workflowTab-1"].waitForExistence(timeout: 10), app.debugDescription)
        element("workflowChoice-Terminal", in: app).click()
        let installer =
            "echo $PPID > twine.pid; mkdir bin; printf '#!/bin/sh\\n' > bin/pi; "
            + "cat stub.txt >> bin/pi; chmod +x bin/pi\r"
        app.typeText(installer)
        let installed = expectation(
            for: NSPredicate { _, _ in
                FileManager.default.isExecutableFile(atPath: folder.appending(path: "bin/pi").path)
            },
            evaluatedWith: nil)
        wait(for: [installed], timeout: 10)
        app.buttons["newWorkflow"].click()
        chooseHarness("pi", in: app)
        XCTAssertTrue(app.staticTexts["Running"].waitForExistence(timeout: 10), app.debugDescription)
        let agentStarted = expectation(
            for: NSPredicate { _, _ in FileManager.default.fileExists(atPath: folder.appending(path: "agent.pid").path)
            },
            evaluatedWith: nil)
        wait(for: [agentStarted], timeout: 10)
        let processID = try XCTUnwrap(pid(in: folder.appending(path: "twine.pid")))
        guard processID > 1 else { throw NSError(domain: "Invalid crash fixture PID", code: 1) }
        XCTAssertEqual(kill(processID, SIGKILL), 0)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))

        app.launch()
        XCTAssertTrue(app.buttons["workflowTab-2"].waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["workflowTab-2"].click()
        XCTAssertTrue(app.staticTexts["restoredWorkflowNotice"].waitForExistence(timeout: 10), app.debugDescription)
        assertSavedOutput("CRASH-HISTORY", in: app)
        app.buttons["returnToLive"].click()
        XCTAssertTrue(app.staticTexts["Interrupted"].exists, app.debugDescription)
        XCTAssertFalse(app.staticTexts["Completed"].exists)
        attachAgentWindow(in: app, name: "Force-quit agent recovered as interrupted")
        resumeTestAgentSession(in: app, folder: folder)

        app.buttons["workflowTab-1"].click()
        app.typeText("printf '%s' RECOVERED-INPUT > recovered-input.txt\r")
        waitForFile(folder.appending(path: "recovered-input.txt"), containing: "RECOVERED-INPUT")
    }

    @MainActor
    private func resumeTestAgentSession(in app: XCUIApplication, folder: URL) {
        app.buttons["resumeAgentSession"].click()
        let session = app.textFields["resumeSessionID"]
        XCTAssertTrue(session.waitForExistence(timeout: 5), app.debugDescription)
        session.click()
        session.typeText("/tmp/twine-fixture-session.jsonl")
        app.sheets.buttons["Resume"].click()
        XCTAssertTrue(app.staticTexts["Running"].waitForExistence(timeout: 10), app.debugDescription)
        waitForFile(folder.appending(path: "agent-arguments"), containing: "/tmp/twine-fixture-session.jsonl", in: app)
        app.typeText("RESUMED-INPUT\r")
        waitForFile(folder.appending(path: "resumed-input"), containing: "RESUMED-INPUT", in: app)
    }

    /// Starts a stub `pi` from the new-tab card without a prompt, types to it, and cancels it.
    @MainActor
    func testSingleAgentStartsInteractivelyTakesInputAndCancels() throws {
        let folder = try makeFolder()
        // The UI test runner is sandboxed, and macOS won't let Twine execute a script that it wrote.
        // So the runner only writes the script's text, and Twine's own shell installs the executable.
        try """
        echo $$ > agent.pid
        for argument in "$@"; do [ "$argument" = -- ] && echo prompt > agent-args.txt; done
        echo STUB-AGENT-READY
        read line
        printf '%s' "$line" > agent-input.txt
        trap '' HUP
        while :; do sleep 1; done
        """.write(to: folder.appending(path: "stub.txt"), atomically: true, encoding: .utf8)
        let harnesses = folder.appending(path: "bin")
        let app = try makeApp(lastOpenFolder: folder)
        // The fixture's installer uses a predictable shell without the user's interactive configuration.
        app.launchEnvironment["SHELL"] = "/bin/sh"
        app.launchEnvironment["TWINE_HARNESS_PATH"] = "\(harnesses.path(percentEncoded: false)):/bin:/usr/bin"
        app.launch()
        XCTAssertTrue(app.buttons["workflowTab-1"].waitForExistence(timeout: 10), app.debugDescription)
        sidebarToggle(in: app).click()
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 520, height: 302))
        element("workflowChoice-Terminal", in: app).click()
        app.typeText("mkdir bin; printf '#!/bin/sh\\n' > bin/pi; cat stub.txt >> bin/pi; chmod +x bin/pi\r")
        let installed = expectation(
            for: NSPredicate { _, _ in
                FileManager.default.isExecutableFile(atPath: harnesses.appending(path: "pi").path)
            }, evaluatedWith: nil)
        wait(for: [installed], timeout: 10)

        app.buttons["newWorkflow"].click()
        XCTAssertTrue(app.buttons["workflowTab-2"].waitForExistence(timeout: 10), app.debugDescription)
        chooseHarness("pi", in: app)

        XCTAssertTrue(app.staticTexts["Running"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(element("newTabChoices", in: app).waitForNonExistence(timeout: 10), app.debugDescription)
        attachAgentWindow(in: app, name: "Running single agent")
        let pid = try XCTUnwrap(
            pid(in: folder.appending(path: "agent.pid")), "The agent should have recorded its process ID")

        app.typeText("typed input\r")
        waitForFile(folder.appending(path: "agent-input.txt"), containing: "typed input")
        // The stub checks its arguments before it reads input.
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: folder.appending(path: "agent-args.txt").path),
            "The agent starts without a prompt")

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
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 900, height: 620))

        chooseHarness("pi", in: app)

        let failure = app.staticTexts["agentStartFailure"]
        XCTAssertTrue(failure.waitForExistence(timeout: 10), app.debugDescription)
        // SwiftUI puts the message in the element's value, not its label.
        let message = failure.value as? String ?? ""
        XCTAssertTrue(message.contains("wasn't found on your PATH"), message)
        XCTAssertTrue(app.staticTexts["Draft"].exists, "The tab is still a draft")
        XCTAssertTrue(
            element("workflowChoice-Single agent", in: app).exists, "The choices stay so another harness can be tried")
        attachAgentWindow(in: app, name: "Missing harness message")
        app.terminate()
    }

    /// Starts `harness` with its default model from the Single agent tile's menu.
    @MainActor
    private func chooseHarness(_ harness: String, displayName: String? = nil, in app: XCUIApplication) {
        let tile = element("workflowChoice-Single agent", in: app)
        XCTAssertTrue(tile.waitForExistence(timeout: 10), app.debugDescription)
        tile.click()
        let item = app.menuItems[displayName ?? harness]
        XCTAssertTrue(item.waitForExistence(timeout: 5), app.debugDescription)
        item.click()
        // Stub harnesses list no models or effort levels, so the default model starts it directly.
        // SwiftUI doesn't carry identifiers into nested submenus, so find it by title in the harness's.
        let defaultModel = app.menuItems["harness-\(harness)"].menuItems["Default model"]
        XCTAssertTrue(defaultModel.waitForExistence(timeout: 5), app.debugDescription)
        defaultModel.click()
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
