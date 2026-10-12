import Foundation

nonisolated enum TraceViewMode: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case inDepth = "In Depth"
    var id: Self { self }
    var expandedHeight: CGFloat {
        self == .overview ? TracesLayout.expandedHeight : TracesLayout.expandedHeaderHeight + 384
    }
}
