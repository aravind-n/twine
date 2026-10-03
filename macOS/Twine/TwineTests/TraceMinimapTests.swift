import Testing

@testable import Twine

@MainActor
struct TraceMinimapTests {
    @Test(arguments: [false, true])
    func processPointIsReplacedWhenItsWorkflowAnchorArrives(completed: Bool) async throws {
        let marker = TerminalMinimapTests.marker(offset: 20)
        let started = CoreTraceEvent(
            eventID: 1, workflowID: 1, spanID: marker.id, timestamp: 0, kind: .processStarted,
            message: "Started", anchor: .init(terminalID: 41, byteOffset: 0))
        let trace = CoreWorkflowTracePage(
            summary: .init(workflowID: 1, revision: 300, spanCount: 1, agentCount: 1),
            lanes: [marker.lane], spans: [marker.step.span], nextBefore: nil)
        let transport = TranscriptFixtureTransport(bytes: nil, trace: trace, recordedEvents: [started])
        let client = CoreClient(transport: transport)
        client.start()
        try await client.waitUntilRunning()
        defer { Task { await client.stop() } }
        let activity = TracePanelState()
        await activity.refresh(workflowID: 1, client: client)
        let state = TraceMinimapState()
        await state.refresh(activity: activity, client: client)
        #expect(state.markers.first?.anchor?.byteOffset == 0)
        await transport.replaceEvents([started, marker.event])
        if completed {
            let span = marker.step.span
            await transport.replaceTrace(
                .init(
                    summary: trace.summary, lanes: trace.lanes,
                    spans: [
                        .init(
                            spanID: span.id, laneID: span.laneID, title: span.title, startedAt: span.startedAt,
                            endedAt: 20, status: .completed, terminalID: span.terminalID, isLive: false)
                    ], nextBefore: nil))
            await activity.refresh(workflowID: 1, client: client)
        }
        await state.refresh(activity: activity, client: client)
        #expect(state.markers.first?.event.id == marker.event.id)
        #expect(state.markers.first?.anchor?.byteOffset == 20)
    }

    @Test func workflowAnchorOnALaterPageTakesPrecedenceOverProcessStart() async throws {
        let marker = TerminalMinimapTests.marker(id: 201, offset: 20)
        let earlier = (1...200).map { id in
            CoreTraceEvent(
                eventID: UInt64(id), workflowID: 1, spanID: marker.id, timestamp: 0, kind: .processStarted,
                message: "Started", anchor: .init(terminalID: 41, byteOffset: 0))
        }
        let trace = CoreWorkflowTracePage(
            summary: .init(workflowID: 1, revision: 400, spanCount: 1, agentCount: 1),
            lanes: [marker.lane], spans: [marker.step.span], nextBefore: nil)
        let client = CoreClient(
            transport: TranscriptFixtureTransport(bytes: nil, trace: trace, recordedEvents: earlier + [marker.event]))
        client.start()
        try await client.waitUntilRunning()
        defer { Task { await client.stop() } }
        let activity = TracePanelState()
        await activity.refresh(workflowID: 1, client: client)
        let state = TraceMinimapState()
        await state.refresh(activity: activity, client: client)
        #expect(state.markers.first?.event.id == marker.event.id)
    }
}
