import Foundation

extension CoreClient {
    func pollFiles(_ request: FileBrowserRequest) async throws -> FileBrowserSnapshot? {
        guard runState == .running, !isStopping, !isTerminating else { throw CoreFailure.notRunning }
        return try await transport.pollFiles(request)
    }

    func saveFile(_ request: FileSaveRequest) async throws -> FileSaveResult {
        guard runState == .running, !isStopping, !isTerminating else { throw CoreFailure.notRunning }
        return try await transport.saveFile(request)
    }
}
