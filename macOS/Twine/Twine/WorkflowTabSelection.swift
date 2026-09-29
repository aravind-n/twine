/// Presentation state only. Prefer the next neighbor when the selected tab closes, then the previous.
struct WorkflowTabSelection {
    var selectedID: UInt64?

    mutating func reconcile(previous: [UInt64], current: [UInt64]) {
        if let selectedID, current.contains(selectedID) { return }
        let oldIndex = selectedID.flatMap { previous.firstIndex(of: $0) } ?? 0
        selectedID = current.isEmpty ? nil : current[min(oldIndex, current.count - 1)]
    }
}
