import Darwin
import XCTest

extension TwineUITests {
    @MainActor
    func testAgentSubtabsKeepEachShellAndEachWorkflowRemembersItsSubtab() throws {
        let folder = try makeTestFolder(prefix: "TwineAgentUITests")
        let app = try makeApp(lastOpenFolder: folder)
        app.launch()
        let draft = app.buttons["workflowTab-1"]
        XCTAssertTrue(draft.waitForExistence(timeout: 10), app.debugDescription)
        let allSubtabs = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "agentSubtab-"))
        openTestWorkflow(agents: 3, in: app)
        let agentsTab = app.buttons["workflowTab-2"]
        XCTAssertTrue(agentsTab.waitForExistence(timeout: 10), app.debugDescription)
        // A fresh database numbers the agents from 1, in role order.
        let subtabs = (1...3).map { app.buttons["agentSubtab-\($0)"] }
        XCTAssertTrue(subtabs[2].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(subtabs.map(\.label), ["Implementer", "Reviewer", "Coordinator"], app.debugDescription)
        XCTAssertEqual(subtabs[0].value as? String, "Selected", app.debugDescription)

        let processIDs = try startShells(in: subtabs, folder: folder, app: app)
        defer { processIDs.forEach(endProcessIfRunning) }
        try checkShellsSurviveSwitching(subtabs, processIDs: processIDs, folder: folder, app: app)

        // Each workflow keeps its own subtab.
        subtabs[1].click()
        waitUntilSelected(subtabs[1], in: app)
        openTestWorkflow(agents: 3, in: app)
        let otherTab = app.buttons["workflowTab-3"]
        XCTAssertTrue(otherTab.waitForExistence(timeout: 10), app.debugDescription)
        let otherCoordinator = app.buttons["agentSubtab-6"]
        XCTAssertTrue(otherCoordinator.waitForExistence(timeout: 10), app.debugDescription)
        otherCoordinator.click()
        waitUntilSelected(otherCoordinator, in: app)
        agentsTab.click()
        waitUntilSelected(subtabs[1], in: app)
        app.typeText("echo $TWINE_AGENT > remembered.txt\r")
        waitForFile(folder.appending(path: "remembered.txt"), containing: "agent1", in: app)
        otherTab.click()
        waitUntilSelected(otherCoordinator, in: app)
        draft.click()
        waitUntilSelected(draft, in: app)
        XCTAssertEqual(allSubtabs.count, 0, "A workflow without agents shows no subtabs\n\(app.debugDescription)")
        XCTAssertFalse(app.staticTexts["TERMINAL"].exists, "A workflow without agents shows no subtab strip")
        agentsTab.click()
        waitUntilSelected(subtabs[1], in: app)
        attachScreenshot(of: app, named: "Agent subtabs with Reviewer selected")

        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(agentsTab.waitForNonExistence(timeout: 5), app.debugDescription)
        for processID in processIDs {
            XCTAssertTrue(processEnds(processID), "Closing the workflow left agent \(processID) running")
        }
        app.terminate()
    }

    @MainActor
    func testAgentsKeepTheirTerminalAtTheMinimumWindowSizeInDarkAppearance() throws {
        let folder = try makeTestFolder(prefix: "TwineAgentUITests")
        let app = try makeApp(lastOpenFolder: folder)
        app.launchEnvironment["TWINE_TEST_APPEARANCE"] = "Dark"
        app.launch()
        XCTAssertTrue(app.buttons["workflowTab-1"].waitForExistence(timeout: 10), app.debugDescription)
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 900, height: 620))
        let allSubtabs = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "agentSubtab-"))

        openTestWorkflow(agents: 1, in: app)
        XCTAssertTrue(app.buttons["workflowTab-2"].waitForExistence(timeout: 10), app.debugDescription)
        app.typeText("printf '%s\\n' single > single.txt\r")
        waitForFile(folder.appending(path: "single.txt"), containing: "single", in: app)
        XCTAssertEqual(allSubtabs.count, 0, "One agent shows no subtabs\n\(app.debugDescription)")
        XCTAssertFalse(app.staticTexts["TERMINAL"].exists, "One agent shows no subtab strip")

        openTestWorkflow(agents: 3, in: app)
        XCTAssertTrue(app.buttons["workflowTab-3"].waitForExistence(timeout: 10), app.debugDescription)
        // The single agent took ID 1, so this workflow's Coordinator is agent 4.
        let coordinator = app.buttons["agentSubtab-4"]
        XCTAssertTrue(coordinator.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(allSubtabs.count, 3, app.debugDescription)
        coordinator.click()
        waitUntilSelected(coordinator, in: app)
        attachScreenshot(of: app, named: "Dark, three agent subtabs")

        // The title bar adds 52 points to the 400 × 250 minimum content size.
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 400, height: 302))
        XCTAssertTrue(coordinator.isHittable, "The selected subtab should scroll into view\n\(app.debugDescription)")
        app.typeText("exec /bin/sh\r")
        app.typeText("stty size > rows.txt\r")
        let rowsFile = folder.appending(path: "rows.txt")
        waitForFile(rowsFile, containing: " ", in: app)
        let size = try String(contentsOf: rowsFile, encoding: .utf8)
        let rows = try XCTUnwrap(Int(size.split(separator: " ").first ?? ""), "stty wrote \"\(size)\"")
        XCTAssertGreaterThanOrEqual(rows, 2, "The shown agent needs visible rows in a minimum-size window")
        attachScreenshot(of: app, named: "Dark, three agent subtabs at the minimum window size")
        app.terminate()
    }

    /// Replaces each agent's login shell with `sh`, tags it with a variable, and returns its PID.
    @MainActor
    private func startShells(in subtabs: [XCUIElement], folder: URL, app: XCUIApplication) throws -> [pid_t] {
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

    /// Switching back to each subtab finds its shell as it was left: the same process and variable.
    @MainActor
    private func checkShellsSurviveSwitching(
        _ subtabs: [XCUIElement], processIDs: [pid_t], folder: URL, app: XCUIApplication
    ) throws {
        for index in [1, 0, 2] {
            subtabs[index].click()
            waitUntilSelected(subtabs[index], in: app)
            app.typeText("{ echo $$; echo $TWINE_AGENT; } > check\(index).txt\r")
            let check = folder.appending(path: "check\(index).txt")
            waitForFile(check, containing: "agent\(index)", in: app)
            let lines = try String(contentsOf: check, encoding: .utf8).split(separator: "\n")
            XCTAssertEqual(lines.first, String(processIDs[index])[...], "Switching subtabs restarted a shell")
        }
    }

    /// Opens a workflow whose agents run shells, from the debug-only File menu.
    @MainActor
    private func openTestWorkflow(agents: Int, in app: XCUIApplication) {
        app.menuBars.menuBarItems["File"].click()
        let menu = app.menuBars.menuItems["New Test Workflow"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5), app.debugDescription)
        menu.hover()
        let item = menu.menuItems[agents == 1 ? "1 Agent" : "\(agents) Agents"]
        XCTAssertTrue(item.waitForExistence(timeout: 5), app.debugDescription)
        item.click()
    }

    @MainActor
    private func waitUntilSelected(_ element: XCUIElement, in app: XCUIApplication) {
        let selected = expectation(for: NSPredicate(format: "value == 'Selected'"), evaluatedWith: element)
        let result = XCTWaiter.wait(for: [selected], timeout: 5)
        XCTAssertEqual(result, .completed, "\(element) wasn't selected\n\(app.debugDescription)")
    }
}
