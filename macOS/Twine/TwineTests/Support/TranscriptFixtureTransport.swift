import Foundation

@testable import Twine

actor TranscriptFixtureTransport {
    private let bytes: Data?
    private let transcripts: [UInt64: Data]
    private let replayAvailable: Bool
    private var delayed: Bool
    private var trace: CoreWorkflowTracePage?
    private var recordedEvents: [CoreTraceEvent]
    private var pending: CheckedContinuation<Void, Never>?
    private(set) var readLimits: [UInt32] = []
    var hasPendingRead: Bool { pending != nil }

    init(
        bytes: Data?, replayAvailable: Bool = true, delayed: Bool = false,
        trace: CoreWorkflowTracePage? = nil, recordedEvents: [CoreTraceEvent] = [],
        transcripts: [UInt64: Data] = [:]
    ) {
        self.bytes = bytes
        self.transcripts = transcripts
        self.replayAvailable = replayAvailable
        self.delayed = delayed
        self.trace = trace
        self.recordedEvents = recordedEvents
    }

    func release() {
        pending?.resume()
        pending = nil
    }

    func setDelayed(_ value: Bool) { delayed = value }

    func replaceEvents(_ events: [CoreTraceEvent]) { recordedEvents = events }
    func replaceTrace(_ trace: CoreWorkflowTracePage) { self.trace = trace }

    func terminalTranscript(terminalID: UInt64, offset: UInt64, limit: UInt32) async -> CoreTranscriptPage? {
        readLimits.append(limit)
        if delayed { await withCheckedContinuation { pending = $0 } }
        guard let bytes = transcripts[terminalID] ?? bytes else { return nil }
        let start = min(Int(offset), bytes.count)
        let end = min(start + Int(limit), bytes.count)
        return .init(
            offset: offset, nextOffset: UInt64(end), endOffset: UInt64(bytes.count),
            sizes: offset == 0 && end > 0 ? [.init(offset: 0, rows: 24, columns: 80)] : [],
            bytes: bytes.subdata(in: start..<end), replayAvailable: replayAvailable)
    }

    func open() -> CoreSnapshot { .testReady() }
    func close() {}
    func snapshot() -> CoreSnapshot { .testReady() }
    func pollFiles(_ request: FileBrowserRequest) -> FileBrowserSnapshot? { nil }
    func saveFile(_ request: FileSaveRequest) throws -> FileSaveResult { throw CoreFailure.unexpectedCommandResult }
    func send(_ command: CoreCommand) -> CoreCommandReceipt {
        CoreCommandReceipt(requestID: 1, status: .accepted, error: nil)
    }
    func events(after sequence: UInt64, limit: UInt32) -> [CoreEvent] { [] }
    func nextTerminalChunk() -> CoreTerminalChunk? { nil }
    func writeTerminalInput(terminalID: UInt64, bytes: Data) {}
    func resizeTerminal(terminalID: UInt64, size: CoreTerminalSize) {}
    func workflowTrace(workflowID: UInt64, before: UInt64?, limit: UInt32) throws -> CoreWorkflowTracePage {
        if let trace { return trace }
        throw CoreFailure.unexpectedCommandResult
    }
    func traceEvents(spanID: UInt64, after: UInt64?, limit: UInt32) throws -> CoreTraceEventsPage {
        guard let trace else { throw CoreFailure.unexpectedCommandResult }
        let remaining = recordedEvents.filter { $0.spanID == spanID && $0.id > (after ?? 0) }
        let events = Array(remaining.prefix(Int(limit)))
        return .init(
            workflowID: trace.summary.workflowID, spanID: spanID, revision: trace.summary.revision,
            events: events, nextAfter: remaining.count > events.count ? events.last?.id : nil)
    }
}

// Declaring this conformance on the actor fails to compile in batch mode in Xcode 27.0.
extension TranscriptFixtureTransport: CoreTransport {}
