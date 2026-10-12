import Foundation

extension CoreClient {
    func memoryCatalog(_ request: CoreMemoryRequest) async throws -> CoreMemoryCatalog {
        try await transport.memoryCatalog(request)
    }

    func memoryRead(_ request: CoreMemoryRequest) async throws -> CoreMemoryRead {
        try await transport.memoryRead(request)
    }

    func memorySave(_ request: CoreMemorySaveRequest) async throws -> FileSaveResult {
        try await transport.memorySave(request)
    }
}
