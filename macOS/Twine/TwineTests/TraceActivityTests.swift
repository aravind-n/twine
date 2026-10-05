import Foundation
import Testing

@testable import Twine

nonisolated private func activity(
    _ id: UInt64, parent: UInt64? = nil, kind: CoreTraceActivity.Kind = .tool,
    start: UInt64? = 100, end: UInt64? = 200, status: CoreTraceActivity.Status = .completed
) -> CoreTraceActivity {
    .init(
        activityID: id, spanID: 10, parentActivityID: parent, kind: kind, title: "Activity \(id)",
        startedAt: start, endedAt: end, status: status, input: "Input \(id)", output: "Result \(id)", anchor: nil)
}

struct TraceActivityTimelineTests {
    @Test func optionalTimingAndParentsDecodeWithoutFabrication() throws {
        let json = """
            {"workflowId":1,"spanId":10,"revision":8,"nextAfter":null,"activities":[
              {"activityId":3,"spanId":10,"parentActivityId":8,"kind":"tool","title":"Read",
               "startedAt":null,"endedAt":200,"status":"completed","input":"","output":"ok","anchor":null}]}
            """
        let page = try JSONDecoder().decode(CoreTraceActivitiesPage.self, from: Data(json.utf8))
        let item = try #require(page.activities.first)
        #expect(item.parentActivityID == 8)
        #expect(item.startedAt == nil)
        #expect(item.durationLabel(at: 500) == "Timing incomplete")
    }

    @Test func nestedParallelChildrenRemainWithParentsArrivingLater() {
        let items = [
            activity(1, parent: 4), activity(2, parent: 3),
            activity(3, parent: 4, kind: .subagent), activity(4, kind: .subagent), activity(5),
        ]
        let rows = TraceActivityTimeline.rows(activities: items, collapsed: [], search: "", failuresOnly: false)
        #expect(rows.map(\.id) == [4, 1, 3, 2, 5])
        #expect(rows.map(\.depth) == [0, 1, 1, 2, 0])
        let collapsed = TraceActivityTimeline.rows(activities: items, collapsed: [4], search: "", failuresOnly: false)
        #expect(collapsed.map(\.id) == [4, 5])
    }

    @Test func filtersRevealMatchingDescendantsAndTheirAncestors() {
        let items = [activity(1, kind: .subagent), activity(2, parent: 1, status: .failed), activity(3, parent: 1)]
        let failed = TraceActivityTimeline.rows(activities: items, collapsed: [1], search: "", failuresOnly: true)
        #expect(failed.map(\.id) == [1, 2])
        let searched = TraceActivityTimeline.rows(
            activities: items, collapsed: [1], search: "Result 3", failuresOnly: false)
        #expect(searched.map(\.id) == [1, 3])
    }

    @Test func missingParentsAndCyclesDoNotHideActivityOrLoop() {
        let rows = TraceActivityTimeline.rows(
            activities: [activity(1, parent: 2), activity(2, parent: 1), activity(3, parent: 90)],
            collapsed: [], search: "", failuresOnly: false)
        #expect(Set(rows.map(\.id)) == [1, 2, 3])
        #expect(rows.count == 3)
    }

    @Test func backgroundChildrenRemainLiveAfterParentCompletionWithoutInventingMissingTiming() {
        let running = activity(1, end: nil, status: .running)
        #expect(running.end(at: 10_000) == 10_000)
        #expect(running.statusLabel == "Running")
        let interrupted = activity(3, end: nil, status: .interrupted)
        #expect(interrupted.end(at: 10_000) == nil)
        #expect(interrupted.durationLabel(at: 10_000) == "Timing incomplete")
        #expect(activity(2, start: 300, end: 200).durationLabel(at: 500) == "Timing incomplete")
        #expect(activity(4, start: 300, end: 300).durationLabel(at: 500) == "0ms")
        let span = CoreTraceSpan(
            spanID: 10, laneID: 1, title: "Prompt", startedAt: 100, endedAt: 600,
            status: .completed, terminalID: 1, isLive: false)
        let timeline = TraceActivityTimeline(span: span, activities: [running], now: 10_000)
        #expect(timeline.end == 10_000)
        #expect(timeline.fraction(50) == 0)
        #expect(timeline.fraction(100_000) == 1)
        #expect(TraceActivityTimeline(span: span, activities: [interrupted], now: 10_000).end == 600)
    }
}

@MainActor
struct TraceActivityStateTests {
    @Test func activityOutputJumpUsesTheRecordedCompletionBoundary() {
        let navigation = TraceTerminalNavigation()
        let anchor = CoreTraceAnchor(terminalID: 9, byteOffset: 42)
        let item = CoreTraceActivity(
            activityID: 1, spanID: 10, parentActivityID: nil, kind: .tool, title: "Read",
            startedAt: 100, endedAt: 200, status: .completed, input: "", output: "", anchor: anchor)
        let lane = CoreTraceLane(
            laneID: 3, workflowID: 5, name: "Agent", isAgent: true, role: nil, harness: "claude-code", agentID: 4)
        navigation.jump(to: item, lane: lane, fallbackTime: 50)
        #expect(navigation.scrollTarget?.timestamp == 200)
        #expect(navigation.scrollTarget?.anchor == anchor)
        #expect(navigation.scrollTarget?.workflowID == 5)
        #expect(navigation.scrollTarget?.agentID == 4)
    }

    @Test func refreshUpdatesLoadedActivityAndRetainsPaginationAndSelection() async throws {
        let transport = ActivityTestTransport()
        let client = CoreClient(transport: transport)
        client.start()
        try await waitUntil { client.runState == .running }
        let state = TraceActivityState()
        await state.refresh(spanID: 10, workflowID: 1, client: client)
        #expect(state.activities.map(\.id) == [1])
        #expect(state.activities.first?.status == .running)
        state.selectedActivityID = 1
        await state.refresh(spanID: 10, workflowID: 1, client: client, more: true)
        #expect(state.activities.map(\.id) == [1, 2])
        await transport.finish()
        await state.refresh(spanID: 10, workflowID: 1, client: client)
        #expect(state.activities.map(\.id) == [1, 2])
        #expect(state.activities.first?.status == .completed)
        #expect(state.selectedActivityID == 1)
        #expect(state.nextAfter == nil)
        await client.stop()
    }

    @Test func lateActivityReadCannotReplaceTheNewSelection() async throws {
        let transport = ActivityTestTransport()
        let client = CoreClient(transport: transport)
        client.start()
        try await waitUntil { client.runState == .running }
        let state = TraceActivityState()
        await transport.hold()
        let previous = Task { await state.refresh(spanID: 10, workflowID: 1, client: client) }
        try await waitUntil { await transport.hasPendingRead }
        await state.refresh(spanID: 20, workflowID: 2, client: client)
        #expect(state.activities.isEmpty)
        await transport.release()
        await previous.value
        #expect(state.spanID == 20)
        #expect(state.activities.isEmpty)
        #expect(state.nextAfter == nil)
        #expect(!state.isLoading)
        await client.stop()
    }

    @Test func liveRefreshPreservesPendingMoreActivityRequest() async throws {
        let transport = ActivityTestTransport()
        let client = CoreClient(transport: transport)
        client.start()
        try await waitUntil { client.runState == .running }
        let state = TraceActivityState()
        await state.refresh(spanID: 10, workflowID: 1, client: client)
        await transport.holdNextMoreRead()
        let more = Task { await state.refresh(spanID: 10, workflowID: 1, client: client, more: true) }
        try await waitUntil { await transport.hasPendingRead }
        await transport.finish()
        await state.refresh(spanID: 10, workflowID: 1, client: client)
        #expect(state.activities.map(\.id) == [1, 2])
        #expect(state.activities.first?.status == .completed)
        #expect(state.nextAfter == nil)
        await transport.release()
        await more.value
        #expect(state.activities.map(\.id) == [1, 2])
        #expect(!state.isLoading)
        await client.stop()
    }
}

private actor ActivityTestTransport: CoreTransport {
    private var finished = false
    private var held = false
    private var holdMore = false
    private var pending: CheckedContinuation<Void, Never>?
    var hasPendingRead: Bool { pending != nil }
    func hold() { held = true }
    func holdNextMoreRead() { holdMore = true }
    func finish() { finished = true }
    func release() {
        pending?.resume()
        pending = nil
        held = false
    }

    func traceActivities(spanID: UInt64, after: UInt64?, limit: UInt32) async -> CoreTraceActivitiesPage {
        if spanID == 10 && held { await withCheckedContinuation { pending = $0 } }
        if after != nil && holdMore {
            holdMore = false
            await withCheckedContinuation { pending = $0 }
        }
        let items: [CoreTraceActivity] =
            spanID != 10
            ? []
            : after == nil
                ? [activity(1, end: finished ? 200 : nil, status: finished ? .completed : .running)] : [activity(2)]
        return .init(
            workflowID: spanID / 10, spanID: spanID, revision: finished ? 3 : 2,
            activities: items, nextAfter: spanID == 10 && after == nil ? 1 : nil)
    }

    func open() -> CoreSnapshot { .testReady() }
    func close() {}
    func snapshot() -> CoreSnapshot { .testReady() }
    func pollFiles(_ request: FileBrowserRequest) -> FileBrowserSnapshot? { nil }
    func saveFile(_ request: FileSaveRequest) throws -> FileSaveResult { throw CoreFailure.unexpectedCommandResult }
    func send(_ command: CoreCommand) -> CoreCommandReceipt {
        CoreCommandReceipt(requestID: 1, status: .accepted, error: nil)
    }
    func events(after sequence: UInt64, limit: UInt32) -> [CoreEvent] { [] }
    func nextTerminalChunk() -> CoreTerminalChunk? { nil }
    func writeTerminalInput(terminalID: UInt64, bytes: Data) {}
    func resizeTerminal(terminalID: UInt64, size: CoreTerminalSize) {}
}
