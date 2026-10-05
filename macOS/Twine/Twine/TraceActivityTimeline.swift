import Foundation

/// Presentation geometry uses elapsed time within a step, independently of its overview position.
nonisolated struct TraceActivityTimeline {
    struct Row: Identifiable {
        let activity: CoreTraceActivity
        let depth: Int
        let hasChildren: Bool
        var id: UInt64 { activity.id }
    }

    let start: UInt64
    let end: UInt64

    init(span: CoreTraceSpan, activities: [CoreTraceActivity], now: UInt64) {
        start = min(span.startedAt, activities.compactMap(\.startedAt).min() ?? span.startedAt)
        end = max(
            start, span.end(at: now),
            activities.compactMap { $0.end(at: now) }.max() ?? start)
    }

    func fraction(_ time: UInt64) -> Double {
        let duration = max(1, end - start)
        return min(1, Double(time > start ? time - start : 0) / Double(duration))
    }

    static func duration(_ milliseconds: UInt64) -> String {
        if milliseconds < 1_000 { return "\(milliseconds)ms" }
        if milliseconds < 10_000 { return String(format: "%.1fs", Double(milliseconds) / 1_000) }
        return TraceFormatting.elapsed(milliseconds)
    }

    static func rows(
        activities: [CoreTraceActivity], collapsed: Set<UInt64>, search: String, failuresOnly: Bool
    ) -> [Row] {
        let ordered = activities.sorted {
            if $0.startedAt == $1.startedAt { return $0.id < $1.id }
            return ($0.startedAt ?? UInt64.max) < ($1.startedAt ?? UInt64.max)
        }
        let byID = Dictionary(ordered.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtering = !query.isEmpty || failuresOnly
        var included = Set(
            ordered.filter {
                (!failuresOnly || $0.status == .failed)
                    && (query.isEmpty || "\($0.title) \($0.input) \($0.output)".localizedCaseInsensitiveContains(query))
            }.map(\.id))
        if filtering {
            for activity in ordered where included.contains(activity.id) {
                var parent = activity.parentActivityID
                var visited: Set<UInt64> = [activity.id]
                while let id = parent, let ancestor = byID[id], visited.insert(id).inserted {
                    included.insert(id)
                    parent = ancestor.parentActivityID
                }
            }
        }
        let children = Dictionary(grouping: ordered) { activity in
            activity.parentActivityID.flatMap { byID[$0] == nil ? nil : $0 } ?? 0
        }
        var rows: [Row] = []
        var visited: Set<UInt64> = []
        func append(_ activity: CoreTraceActivity, depth: Int) {
            guard visited.insert(activity.id).inserted else { return }
            let descendants = children[activity.id] ?? []
            if !filtering || included.contains(activity.id) {
                rows.append(Row(activity: activity, depth: depth, hasChildren: !descendants.isEmpty))
            }
            if filtering || !collapsed.contains(activity.id) {
                for child in descendants { append(child, depth: min(depth + 1, 12)) }
            } else {
                // Mark the hidden subtree so the orphan/cycle fallback cannot surface it again.
                var pending = descendants
                while let child = pending.popLast() {
                    guard visited.insert(child.id).inserted else { continue }
                    pending.append(contentsOf: children[child.id] ?? [])
                }
            }
        }
        for activity in children[0] ?? [] { append(activity, depth: 0) }
        // Incomplete pages and malformed relationships must still leave recorded activity accessible.
        for activity in ordered where !visited.contains(activity.id) { append(activity, depth: 0) }
        return rows
    }
}
