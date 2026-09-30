import Foundation
import SwiftTerm
import Testing

@testable import Twine

@MainActor
struct TerminalHistoryTests {
    @Test func commandSelectionIncludesItsOutputAndPointsAtItsFirstRow() async throws {
        let bytes = Data("old output\r\n$ printf hello\r\nhello\r\nlater prompt".utf8)
        let startOffset = UInt64(Data("old output\r\n$ printf hello\r\n".utf8).count)
        let endOffset = startOffset + 7
        let lane = CoreTraceLane(laneID: 1, workflowID: 3, name: "Terminal", isAgent: false, role: nil, harness: nil)
        let span = CoreTraceSpan(
            spanID: 1, laneID: 1, title: "printf hello", startedAt: 0, endedAt: 1, status: .completed, terminalID: 8,
            isLive: false)
        let events: [CoreTraceEvent] = [
            .init(
                eventID: 1, workflowID: 3, spanID: 1, timestamp: 0, kind: .workflowEvent, message: "Command started.",
                anchor: .init(terminalID: 8, byteOffset: startOffset)),
            .init(
                eventID: 2, workflowID: 3, spanID: 1, timestamp: 1, kind: .workflowEvent,
                message: "Command exited with code 0.", anchor: .init(terminalID: 8, byteOffset: endOffset)),
        ]
        let navigation = TraceTerminalNavigation()
        navigation.jump(toCommand: span, events: events, lane: lane)
        let target = try #require(navigation.target)
        #expect(target.outputStartAnchor?.byteOffset == startOffset)
        let state = TerminalHistoryState()
        await state.load(target, client: CoreClient(transport: TranscriptFixtureTransport(bytes: bytes)))
        guard case .ready(let replay) = state.status else {
            Issue.record("Command history failed to load")
            return
        }
        #expect(replay.text.contains("hello"))
        #expect(!replay.text.contains("later prompt"))
        #expect(replay.offset == endOffset)
        let range = try #require(replay.outputStartRange)
        #expect((replay.text as NSString).substring(from: range.location).hasPrefix("hello"))
        navigation.target = nil
        navigation.jump(toCommand: span, events: events, lane: lane)
        #expect(navigation.target?.id != target.id)
    }

    @Test func runningCommandLoadsRecordedOutputAfterItsStartAnchor() async throws {
        let bytes = Data("$ run\r\nfirst output\r\n".utf8)
        let anchor = CoreTraceAnchor(terminalID: 1, byteOffset: 7)
        let target = TraceTerminalTarget(
            workflowID: 1, agentID: nil, anchor: anchor, timestamp: 0, message: "run", outputStartAnchor: anchor,
            readToCurrentEnd: true)
        let state = TerminalHistoryState()
        await state.load(target, client: CoreClient(transport: TranscriptFixtureTransport(bytes: bytes)))
        guard case .ready(let replay) = state.status else {
            Issue.record("Running command history failed to load")
            return
        }
        #expect(replay.text.contains("first output"))
        #expect(replay.offset == UInt64(bytes.count))
    }

    @Test func freshEndingBoundsSelectionEvenWhenTheSpanSnapshotIsStillRunning() throws {
        let navigation = TraceTerminalNavigation()
        let lane = CoreTraceLane(laneID: 1, workflowID: 3, name: "Terminal", isAgent: false, role: nil, harness: nil)
        let span = CoreTraceSpan(
            spanID: 1, laneID: 1, title: "run", startedAt: 0, endedAt: nil, status: .running,
            terminalID: 8, isLive: true)
        let events: [CoreTraceEvent] = [
            .init(
                eventID: 1, workflowID: 3, spanID: 1, timestamp: 0, kind: .workflowEvent,
                message: "Command started.", anchor: .init(terminalID: 8, byteOffset: 10)),
            .init(
                eventID: 2, workflowID: 3, spanID: 1, timestamp: 1, kind: .workflowEvent,
                message: "Command exited with code 0.", anchor: .init(terminalID: 8, byteOffset: 20)),
        ]
        navigation.jump(toCommand: span, events: events, lane: lane)
        let target = try #require(navigation.target)
        #expect(!target.readToCurrentEnd)
        #expect(target.anchor.byteOffset == 20)
    }

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
