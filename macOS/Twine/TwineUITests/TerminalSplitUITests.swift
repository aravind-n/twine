import AppKit
import XCTest

extension TwineUITests {
    @MainActor
    func testTerminalSplitsResizeKeepTheirNeighborAndRestoreOutput() throws {
        let folder = try makeTestFolder(prefix: "TwineSplitUITests")
        let app = try makeApp(lastOpenFolder: folder)
        app.launchEnvironment["SHELL"] = "/bin/bash"
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["workflowTab-1"].waitForExistence(timeout: 10))
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 1100, height: 750))
        app.buttons["workflowChoice-Terminal"].click()
        app.typeText("stty size > full-size\r")
        waitForFile(folder.appending(path: "full-size"), containing: " ", in: app)
        app.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(app.buttons["workflowTab-2"].waitForExistence(timeout: 5))
        app.buttons["workflowChoice-Terminal"].click()
        app.buttons["workflowTab-1"].click()
        app.typeKey("d", modifierFlags: .command)
        app.typeText("printf 'SPLIT_PANE_OUTPUT\\n'; stty size > split-size\r")
        waitForFile(folder.appending(path: "split-size"), containing: " ", in: app)
        XCTAssertFalse(app.buttons["workflowTab-3"].exists)
        let full = try String(contentsOf: folder.appending(path: "full-size"), encoding: .utf8).split(separator: " ")
        let split = try String(contentsOf: folder.appending(path: "split-size"), encoding: .utf8).split(separator: " ")
        let fullColumns = try XCTUnwrap(full.last.flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) })
        let splitColumns = try XCTUnwrap(split.last.flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) })
        XCTAssertLessThan(splitColumns, fullColumns)
        app.buttons["splitTerminalDown"].click()
        XCTAssertTrue(app.buttons["closeTerminalPane-4"].waitForExistence(timeout: 5))
        app.typeText("echo bottom > bottom-ready\r")
        waitForFile(folder.appending(path: "bottom-ready"), containing: "bottom", in: app)
        attachScreenshot(of: app, named: "Minimal terminal split controls and nested panes")
        app.buttons["closeTerminalPane-4"].click()
        // The first sibling is the original pane. Closing it promotes the surviving split,
        // even though an unrelated workflow was created between their IDs.
        app.buttons["closeTerminalPane-1"].click()
        XCTAssertTrue(app.buttons["workflowTab-3"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["workflowTab-3"].value as? String, "Selected")
        app.typeText("echo alive > split-alive\r")
        waitForFile(folder.appending(path: "split-alive"), containing: "alive", in: app)
        app.menuBars.menuBarItems["Twine"].click()
        app.menuItems["Quit Twine"].click()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
        app.launch()
        XCTAssertTrue(app.buttons["workflowTab-3"].waitForExistence(timeout: 10))
        app.buttons["workflowTab-3"].click()
        assertSavedOutput("SPLIT_PANE_OUTPUT", in: app)
    }
    @MainActor
    func testClipboardImagePastesIntoTheFocusedSplitAndActivityStaysUnified() throws {
        let folder = try makeTestFolder(prefix: "TwineImagePasteUITests")
        let app = try makeApp(lastOpenFolder: folder)
        app.launchEnvironment["SHELL"] = "/bin/bash"
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["workflowTab-1"].waitForExistence(timeout: 10))
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 1100, height: 800))
        app.buttons["workflowChoice-Terminal"].click()
        app.typeText("echo first > first-ready\r")
        waitForFile(folder.appending(path: "first-ready"), containing: "first", in: app)
        app.typeKey("d", modifierFlags: .command)
        XCTAssertTrue(app.buttons["closeTerminalPane-2"].waitForExistence(timeout: 5))
        app.typeText("echo second > second-ready\r")
        waitForFile(folder.appending(path: "second-ready"), containing: "second", in: app)

        let saved: [NSPasteboardItem] =
            NSPasteboard.general.pasteboardItems?.map { item in
                let copy = NSPasteboardItem()
                for type in item.types {
                    if let data = item.data(forType: type) { copy.setData(data, forType: type) }
                }
                return copy
            } ?? []
        defer {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(saved)
        }
        let bitmap = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 8, bitsPerPixel: 32))
        bitmap.setColor(.red, atX: 0, y: 0)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(try XCTUnwrap(bitmap.representation(using: .png, properties: [:])), forType: .png)
        app.typeText("test -f ")
        app.typeKey("v", modifierFlags: .command)
        app.typeText(" && echo image-ok > image-pasted\r")
        waitForFile(folder.appending(path: "image-pasted"), containing: "image-ok", in: app)
        app.buttons["tracesHeader"].click()
        let first = app.staticTexts["Terminal · 1"].firstMatch
        let second = app.staticTexts["Terminal · 2"].firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(second.waitForExistence(timeout: 5), app.debugDescription)
        attachWindow(in: app, name: "Bento split with unified traces and image paste")
    }

    @MainActor
    func assertSavedOutput(_ marker: String, in app: XCUIApplication) {
        let saved = app.descendants(matching: .any).matching(identifier: "savedTerminalOutput").firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 5))
        saved.click()
        app.menuItems.matching(NSPredicate(format: "title CONTAINS %@", "· 1")).firstMatch.click()
        let history = app.textViews["terminalHistoryText"]
        XCTAssertTrue(history.waitForExistence(timeout: 10))
        XCTAssertTrue((history.value as? String)?.contains(marker) == true)
    }

}
