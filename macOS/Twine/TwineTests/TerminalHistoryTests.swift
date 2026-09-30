import Foundation
import SwiftTerm
import Testing

@testable import Twine

@MainActor
struct TerminalHistoryTests {
    @Test func exactAnchorAndBoundaryResizesExcludeLaterOutput() async throws {
        let transport = TranscriptFixtureTransport(bytes: Data("first\r\nsecond\r\nlater".utf8))
        let client = CoreClient(transport: transport)
        let state = TerminalHistoryState()
        var anchor = CoreTraceAnchor(terminalID: 1, byteOffset: 15)
        anchor.boundarySizes = [.init(rows: 2, columns: 5), .init(rows: 4, columns: 12)]
        let target = TraceTerminalTarget(workflowID: 1, agentID: nil, anchor: anchor, timestamp: 0, message: "Stopped")
        await state.load(target, client: client)
        guard case .ready(let replay) = state.status else {
            Issue.record("History failed to load")
            return
        }
        #expect(!replay.text.contains("later"))
        #expect(replay.offset == 15)
        #expect(replay.terminal.rows == 4)
        #expect(replay.terminal.cols == 12)
        #expect(await transport.readLimits == [15])
    }

    @Test func expiredBytesMissingGeometryAndCancelledReadsNeverPublishReady() async throws {
        let target = TraceTerminalTarget(
            workflowID: 1, agentID: nil, anchor: .init(terminalID: 1, byteOffset: 1), timestamp: 0, message: "Stopped")
        let expired = TerminalHistoryState()
        await expired.load(target, client: CoreClient(transport: TranscriptFixtureTransport(bytes: nil)))
        guard case .expired = expired.status else {
            Issue.record("Expected expired history")
            return
        }
        let missing = TerminalHistoryState()
        await missing.load(
            target,
            client: CoreClient(transport: TranscriptFixtureTransport(bytes: Data([65]), replayAvailable: false)))
        guard case .expired = missing.status else {
            Issue.record("Expected unavailable geometry")
            return
        }
        let transport = TranscriptFixtureTransport(bytes: Data([65]), delayed: true)
        let cancelled = TerminalHistoryState()
        let load = Task { await cancelled.load(target, client: CoreClient(transport: transport)) }
        try await waitUntil { await transport.hasPendingRead }
        load.cancel()
        await transport.release()
        await load.value
        guard case .loading = cancelled.status else {
            Issue.record("Canceled read published a result")
            return
        }
    }

    @Test func onlyAnchoredEventsNavigateToTheExactAgent() {
        let navigation = TraceTerminalNavigation()
        let lane = CoreTraceLane(
            laneID: 1, workflowID: 3, name: "Worker", isAgent: true, role: "Worker", harness: nil, agentID: 9)
        let event = CoreTraceEvent(
            eventID: 1, workflowID: 3, spanID: 1, timestamp: 42, kind: .processStopped,
            message: "Stopped", anchor: .init(terminalID: 8, byteOffset: 50))
        navigation.jump(to: event, lane: lane)
        #expect(navigation.target?.workflowID == 3)
        #expect(navigation.target?.agentID == 9)
        #expect(navigation.target?.anchor.terminalID == 8)
        navigation.target = nil
        navigation.jump(
            to: .init(
                eventID: 2, workflowID: 3, spanID: 1, timestamp: 43, kind: .processFailed, message: "Unavailable",
                anchor: nil),
            lane: lane)
        #expect(navigation.target == nil)
    }
}
