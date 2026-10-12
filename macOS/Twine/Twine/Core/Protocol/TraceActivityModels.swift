import Foundation

nonisolated struct CoreTraceActivity: Decodable, Equatable, Identifiable, Sendable {
    let activityID: UInt64
    let spanID: UInt64
    let parentActivityID: UInt64?
    let kind: Kind
    let title: String
    let startedAt: UInt64?
    let endedAt: UInt64?
    let status: Status
    let input: String
    let output: String
    let anchor: CoreTraceAnchor?
    var metadata: CoreTraceMetadata?
    var inputBytes: UInt64?
    var outputBytes: UInt64?
    var inputVersion: String?
    var outputVersion: String?
    var id: UInt64 { activityID }

    enum Kind: String, Decodable, Sendable {
        case tool, subagent, model, note

        var label: String {
            switch self {
            case .tool: "Tool call"
            case .subagent: "Subagent"
            case .model: "LLM call"
            case .note: "Event"
            }
        }
        var symbol: String {
            switch self {
            case .tool: "diamond"
            case .subagent: "arrow.triangle.branch"
            case .model: "sparkles"
            case .note: "info.circle"
            }
        }
    }

    enum Status: String, Decodable, Sendable {
        case running, completed, failed, interrupted
    }

    private enum CodingKeys: String, CodingKey {
        case activityID = "activityId"
        case spanID = "spanId"
        case parentActivityID = "parentActivityId"
        case kind, title, startedAt, endedAt, status, input, output, anchor, metadata, inputBytes, outputBytes,
            inputVersion, outputVersion
    }

    func end(at now: UInt64) -> UInt64? {
        endedAt ?? (status == .running ? now : nil)
    }

    var statusLabel: String {
        switch status {
        case .running: "Running"
        case .completed: "Completed"
        case .failed: "Failed"
        case .interrupted: "Interrupted"
        }
    }

    func durationLabel(at now: UInt64) -> String {
        guard let startedAt, let end = end(at: now), end >= startedAt else { return "Timing incomplete" }
        return TraceActivityTimeline.duration(end - startedAt)
    }
}

nonisolated struct CoreTraceActivitiesPage: Decodable, Equatable, Sendable {
    let workflowID: UInt64
    let spanID: UInt64
    let revision: UInt64
    let activities: [CoreTraceActivity]
    let nextAfter: UInt64?
    var counts: CoreTraceActivityCounts?

    private enum CodingKeys: String, CodingKey {
        case workflowID = "workflowId"
        case spanID = "spanId"
        case revision, activities, nextAfter, counts
    }
}

nonisolated struct CoreTraceMetadata: Decodable, Equatable, Sendable {
    var model: String?
    var source: String?
    var responseId: String?
    var inputTokens: UInt64?
    var outputTokens: UInt64?
    var cacheReadTokens: UInt64?
    var cacheWriteTokens: UInt64?
    var totalTokens: UInt64?
    var reasoningTokens: UInt64?
    var cost: Double?
    var stopReason: String?
    var event: String?
    var trigger: String?
    var notificationType: String?
    var inputKind: String?
    var recordFormat: String?
}

nonisolated struct CoreTraceActivityCounts: Decodable, Equatable, Sendable {
    var tools: UInt64
    var subagents: UInt64
    var models: UInt64
    var notes: UInt64
    var failures: UInt64
    var label: String {
        "\(models) LLM calls · \(tools) tools · \(subagents) subagents · \(notes) events · \(failures) failures"
    }
}

nonisolated struct CoreTraceDetailPage: Decodable, Sendable {
    let activityId: UInt64
    let output: Bool
    let offset: UInt64
    let nextOffset: UInt64?
    let totalBytes: UInt64
    let text: String
    let version: String?
}
