import Foundation

/// Text derived from the core's lifecycle and timestamps, independent of the visible tab's lifetime.
struct WorkflowFooterState {
    let status: String
    let elapsed: String
    /// The run's message, such as a review limit or a rejected completion.
    let message: String?

    init(workflow: CoreWorkflow, now: Date) {
        switch workflow.status {
        case .running: status = workflow.kind == .draft ? "Draft" : "Running"
        case .completed: status = "Completed"
        case .exited: status = "Exited"
        case .failed: status = "Failed"
        case .cancelled: status = "Cancelled"
        case .interrupted: status = "Interrupted"
        case .closed: status = "Closed"
        }
        message =
            switch workflow.run?.status {
            // These statuses' messages only repeat the status beside them.
            case nil, .completed, .cancelled, .interrupted: nil
            case .running, .limitReached, .failed:
                workflow.run?.message.flatMap { $0.isEmpty ? nil : $0 }
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
