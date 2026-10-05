import Foundation

extension CoreClient {
    /// Settings access works independently of the folder runtime.
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
