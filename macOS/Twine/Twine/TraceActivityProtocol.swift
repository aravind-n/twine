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
    var id: UInt64 { activityID }

    enum Kind: String, Decodable, Sendable {
        case tool, subagent

        var label: String { self == .tool ? "Tool call" : "Subagent" }
        var symbol: String { self == .tool ? "diamond" : "arrow.triangle.branch" }
    }

    enum Status: String, Decodable, Sendable {
        case running, completed, failed, interrupted
    }

    private enum CodingKeys: String, CodingKey {
        case activityID = "activityId"
        case spanID = "spanId"
        case parentActivityID = "parentActivityId"
        case kind, title, startedAt, endedAt, status, input, output, anchor
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

    private enum CodingKeys: String, CodingKey {
        case workflowID = "workflowId"
        case spanID = "spanId"
        case revision, activities, nextAfter
    }
}
