import Foundation

/// Every start gets one column across all tracks. Stable lane IDs define track priority for ties.
nonisolated struct TraceSequenceLayout {
    struct Step: Identifiable, Equatable {
        let span: CoreTraceSpan
        let index: Int
        var id: UInt64 { span.id }
        var number: String { String(format: "%02d", index + 1) }
    }

    static let focusCount = 7
    let steps: [Step]

    init(spans: [CoreTraceSpan]) {
        steps = spans.sorted {
            if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
            if $0.laneID != $1.laneID { return $0.laneID < $1.laneID }
            return $0.id < $1.id
        }.enumerated().map { Step(span: $0.element, index: $0.offset) }
    }

    func focusedIndex(selectedID: UInt64?) -> Int? {
        steps.firstIndex { $0.id == selectedID } ?? steps.indices.last
    }

    func focusRange(selectedID: UInt64?) -> Range<Int> {
        guard let index = focusedIndex(selectedID: selectedID) else { return 0..<0 }
        let count = min(Self.focusCount, steps.count)
        let start = max(0, min(steps.count - count, index - count / 2))
        return start..<(start + count)
    }

    func neighbor(selectedID: UInt64?, offset: Int) -> UInt64? {
        guard let index = focusedIndex(selectedID: selectedID), steps.indices.contains(index + offset) else {
            return nil
        }
        return steps[index + offset].id
    }
}
