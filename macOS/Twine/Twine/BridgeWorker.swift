import Foundation
import TwineBridge

actor BridgeWorker: BridgeTransport {
    /// The directory where the core keeps its database.
    private let dataDirectory: URL
    private var client: OpaquePointer?
    private var nextRequestID: UInt64 = 1
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(dataDirectory: URL) {
        self.dataDirectory = dataDirectory
    }

    isolated deinit {
        if let client {
            _ = twine_client_destroy(client)
        }
    }

    func open() throws -> BridgeSnapshot {
        if client == nil {
            var createdClient: OpaquePointer?
            let path = Array(dataDirectory.path(percentEncoded: false).utf8)
            try check(path.withUnsafeBufferPointer { twine_client_create($0.baseAddress, $0.count, &createdClient) })
            guard let createdClient else {
                throw BridgeFailure.nullPointer
            }
            client = createdClient
        }
        return try readSnapshot()
    }

    func close() {
        guard let client else { return }
        _ = twine_client_destroy(client)
        self.client = nil
    }

    func send(_ command: BridgeCommand) throws -> BridgeCommandReceipt {
        let requestID = nextRequestID
        let (incrementedID, overflow) = requestID.addingReportingOverflow(1)
        guard !overflow else { throw BridgeFailure.requestIDOverflow }
        nextRequestID = incrementedID

        let data = try encoder.encode(CommandEnvelope(requestID: requestID, command: command))
        var response = TwineBuffer()
        let status = try withClient { client in
            data.withUnsafeBytes { bytes in
                twine_client_send_command(
                    client,
                    bytes.bindMemory(to: UInt8.self).baseAddress,
                    bytes.count,
                    &response
                )
            }
        }
        try check(status)
        return try decoder.decode(BridgeCommandReceipt.self, from: consume(&response))
    }

    func snapshot() throws -> BridgeSnapshot {
        try readSnapshot()
    }

    func pollFiles(_ request: FileBrowserRequest) throws -> FileBrowserSnapshot? {
        let data = try encoder.encode(request)
        var response = TwineBuffer()
        let status = try withClient { client in
            data.withUnsafeBytes { bytes in
                twine_client_poll_files(
                    client, bytes.bindMemory(to: UInt8.self).baseAddress,
                    bytes.count, &response)
            }
        }
        if status == TWINE_STATUS_EMPTY { return nil }
        try check(status)
        return try decoder.decode(FileBrowserSnapshot.self, from: consume(&response))
    }

    func events(after sequence: UInt64, limit: UInt32) throws -> [BridgeEvent] {
        var response = TwineBuffer()
        let status = try withClient { client in
            twine_client_events_after(client, sequence, limit, &response)
        }
        try check(status)
        return try decoder.decode(BridgeEventBatch.self, from: consume(&response)).events
    }

    func nextTerminalChunk() throws -> BridgeTerminalChunk? {
        var chunk = TwineTerminalChunk()
        let status = try withClient { client in
            twine_client_next_terminal_chunk(client, &chunk)
        }
        if status == TWINE_STATUS_EMPTY {
            return nil
        }
        try check(status)
        return BridgeTerminalChunk(
            terminalID: chunk.terminal_id,
            offset: chunk.offset,
            bytes: try consume(&chunk.bytes)
        )
    }

    func writeTerminalInput(terminalID: UInt64, bytes: Data) throws {
        let status = try withClient { client in
            bytes.withUnsafeBytes { input in
                twine_client_write_terminal_input(
                    client,
                    terminalID,
                    input.bindMemory(to: UInt8.self).baseAddress,
                    input.count
                )
            }
        }
        try check(status)
    }

    func resizeTerminal(terminalID: UInt64, size: BridgeTerminalSize) throws {
        let status = try withClient { client in
            twine_client_resize_terminal(
                client,
                terminalID,
                size.rows,
                size.columns,
                size.pixelWidth,
                size.pixelHeight
            )
        }
        try check(status)
    }

    private func readSnapshot() throws -> BridgeSnapshot {
        var response = TwineBuffer()
        let status = try withClient { client in
            twine_client_snapshot(client, &response)
        }
        try check(status)
        return try decoder.decode(BridgeSnapshot.self, from: consume(&response))
    }

    private func withClient<T>(_ operation: (OpaquePointer) -> T) throws -> T {
        guard let client else { throw BridgeFailure.nullPointer }
        return operation(client)
    }

    private func consume(_ buffer: inout TwineBuffer) throws -> Data {
        let data: Data
        if buffer.length == 0 {
            data = Data()
        } else {
            guard let bytes = buffer.data else { throw BridgeFailure.nullPointer }
            data = Data(bytes: bytes, count: buffer.length)
        }
        try check(twine_buffer_release(&buffer))
        return data
    }

    private func check(_ status: TwineStatus) throws {
        switch status {
        case TWINE_STATUS_OK:
            return
        case TWINE_STATUS_EMPTY:
            throw BridgeFailure.empty
        case TWINE_STATUS_NULL_POINTER:
            throw BridgeFailure.nullPointer
        case TWINE_STATUS_INVALID_UTF8:
            throw BridgeFailure.invalidUTF8
        case TWINE_STATUS_MALFORMED_COMMAND:
            throw BridgeFailure.malformedCommand
        case TWINE_STATUS_INVALID_ARGUMENT:
            throw BridgeFailure.invalidArgument
        case TWINE_STATUS_CURSOR_EXPIRED:
            throw BridgeFailure.cursorExpired
        case TWINE_STATUS_INTERNAL_ERROR:
            throw BridgeFailure.internalError
        case TWINE_STATUS_PANIC:
            throw BridgeFailure.panic
        default:
            throw BridgeFailure.unknownStatus(status.rawValue)
        }
    }
}
