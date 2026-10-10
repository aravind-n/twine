import AppKit
import XCTest

extension TwineUITests {
    @MainActor
    func testHTMLPreviewFillsViewportAtEveryZoomLevel() throws {
        let folder = try makeTestFolder(prefix: "TwineHTMLViewportUITests")
        let file = folder.appending(path: "viewport.html")
        try """
        <!doctype html><html><head><style>
        html, body { margin: 0; }
        body { background: #d6f5e8; }
        h1 { position: relative; margin: 0; font: bold 24px sans-serif; }
        #viewport { position: fixed; inset: 0; background: #d6f5e8; }
        #corner { position: fixed; right: 12px; bottom: 12px; }
        </style></head><body>
        <a id="viewport" href="#top" aria-label="Viewport bounds"></a>
        <h1 id="top">Viewport zoom</h1>
        <a id="corner" href="next.html">Bottom corner</a>
        </body></html>
        """.write(to: file, atomically: true, encoding: .utf8)
        try "<h1>Corner link opened</h1>".write(
            to: folder.appending(path: "next.html"), atomically: true, encoding: .utf8)
        let app = try makeApp(lastOpenFolder: folder)
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["workflowTab-1"].waitForExistence(timeout: 10))
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 1100, height: 800))
        fileRow(file, in: app).click()
        XCTAssertTrue(app.staticTexts["Viewport zoom"].firstMatch.waitForExistence(timeout: 5))
        let originalHeight = app.staticTexts["Viewport zoom"].firstMatch.frame.height
        for percent in [100, 50, 67, 75, 90, 100, 110, 125, 150, 175, 200, 100] {
            if percent == 50 {
                for _ in 0..<4 { app.typeKey("-", modifierFlags: .command) }
            } else if percent == 100 {
                app.typeKey("0", modifierFlags: .command)
            } else {
                app.typeKey("=", modifierFlags: .command)
            }
            assertHTMLViewport(in: app, percent: percent, originalHeight: originalHeight)
            if [50, 125, 200].contains(percent) {
                verifyHTMLResizeAndSidebar(in: app, percent: percent, originalHeight: originalHeight)
            }
            if [50, 200].contains(percent) {
                let corner = app.links["Bottom corner"]
                corner.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
                XCTAssertTrue(app.staticTexts["Corner link opened"].firstMatch.waitForExistence(timeout: 5))
                fileTab(file, in: app).click()
                assertHTMLViewport(in: app, percent: percent, originalHeight: originalHeight)
            }
        }
        let corner = app.links["Bottom corner"]
        corner.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertTrue(app.staticTexts["Corner link opened"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func verifyHTMLResizeAndSidebar(in app: XCUIApplication, percent: Int, originalHeight: CGFloat) {
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 950, height: 700))
        assertHTMLViewport(in: app, percent: percent, originalHeight: originalHeight)
        let pane = app.descendants(matching: .any).matching(identifier: "fileViewport").firstMatch
        let widthWithSidebar = pane.frame.width
        toggleHTMLSidebar(in: app)
        assertHTMLViewport(in: app, percent: percent, originalHeight: originalHeight)
        XCTAssertGreaterThan(pane.frame.width, widthWithSidebar + 10)
        toggleHTMLSidebar(in: app)
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 1100, height: 800))
        assertHTMLViewport(in: app, percent: percent, originalHeight: originalHeight)
    }

    @MainActor
    private func toggleHTMLSidebar(in app: XCUIApplication) {
        // Use the SidebarCommands shortcut while WebKit owns keyboard focus.
        app.typeKey("s", modifierFlags: [.command, .option])
    }

    @MainActor
    private func assertHTMLViewport(in app: XCUIApplication, percent: Int, originalHeight: CGFloat) {
        let pane = app.descendants(matching: .any).matching(identifier: "fileViewport").firstMatch
        XCTAssertTrue(pane.waitForExistence(timeout: 5))
        let expected = pane.frame
        let preview = app.descendants(matching: .any).matching(identifier: "htmlPreview").firstMatch
        let viewport = app.links["Viewport bounds"].firstMatch
        XCTAssertTrue(viewport.waitForExistence(timeout: 5))
        attachScreenshot(of: app, named: "HTML viewport at \(percent) percent")
        let fills = expectation(
            for: NSPredicate { _, _ in
                let actual = viewport.frame
                return abs(actual.width - expected.width) < 2 && abs(actual.height - expected.height) < 2
                    && abs(actual.minX - expected.minX) < 2 && abs(actual.minY - expected.minY) < 2
            }, evaluatedWith: nil)
        XCTAssertEqual(
            XCTWaiter.wait(for: [fills], timeout: 5), .completed,
            "At \(percent)%: editor \(expected), WebKit \(preview.frame), HTML viewport \(viewport.frame)")
        XCTAssertEqual(
            app.staticTexts["Viewport zoom"].firstMatch.frame.height, originalHeight * CGFloat(percent) / 100,
            accuracy: 2)
        let corner = app.links["Bottom corner"].frame
        XCTAssertEqual(corner.maxX, expected.maxX - 12 * CGFloat(percent) / 100, accuracy: 2)
        XCTAssertEqual(corner.maxY, expected.maxY - 12 * CGFloat(percent) / 100, accuracy: 2)
    }

    @MainActor
    func testZoomedWebPreviewsKeepLocalLinksInteractive() throws {
        let folder = try makeTestFolder(prefix: "TwineZoomPreviewUITests")
        let html = folder.appending(path: "index.html")
        let markdown = folder.appending(path: "index.md")
        try "<h1>HTML zoom</h1><a href='next.md'>Next page</a>".write(to: html, atomically: true, encoding: .utf8)
        try "# Markdown zoom\n\n[Next page](next.md)".write(to: markdown, atomically: true, encoding: .utf8)
        try "# Linked page".write(to: folder.appending(path: "next.md"), atomically: true, encoding: .utf8)
        let app = try makeApp(lastOpenFolder: folder)
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["workflowTab-1"].waitForExistence(timeout: 10))
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 1100, height: 800))
        for (file, title) in [(html, "HTML zoom"), (markdown, "Markdown zoom")] {
            app.typeKey("0", modifierFlags: .command)
            fileRow(file, in: app).click()
            let heading = app.staticTexts[title].firstMatch
            XCTAssertTrue(heading.waitForExistence(timeout: 5))
            let height = heading.frame.height
            attachScreenshot(of: app, named: "\(title) at actual size")
            heading.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
            app.typeKey("=", modifierFlags: .command)
            app.typeKey("=", modifierFlags: .command)
            attachScreenshot(of: app, named: "\(title) at 125 percent")
            let enlarged = expectation(
                for: NSPredicate { _, _ in abs(heading.frame.height - height * 1.25) < 2 }, evaluatedWith: nil)
            XCTAssertEqual(
                XCTWaiter.wait(for: [enlarged], timeout: 5), .completed,
                "Expected heading height \(height * 1.25), observed \(heading.frame.height)")
            let link = app.links["Next page"]
            link.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
            XCTAssertTrue(app.staticTexts["Linked page"].waitForExistence(timeout: 5))
        }
    }

}
