import AppKit
import XCTest

extension TwineUITests {
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
