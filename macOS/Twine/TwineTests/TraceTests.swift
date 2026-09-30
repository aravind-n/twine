import Foundation
import Testing

@testable import Twine

nonisolated private func traceSpan(
    id: UInt64 = 1, laneID: UInt64 = 1, start: UInt64 = 0, end: UInt64? = 100,
    status: CoreTraceSpan.Status = .exited, live: Bool = false
) -> CoreTraceSpan {
    CoreTraceSpan(
        spanID: id, laneID: laneID, title: "Shell", startedAt: start,
        endedAt: end, status: status, terminalID: id, isLive: live)
}

nonisolated private func tracePage(workflowID: UInt64, spanID: UInt64) -> CoreWorkflowTracePage {
    CoreWorkflowTracePage(
        summary: .init(workflowID: workflowID, revision: 2, spanCount: 1, agentCount: 0),
        lanes: [
            .init(
                laneID: workflowID, workflowID: workflowID, name: "Terminal", isAgent: false,
                role: nil, harness: nil)
        ],
        spans: [traceSpan(id: spanID, laneID: workflowID)], nextBefore: nil)
}

struct TraceTimelineTests {
    @Test func assignmentCompletionAndLegacyProcessExitRemainDistinct() throws {
        for (status, label) in [("completed", "Completed"), ("exited", "Exited")] {
            let data = Data(
                """
                {"spanId":1,"laneId":1,"title":"Work","startedAt":100,
                 "endedAt":200,"status":"\(status)","terminalId":90,"isLive":false}
                """.utf8)
            let span = try JSONDecoder().decode(CoreTraceSpan.self, from: data)
            #expect(span.statusLabel == label)
            #expect(span.end(at: 500) == 200)
        }
    }

    @Test func narrowPanelPreservesASelectableTimelineBesideDetails() {
        let layout = TracePanelLayout(width: 372, showsDetails: true)
        #expect(layout.timelineViewportWidth >= 90)
        #expect(layout.labelWidth == TracesLayout.compactLabelWidth)
        #expect(layout.detailWidth > 200)
        #expect(
            layout.detailWidth + layout.labelWidth + layout.timelineViewportWidth
                + TracesLayout.timelineTrailingInset == 372)
        let normal = TracePanelLayout(width: 800, showsDetails: true)
        #expect(normal.detailWidth == 320)
        #expect(normal.labelWidth == TracesLayout.detailLabelWidth)
        #expect(TracePanelLayout(width: 1_500, showsDetails: true).detailWidth == 440)
    }

    @Test func minimumWidthCollisionsArePackedEvenWhenTimeIntervalsDoNotOverlap() {
        let spans = [
            traceSpan(id: 1, start: 0, end: 10), traceSpan(id: 2, start: 20, end: 30),
            traceSpan(id: 3, start: 200, end: 210),
        ]
        let layout = TraceTimelineLayout(spans: spans, now: 1_000)
        let placements = layout.placements(spans: spans, width: 500, now: 1_000)
        #expect(placements.map(\.row) == [0, 1, 0])
        #expect(placements.allSatisfy { $0.width >= 40 && $0.offset >= 0 && $0.offset + $0.width <= 500 })
    }

    @Test func simultaneousSpansRemainDistinctAndLanesArePackedIndependently() {
        let first = traceSpan(id: 1, laneID: 1, start: 100, end: 1_100)
        let second = traceSpan(id: 2, laneID: 1, start: 100, end: 1_100)
        let otherLane = traceSpan(id: 3, laneID: 2, start: 100, end: 1_100)
        let layout = TraceTimelineLayout(spans: [first, second, otherLane], now: 1_100)
        #expect(layout.placements(spans: [second, first], width: 400, now: 1_100).map(\.row) == [0, 1])
        #expect(layout.placements(spans: [otherLane], width: 400, now: 1_100)[0].row == 0)
    }

    @Test func unrecordedEndDoesNotExtendHistoricalActivity() {
        let historical = traceSpan(start: 100, end: nil, status: .running)
        let live = traceSpan(id: 2, start: 100, end: nil, status: .running, live: true)
        #expect(historical.end(at: 5_000) == 100)
        #expect(historical.statusLabel == "End not recorded")
        #expect(live.end(at: 5_000) == 5_000)
        let layout = TraceTimelineLayout(spans: [historical], now: 5_000)
        let placement = layout.placements(spans: [historical], width: 0, now: 5_000)[0]
        #expect(placement.width == 40)
        #expect(placement.offset.isFinite)
    }

    @Test func unfinishedOwnedAssignmentContinuesAfterItsProcessExit() throws {
        let data = Data(
            """
            {"spanId":1,"laneId":1,"title":"Implement · Round 1","startedAt":100,
             "endedAt":null,"status":"running","terminalId":90,"isLive":true}
            """.utf8)
        let span = try JSONDecoder().decode(CoreTraceSpan.self, from: data)
        #expect(span.end(at: 500) == 500)
        #expect(span.statusLabel == "Running")
        #expect(span.statusSymbol == "circle.fill")
    }

    @Test func optionalAnchorsAndStableIdentifiersDecode() throws {
        let data = Data(
            """
            {"workflowId":4,"spanId":5,"revision":9,"nextAfter":null,"events":[
                {"eventId":8,"workflowId":4,"spanId":5,"timestamp":123,"kind":"processStarted",
                 "message":"Started","anchor":{"terminalId":90,"byteOffset":42}},
                {"eventId":9,"workflowId":4,"spanId":5,"timestamp":124,"kind":"processStopped",
                 "message":"Stopped","anchor":null}]}
            """.utf8)
        let page = try JSONDecoder().decode(CoreTraceEventsPage.self, from: data)
        #expect(page.events[0].anchor?.terminalID == 90)
        #expect(page.events[0].anchor?.byteOffset == 42)
        #expect(page.events[1].anchor == nil)
        #expect(page.nextAfter == nil)
    }
}

@MainActor
struct TraceStateTests {
    @Test func lateReadCannotReplaceTheSelectedWorkflowsTraces() async throws {
        let transport = TraceTestTransport()
        let client = CoreClient(transport: transport)
        client.start()
        try await waitUntil { client.runState == .running }
        let state = TracePanelState()
        await transport.hold(workflowID: 1)
        let previous = Task { await state.refresh(workflowID: 1, client: client) }
        try await waitUntil { await transport.hasPendingRead }
        await state.refresh(workflowID: 2, client: client)
        await transport.release()
        await previous.value
        #expect(state.workflowID == 2)
        #expect(state.spans.map(\.id) == [20])
        #expect(!state.isLoading)
        await client.stop()
    }

    @Test func copyIncludesEventsBeyondTheLoadedLogPage() async throws {
        let transport = TraceTestTransport()
        let client = CoreClient(transport: transport)
        client.start()
        try await waitUntil { client.runState == .running }
        let state = TracePanelState()
        await state.refresh(workflowID: 2, client: client)
        state.selectedSpanID = 20
        await state.loadEvents(client: client)
        #expect(state.events.count == 1)
        #expect(state.nextAfter == 1)
        let log = try await state.completeLog(spanID: 20, client: client)
        #expect(log.contains("First event"))
        #expect(log.contains("Second event"))
        #expect(state.events.count == 1)
        state.reset(workflowID: nil)
        #expect(state.selectedSpanID == nil)
        #expect(state.events.isEmpty)
        await client.stop()
    }

    @Test func replacingTheLogCannotUseThePreviousSpansCursor() async throws {
        let transport = TraceTestTransport()
        let client = CoreClient(transport: transport)
        client.start()
        try await waitUntil { client.runState == .running }
        let state = TracePanelState()
        await state.refresh(workflowID: 2, client: client)
        state.selectedSpanID = 20
        await state.loadEvents(client: client)
        #expect(state.nextAfter == 1)
        await state.refresh(workflowID: 3, client: client)
        state.selectedSpanID = 30
        await transport.holdEvents(spanID: 30)
        let replacement = Task { await state.loadEvents(client: client) }
        try await waitUntil { await transport.hasPendingEventRead }
        #expect(state.nextAfter == nil)
        #expect(state.events.isEmpty)
        await state.loadEvents(client: client, more: true)
        #expect(await transport.eventReadCursors == [nil, nil])
        await transport.releaseEvents()
        await replacement.value
        #expect(state.events.map(\.id) == [1])
        #expect(state.events.first?.spanID == 30)
        #expect(state.nextAfter == 1)
        #expect(!state.isLoadingEvents)
        await client.stop()
    }

    @Test func realCoreTraceRoundTripAndRevisionUpdate() async throws {
        let data = TemporaryPath()
        let folder = TemporaryPath()
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        let client = CoreClient(transport: CoreWorker(dataDirectory: data.url))
        client.start()
        do {
            try await waitUntil { client.runState == .running }
            _ = try await client.send(.openFolder(path: folder.path))
            try await waitUntil { client.snapshot?.folders.openFolder == folder.path }
            let id = try await client.createWorkflow(folder: folder.path)
            let workflow = try #require(client.snapshot?.workflows.workflows.first(where: { $0.id == id }))
            try await client.writeTerminalInput(terminalID: workflow.terminalID, bytes: Data("sleep 60\r".utf8))
            try await waitUntil {
                let page = try? await client.workflowTrace(workflowID: id)
                return page?.spans.contains(where: { $0.title == "sleep 60" }) == true
            }
            let page = try await client.workflowTrace(workflowID: id)
            let span = try #require(page.spans.first)
            #expect(span.isLive)
            #expect(page.summary.agentCount == 0)
            #expect(page.summary.spanCount == 1)
            let events = try await client.traceEvents(spanID: span.id)
            #expect(events.events.first?.kind == .workflowEvent)
            #expect(events.events.first?.message == "Command started.")
            #expect(events.events.first?.anchor?.terminalID == workflow.terminalID)
            #expect((events.events.first?.anchor?.byteOffset ?? 0) > 0)
            try await client.closeWorkflow(workflowID: id)
            let closed = try await client.workflowTrace(workflowID: id)
            #expect(closed.spans.first?.status == .stopped)
            #expect(closed.summary.revision > page.summary.revision)
            #expect(!closed.spans[0].isLive)
            await client.stop()
        } catch {
            await client.stop()
            throw error
        }
    }
}

private actor TraceTestTransport {
    private var heldSpan: UInt64?
    private var pendingEvents: CheckedContinuation<CoreTraceEventsPage, Never>?
    private(set) var eventReadCursors: [UInt64?] = []
    var hasPendingEventRead: Bool { pendingEvents != nil }
    func holdEvents(spanID: UInt64) { heldSpan = spanID }
    func releaseEvents() {
        if let heldSpan { pendingEvents?.resume(returning: eventPage(spanID: heldSpan, after: nil)) }
        pendingEvents = nil
        heldSpan = nil
    }
    private var heldWorkflow: UInt64?
    private var pending: CheckedContinuation<CoreWorkflowTracePage, Never>?
    var hasPendingRead: Bool { pending != nil }
    func hold(workflowID: UInt64) { heldWorkflow = workflowID }
    func release() {
        pending?.resume(returning: tracePage(workflowID: heldWorkflow ?? 1, spanID: 10))
        pending = nil
        heldWorkflow = nil
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
    func workflowTrace(workflowID: UInt64, before: UInt64?, limit: UInt32) async -> CoreWorkflowTracePage {
        if heldWorkflow == workflowID {
            return await withCheckedContinuation { pending = $0 }
        }
        return tracePage(workflowID: workflowID, spanID: workflowID * 10)
    }
    func traceEvents(spanID: UInt64, after: UInt64?, limit: UInt32) async -> CoreTraceEventsPage {
        eventReadCursors.append(after)
        if heldSpan == spanID { return await withCheckedContinuation { pendingEvents = $0 } }
        return eventPage(spanID: spanID, after: after)
    }
    private func eventPage(spanID: UInt64, after: UInt64?) -> CoreTraceEventsPage {
        let first = after == nil
        return CoreTraceEventsPage(
            workflowID: spanID / 10, spanID: spanID, revision: 2,
            events: [
                .init(
                    eventID: first ? 1 : 2, workflowID: spanID / 10, spanID: spanID, timestamp: 100,
                    kind: first ? .processStarted : .processStopped,
                    message: first ? "First event" : "Second event", anchor: nil)
            ], nextAfter: first ? 1 : nil)
    }
}

extension TraceTestTransport: CoreTransport {}
