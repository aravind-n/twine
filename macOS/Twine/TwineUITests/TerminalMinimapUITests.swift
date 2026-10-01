import XCTest

extension TwineUITests {
    @MainActor
    func testShortOutputMinimapInBothAppearances() throws {
        for appearance in ["Dark", "Light"] {
            let folder = try makeTestFolder(prefix: "TwineShortMinimapUITests")
            let app = try makeApp(lastOpenFolder: folder)
            app.launchEnvironment["SHELL"] = "/bin/bash"
            app.launchEnvironment["TWINE_TEST_APPEARANCE"] = appearance
            app.launch()
            defer { app.terminate() }
            XCTAssertTrue(app.buttons["workflowTab-1"].waitForExistence(timeout: 10))
            resizeWindow(app.windows.firstMatch, to: CGSize(width: 1000, height: 650))
            app.typeText(
                "printf '\\033[2J\\033[H'; printf '%s\\n' 'Explored the folder' '  List complete' '' "
                    + "'Searched the web' '' 'Seattle forecast: mostly sunny, with a high near 63 degrees.' '' "
                    + "'Completion submitted to Twine.' 'Review approved.'; echo ready > minimap-ready\r")
            waitForFile(folder.appending(path: "minimap-ready"), containing: "ready", in: app)
            let map = app.descendants(matching: .any).matching(identifier: "terminalMinimap").firstMatch
            XCTAssertTrue(map.waitForExistence(timeout: 10), app.debugDescription)
            attachScreenshot(of: app, named: "Short output compact minimap in \(appearance)")
            map.hover()
            attachScreenshot(of: app, named: "Short output expanded minimap in \(appearance)")
        }
    }

    @MainActor
    func testCompactMinimapScrollsAndSelectsItsActivityStep() throws {
        let folder = try makeTestFolder(prefix: "TwineMinimapUITests")
        let app = try makeApp(lastOpenFolder: folder)
        app.launchEnvironment["SHELL"] = "/bin/bash"
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["workflowTab-1"].waitForExistence(timeout: 10))
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 1000, height: 800))
        app.typeText(
            "stty size > minimap-before; printf 'MINIMAP_ANCHOR\\n'; "
                + "i=0; while [ $i -lt 120 ]; do echo line-$i; i=$((i+1)); done; "
                + "echo ready > minimap-ready\r"
        )
        waitForFile(folder.appending(path: "minimap-ready"), containing: "ready", in: app)
        let map = app.descendants(matching: .any).matching(identifier: "terminalMinimap").firstMatch
        XCTAssertTrue(map.waitForExistence(timeout: 10), app.debugDescription)
        let grid = try String(contentsOf: folder.appending(path: "minimap-before"), encoding: .utf8)
        map.hover()
        app.typeText("stty size > minimap-after\r")
        waitForFile(folder.appending(path: "minimap-after"), containing: grid, in: app)
        map.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).click()
        let returnToLive = app.buttons["minimapReturnToLive"]
        XCTAssertTrue(returnToLive.waitForExistence(timeout: 5), app.debugDescription)
        attachScreenshot(of: app, named: "Compact minimap expanded over terminal output")
        returnToLive.click()
        XCTAssertTrue(returnToLive.waitForNonExistence(timeout: 5))
        map.hover()
        let marker = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'minimapStep-'")).firstMatch
        XCTAssertTrue(marker.waitForExistence(timeout: 10), app.debugDescription)
        let id = marker.identifier.replacingOccurrences(of: "minimapStep-", with: "")
        marker.click()
        XCTAssertTrue(app.buttons["traceSpan-\(id)"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.textViews["terminalHistoryText"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "terminalMinimap").firstMatch.exists)
        attachScreenshot(of: app, named: "Minimap point and matching Activity step")
        app.buttons["returnToLive"].click()
        XCTAssertTrue(app.textViews["terminalHistoryText"].waitForNonExistence(timeout: 5))
        app.typeText("echo returned > minimap-returned\r")
        waitForFile(folder.appending(path: "minimap-returned"), containing: "returned", in: app)
    }
}
