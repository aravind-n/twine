import Foundation
import OSLog
import Observation

private let updateLogger = Logger(subsystem: "com.twineproject.Twine", category: "updates")

@MainActor
protocol UpdateDriver: AnyObject {
    var automaticallyChecks: Bool { get set }
    var automaticallyDownloads: Bool { get set }
    var channel: CoreUpdateConfig.Channel { get set }
    var canCheck: Bool { get }
    var availabilityChanged: (@MainActor () -> Void)? { get set }
    var preferenceChanged: (@MainActor () -> Void)? { get set }
    func start() throws
    func check()
    func resetSchedule()
}

/// One updater for the installed app. Core configuration remains authoritative for policy.
@MainActor
@Observable
final class AppUpdater {
    private(set) var canCheckForUpdates = false
    private(set) var failure: String?
    @ObservationIgnored private let driver: (any UpdateDriver)?
    @ObservationIgnored private var policy: CoreUpdateConfig?
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var desiredInstall: Bool?
    @ObservationIgnored private var pendingPolicy: CoreUpdateConfig?
    @ObservationIgnored private var policyRevision = 0
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var savePreference: (@MainActor (Bool, Bool) async throws -> Void)?

    init(
        driver: (any UpdateDriver)? = AppUpdater.distributionDriver(),
        savePreference: (@MainActor (Bool, Bool) async throws -> Void)? = nil
    ) {
        self.driver = driver
        self.savePreference = savePreference
        driver?.availabilityChanged = { [weak self] in self?.refreshAvailability() }
        driver?.preferenceChanged = { [weak self] in self?.recordPreference() }
    }

    private static func distributionDriver() -> (any UpdateDriver)? {
        let environment = ProcessInfo.processInfo.environment
        guard environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1",
            let publicKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
            Data(base64Encoded: publicKey)?.count == 32
        else { return nil }
        #if DEBUG
            guard environment["TWINE_DATA_DIRECTORY"] != nil,
                let feed = environment["TWINE_TEST_UPDATE_FEED_URL"], let url = URL(string: feed),
                url.scheme == "http", url.host == "127.0.0.1"
            else { return nil }
            return SparkleUpdateDriver(testFeedURL: url)
        #else
            guard environment["TWINE_DATA_DIRECTORY"] == nil else { return nil }
            return SparkleUpdateDriver()
        #endif
    }

    func attach(coreClient: CoreClient, windows: FolderWindows) {
        savePreference = { enabled, previous in
            try await coreClient.setAutomaticUpdates(enabled, expectedPrevious: previous)
            do {
                try await windows.reloadConfig()
            } catch {
                updateLogger.error("Reloading update policy failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func apply(_ config: CoreUpdateConfig) {
        guard let driver, config != policy else { return }
        let channelChanged = policy?.channel != config.channel
        // A snapshot acknowledging our write must not discard a newer choice queued behind it.
        if config != pendingPolicy {
            policyRevision += 1
            desiredInstall = nil
        }
        policy = config
        driver.channel = config.channel
        driver.automaticallyChecks = config.automaticallyCheck
        driver.automaticallyDownloads = config.automaticallyCheck && (desiredInstall ?? config.automaticallyInstall)
        if !hasStarted {
            do {
                try driver.start()
                hasStarted = true
            } catch {
                failure = "Updates could not be started. Try again after reopening Twine."
                updateLogger.error("Updater startup failed: \(error.localizedDescription, privacy: .public)")
            }
        } else if channelChanged {
            driver.resetSchedule()
        }
        refreshAvailability()
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        driver?.check()
    }

    func finishSavingPreferences() async {
        // Sparkle binds its checkbox immediately. Quitting with its window open can skip
        // the selection delegate, so collect the live value before normal app shutdown.
        recordPreference()
        await saveTask?.value
    }

    private func refreshAvailability() {
        canCheckForUpdates = hasStarted && driver?.canCheck == true
    }

    private func recordPreference() {
        guard let driver, hasStarted, let policy, policy.automaticallyCheck, savePreference != nil else { return }
        let enabled = driver.automaticallyDownloads
        guard saveTask != nil || enabled != policy.automaticallyInstall else { return }
        desiredInstall = enabled
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in await self?.saveChoices() }
    }

    private func saveChoices() async {
        defer {
            pendingPolicy = nil
            saveTask = nil
        }
        while let enabled = desiredInstall, let policy, let savePreference {
            guard enabled != policy.automaticallyInstall else {
                desiredInstall = nil
                break
            }
            let revision = policyRevision
            var expectedPolicy = policy
            expectedPolicy.automaticallyInstall = enabled
            pendingPolicy = expectedPolicy
            do {
                try await savePreference(enabled, policy.automaticallyInstall)
                guard revision == policyRevision else { continue }
                self.policy?.automaticallyInstall = enabled
                failure = nil
                if desiredInstall == enabled { desiredInstall = nil }
            } catch {
                guard revision == policyRevision else { continue }
                desiredInstall = nil
                failure = "The update preference could not be saved. Change it in Settings."
                driver?.automaticallyDownloads =
                    self.policy?.automaticallyCheck == true
                    && self.policy?.automaticallyInstall == true
                updateLogger.error("Update preference save failed: \(error.localizedDescription, privacy: .public)")
            }
            pendingPolicy = nil
        }
    }
}
