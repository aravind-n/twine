import Foundation

/// Text derived from the core's lifecycle and timestamps, independent of the visible tab's lifetime.
struct WorkflowFooterState {
    let status: String
    let elapsed: String

    init(workflow: BridgeWorkflow, now: Date) {
        switch workflow.status {
        case .running: status = workflow.kind == .draft ? "Draft" : "Running"
        case .exited: status = "Exited"
        case .failed: status = "Failed"
        case .cancelled: status = "Cancelled"
        case .interrupted: status = "Interrupted"
        case .closed: status = "Closed"
        }
        let end = workflow.endedAt.map { Double($0) / 1_000 } ?? now.timeIntervalSince1970
        let seconds = Int(max(0, end - Double(workflow.startedAt) / 1_000))
        let remainder = String(format: "%02d", seconds % 60)
        elapsed =
            if seconds >= 3_600 {
                "\(seconds / 3_600):\(String(format: "%02d", (seconds / 60) % 60)):\(remainder)"
            } else {
                "\(seconds / 60):\(remainder)"
            }
    }
}
