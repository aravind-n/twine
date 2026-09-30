import Testing

@testable import Twine

struct TraceSequenceTests {
    @Test func allAgentsShareOneStartOrderRegardlessOfPauseOrDuration() {
        for pause: UInt64 in [1, 1_080_000, 7_200_000] {
            let layout = TraceSequenceLayout(spans: [
                span(3, lane: 1, start: 100 + pause),
                span(1, lane: 2, start: 0, end: nil),
                span(2, lane: 3, start: 100, end: 200 + pause),
            ])
            #expect(layout.steps.map(\.id) == [1, 2, 3])
            #expect(layout.steps.map(\.index) == [0, 1, 2])
        }
    }

    @Test func exactTiesUseTrackPriorityThenSpanIDWithoutSharingColumns() {
        let spans = [span(1, lane: 3), span(4, lane: 1), span(2, lane: 2), span(3, lane: 1)]
        for input in [spans, Array(spans.reversed())] {
            let layout = TraceSequenceLayout(spans: Array(input))
            #expect(layout.steps.map(\.id) == [3, 4, 2, 1])
            #expect(layout.steps.map(\.index) == [0, 1, 2, 3])
        }
    }

    @Test(arguments: [UInt64(1), 2, 3, 4, 5, 8, 12, 13, 14, 15])
    func sevenStepsStayCenteredUntilAnEdgeIsReached(selected: UInt64) {
        let layout = TraceSequenceLayout(spans: (1...15).map { span(UInt64($0), start: UInt64($0)) })
        let range = layout.focusRange(selectedID: selected)
        #expect(range.count == 7)
        #expect(range.contains(Int(selected) - 1))
        #expect(range.lowerBound == max(0, min(8, Int(selected) - 4)))
        #expect(layout.neighbor(selectedID: selected, offset: -1) == (selected == 1 ? nil : selected - 1))
        #expect(layout.neighbor(selectedID: selected, offset: 1) == (selected == 15 ? nil : selected + 1))
    }

    @Test func emptyAndShortHistoriesHaveNoPhantomSteps() {
        for count in 0...7 {
            let layout = TraceSequenceLayout(spans: (0..<count).map { span(UInt64($0)) })
            #expect(layout.focusRange(selectedID: nil) == 0..<count)
            #expect(layout.focusRange(selectedID: 999) == 0..<count)
            #expect(layout.neighbor(selectedID: nil, offset: 1) == nil)
        }
    }

    @Test func refreshAndOlderHistoryPreserveSelectionByIdentity() {
        let spans = (10...25).map { span(UInt64($0), start: UInt64($0)) }
        let initial = TraceSequenceLayout(spans: Array(spans.prefix(15)))
        #expect(initial.focusRange(selectedID: nil) == 8..<15)
        let refreshed = TraceSequenceLayout(spans: spans)
        #expect(refreshed.steps[refreshed.focusRange(selectedID: 18)].map(\.id) == [15, 16, 17, 18, 19, 20, 21])
        let older = TraceSequenceLayout(spans: spans + [span(2, start: 2), span(1, start: 1)])
        #expect(older.steps[older.focusRange(selectedID: 18)].map(\.id) == [15, 16, 17, 18, 19, 20, 21])
        #expect(refreshed.focusRange(selectedID: nil) == 9..<16)
    }

    private func span(_ id: UInt64, lane: UInt64 = 1, start: UInt64 = 0, end: UInt64? = 100) -> CoreTraceSpan {
        CoreTraceSpan(
            spanID: id, laneID: lane, title: "Step \(id)", startedAt: start, endedAt: end,
            status: end == nil ? .running : .completed, terminalID: nil, isLive: end == nil)
    }
}
