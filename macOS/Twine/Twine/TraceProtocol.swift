import Foundation

nonisolated struct BridgeTraceSummary: Decodable, Equatable, Sendable {
    let workflowID: UInt64
    let revision: UInt64
    let spanCount: UInt64
    let agentCount: UInt64

    private enum CodingKeys: String, CodingKey {
        case workflowID = "workflowId"
        case revision, spanCount, agentCount
    }
}

nonisolated struct BridgeTraceLane: Decodable, Equatable, Identifiable, Sendable {
    let laneID: UInt64
    let workflowID: UInt64
    let name: String
    let isAgent: Bool
    let role: String?
    let harness: String?
    var id: UInt64 { laneID }

    private enum CodingKeys: String, CodingKey {
        case laneID = "laneId"
        case workflowID = "workflowId"
        case name, isAgent, role, harness
    }
}

nonisolated struct BridgeTraceSpan: Decodable, Equatable, Identifiable, Sendable {
    let spanID: UInt64
    let laneID: UInt64
    let title: String
    let startedAt: UInt64
    let endedAt: UInt64?
    let status: Status
    let terminalID: UInt64?
    let isLive: Bool
    var id: UInt64 { spanID }

    enum Status: String, Decodable, Sendable {
        case running, exited, failed, stopped
    }

    private enum CodingKeys: String, CodingKey {
        case spanID = "spanId"
        case laneID = "laneId"
        case terminalID = "terminalId"
        case title, startedAt, endedAt, status, isLive
    }

    func end(at now: UInt64) -> UInt64 {
        max(startedAt, endedAt ?? (isLive ? now : startedAt))
    }

    var statusLabel: String {
        switch status {
        case .running: isLive ? "Running" : "End not recorded"
        case .exited: "Exited"
        case .failed: "Failed"
        case .stopped: "Stopped"
        }
    }

    var statusSymbol: String {
        switch status {
        case .running: isLive ? "circle.fill" : "questionmark.circle"
        case .exited: "stop.circle"
        case .failed: "exclamationmark.circle"
        case .stopped: "stop.circle"
        }
    }
}

nonisolated struct BridgeTraceEvent: Decodable, Equatable, Identifiable, Sendable {
    let eventID: UInt64
    let workflowID: UInt64
    let spanID: UInt64?
    let timestamp: UInt64
    let kind: Kind
    let message: String
    let anchor: BridgeTraceAnchor?
    var id: UInt64 { eventID }

    enum Kind: String, Decodable, Sendable {
        case processStarted, processExited, processFailed, processStopped, workflowEvent

        var label: String {
            switch self {
            case .processStarted: "start"
            case .processExited: "exit"
            case .processFailed: "failure"
            case .processStopped: "stop"
            case .workflowEvent: "workflow"
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case eventID = "eventId"
        case workflowID = "workflowId"
        case spanID = "spanId"
        case timestamp, kind, message, anchor
    }
}

nonisolated struct BridgeWorkflowTracePage: Decodable, Equatable, Sendable {
    let summary: BridgeTraceSummary
    let lanes: [BridgeTraceLane]
    let spans: [BridgeTraceSpan]
    let nextBefore: UInt64?
}

nonisolated struct BridgeTraceEventsPage: Decodable, Equatable, Sendable {
    let workflowID: UInt64
    let spanID: UInt64
    let revision: UInt64
    let events: [BridgeTraceEvent]
    let nextAfter: UInt64?

    private enum CodingKeys: String, CodingKey {
        case workflowID = "workflowId"
        case spanID = "spanId"
        case revision, events, nextAfter
    }
}

nonisolated struct BridgeTraceAnchor: Decodable, Equatable, Sendable {
    let terminalID: UInt64
    let byteOffset: UInt64
    private enum CodingKeys: String, CodingKey {
        case terminalID = "terminalId"
        case byteOffset
    }
}
