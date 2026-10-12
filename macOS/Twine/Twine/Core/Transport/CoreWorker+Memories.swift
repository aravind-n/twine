import Foundation

extension CoreWorker {
    func memoryCatalog(_ request: CoreMemoryRequest) async throws -> CoreMemoryCatalog {
        try await memoryWorker.memoryCatalog(request)
    }

    func memoryRead(_ request: CoreMemoryRequest) async throws -> CoreMemoryRead {
        try await memoryWorker.memoryRead(request)
    }

    func memorySave(_ request: CoreMemorySaveRequest) async throws -> FileSaveResult {
        try await memoryWorker.memorySave(request)
    }
}
