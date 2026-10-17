import Foundation
import Testing

@testable import Twine

@MainActor
struct HarnessModelTests {
    private let models = CoreHarnessModels(
        models: [
            .init(id: "a", name: "Alpha", efforts: ["low", "high"]),
            .init(id: "p/x", name: "x", group: "p"),
            .init(id: "q/y", name: "y", group: "q"),
            .init(id: "p/z", name: "z", group: "p"),
            .init(id: "b", name: "Beta"),
        ],
        allowsCustom: false, efforts: ["low", "medium", "high", "ultra"], supportsYolo: true)

    @Test func modelsGroupInListedOrderAndEffortsFollowTheModel() {
        let listed = ListedHarnessModels(models)
        #expect(listed.groups.map(\.title) == [nil, "p", "q"], "Ungrouped models come first")
        #expect(listed.groups[0].models.map(\.id) == ["a", "b"])
        #expect(listed.groups[1].models.map(\.id) == ["p/x", "p/z"])
        #expect(models.efforts(for: "a") == ["low", "high"])
        #expect(models.efforts(for: "p/x") == ["low", "medium", "high", "ultra"], "Unlisted levels fall back")
        #expect(listed.efforts(for: nil) == ["low", "medium", "high", "ultra"])
        #expect(models.name(of: "a") == "Alpha")
        #expect(models.name(of: "typed-model") == "typed-model")
    }

    @Test func choicesFitTheListOnceItLoads() {
        var choice = HarnessChoice(harness: .codex, model: nil, effort: "ultra", yolo: true)
        choice.fit(to: models)
        #expect(choice == .init(harness: .codex, effort: "ultra", yolo: true))
        choice.model = "a"
        choice.fit(to: models)
        #expect(choice.effort == nil, "Alpha doesn't support Ultra")

        var stale = HarnessChoice(harness: .piAgent, model: "gone/model", effort: "high")
        stale.fit(to: models)
        #expect(stale.model == nil, "A model the harness no longer lists is dropped")
        let custom = CoreHarnessModels(models: [], allowsCustom: true, efforts: [], supportsYolo: true)
        var typed = HarnessChoice(harness: .claudeCode, model: "claude-dated-model")
        typed.fit(to: custom)
        #expect(typed.model == "claude-dated-model", "A harness that takes typed names keeps them")
        var unknown = HarnessChoice(harness: .codex, model: "x", effort: "ultra")
        unknown.fit(to: nil)
        #expect(unknown == .init(harness: .codex, model: "x", effort: "ultra"), "Without a list, the core checks it")

        let noPrompts = CoreHarnessModels(models: [], allowsCustom: false, efforts: [], supportsYolo: false)
        var piChoice = HarnessChoice(harness: .piAgent, yolo: true)
        piChoice.fit(to: noPrompts)
        #expect(!piChoice.yolo, "pi has no permission prompts to skip")
    }

    @Test func switchingHarnessesClearsTheModelAndEffort() {
        var choice = HarnessChoice(harness: .piAgent, model: "p/x", effort: "high", yolo: true)
        choice.switchHarness(to: .piAgent)
        #expect(choice.model == "p/x", "Picking the same harness keeps the choice")
        choice.switchHarness(to: .codex)
        #expect(choice == .init(harness: .codex, yolo: true))
    }

    @Test func listedAndFailedResultsDecodeAndRoleLaunchesCarryTheChoice() throws {
        let listed =
            #"{"status":"listed","models":{"models":[{"id":"opus","name":"Opus"}],"allowsCustom":true,"#
            + #""efforts":["high"],"supportsYolo":true}}"#
        let result = try JSONDecoder().decode(CoreHarnessModelsResult.self, from: Data(listed.utf8))
        #expect(
            result
                == .listed(
                    .init(
                        models: [.init(id: "opus", name: "Opus")], allowsCustom: true, efforts: ["high"],
                        supportsYolo: true)))
        let failed = #"{"status":"failed","message":"pi wasn't found on your PATH."}"#
        #expect(
            try JSONDecoder().decode(CoreHarnessModelsResult.self, from: Data(failed.utf8))
                == .failed("pi wasn't found on your PATH."))

        let launch = CoreRoleLaunch(
            role: "worker", choice: .init(harness: .piAgent, model: "p/x", effort: "high", yolo: true))
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(launch)) as? [String: Any])
        #expect(encoded["model"] as? String == "p/x")
        #expect(encoded["effort"] as? String == "high")
        #expect(encoded["yolo"] as? Bool == true)
        let plain = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(CoreRoleLaunch(role: "r", harness: .codex)))
                as? [String: String])
        #expect(plain == ["role": "r", "harness": "codex"], "Defaults are left out")
    }

    @Test func theCatalogListsEachHarnessOnceAndRetriesFailures() async throws {
        let transport = DelayedStartTransport()
        await transport.failModels(.piAgent, with: .failed("pi crashed"))
        let client = CoreClient(transport: transport)
        client.start()
        defer { Task { await client.stop() } }
        try await waitUntil { client.runState == .running }
        let catalog = HarnessModelCatalog()

        await catalog.load(using: client)
        #expect(catalog.entry(for: .codex).models != nil)
        #expect(catalog.entry(for: .antigravity).models != nil)
        #expect(catalog.entry(for: .omp).models != nil)
        #expect(catalog.entry(for: .opencode).models != nil)
        guard case .failed(let message) = catalog.entry(for: .piAgent) else {
            Issue.record("pi's listing should have failed")
            return
        }
        #expect(message.contains("pi crashed"))
        #expect(await transport.modelRequests.count == CoreHarness.allCases.count)

        await transport.failModels(.piAgent, with: nil)
        await catalog.load(using: client)
        #expect(
            await transport.modelRequests.count == CoreHarness.allCases.count + 1,
            "Only the failed harness is asked again")
        #expect(catalog.entry(for: .piAgent).models != nil)
    }

    @Test func aListingOutlivesThePickerThatStartedItAndWaitsForTheCore() async throws {
        let transport = DelayedStartTransport()
        let client = CoreClient(transport: transport)
        let catalog = HarnessModelCatalog()
        // Before the core runs, nothing is recorded, so the next picker asks again.
        await catalog.load(using: client)
        #expect(CoreHarness.allCases.allSatisfy { catalog.entry(for: $0) == .loading })
        #expect(await transport.modelRequests.isEmpty)

        client.start()
        defer { Task { await client.stop() } }
        try await waitUntil { client.runState == .running }
        let closedPicker = Task { await catalog.load(using: client) }
        closedPicker.cancel()
        await catalog.load(using: client)
        #expect(CoreHarness.allCases.allSatisfy { catalog.entry(for: $0).models != nil })
        #expect(await transport.modelRequests.count == CoreHarness.allCases.count, "Each harness is listed once")
    }

}

@MainActor
extension HarnessModelTests {
    @Test func availableHarnessesIncludesAllWhileLoading() async throws {
        let transport = DelayedStartTransport()
        let client = CoreClient(transport: transport)
        let catalog = HarnessModelCatalog()
        // Before the core runs, all entries are .loading — none should be excluded
        await catalog.load(using: client)
        #expect(catalog.availableHarnesses() == CoreHarness.allCases)
    }

    @Test func availableHarnessesExcludesFailedHarnesses() async throws {
        let transport = DelayedStartTransport()
        await transport.failModels(.piAgent, with: .failed("pi wasn't found on your PATH."))
        await transport.failModels(.codex, with: .failed("codex wasn't found on your PATH."))
        let client = CoreClient(transport: transport)
        client.start()
        defer { Task { await client.stop() } }
        try await waitUntil { client.runState == .running }
        let catalog = HarnessModelCatalog()
        await catalog.load(using: client)
        let available = catalog.availableHarnesses()
        #expect(!available.contains(.piAgent), "pi is not in PATH")
        #expect(!available.contains(.codex), "codex is not in PATH")
        #expect(available.contains(.claudeCode))
        #expect(available.contains(.antigravity))
        #expect(available.contains(.omp))
        #expect(available.contains(.opencode))
    }

    @Test func availableHarnessesIsEmptyWhenNoneAreInstalled() async throws {
        let transport = DelayedStartTransport()
        for harness in CoreHarness.allCases {
            await transport.failModels(harness, with: .failed("\(harness.rawValue) wasn't found on your PATH."))
        }
        let client = CoreClient(transport: transport)
        client.start()
        defer { Task { await client.stop() } }
        try await waitUntil { client.runState == .running }
        let catalog = HarnessModelCatalog()
        await catalog.load(using: client)
        #expect(catalog.availableHarnesses().isEmpty, "No agents in PATH means empty list")
    }

    @Test func availableHarnessesUpdatesAfterFailedHarnessRetries() async throws {
        let transport = DelayedStartTransport()
        await transport.failModels(.piAgent, with: .failed("pi wasn't found on your PATH."))
        let client = CoreClient(transport: transport)
        client.start()
        defer { Task { await client.stop() } }
        try await waitUntil { client.runState == .running }
        let catalog = HarnessModelCatalog()
        await catalog.load(using: client)
        #expect(!catalog.availableHarnesses().contains(.piAgent))
        // pi becomes available — retry succeeds
        await transport.failModels(.piAgent, with: nil)
        await catalog.load(using: client)
        #expect(catalog.availableHarnesses().contains(.piAgent), "pi is now available after retry")
    }

    @Test func availableHarnessesUsesTheFolderForOpencode() async throws {
        var snapshot = CoreSnapshot.testReady()
        snapshot.folders.openFolder = "/myproject"
        let transport = DelayedStartTransport(snapshot: snapshot)
        await transport.failModels(.opencode, with: .failed("opencode wasn't found on your PATH."))
        let client = CoreClient(transport: transport)
        client.start()
        defer { Task { await client.stop() } }
        try await waitUntil { client.runState == .running }
        let catalog = HarnessModelCatalog()
        await catalog.load(using: client)
        #expect(!catalog.availableHarnesses(folder: "/myproject").contains(.opencode))
        #expect(
            catalog.availableHarnesses(folder: nil).contains(.opencode),
            "Different folder key — opencode not yet checked for nil folder")
    }

    @Test func savedChoiceSwitchesToFirstAvailableWhenItsHarnessIsUnavailable() async throws {
        let transport = DelayedStartTransport()
        // pi and codex are not installed
        await transport.failModels(.piAgent, with: .failed("pi wasn't found on your PATH."))
        await transport.failModels(.codex, with: .failed("codex wasn't found on your PATH."))
        let client = CoreClient(transport: transport)
        client.start()
        defer { Task { await client.stop() } }
        try await waitUntil { client.runState == .running }
        let catalog = HarnessModelCatalog()
        await catalog.load(using: client)

        // Saved choice is pi — not available
        var choice = HarnessChoice(harness: .piAgent, model: "pi-model", effort: "high")
        let available = catalog.availableHarnesses()
        if !available.contains(choice.harness), let first = available.first {
            choice.switchHarness(to: first)
        }
        // Should switch to first available, clearing model and effort
        #expect(choice.harness != .piAgent, "Unavailable harness must be replaced")
        #expect(available.contains(choice.harness), "New harness must be in available list")
        #expect(choice.model == nil, "Model from old harness is cleared on switch")
        #expect(choice.effort == nil, "Effort from old harness is cleared on switch")
    }

    @Test func savedChoiceIsKeptWhenItsHarnessIsStillAvailable() async throws {
        let transport = DelayedStartTransport()
        let client = CoreClient(transport: transport)
        client.start()
        defer { Task { await client.stop() } }
        try await waitUntil { client.runState == .running }
        let catalog = HarnessModelCatalog()
        await catalog.load(using: client)

        // Saved choice is claudeCode — available
        var choice = HarnessChoice(harness: .claudeCode, model: "claude-3", effort: "high")
        let available = catalog.availableHarnesses()
        if !available.contains(choice.harness), let first = available.first {
            choice.switchHarness(to: first)
        }
        // Should keep the existing choice untouched
        #expect(choice.harness == .claudeCode)
        #expect(choice.model == "claude-3")
        #expect(choice.effort == "high")
    }

    @Test func savedChoiceIsKeptWhenNoHarnessesAreAvailable() async throws {
        let transport = DelayedStartTransport()
        for harness in CoreHarness.allCases {
            await transport.failModels(harness, with: .failed("\(harness.rawValue) not found."))
        }
        let client = CoreClient(transport: transport)
        client.start()
        defer { Task { await client.stop() } }
        try await waitUntil { client.runState == .running }
        let catalog = HarnessModelCatalog()
        await catalog.load(using: client)

        // Saved choice is piAgent — nothing is available
        var choice = HarnessChoice(harness: .piAgent)
        let available = catalog.availableHarnesses()
        if !available.contains(choice.harness), let first = available.first {
            choice.switchHarness(to: first)
        }
        // No harnesses available — choice stays unchanged, UI shows "No agents available"
        #expect(choice.harness == .piAgent, "Choice unchanged when no alternatives exist")
    }
}

@MainActor
extension HarnessModelTests {
    @Test func opencodeCatalogsFollowFoldersAndLateResponsesStayWithTheirFolder() async throws {
        var snapshot = CoreSnapshot.testReady()
        snapshot.folders.openFolder = "/first"
        let transport = DelayedStartTransport(snapshot: snapshot)
        let first = CoreHarnessModelsResult.listed(
            .init(
                models: [.init(id: "local/first", name: "First", efforts: ["custom-name"])], allowsCustom: true,
                efforts: [], supportsYolo: false))
        let second = CoreHarnessModelsResult.listed(
            .init(
                models: [.init(id: "local/second", name: "Second", efforts: ["Custom_Name"])], allowsCustom: true,
                efforts: [], supportsYolo: false))
        await transport.setModels(first, folder: "/first", held: true)
        await transport.setModels(second, folder: "/second")
        let client = CoreClient(transport: transport)
        client.start()
        defer { Task { await client.stop() } }
        try await waitUntil { client.runState == .running }
        let catalog = HarnessModelCatalog()
        let firstLoad = Task { await catalog.load(using: client) }
        try await waitUntil { await transport.modelFolders == ["/first"] }
        await transport.setOpenFolder("/second")
        try await waitUntil { client.snapshot?.folders.openFolder == "/second" }
        await catalog.load(using: client)
        #expect(catalog.entry(for: .opencode, folder: "/second").models?.models.first?.id == "local/second")
        await transport.releaseModels(folder: "/first")
        await firstLoad.value
        #expect(catalog.entry(for: .opencode, folder: "/first").models?.models.first?.id == "local/first")
        #expect(catalog.entry(for: .opencode, folder: "/second").models?.models.first?.id == "local/second")
        await transport.setOpenFolder("/first")
        try await waitUntil { client.snapshot?.folders.openFolder == "/first" }
        await catalog.load(using: client)
        #expect(await transport.modelFolders == ["/first", "/second"])
        var choice = HarnessChoice(harness: .opencode, model: "local/first", effort: "custom-name", yolo: true)
        choice.fit(to: catalog.entry(for: .opencode, folder: "/first").models)
        #expect(choice.effort == "custom-name" && !choice.yolo)
    }
}
