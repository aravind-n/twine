import XCTest

extension TwineUITests {
    @MainActor
    func testSidebarToolbarInFullScreenInDarkAppearance() throws {
        try checkFullScreenSidebar(appearance: "Dark")
    }

    @MainActor
    private func checkFullScreenSidebar(appearance: String) throws {
        let folder = try makeTestFolder(prefix: "TwineSidebar")
        let app = try makeApp(lastOpenFolder: folder)
        app.launchEnvironment["TWINE_TEST_APPEARANCE"] = appearance
        app.launch()
        defer { app.terminate() }

        let toggle = sidebarToggle(in: app)
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), app.debugDescription)
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 900, height: 620))
        let root = fileRow(folder, in: app)
        XCTAssertTrue(root.waitForExistence(timeout: 5), app.debugDescription)
        let viewport = app.scrollViews["workspaceViewport"]
        assertSidebarToolbar(in: app, viewport: viewport)
        let windowedHeight = viewport.frame.height

        app.typeKey("f", modifierFlags: .function)
        let entered = expectation(
            for: NSPredicate { _, _ in viewport.frame.height > windowedHeight + 100 }, evaluatedWith: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [entered], timeout: 10), .completed, app.debugDescription)
        assertSidebarToolbar(in: app, viewport: viewport)
        XCTAssertTrue(viewport.frame.contains(app.staticTexts["workflowStatus"].frame), app.debugDescription)

        let sidebarWidth = viewport.frame.width
        toggle.click()
        XCTAssertTrue(root.waitForNonExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(toggle.isHittable, "The show button must remain available in full screen")
        XCTAssertGreaterThan(viewport.frame.width, sidebarWidth)
        XCTAssertGreaterThanOrEqual(app.buttons["newWorkflow"].frame.minY, toggle.frame.maxY)

        app.typeKey("s", modifierFlags: [.command, .control])
        XCTAssertTrue(root.waitForExistence(timeout: 5), app.debugDescription)
        assertSidebarToolbar(in: app, viewport: viewport)
        app.typeKey("f", modifierFlags: .function)
        let exited = expectation(
            for: NSPredicate { _, _ in abs(viewport.frame.height - windowedHeight) < 2 }, evaluatedWith: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [exited], timeout: 10), .completed, app.debugDescription)
        assertSidebarToolbar(in: app, viewport: viewport)
    }

    @MainActor
    private func assertSidebarToolbar(in app: XCUIApplication, viewport: XCUIElement) {
        let toggle = sidebarToggle(in: app)
        XCTAssertEqual(sidebarToggleButtons(in: app).count, 1)
        XCTAssertTrue(toggle.isHittable, app.debugDescription)
        XCTAssertLessThanOrEqual(toggle.frame.maxX, viewport.frame.minX, "Keep the toggle over its sidebar")
        XCTAssertGreaterThanOrEqual(app.buttons["newWorkflow"].frame.minY, toggle.frame.maxY)
    }

    @MainActor
    func testFolderWindowInLightAppearance() throws {
        try checkFolderWindow(appearance: "Light")
    }

    @MainActor
    func testFolderWindowInDarkAppearance() throws {
        try checkFolderWindow(appearance: "Dark")
    }

    @MainActor
    func testDraftAndFooterAtMinimumWindowSizeInLightAppearance() throws {
        try checkMinimumDraftWindow(appearance: "Light")
    }

    @MainActor
    func testDraftAndFooterAtMinimumWindowSizeInDarkAppearance() throws {
        try checkMinimumDraftWindow(appearance: "Dark")
    }

    @MainActor
    private func checkMinimumDraftWindow(appearance: String) throws {
        let folder = try createFolder()
        try FileManager.default.createDirectory(
            at: folder.appending(path: ".git/objects"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: folder.appending(path: ".git/refs/heads"), withIntermediateDirectories: true)
        try "ref: refs/heads/a-long-branch-name-for-checking-footer-truncation\n".write(
            to: folder.appending(path: ".git/HEAD"), atomically: true, encoding: .utf8)
        let app = try makeApp(lastOpenFolder: folder)
        app.launchEnvironment["TWINE_TEST_APPEARANCE"] = appearance
        app.launch()
        let choices = app.scrollViews["newTabChoices"]
        XCTAssertTrue(choices.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["gitBranch"].waitForExistence(timeout: 10), app.debugDescription)
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 900, height: 620))
        attachWindow(in: app, name: "\(appearance), centered draft and footer")

        sidebarToggle(in: app).click()
        // The title bar adds 52 points to the 400 × 250 minimum content size.
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 400, height: 302))
        XCTAssertEqual(app.windows.firstMatch.frame.width, 400, accuracy: 2)
        XCTAssertEqual(app.windows.firstMatch.frame.height, 302, accuracy: 2)
        XCTAssertGreaterThan(choices.frame.minY, app.buttons["newWorkflow"].frame.maxY + 40)
        XCTAssertTrue(app.staticTexts["workflowStatus"].isHittable, app.debugDescription)
        XCTAssertTrue(app.staticTexts["workflowElapsed"].isHittable, app.debugDescription)
        XCTAssertGreaterThan(app.staticTexts["gitBranch"].frame.width, 0)
        attachWindow(in: app, name: "\(appearance), minimum window with visible prompt")

        let coordinator = app.buttons["workflowChoice-Coordinator"]
        for _ in 0..<8 where !coordinator.exists || coordinator.frame.midY > choices.frame.maxY - 4 {
            choices.scroll(byDeltaX: 0, deltaY: -60)
        }
        XCTAssertTrue(coordinator.isHittable, app.debugDescription)
        attachWindow(in: app, name: "\(appearance), minimum window scrolled choices")
        coordinator.click()
        let back = app.buttons["Back"]
        XCTAssertTrue(back.waitForExistence(timeout: 10), app.debugDescription)
        for _ in 0..<12 where back.frame.midY > choices.frame.maxY - 4 {
            choices.scroll(byDeltaX: 0, deltaY: -60)
        }
        XCTAssertTrue(back.isHittable, app.debugDescription)
        back.click()
        app.typeText("printf '%s' compact > compact.txt\r")
        let typed = expectation(
            for: NSPredicate { _, _ in
                (try? String(contentsOf: folder.appending(path: "compact.txt"), encoding: .utf8)) == "compact"
            }, evaluatedWith: nil)
        wait(for: [typed], timeout: 10)
        XCTAssertTrue(choices.waitForNonExistence(timeout: 10), app.debugDescription)
        app.terminate()
    }

    @MainActor
    private func checkFolderWindow(appearance: String) throws {
        let folder = try createFolder()
        let app = try makeApp(lastOpenFolder: folder)
        app.launchEnvironment["TWINE_TEST_APPEARANCE"] = appearance
        app.launch()

        let toggle = sidebarToggle(in: app)
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), app.debugDescription)
        let root = fileRow(folder, in: app)
        XCTAssertTrue(root.waitForExistence(timeout: 5), "The sidebar should start open")
        toggle.click()
        XCTAssertTrue(root.waitForNonExistence(timeout: 5), "The sidebar must remain collapsible")
        let traces = app.descendants(matching: .any).matching(identifier: "tracesHeader").firstMatch
        XCTAssertTrue(traces.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(traces.label, "Traces, collapsed")
        XCTAssertEqual(traces.frame.height, 48, accuracy: 1)

        // The terminal takes typing on open; the subsequent checks also type without clicking it.
        app.typeText("exec /bin/sh\r")
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 900, height: 620))
        let initial = try shellState(in: app, folder: folder, checkpoint: "initial")
        let fullWidth = traces.frame.width
        attachWindow(in: app, name: "\(appearance), sidebar hidden")

        toggle.click()
        XCTAssertTrue(root.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(sidebarToggleButtons(in: app).count, 1)
        XCTAssertEqual(root.label, folder.lastPathComponent)
        XCTAssertEqual(root.value as? String, "Expanded")
        XCTAssertLessThan(traces.frame.width, fullWidth)
        let withSidebar = try shellState(in: app, folder: folder, checkpoint: "sidebar")
        XCTAssertEqual(withSidebar.processID, initial.processID, "Toggling must preserve the live shell")
        XCTAssertLessThan(withSidebar.columns, initial.columns, "The sidebar must resize the PTY")
        XCTAssertGreaterThan(withSidebar.rows, 0)
        attachWindow(in: app, name: "\(appearance), sidebar visible")

        app.typeKey("s", modifierFlags: [.command, .control])
        XCTAssertTrue(root.waitForNonExistence(timeout: 5))
        let hiddenAgain = try shellState(in: app, folder: folder, checkpoint: "hidden")
        XCTAssertEqual(hiddenAgain.processID, initial.processID)
        XCTAssertEqual(hiddenAgain.columns, initial.columns)

        resizeWindow(app.windows.firstMatch, to: CGSize(width: 520, height: 360))
        let narrow = try shellState(in: app, folder: folder, checkpoint: "narrow")
        XCTAssertEqual(narrow.processID, initial.processID)
        XCTAssertLessThan(narrow.columns, initial.columns)
        XCTAssertLessThan(narrow.rows, initial.rows)
        XCTAssertTrue(traces.isHittable)

        toggle.click()
        XCTAssertTrue(root.waitForExistence(timeout: 5))
        let narrowSidebar = try shellState(in: app, folder: folder, checkpoint: "narrow-sidebar")
        XCTAssertEqual(narrowSidebar.processID, initial.processID)
        XCTAssertGreaterThan(narrowSidebar.columns, 0)
        XCTAssertGreaterThan(narrowSidebar.rows, 0)
        XCTAssertEqual(traces.frame.height, 48, accuracy: 1)
        attachWindow(in: app, name: "\(appearance), narrow window with sidebar")
        app.terminate()
    }

    @MainActor
    func resizeWindow(_ window: XCUIElement, to size: CGSize) {
        // Keep a tall restored window's bottom resize edge on-screen.
        let titleBar = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0))
            .withOffset(CGVector(dx: 0, dy: 20))
        let positionTarget = titleBar.withOffset(CGVector(dx: 0, dy: 30 - window.frame.minY))
        titleBar.click(forDuration: 0.2, thenDragTo: positionTarget)
        // Use straight edges: the extreme corner falls outside macOS's rounded window shape.
        let rightEdge = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5))
            .withOffset(CGVector(dx: -1, dy: 0))
        let widthTarget = window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: size.width - 1, dy: window.frame.height / 2))
        rightEdge.click(forDuration: 0.2, thenDragTo: widthTarget)
        // Stay near the left edge so the Dock cannot intercept a tall window's bottom resize handle.
        let bottomEdge = window.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 1))
            .withOffset(CGVector(dx: 24, dy: -1))
        let heightTarget = window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 24, dy: size.height - 1))
        bottomEdge.click(forDuration: 0.2, thenDragTo: heightTarget)
    }

    private func createFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(
            path: "Twine folder with a long name for checking sidebar truncation \(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    @MainActor
    private func shellState(
        in app: XCUIApplication, folder: URL, checkpoint: String
    ) throws -> ShellState {
        let file = folder.appending(path: "\(checkpoint).txt")
        app.typeText("{ echo $$; stty size; } > \(file.lastPathComponent)\r")
        let written = expectation(
            for: NSPredicate { _, _ in
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { return false }
                return text.split(whereSeparator: \.isWhitespace).count == 3
            },
            evaluatedWith: nil
        )
        wait(for: [written], timeout: 10)
        let values = try String(contentsOf: file, encoding: .utf8).split(whereSeparator: \.isWhitespace)
        XCTAssertEqual(values.count, 3)
        return ShellState(
            processID: String(values[0]),
            rows: try XCTUnwrap(Int(values[1])),
            columns: try XCTUnwrap(Int(values[2]))
        )
    }

    @MainActor
    func attachWindow(in app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private struct ShellState {
    let processID: String
    let rows: Int
    let columns: Int
}
