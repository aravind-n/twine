import Foundation
import Sparkle

/// Adapts Sparkle's macOS installation machinery to the app's observed presentation state.
@MainActor
final class SparkleUpdateDriver: NSObject, UpdateDriver, SPUUpdaterDelegate {
    var channel = CoreUpdateConfig.Channel.stable
    var availabilityChanged: (@MainActor () -> Void)?
    var preferenceChanged: (@MainActor () -> Void)?
    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
    private var observation: NSKeyValueObservation?
    #if DEBUG
        private let testFeedURL: URL?
    #endif

    #if DEBUG
        init(testFeedURL: URL? = nil) {
            self.testFeedURL = testFeedURL
            super.init()
            observeAvailability()
        }
    #else
        override init() {
            super.init()
            observeAvailability()
        }
    #endif

    private func observeAvailability() {
        observation = controller.updater.observe(\.canCheckForUpdates) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.availabilityChanged?() }
        }
    }

    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    var automaticallyDownloads: Bool {
        get { controller.updater.automaticallyDownloadsUpdates }
        set { controller.updater.automaticallyDownloadsUpdates = newValue }
    }

    var canCheck: Bool { controller.updater.canCheckForUpdates }

    func start() throws {
        controller.updater.sendsSystemProfile = false
        try controller.updater.start()
    }

    func check() {
        #if DEBUG
            if testFeedURL != nil && ProcessInfo.processInfo.environment["TWINE_TEST_UPDATE_BACKGROUND"] == "1" {
                controller.updater.checkForUpdatesInBackground()
                return
            }
        #endif
        controller.checkForUpdates(nil)
    }
    func resetSchedule() { controller.updater.resetUpdateCycle() }

    func updater(
        _ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice,
        forUpdate item: SUAppcastItem, state: SPUUserUpdateState
    ) {
        preferenceChanged?()
    }

    #if DEBUG
        func updater(
            _ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
            immediateInstallationBlock: @escaping () -> Void
        ) -> Bool {
            guard testFeedURL != nil,
                let path = ProcessInfo.processInfo.environment["TWINE_TEST_UPDATE_READY_PATH"]
            else { return false }
            try? Data().write(to: URL(filePath: path))
            return false
        }

    #endif

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        channel == .nightly ? ["nightly"] : []
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        #if DEBUG
            if let testFeedURL { return testFeedURL.absoluteString }
        #endif
        return Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
    }
}
