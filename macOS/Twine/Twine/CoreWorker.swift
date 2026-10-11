import Foundation
import TwineCore

actor CoreWorker: CoreTransport {
    let memoryWorker = MemoryWorker()
    /// The directory where the core keeps its database.
    private let dataDirectory: URL
    private let windowMode: Bool
    private var client: OpaquePointer?
    private var nextRequestID: UInt64 = 1
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(dataDirectory: URL, windowMode: Bool = false) {
        self.dataDirectory = dataDirectory
        self.windowMode = windowMode
    }

    isolated deinit {
        if let client {
            _ = twine_client_destroy(client)
        }
    }

    func close() {
        guard let client else { return }
        _ = twine_client_destroy(client)
        self.client = nil
    }

    func send(_ command: CoreCommand) throws -> CoreCommandReceipt {
        let requestID = nextRequestID
        let (incrementedID, overflow) = requestID.addingReportingOverflow(1)
        guard !overflow else { throw CoreFailure.requestIDOverflow }
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
        return try decoder.decode(CoreCommandReceipt.self, from: consume(&response))
    }

    func snapshot() throws -> CoreSnapshot {
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

    /// Lists a harness's models on a core thread, polling between waits so the worker stays free for
    /// terminals and commands. Cancelling stops the harness.
    func harnessModels(_ request: HarnessModelsRequest) async throws -> CoreHarnessModelsResult {
        let data = try encoder.encode(request)
        var pending: OpaquePointer?
        let status = try withClient { client in
            data.withUnsafeBytes { bytes in
                twine_client_request_harness_models(
                    client, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, &pending)
            }
        }
        try check(status)
        defer { _ = twine_models_request_destroy(pending) }
        while true {
            try Task.checkCancellation()
            var response = TwineBuffer()
            let status = twine_models_request_poll(pending, &response)
            if status == TWINE_STATUS_EMPTY {
                try await Task.sleep(for: .milliseconds(50))
            } else {
                try check(status)
                return try decoder.decode(CoreHarnessModelsResult.self, from: consume(&response))
            }
        }
    }

    func saveFile(_ request: FileSaveRequest) throws -> FileSaveResult {
        let data = try encoder.encode(request)
        var response = TwineBuffer()
        let status = try withClient { client in
            data.withUnsafeBytes { bytes in
                twine_client_save_file(
                    client, bytes.bindMemory(to: UInt8.self).baseAddress,
                    bytes.count, &response)
            }
        }
        try check(status)
        return try decoder.decode(FileSaveResult.self, from: consume(&response))
    }

    func events(after sequence: UInt64, limit: UInt32) throws -> [CoreEvent] {
        var response = TwineBuffer()
        let status = try withClient { client in
            twine_client_events_after(client, sequence, limit, &response)
        }
        try check(status)
        return try decoder.decode(CoreEventBatch.self, from: consume(&response)).events
    }

    func nextTerminalChunk() throws -> CoreTerminalChunk? {
        var chunk = TwineTerminalChunk()
        let status = try withClient { client in
            twine_client_next_terminal_chunk(client, &chunk)
        }
        if status == TWINE_STATUS_EMPTY {
            return nil
        }
        try check(status)
        return CoreTerminalChunk(
            terminalID: chunk.terminal_id,
            offset: chunk.offset,
            bytes: try consume(&chunk.bytes)
        )
    }

    func terminalTranscript(terminalID: UInt64, offset: UInt64, limit: UInt32) async throws -> CoreTranscriptPage? {
        var request: OpaquePointer?
        while request == nil {
            try Task.checkCancellation()
            let status = try withClient { client in
                twine_client_request_transcript(client, terminalID, offset, limit, &request)
            }
            if status == TWINE_STATUS_EMPTY { try await Task.sleep(for: .milliseconds(10)) } else { try check(status) }
        }
        defer { _ = twine_transcript_request_destroy(request) }
        while true {
            try Task.checkCancellation()
            var response = TwineBuffer()
            let status = twine_transcript_request_poll(request, &response)
            if status == TWINE_STATUS_EMPTY {
                try await Task.sleep(for: .milliseconds(10))
            } else {
                try check(status)
                return try CoreTranscriptPage.decode(consume(&response))
            }
        }
    }

    func writeTerminalInput(terminalID: UInt64, bytes: Data) throws {
        try writeTerminalBytes(terminalID: terminalID, bytes: bytes, userInput: true)
    }

    func writeTerminalResponse(terminalID: UInt64, bytes: Data) throws {
        try writeTerminalBytes(terminalID: terminalID, bytes: bytes, userInput: false)
    }

    private func writeTerminalBytes(terminalID: UInt64, bytes: Data, userInput: Bool) throws {
        let status = try withClient { client in
            bytes.withUnsafeBytes { input in
                let write = userInput ? twine_client_write_terminal_input : twine_client_write_terminal_response
                return write(
                    client,
                    terminalID,
                    input.bindMemory(to: UInt8.self).baseAddress,
                    input.count
                )
            }
        }
        try checkTerminalStatus(status)
    }

    func resizeTerminal(terminalID: UInt64, size: CoreTerminalSize) throws {
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
        try checkTerminalStatus(status)
    }

    private func checkTerminalStatus(_ status: TwineStatus) throws {
        if status == TWINE_STATUS_TERMINAL_NOT_RUNNING { throw CoreFailure.terminalNotRunning }
        try check(status)
    }

    private func readSnapshot() throws -> CoreSnapshot {
        var response = TwineBuffer()
        let status = try withClient { client in
            twine_client_snapshot(client, &response)
        }
        try check(status)
        return try decoder.decode(CoreSnapshot.self, from: consume(&response))
    }

    private func withClient<T>(_ operation: (OpaquePointer) -> T) throws -> T {
        guard let client else { throw CoreFailure.nullPointer }
        return operation(client)
    }

    private func consume(_ buffer: inout TwineBuffer) throws -> Data {
        let data: Data
        if buffer.length == 0 {
            data = Data()
        } else {
            guard let bytes = buffer.data else { throw CoreFailure.nullPointer }
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
            throw CoreFailure.empty
        case TWINE_STATUS_NULL_POINTER:
            throw CoreFailure.nullPointer
        case TWINE_STATUS_INVALID_UTF8:
            throw CoreFailure.invalidUTF8
        case TWINE_STATUS_MALFORMED_COMMAND:
            throw CoreFailure.malformedCommand
        case TWINE_STATUS_INVALID_ARGUMENT:
            throw CoreFailure.invalidArgument
        case TWINE_STATUS_CURSOR_EXPIRED:
            throw CoreFailure.cursorExpired
        case TWINE_STATUS_INTERNAL_ERROR:
            throw CoreFailure.internalError
        case TWINE_STATUS_PANIC:
            throw CoreFailure.panic
        default:
            throw CoreFailure.unknownStatus(status.rawValue)
        }
    }
}

extension CoreWorker {
    /// Config access does not create or require a folder runtime.
    func configFile() throws -> FilePreview {
        var response = TwineBuffer()
        try check(twine_config_file(&response))
        return try decoder.decode(FilePreview.self, from: consume(&response))
    }

    func saveConfigFile(_ request: FileSaveRequest) throws -> FileSaveResult {
        let data = try encoder.encode(request)
        var response = TwineBuffer()
        let status = data.withUnsafeBytes { bytes in
            twine_config_save_file(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, &response)
        }
        try check(status)
        return try decoder.decode(FileSaveResult.self, from: consume(&response))
    }

    func open() throws -> CoreSnapshot {
        if client == nil {
            var createdClient: OpaquePointer?
            let path = Array(dataDirectory.path(percentEncoded: false).utf8)
            let windowMode = self.windowMode
            try check(
                path.withUnsafeBufferPointer {
                    if windowMode { return twine_client_create_window($0.baseAddress, $0.count, &createdClient) }
                    return twine_client_create($0.baseAddress, $0.count, &createdClient)
                })
            guard let createdClient else {
                throw CoreFailure.nullPointer
            }
            client = createdClient
        }
        return try readSnapshot()
    }

    func restorableFolders() throws -> [String] {
        var response = TwineBuffer()
        try check(try withClient { twine_client_restorable_folders($0, &response) })
        return try decoder.decode([String].self, from: consume(&response))
    }

}

extension CoreWorker {
    func workflowTrace(workflowID: UInt64, before: UInt64?, limit: UInt32) throws -> CoreWorkflowTracePage {
        var response = TwineBuffer()
        let status = try withClient { client in
            twine_client_workflow_trace(client, workflowID, before ?? 0, limit, &response)
        }
        try check(status)
        return try decoder.decode(CoreWorkflowTracePage.self, from: consume(&response))
    }

    func traceEvents(spanID: UInt64, after: UInt64?, limit: UInt32) throws -> CoreTraceEventsPage {
        var response = TwineBuffer()
        let status = try withClient { client in
            twine_client_trace_events(client, spanID, after ?? 0, limit, &response)
        }
        try check(status)
        return try decoder.decode(CoreTraceEventsPage.self, from: consume(&response))
    }

    func traceActivities(spanID: UInt64, after: UInt64?, limit: UInt32) throws -> CoreTraceActivitiesPage {
        var response = TwineBuffer()
        let status = try withClient { client in
            twine_client_trace_activities(client, spanID, after ?? 0, limit, &response)
        }
        try check(status)
        return try decoder.decode(CoreTraceActivitiesPage.self, from: consume(&response))
    }

    func traceDetail(activityID: UInt64, output: Bool, offset: UInt64, limit: UInt32) throws -> CoreTraceDetailPage {
        var response = TwineBuffer()
        let status = try withClient { client in
            twine_client_trace_detail(client, activityID, output, offset, limit, &response)
        }
        try check(status)
        return try decoder.decode(CoreTraceDetailPage.self, from: consume(&response))
    }

    func traceStorage(spanID: UInt64?, operation: UInt32) throws -> CoreTraceStorageStatus {
        var response = TwineBuffer()
        let status = try withClient { client in twine_client_trace_storage(client, spanID ?? 0, operation, &response) }
        try check(status)
        return try decoder.decode(CoreTraceStorageStatus.self, from: consume(&response))
    }
}
