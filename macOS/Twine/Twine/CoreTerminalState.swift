import Foundation

nonisolated struct CoreTerminalChunk: Equatable, Sendable {
    let terminalID: UInt64
    let offset: UInt64
    let bytes: Data
}

nonisolated struct CoreTerminalExit: Decodable, Equatable, Sendable {
    let exitCode: UInt32
    let signal: String?
}

nonisolated struct CoreTerminalState: Decodable, Equatable, Sendable {
    let terminalID: UInt64
    let status: Status

    enum Status: Equatable, Sendable {
        case running
        case exited(CoreTerminalExit)
        case failed(message: String)
    }

    private enum CodingKeys: String, CodingKey {
        case exitCode
        case message
        case signal
        case status
        case terminalID = "terminalId"
    }

    private enum WireStatus: String, Decodable {
        case exited
        case failed
        case running
    }

    init(terminalID: UInt64, status: Status) {
        self.terminalID = terminalID
        self.status = status
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        terminalID = try container.decode(UInt64.self, forKey: .terminalID)
        switch try container.decode(WireStatus.self, forKey: .status) {
        case .running:
            status = .running
        case .exited:
            status = .exited(
                CoreTerminalExit(
                    exitCode: try container.decode(UInt32.self, forKey: .exitCode),
                    signal: try container.decodeIfPresent(String.self, forKey: .signal)
                )
            )
        case .failed:
            status = .failed(message: try container.decode(String.self, forKey: .message))
        }
    }
}
