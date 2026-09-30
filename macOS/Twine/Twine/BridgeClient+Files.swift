import Foundation

extension BridgeClient {
    func pollFiles(_ request: FileBrowserRequest) async throws -> FileBrowserSnapshot? {
        guard connectionState == .running, !isStopping, !isTerminating else { throw BridgeFailure.notConnected }
        return try await transport.pollFiles(request)
    }

    func saveFile(_ request: FileSaveRequest) async throws -> FileSaveResult {
        guard connectionState == .running, !isStopping, !isTerminating else { throw BridgeFailure.notConnected }
        return try await transport.saveFile(request)
    }
}
