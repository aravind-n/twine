import Darwin
import XCTest

extension TwineUITests {
    @MainActor
    func testBentoPanesKeepEachShellAndMoveTheKeyboardBetweenThem() throws {
        let folder = try makeTestFolder(prefix: "TwineBentoUITests")
        let app = try makeApp(lastOpenFolder: folder)
        app.launch()
        XCTAssertTrue(app.buttons["workflowTab-1"].waitForExistence(timeout: 10), app.debugDescription)
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 1100, height: 760))
        openTestWorkflow(agents: 3, in: app)
        let subtabs = (1...3).map { app.buttons["agentSubtab-\($0)"] }
        XCTAssertTrue(subtabs[2].waitForExistence(timeout: 10), app.debugDescription)
        let shells = try BentoShells(processIDs: startShells(in: subtabs, folder: folder, app: app), folder: folder)
        defer { shells.processIDs.forEach(endProcessIfRunning) }

        // Bento mode shows every agent's shell, and the Reviewer keeps the keyboard.
        subtabs[1].click()
        waitUntilSelected(subtabs[1], in: app)
        let layout = app.radioGroups["agentLayout"]
        layout.radioButtons["Bento"].click()
        let panes = (1...3).map { app.menuButtons["agentPane-\($0)"] }
        XCTAssertTrue(panes[2].waitForExistence(timeout: 5), app.debugDescription)
        waitUntilFocused(panes[1], in: app)
        try checkKeyboardReaches(agent: 1, of: shells, app: app)
        try checkKeyboardMovesBetweenPanes(panes, shells: shells, app: app)
        try checkPanesCanBeChosenAndResized(panes, shells: shells, app: app)
        attachScreenshot(of: app, named: "Bento panes, the Coordinator moved first and widened")
        try checkKeyboardReturnsWithTheWorkflow(to: panes[2], agent: 2, shells: shells, app: app)

        // Tab mode shows the focused agent alone, and every shell is still the one it started.
        layout.radioButtons["Tabs"].click()
        XCTAssertTrue(panes[0].waitForNonExistence(timeout: 5), app.debugDescription)
        waitUntilSelected(subtabs[2], in: app)
        try checkKeyboardReaches(agent: 2, of: shells, app: app)
        for index in [0, 1] {
            subtabs[index].click()
            waitUntilSelected(subtabs[index], in: app)
            try checkKeyboardReaches(agent: index, of: shells, app: app)
        }

        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.buttons["workflowTab-2"].waitForNonExistence(timeout: 5), app.debugDescription)
        for processID in shells.processIDs {
            XCTAssertTrue(processEnds(processID), "Closing the workflow left agent \(processID) running")
        }
        app.terminate()
    }

    @MainActor
    func testBentoLayoutPersistsAcrossRelaunchAndSmallWindowsShowFewerPanes() throws {
        let folder = try makeTestFolder(prefix: "TwineBentoUITests")
        let app = try makeApp(lastOpenFolder: folder)
        app.launchEnvironment["TWINE_TEST_APPEARANCE"] = "Dark"
        app.launch()
        XCTAssertTrue(app.buttons["workflowTab-1"].waitForExistence(timeout: 10), app.debugDescription)
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 1100, height: 760))
        openTestWorkflow(agents: 4, in: app)
        let subtabs = (1...4).map { app.buttons["agentSubtab-\($0)"] }
        XCTAssertTrue(subtabs[3].waitForExistence(timeout: 10), app.debugDescription)

        // Four panes make a grid. The Worker takes the first pane, and the first column narrows.
        app.menuBars.menuBarItems["View"].click()
        app.menuItems["Bento Panes"].click()
        let panes = (1...4).map { app.menuButtons["agentPane-\($0)"] }
        XCTAssertTrue(panes[3].waitForExistence(timeout: 5), app.debugDescription)
        panes[0].click()
        app.menuItems["Worker"].click()
        waitUntilFocused(panes[3], in: app)
        // A login shell's prompt can outgrow a minimum-size terminal, so the Worker runs `sh`.
        app.typeText("exec /bin/sh\r")
        let divider = app.otherElements["columnDivider"]
        drag(divider, by: -150)
        XCTAssertLessThan(divider.frame.midX, app.windows.firstMatch.frame.midX - 100, app.debugDescription)
        attachScreenshot(of: app, named: "Dark, four Bento panes")
        try checkSmallWindowsShowFewerPanes(panes, subtabs: subtabs, folder: folder, app: app)

        // The layout comes back after relaunch, with the Worker first and focused.
        let dataDirectory = try XCTUnwrap(app.launchEnvironment["TWINE_DATA_DIRECTORY"])
        let saved = URL(filePath: dataDirectory).appending(path: "workflow-layouts.json")
        waitForFile(saved, containing: "\"focusedAgentID\":4", in: app)
        app.terminate()
        app.launch()
        let agentsTab = app.buttons["workflowTab-2"]
        XCTAssertTrue(agentsTab.waitForExistence(timeout: 10), app.debugDescription)
        agentsTab.click()
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 1100, height: 760))
        XCTAssertTrue(panes[3].waitForExistence(timeout: 10), app.debugDescription)
        waitUntilFocused(panes[3], in: app)
        XCTAssertLessThan(panes[3].frame.minY, panes[1].frame.minY, "The Worker should sit above the Reviewer")
        XCTAssertLessThan(panes[3].frame.minX, panes[2].frame.minX, "The Worker's column should come first")
        XCTAssertLessThan(divider.frame.midX, app.windows.firstMatch.frame.midX - 50, app.debugDescription)
        attachScreenshot(of: app, named: "Dark, Bento layout restored after relaunch")
        app.terminate()
    }

    /// ⌘] and ⌘[ move the keyboard between panes, wrapping around, and so does a click in a terminal.
    @MainActor
    private func checkKeyboardMovesBetweenPanes(
        _ panes: [XCUIElement], shells: BentoShells, app: XCUIApplication
    ) throws {
        app.typeKey("]", modifierFlags: .command)
        waitUntilFocused(panes[2], in: app)
        try checkKeyboardReaches(agent: 2, of: shells, app: app)
        app.typeKey("]", modifierFlags: .command)
        waitUntilFocused(panes[0], in: app)
        app.typeKey("[", modifierFlags: .command)
        waitUntilFocused(panes[2], in: app)
        panes[1].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).withOffset(CGVector(dx: 0, dy: 80))
            .click()
        waitUntilFocused(panes[1], in: app)
        try checkKeyboardReaches(agent: 1, of: shells, app: app)
    }

    /// Choosing a pane's agent swaps it with the pane that showed it, and dragging the divider
    /// widens the first pane's terminal.
    @MainActor
    private func checkPanesCanBeChosenAndResized(
        _ panes: [XCUIElement], shells: BentoShells, app: XCUIApplication
    ) throws {
        panes[0].click()
        app.menuItems["Coordinator"].click()
        waitUntilFocused(panes[2], in: app)
        XCTAssertLessThan(panes[2].frame.minX, panes[1].frame.minX, "The Coordinator should take the first pane")
        XCTAssertGreaterThan(panes[0].frame.minX, panes[2].frame.minX, "The Implementer should take its pane")
        try checkKeyboardReaches(agent: 2, of: shells, app: app)

        let columns = try terminalSize(folder: shells.folder, app: app).columns
        drag(app.otherElements["columnDivider"], by: 200)
        let widened = try terminalSize(folder: shells.folder, app: app).columns
        XCTAssertGreaterThan(widened, columns + 10, "Dragging the divider didn't widen the pane")
    }

    /// Selecting another workflow hides the panes. Coming back gives the keyboard to the same pane.
    @MainActor
    private func checkKeyboardReturnsWithTheWorkflow(
        to pane: XCUIElement, agent index: Int, shells: BentoShells, app: XCUIApplication
    ) throws {
        let draft = app.buttons["workflowTab-1"]
        draft.click()
        waitUntilSelected(draft, in: app)
        let hidden = [pane, app.radioGroups["agentLayout"]].filter(\.exists)
        XCTAssertTrue(hidden.isEmpty, "Another workflow's tab hides the panes and picker\n\(app.debugDescription)")
        app.buttons["workflowTab-2"].click()
        waitUntilFocused(pane, in: app)
        try checkKeyboardReaches(agent: index, of: shells, app: app)
    }

    /// Panes are Bento panes [Worker, Reviewer, Coordinator, Implementer], with the Worker focused.
    @MainActor
    private func checkSmallWindowsShowFewerPanes(
        _ panes: [XCUIElement], subtabs: [XCUIElement], folder: URL, app: XCUIApplication
    ) throws {
        // A short window keeps one pane per column: the focused one, or the column's first.
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 900, height: 520))
        XCTAssertTrue(panes[1].waitForNonExistence(timeout: 5), "The Reviewer's pane should give way")
        XCTAssertTrue(panes[3].exists && panes[2].exists, "Each column keeps a pane\n\(app.debugDescription)")
        XCTAssertFalse(panes[0].exists, "The Implementer's pane should give way\n\(app.debugDescription)")
        attachScreenshot(of: app, named: "Dark, Bento in a short window")

        // The smallest window keeps only the focused pane, which fills the panel as in tab mode.
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 400, height: 302))
        XCTAssertTrue(panes[3].waitForNonExistence(timeout: 5), "One pane fills the panel without a header")
        waitUntilSelected(subtabs[3], in: app)
        let rows = try terminalSize(folder: folder, app: app).rows
        XCTAssertGreaterThanOrEqual(rows, 2, "The focused agent needs visible rows in a minimum-size window")
        attachScreenshot(of: app, named: "Dark, Bento at the minimum window size")
        app.typeKey("]", modifierFlags: .command)
        waitUntilSelected(subtabs[1], in: app)
        app.typeKey("[", modifierFlags: .command)
        waitUntilSelected(subtabs[3], in: app)
    }

    /// Types into the terminal that has the keyboard and checks that it's the agent's original shell,
    /// and that no terminal was rebuilt, which would lose its place in the output.
    @MainActor
    private func checkKeyboardReaches(agent index: Int, of shells: BentoShells, app: XCUIApplication) throws {
        let file = shells.folder.appending(path: "keyboard-\(UUID().uuidString).txt")
        app.typeText("{ echo $$; echo $TWINE_AGENT; } > \(file.lastPathComponent)\r")
        waitForFile(file, containing: "agent\(index)", in: app)
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.first, String(shells.processIDs[index])[...], "A different shell has the keyboard")
        let outOfOrder = app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "out of order"))
        XCTAssertEqual(outOfOrder.count, 0, "A terminal was rebuilt\n\(app.debugDescription)")
    }

    /// The size of the terminal that has the keyboard, as its shell sees it.
    @MainActor
    private func terminalSize(folder: URL, app: XCUIApplication) throws -> (rows: Int, columns: Int) {
        let file = folder.appending(path: "size-\(UUID().uuidString).txt")
        app.typeText("stty size > \(file.lastPathComponent)\r")
        waitForFile(file, containing: "\n", in: app)
        let size = try String(contentsOf: file, encoding: .utf8)
        let numbers = size.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
        XCTAssertEqual(numbers.count, 2, "stty wrote \"\(size)\"")
        return (numbers.first ?? 0, numbers.last ?? 0)
    }

    /// Drags a divider sideways with the mouse.
    @MainActor
    private func drag(_ divider: XCUIElement, by distance: CGFloat) {
        let grip = divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        grip.click(forDuration: 0.2, thenDragTo: grip.withOffset(CGVector(dx: distance, dy: 0)))
    }

    @MainActor
    private func waitUntilFocused(_ pane: XCUIElement, in app: XCUIApplication) {
        let focused = expectation(for: NSPredicate(format: "value == 'Focused'"), evaluatedWith: pane)
        let result = XCTWaiter.wait(for: [focused], timeout: 5)
        XCTAssertEqual(result, .completed, "\(pane) doesn't have the keyboard\n\(app.debugDescription)")
    }
}

/// Each agent's shell, which `startShells` tagged with `TWINE_AGENT=agent<index>`.
private struct BentoShells {
    let processIDs: [pid_t]
    let folder: URL
}
