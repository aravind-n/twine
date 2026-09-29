import Foundation

nonisolated enum BridgeCommand: Sendable {
    case ping
}

nonisolated struct BridgeCommandReceipt: Decodable, Equatable, Sendable {
    let requestID: UInt64
    let status: Status
    let error: Rejection?

    enum Status: String, Decodable, Sendable {
        case accepted
        case rejected
    }

    struct Rejection: Decodable, Equatable, Sendable {
        let code: String
        let message: String
    }

    private enum CodingKeys: String, CodingKey {
        case error
        case requestID = "requestId"
        case status
    }
}

nonisolated struct BridgeSnapshot: Decodable, Equatable, Sendable {
    var sequence: UInt64
    var state: BridgeApplicationState
}

nonisolated struct BridgeApplicationState: Decodable, Equatable, Sendable {
    var status: Status

    enum Status: String, Decodable, Sendable {
        case ready
    }
}

nonisolated struct BridgeEventBatch: Decodable, Sendable {
    let events: [BridgeEvent]
}

nonisolated struct BridgeEvent: Decodable, Equatable, Sendable {
    let sequence: UInt64
    let event: Kind

    enum Kind: Equatable, Sendable {
        case applicationReady
        case commandCompleted(requestID: UInt64, result: BridgeCommandResult)
    }

    private enum CodingKeys: CodingKey {
        case sequence
        case event
    }

    init(sequence: UInt64, event: Kind) {
        self.sequence = sequence
        self.event = event
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sequence = try container.decode(UInt64.self, forKey: .sequence)
        event = try container.decode(EventPayload.self, forKey: .event).kind
    }
}

nonisolated enum BridgeCommandResult: Equatable, Sendable {
    case pong
}

nonisolated struct BridgeCommandCompletion: Equatable, Sendable {
    let requestID: UInt64
    let result: BridgeCommandResult
}

nonisolated struct BridgeTerminalChunk: Equatable, Sendable {
    let terminalID: UInt64
    let offset: UInt64
    let bytes: Data
}

nonisolated enum BridgeFailure: Error, Equatable, LocalizedError, Sendable {
    case cursorExpired
    case empty
    case internalError
    case invalidArgument
    case invalidUTF8
    case malformedCommand
    case nullPointer
    case panic
    case requestIDOverflow
    case unknownStatus(UInt32)

    var errorDescription: String? {
        switch self {
        case .cursorExpired:
            "The bridge event cursor expired."
        case .empty:
            "The bridge has no value available."
        case .internalError:
            "The Rust core reported an internal error."
        case .invalidArgument:
            "The bridge received an invalid argument."
        case .invalidUTF8:
            "The bridge received invalid UTF-8."
        case .malformedCommand:
            "The bridge command was malformed."
        case .nullPointer:
            "The bridge received a null pointer."
        case .panic:
            "The bridge contained an internal Rust panic."
        case .requestIDOverflow:
            "The bridge request ID counter overflowed."
        case .unknownStatus(let status):
            "The bridge returned unknown status \(status)."
        }
    }
}

nonisolated protocol BridgeTransport: Sendable {
    func open() async throws -> BridgeSnapshot
    func close() async
    func send(_ command: BridgeCommand) async throws -> BridgeCommandReceipt
    func snapshot() async throws -> BridgeSnapshot
    func events(after sequence: UInt64, limit: UInt32) async throws -> [BridgeEvent]
    func nextTerminalChunk() async throws -> BridgeTerminalChunk?
}

nonisolated private struct EventPayload: Decodable {
    let kind: BridgeEvent.Kind

    private enum CodingKeys: String, CodingKey {
        case requestID = "requestId"
        case result
        case type
    }

    private enum EventType: String, Decodable {
        case applicationReady
        case commandCompleted
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(EventType.self, forKey: .type) {
        case .applicationReady:
            kind = .applicationReady
        case .commandCompleted:
            kind = .commandCompleted(
                requestID: try container.decode(UInt64.self, forKey: .requestID),
                result: try container.decode(CommandResultPayload.self, forKey: .result).result
            )
        }
    }
}

nonisolated private struct CommandResultPayload: Decodable {
    let result: BridgeCommandResult

    private enum CodingKeys: String, CodingKey {
        case type
    }

    private enum ResultType: String, Decodable {
        case pong
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(ResultType.self, forKey: .type) {
        case .pong:
            result = .pong
        }
    }
}
