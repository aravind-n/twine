import Foundation
import TwineCore

extension CoreClient {
    func memoryCatalog(_ request: CoreMemoryRequest) async throws -> CoreMemoryCatalog {
        try await transport.memoryCatalog(request)
    }

    func memoryRead(_ request: CoreMemoryRequest) async throws -> CoreMemoryRead {
        try await transport.memoryRead(request)
    }
}

extension CoreWorker {
    func memoryCatalog(_ request: CoreMemoryRequest) async throws -> CoreMemoryCatalog {
        try await memoryWorker.memoryCatalog(request)
    }

    func memoryRead(_ request: CoreMemoryRequest) async throws -> CoreMemoryRead {
        try await memoryWorker.memoryRead(request)
    }
}

/// Memory scans run independently so snapshots never hold up terminal I/O.
actor MemoryWorker {
    func memoryCatalog(_ request: CoreMemoryRequest) throws -> CoreMemoryCatalog {
        try Task.checkCancellation()
        let data = try JSONEncoder().encode(request)
        var response = TwineBuffer()
        let status = data.withUnsafeBytes { bytes in
            twine_memory_catalog(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, &response)
        }
        try checkMemoryStatus(status)
        return try JSONDecoder().decode(CoreMemoryCatalog.self, from: consumeMemory(&response))
    }

    func memoryRead(_ request: CoreMemoryRequest) throws -> CoreMemoryRead {
        try Task.checkCancellation()
        let data = try JSONEncoder().encode(request)
        var response = TwineBuffer()
        let status = data.withUnsafeBytes { bytes in
            twine_memory_read(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, &response)
        }
        try checkMemoryStatus(status)
        return try JSONDecoder().decode(CoreMemoryRead.self, from: consumeMemory(&response))
    }

    private func consumeMemory(_ buffer: inout TwineBuffer) throws -> Data {
        defer { _ = twine_buffer_release(&buffer) }
        guard let bytes = buffer.data else { throw CoreFailure.empty }
        return Data(bytes: bytes, count: buffer.length)
    }

    private func checkMemoryStatus(_ status: TwineStatus) throws {
        switch status {
        case TWINE_STATUS_OK: return
        case TWINE_STATUS_NULL_POINTER: throw CoreFailure.nullPointer
        case TWINE_STATUS_INVALID_UTF8: throw CoreFailure.invalidUTF8
        case TWINE_STATUS_MALFORMED_COMMAND: throw CoreFailure.malformedCommand
        case TWINE_STATUS_INVALID_ARGUMENT: throw CoreFailure.invalidArgument
        case TWINE_STATUS_PANIC: throw CoreFailure.panic
        default: throw CoreFailure.failed("The local memory source couldn't be read. Refresh and try again.")
        }
    }
}
