import Darwin
import Foundation
import XCTest

extension TwineUITests {
    /// Opt-in integration test against real local inference servers. Ordinary UI runs skip it.
    @MainActor
    func testLocalPiWorkflowSmoke() throws {
        let fixtureURL = URL(filePath: "/tmp/twine-local-pi-fixture.json")
        guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
            throw XCTSkip("Create /tmp/twine-local-pi-fixture.json to run real Pi agents.")
        }
        let fixture = try JSONDecoder().decode(LocalPiFixture.self, from: Data(contentsOf: fixtureURL))
        let folder = URL(filePath: fixture.folder)
        let app = makeLocalPiApp(fixture)
        let result = folder.appending(path: fixture.resultFile)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: result.path), "Prepare a fresh result path before this test.")
        if let witness = fixture.finalCompletionWitness {
            XCTAssertFalse(FileManager.default.fileExists(atPath: witness))
        }
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15), app.debugDescription)
        resizeWindow(app.windows.firstMatch, to: CGSize(width: 1200, height: 850))
        func item(_ identifier: String) -> XCUIElement {
            app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        }
        let choice = item("workflowChoice-\(fixture.workflow)")
        XCTAssertTrue(choice.waitForExistence(timeout: 15), app.debugDescription)
        choice.click()
        if fixture.workflow == "Single agent" {
            try startLocalPiSingle(try XCTUnwrap(fixture.roles.first), in: app)
        } else {
            try configureLocalPiRoles(fixture.roles, in: app)
            attachScreenshot(of: app, named: "Real Pi workflow launch")
            let start = item("workflowStart")
            XCTAssertTrue(start.waitForExistence(timeout: 10), app.debugDescription)
            start.click()
            XCTAssertTrue(item("workflowMarkDone").waitForExistence(timeout: 20), app.debugDescription)
        }
        app.typeText(fixture.prompt + "\r")
        try waitForLocalPiResult(fixture, result: result, in: app)
        try checkLocalPiFollowUps(fixture, in: app)
        if let witness = fixture.finalCompletionWitness {
            let settled = expectation(
                for: NSPredicate { _, _ in FileManager.default.fileExists(atPath: witness) },
                evaluatedWith: nil)
            wait(for: [settled], timeout: fixture.timeout)
            _ = try livePiProcesses(fixture)
        }
        item("tracesHeader").click()
        XCTAssertTrue(item("traceOverview").waitForExistence(timeout: 10), app.debugDescription)
        attachScreenshot(of: app, named: "Real Pi completed workflow and traces")
    }

    @MainActor
    private func makeLocalPiApp(_ fixture: LocalPiFixture) -> XCUIApplication {
        let app = fixture.applicationPath.map { XCUIApplication(url: URL(filePath: $0)) } ?? XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["TWINE_DATA_DIRECTORY"] = fixture.dataDirectory
        app.launchEnvironment["TWINE_HARNESS_PATH"] = fixture.harnessPath
        app.launchEnvironment["PI_CODING_AGENT_DIR"] = fixture.piDirectory
        app.launchEnvironment["PI_OFFLINE"] = "1"
        app.launchEnvironment["TWINE_BENCH_RUN_ID"] = fixture.runID
        app.launchEnvironment["TWINE_BENCH_COMPLETION_WITNESS"] = fixture.completionWitness
        let preferencesSuite = "com.twineproject.Twine.tests.TwineLocalPi-\(UUID())"
        app.launchEnvironment["TWINE_PREFERENCES_SUITE"] = preferencesSuite
        // XCTest can stop on an assertion without unwinding Swift defer blocks.
        addTeardownBlock {
            await MainActor.run {
                app.terminate()
                UserDefaults(suiteName: preferencesSuite)?.removePersistentDomain(forName: preferencesSuite)
            }
        }
        return app
    }

    @MainActor
    private func checkLocalPiFollowUps(_ fixture: LocalPiFixture, in app: XCUIApplication) throws {
        let processes = try livePiProcesses(fixture)
        for followUp in fixture.followUps ?? [] {
            let followUpResult = URL(filePath: fixture.folder).appending(path: followUp.resultFile)
            XCTAssertFalse(FileManager.default.fileExists(atPath: followUpResult.path))
            if fixture.workflow == "Single agent", fixture.completionWitness != nil {
                let witness = try XCTUnwrap(
                    followUp.completionWitness, "Each follow-up needs its own turn-end witness.")
                XCTAssertFalse(FileManager.default.fileExists(atPath: witness))
            }
            if let agentID = followUp.agentID {
                let tab = app.buttons["agentSubtab-\(agentID)"]
                XCTAssertTrue(tab.waitForExistence(timeout: 10), app.debugDescription)
                tab.click()
                waitUntilSelected(tab, in: app)
            }
            app.typeText(followUp.prompt + "\r")
            if fixture.workflow != "Single agent" {
                XCTAssertTrue(app.staticTexts["Completed"].waitForNonExistence(timeout: 10), app.debugDescription)
            }
            try waitForLocalPiResult(
                fixture, result: followUpResult, in: app, marker: followUp.resultContains,
                witness: followUp.completionWitness)
            XCTAssertEqual(try livePiProcesses(fixture), processes, "Follow-ups must reuse the same live Pi processes.")
            attachScreenshot(of: app, named: "Real Pi completed follow-up")
        }
    }

    @MainActor
    private func startLocalPiSingle(_ role: LocalPiFixture.Role, in app: XCUIApplication) throws {
        app.menuItems["pi"].hover()
        let provider = app.menuItems[role.provider]
        XCTAssertTrue(provider.waitForExistence(timeout: 20), app.debugDescription)
        provider.hover()
        let model = provider.menuItems[role.modelName]
        XCTAssertTrue(model.waitForExistence(timeout: 10), app.debugDescription)
        model.hover()
        let off = model.menuItems["Off"].firstMatch
        if off.waitForExistence(timeout: 3) {
            off.click()
        } else {
            model.click()
        }
        let choices = app.descendants(matching: .any).matching(identifier: "newTabChoices").firstMatch
        XCTAssertTrue(choices.waitForNonExistence(timeout: 20), app.debugDescription)
    }

    @MainActor
    private func waitForLocalPiResult(
        _ fixture: LocalPiFixture, result: URL, in app: XCUIApplication,
        marker: String? = nil, witness: String? = nil
    ) throws {
        let marker = marker ?? fixture.resultContains
        if fixture.workflow == "Single agent" {
            let finished = expectation(
                for: NSPredicate { _, _ in
                    guard let contents = try? String(contentsOf: result, encoding: .utf8) else { return false }
                    let validResult = marker.map(contents.contains) ?? !contents.isEmpty
                    let witnessed =
                        (witness ?? fixture.completionWitness).map {
                            FileManager.default.fileExists(atPath: $0)
                        } ?? true
                    return validResult && witnessed
                },
                evaluatedWith: nil)
            wait(for: [finished], timeout: fixture.timeout)
        } else {
            // Completion must come from the actual agents' mailbox command; never click Mark done.
            XCTAssertTrue(
                app.staticTexts["Completed"].waitForExistence(timeout: fixture.timeout), app.debugDescription)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.path), app.debugDescription)
        if let marker {
            let contents = try String(contentsOf: result, encoding: .utf8)
            XCTAssertTrue(contents.contains(marker), contents)
        }
    }

    @MainActor
    private func livePiProcesses(_ fixture: LocalPiFixture) throws -> Set<pid_t> {
        guard let path = fixture.processWitness else { return [] }
        struct Process: Decodable { let pid: pid_t }
        let lines = try String(contentsOf: URL(filePath: path), encoding: .utf8).split(separator: "\n")
        let processes = try Set(lines.map { try JSONDecoder().decode(Process.self, from: Data($0.utf8)).pid })
        XCTAssertEqual(processes.count, fixture.roles.count, "Each role should retain one harness process.")
        for process in processes {
            XCTAssertEqual(kill(process, 0), 0, "Pi process \(process) must remain alive after completion.")
        }
        return processes
    }

    @MainActor
    private func configureLocalPiRoles(_ roles: [LocalPiFixture.Role], in app: XCUIApplication) throws {
        func item(_ identifier: String) -> XCUIElement {
            app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        }
        for role in roles {
            let harness = item("roleHarness-\(role.identifier)")
            XCTAssertTrue(harness.waitForExistence(timeout: 10), app.debugDescription)
            harness.click()
            app.menuItems["pi"].click()
            let model = item("roleModel-\(role.identifier)")
            XCTAssertTrue(model.waitForExistence(timeout: 10), app.debugDescription)
            model.click()
            let provider = app.menuItems[role.provider]
            XCTAssertTrue(provider.waitForExistence(timeout: 20), app.debugDescription)
            provider.hover()
            let option = provider.menuItems[role.modelName]
            XCTAssertTrue(option.waitForExistence(timeout: 10), app.debugDescription)
            option.click()
        }
    }
}

private struct LocalPiFixture: Decodable {
    let applicationPath: String?
    let folder: String
    /// Prepared by the opt-in fixture's caller and retained as run evidence.
    let dataDirectory: String
    let harnessPath: String
    let piDirectory: String
    let workflow: String
    let roles: [Role]
    let prompt: String
    let resultFile: String
    let resultContains: String?
    let timeout: TimeInterval
    let runID: String?
    /// Optional witness written by the trusted Pi extension after its final agent turn.
    let completionWitness: String?
    /// Trusted caller signal that final model turns have settled before the app is closed.
    let finalCompletionWitness: String?
    let processWitness: String?
    let followUps: [FollowUp]?

    struct FollowUp: Decodable {
        let prompt: String
        let resultFile: String
        let resultContains: String?
        let completionWitness: String?
        /// The first-stage agent starts another graph cycle; nil keeps the current single-agent focus.
        let agentID: UInt64?
    }

    struct Role: Decodable {
        let identifier: String
        let provider: String
        let modelName: String
    }
}
