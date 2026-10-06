import AppKit
import Foundation
import Testing

@testable import Twine

@MainActor
struct AppUpdaterTests {
    @Test func startupAppliesCorePolicyBeforeCheckingAndStartsOnce() {
        let driver = TestUpdateDriver()
        let updater = AppUpdater(driver: driver)
        var config = CoreUpdateConfig()
        config.automaticallyInstall = true
        updater.apply(config)
        #expect(driver.policyAtStart == config)
        #expect(updater.canCheckForUpdates)
        updater.checkForUpdates()
        #expect(driver.checkCount == 1)
        config.channel = .nightly
        updater.apply(config)
        #expect(driver.startCount == 1)
        #expect(driver.channel == .nightly)
        #expect(driver.resetCount == 1)
        config.automaticallyCheck = false
        updater.apply(config)
        #expect(!driver.automaticallyChecks)
        #expect(!driver.automaticallyDownloads)
        #expect(updater.canCheckForUpdates)
        driver.canCheck = false
        driver.availabilityChanged?()
        updater.checkForUpdates()
        #expect(driver.checkCount == 1)
    }

    @Test func startupFailureKeepsTheMenuDisabled() {
        let driver = TestUpdateDriver()
        driver.startError = CoreFailure.internalError
        let updater = AppUpdater(driver: driver)
        updater.apply(CoreUpdateConfig())
        driver.availabilityChanged?()
        updater.checkForUpdates()
        #expect(!updater.canCheckForUpdates)
        #expect(updater.failure != nil)
        #expect(driver.checkCount == 0)
    }

    @Test(arguments: [false, true])
    func latestChoiceSurvivesAnInFlightSave(acknowledge: Bool) async throws {
        let driver = TestUpdateDriver()
        let writer = SuspendedPreferenceWriter()
        let updater = AppUpdater(driver: driver, savePreference: writer.save)
        updater.apply(CoreUpdateConfig())
        driver.choose(true)
        try await waitUntil { writer.writes.count == 1 }
        driver.availabilityChanged?()
        driver.availabilityChanged?()
        #expect(writer.writes.count == 1)
        driver.choose(false)
        if acknowledge {
            var acknowledgment = CoreUpdateConfig()
            acknowledgment.automaticallyInstall = true
            updater.apply(acknowledgment)
        }
        #expect(!driver.automaticallyDownloads)
        writer.complete()
        try await waitUntil { writer.writes.count == 2 }
        #expect(writer.writes.map(\.enabled) == [true, false])
        #expect(writer.writes.map(\.previous) == [false, true])
        writer.complete()
        await updater.finishSavingPreferences()
        #expect(!writer.persisted)
        #expect(!driver.automaticallyDownloads)
        #expect(updater.failure == nil)
    }

    @Test func failedPreferenceSaveRestoresAcceptedPolicy() async throws {
        let driver = TestUpdateDriver()
        let writer = SuspendedPreferenceWriter()
        let updater = AppUpdater(driver: driver, savePreference: writer.save)
        updater.apply(CoreUpdateConfig())
        driver.choose(true)
        try await waitUntil { writer.writes.count == 1 }
        writer.complete(error: CoreFailure.internalError)
        await updater.finishSavingPreferences()
        #expect(!driver.automaticallyDownloads)
        #expect(!writer.persisted)
        #expect(updater.failure != nil)
    }

    @Test func newerCorePolicySupersedesAnInFlightChoice() async throws {
        let driver = TestUpdateDriver()
        let writer = SuspendedPreferenceWriter()
        let updater = AppUpdater(driver: driver, savePreference: writer.save)
        updater.apply(CoreUpdateConfig())
        driver.choose(true)
        try await waitUntil { writer.writes.count == 1 }
        var newer = CoreUpdateConfig()
        newer.automaticallyCheck = false
        newer.channel = .nightly
        updater.apply(newer)
        writer.complete(error: CoreFailure.internalError)
        await updater.finishSavingPreferences()
        #expect(!driver.automaticallyDownloads)
        #expect(!driver.automaticallyChecks)
        #expect(driver.channel == .nightly)
        #expect(updater.failure == nil)
        #expect(writer.writes.count == 1)
    }

    @Test func quitCollectsTheLiveCheckboxAndWaitsForPersistence() async throws {
        let driver = TestUpdateDriver()
        let writer = SuspendedPreferenceWriter()
        let updater = AppUpdater(driver: driver, savePreference: writer.save)
        updater.apply(CoreUpdateConfig())
        // The live checkbox can change without the update window's selection delegate firing.
        driver.automaticallyDownloads = true
        let data = TemporaryPath()
        let delegate = AppTerminationDelegate()
        delegate.attach(
            windows: FolderWindows(dataDirectory: data.url),
            layouts: WorkflowLayouts(fileURL: data.url.appending(path: "layouts.json")), updater: updater)
        var replies: [Bool] = []
        #expect(delegate.beginTermination { replies.append($0) } == .terminateLater)
        try await waitUntil { writer.writes.count == 1 }
        #expect(replies.isEmpty)
        writer.complete()
        try await waitUntil { replies == [true] }
        #expect(writer.persisted)
    }

    @Test func buildsWithoutAnUpdaterStayInactive() async {
        let updater = AppUpdater(driver: nil)
        updater.apply(CoreUpdateConfig())
        updater.checkForUpdates()
        await updater.finishSavingPreferences()
        #expect(!updater.canCheckForUpdates)
        #expect(updater.failure == nil)
    }

    @Test func builtBundleContainsUpdaterPolicy() {
        let info = Bundle.main.infoDictionary ?? [:]
        #expect(info["SUFeedURL"] as? String == "https://aravind-n.github.io/twine/updates/appcast.xml")
        #expect(info["SUEnableAutomaticChecks"] as? Bool == false)
        #expect(info["SUAutomaticallyUpdate"] as? Bool == false)
        #expect(info["SUVerifyUpdateBeforeExtraction"] as? Bool == true)
        #expect((info["SUScheduledCheckInterval"] as? NSNumber)?.doubleValue == 86_400)
    }

    @Test func updatePolicyDecodesFromCore() throws {
        let data = Data(#"{"automatically_check":false,"automatically_install":true,"channel":"nightly"}"#.utf8)
        let config = try JSONDecoder().decode(CoreUpdateConfig.self, from: data)
        #expect(!config.automaticallyCheck)
        #expect(config.automaticallyInstall)
        #expect(config.channel == .nightly)
    }
}

@MainActor
private final class TestUpdateDriver: UpdateDriver {
    var automaticallyChecks = false
    var automaticallyDownloads = false
    var channel = CoreUpdateConfig.Channel.stable
    var canCheck = true
    var availabilityChanged: (@MainActor () -> Void)?
    var preferenceChanged: (@MainActor () -> Void)?
    var startError: (any Error)?
    var policyAtStart: CoreUpdateConfig?
    var startCount = 0
    var checkCount = 0
    var resetCount = 0

    func start() throws {
        startCount += 1
        policyAtStart = CoreUpdateConfig(
            automaticallyCheck: automaticallyChecks, automaticallyInstall: automaticallyDownloads, channel: channel)
        if let startError { throw startError }
    }
    func check() { checkCount += 1 }
    func resetSchedule() { resetCount += 1 }
    func choose(_ enabled: Bool) {
        automaticallyDownloads = enabled
        preferenceChanged?()
    }
}

@MainActor
private final class SuspendedPreferenceWriter {
    var writes: [(enabled: Bool, previous: Bool)] = []
    var persisted = false
    private var continuation: CheckedContinuation<Void, any Error>?

    func save(_ enabled: Bool, _ previous: Bool) async throws {
        writes.append((enabled, previous))
        try await withCheckedThrowingContinuation { continuation = $0 }
        persisted = enabled
    }

    func complete(error: (any Error)? = nil) {
        let pending = continuation
        continuation = nil
        if let error { pending?.resume(throwing: error) } else { pending?.resume() }
    }
}
