/// Presentation state only. Prefer the next neighbor when the selected tab closes, then the previous.
struct WorkflowTabSelection {
    var selectedID: UInt64?
    private var sessionID: UInt64?
    private var selectedBySession: [UInt64: UInt64] = [:]
    private var workflowIDs: [UInt64] = []

    mutating func reconcile(sessionID: UInt64?, current: [UInt64]) {
        if self.sessionID != sessionID {
            if let previous = self.sessionID { selectedBySession[previous] = selectedID }
            self.sessionID = sessionID
            selectedID = sessionID.flatMap { selectedBySession[$0] }
            workflowIDs = []
        }
        reconcile(previous: workflowIDs, current: current)
        workflowIDs = current
    }

    mutating func reconcile(previous: [UInt64], current: [UInt64]) {
        if let selectedID, current.contains(selectedID) { return }
        let oldIndex = selectedID.flatMap { previous.firstIndex(of: $0) } ?? 0
        selectedID = current.isEmpty ? nil : current[min(oldIndex, current.count - 1)]
    }
}
