import Foundation

extension CoreClient {
    /// Settings access works independently of the folder runtime.
    func setAutomaticUpdates(_ enabled: Bool, expectedPrevious: Bool) async throws {
        let result = try await transport.setAutomaticUpdates(enabled, expectedPrevious: expectedPrevious)
        guard result.status == .saved else {
            throw CoreFailure.failed(result.message ?? "Settings changed before the update preference could be saved.")
        }
    }

    func configFile() async throws -> FilePreview {
        try await transport.configFile()
    }

    func saveConfigFile(_ request: FileSaveRequest) async throws -> FileSaveResult {
        try await transport.saveConfigFile(request)
    }

    func pollFiles(_ request: FileBrowserRequest) async throws -> FileBrowserSnapshot? {
        guard runState == .running, !isStopping, !isTerminating else { throw CoreFailure.notRunning }
        return try await transport.pollFiles(request)
    }

    func saveFile(_ request: FileSaveRequest) async throws -> FileSaveResult {
        guard runState == .running, !isStopping, !isTerminating else { throw CoreFailure.notRunning }
        return try await transport.saveFile(request)
    }
}
