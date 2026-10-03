import Foundation
import OSLog

private let coreLogger = Logger(subsystem: "com.twineproject.Twine", category: "core")

extension CoreClient {
    /// Waits until twine-core is running. Throws if it fails or the waiting task is cancelled.
    func waitUntilRunning() async throws {
        while true {
            try Task.checkCancellation()
            switch runState {
            case .running:
                return
            case .failed(let message):
                throw CoreFailure.failed(message)
            case .idle, .starting:
                try await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    /// Sends a command whose outcome arrives as state events, logging a rejection or failure.
    func perform(_ command: CoreCommand) async {
        do {
            let receipt = try await send(command)
            if let rejection = receipt.error {
                coreLogger.notice("Command rejected: \(rejection.code, privacy: .public)")
            }
        } catch {
            coreLogger.error("Command failed: \(error.localizedDescription, privacy: .public)")
        }
    }

}
