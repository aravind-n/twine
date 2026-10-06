import AppKit
import Foundation
import SwiftTerm
import Testing

@testable import Twine

@MainActor
struct TerminalHistoryTests {
    @Test func agentHistoryStartsAtThePromptAboveItsBorderAndStatusRows() async throws {
        let prefix = "earlier\r\n› Check output\r\n──────────\r\n? for shortcuts\r\n"
        let bytes = Data((prefix + "Response\r\n").utf8)
        let marker = TerminalMinimapTests.marker(offset: UInt64(prefix.utf8.count))
        let ending = CoreTraceEvent(
            eventID: 200, workflowID: 1, spanID: marker.id, timestamp: 20, kind: .workflowEvent,
            message: "Finished responding", anchor: .init(terminalID: 41, byteOffset: UInt64(bytes.count)))
        let navigation = TraceTerminalNavigation()
        navigation.jump(toSpan: marker.step.span, events: [marker.event, ending], lane: marker.lane)
        let target = try #require(navigation.scrollTarget)
        #expect(target.inputText == "Check output")
        let state = TerminalHistoryState()
        await state.load(target, client: CoreClient(transport: TranscriptFixtureTransport(bytes: bytes)))
        guard case .ready(let replay) = state.status else {
            Issue.record("Agent history failed to load")
            return
        }
        let range = try #require(replay.outputStartRange)
        #expect((replay.text as NSString).substring(from: range.location).hasPrefix("› Check output"))
        #expect(replay.text.contains("Response"))
    }

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
        let target = try #require(navigation.scrollTarget)
        #expect(navigation.target == nil)
        #expect(target.scrollAnchor.byteOffset == startOffset)
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
        #expect((replay.text as NSString).substring(from: range.location).hasPrefix("$ printf hello"))
        navigation.scrollTarget = nil
        navigation.jump(toCommand: span, events: events, lane: lane)
        #expect(navigation.scrollTarget?.id != target.id)
    }

    @Test func explicitHistoryClearsPriorScrollDestination() {
        let navigation = TraceTerminalNavigation()
        navigation.scrollTarget = .init(
            workflowID: 1, agentID: nil, anchor: .init(terminalID: 1, byteOffset: 0), timestamp: 0, message: "First")
        navigation.target = .init(
            workflowID: 2, agentID: nil, anchor: .init(terminalID: 2, byteOffset: 0), timestamp: 0, message: "Second")
        #expect(navigation.scrollTarget == nil)
        #expect(navigation.destination?.workflowID == 2)
        navigation.target = nil
        #expect(navigation.destination == nil)
    }

    @Test func missingLiveRowOpensSavedOutputAndStaleReadsCannotReplaceAnotherSelection() throws {
        let navigation = TraceTerminalNavigation()
        let first = TraceTerminalTarget(
            workflowID: 1, agentID: nil, anchor: .init(terminalID: 1, byteOffset: 10), timestamp: 0, message: "First")
        navigation.scrollTarget = first
        navigation.finishScroll(first, found: true)
        #expect(navigation.target == nil)
        navigation.finishScroll(first, found: false)
        #expect(navigation.target?.id == first.id)
        #expect(navigation.scrollTarget == nil)
        let second = TraceTerminalTarget(
            workflowID: 2, agentID: nil, anchor: .init(terminalID: 2, byteOffset: 20), timestamp: 0, message: "Second")
        navigation.target = nil
        navigation.scrollTarget = second
        navigation.finishScroll(first, found: false)
        #expect(navigation.target == nil)
        #expect(navigation.scrollTarget?.id == second.id)
    }

    @Test(arguments: [false, true])
    func promptSelectionSkipsTheClearedLaunchScreenAndIncludesItsResponse(staleRunning: Bool) async throws {
        let prefix = "launch\u{1B}[2J\u{1B}[H"
        let input = "› say hi\r\n"
        let response = "Hi!\r\n"
        let bytes = Data((prefix + input + response + "next prompt").utf8)
        let lane = CoreTraceLane(
            laneID: 1, workflowID: 1, name: "Codex", isAgent: true, role: "agent", harness: "codex")
        let span = CoreTraceSpan(
            spanID: 1, laneID: 1, title: "say hi", startedAt: 1, endedAt: staleRunning ? nil : 2,
            status: staleRunning ? .running : .exited, terminalID: 41, isLive: staleRunning)
        let events: [CoreTraceEvent] = [
            .init(
                eventID: 1, workflowID: 1, spanID: 1, timestamp: 0, kind: .processStarted, message: "Started",
                anchor: .init(terminalID: 41, byteOffset: 0)),
            .init(
                eventID: 2, workflowID: 1, spanID: 1, timestamp: 1, kind: .workflowEvent, message: "say hi",
                anchor: .init(terminalID: 41, byteOffset: UInt64((prefix + input).utf8.count))),
            .init(
                eventID: 3, workflowID: 1, spanID: 1, timestamp: 2, kind: .workflowEvent,
                message: "Finished responding", anchor: .init(terminalID: 41, byteOffset: UInt64(bytes.count - 11))),
        ]
        let navigation = TraceTerminalNavigation()
        navigation.jump(toSpan: span, events: events, lane: lane)
        let target = try #require(navigation.scrollTarget)
        #expect(target.scrollAnchor.byteOffset == events[1].anchor?.byteOffset)
        let state = TerminalHistoryState()
        await state.load(target, client: CoreClient(transport: TranscriptFixtureTransport(bytes: bytes)))
        guard case .ready(let replay) = state.status else {
            Issue.record("Prompt history failed to load")
            return
        }
        #expect(replay.text.contains("say hi"))
        #expect(replay.text.contains("Hi!"))
        #expect(!replay.text.contains("next prompt"))
        let range = try #require(replay.outputStartRange)
        #expect((replay.text as NSString).substring(from: range.location).hasPrefix("› say hi"))
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
        let target = try #require(navigation.scrollTarget)
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
        #expect(navigation.scrollTarget?.workflowID == 3)
        #expect(navigation.scrollTarget?.agentID == 9)
        #expect(navigation.scrollTarget?.anchor.terminalID == 8)
        navigation.scrollTarget = nil
        navigation.jump(
            to: .init(
                eventID: 2, workflowID: 3, spanID: 1, timestamp: 43, kind: .processFailed, message: "Unavailable",
                anchor: nil),
            lane: lane)
        #expect(navigation.scrollTarget == nil)
    }
}

extension TerminalHistoryTests {
    @Test func processLifetimeTraceScrollsTheFirstLiveRowWithoutRequiringEchoedInput() async throws {
        let bytes = Data(("$ command\r\n" + String(repeating: "output\r\n", count: 100)).utf8)
        let lane = CoreTraceLane(laneID: 1, workflowID: 1, name: "Terminal", isAgent: false, role: nil, harness: nil)
        let span = CoreTraceSpan(
            spanID: 1, laneID: 1, title: "Terminal", startedAt: 1, endedAt: nil, status: .running,
            terminalID: 41, isLive: true)
        let event = CoreTraceEvent(
            eventID: 1, workflowID: 1, spanID: 1, timestamp: 1, kind: .processStarted, message: "Shell started",
            anchor: .init(terminalID: 41, byteOffset: 0))
        let navigation = TraceTerminalNavigation()
        navigation.jump(toSpan: span, events: [event], lane: lane)
        let target = try #require(navigation.scrollTarget)
        let client = CoreClient(transport: TranscriptFixtureTransport(bytes: bytes))
        let view = MetalTerminalView(frame: .zero)
        view.resize(cols: 80, rows: 24)
        let state = TerminalMinimapState()
        state.view = view
        state.beginFeed()
        view.feed(byteArray: Array(bytes)[...])
        state.received(through: UInt64(bytes.count))
        state.refresh()
        let found = try await state.scroll(
            to: target.scrollAnchor, includingInput: target.includesInput, client: client)
        navigation.finishScroll(target, found: found)
        #expect(found)
        #expect(state.geometry.topRow == 0)
        #expect(navigation.target == nil)
    }

    @Test(arguments: [false, true])
    func resumedPromptDoesNotFreezeAtItsEarlierResponseEnding(staleCompleted: Bool) throws {
        let lane = CoreTraceLane(
            laneID: 1, workflowID: 1, name: "Codex", isAgent: true, role: "agent", harness: "codex")
        let span = CoreTraceSpan(
            spanID: 1, laneID: 1, title: "Continue", startedAt: 1, endedAt: staleCompleted ? 2 : nil,
            status: staleCompleted ? .exited : .running, terminalID: 41, isLive: !staleCompleted)
        let events: [CoreTraceEvent] = [
            .init(
                eventID: 1, workflowID: 1, spanID: 1, timestamp: 1, kind: .workflowEvent, message: "Continue",
                anchor: .init(terminalID: 41, byteOffset: 10)),
            .init(
                eventID: 2, workflowID: 1, spanID: 1, timestamp: 2, kind: .workflowEvent,
                message: "Finished responding", anchor: .init(terminalID: 41, byteOffset: 20)),
            .init(
                eventID: 3, workflowID: 1, spanID: 1, timestamp: 3, kind: .workflowEvent, message: "Run make test",
                anchor: .init(terminalID: 41, byteOffset: 30)),
        ]
        let navigation = TraceTerminalNavigation()
        navigation.jump(toSpan: span, events: events, lane: lane)
        let target = try #require(navigation.scrollTarget)
        #expect(target.readToCurrentEnd)
        #expect(target.anchor.byteOffset == 30)
    }

    @Test func selectedPromptReadsItsEndingBeyondTheFirstEventPage() async throws {
        let lane = CoreTraceLane(
            laneID: 1, workflowID: 1, name: "Codex", isAgent: true, role: "agent", harness: "codex")
        let span = CoreTraceSpan(
            spanID: 1, laneID: 1, title: "Long response", startedAt: 1, endedAt: 201, status: .exited,
            terminalID: 41, isLive: false)
        let trace = CoreWorkflowTracePage(
            summary: .init(workflowID: 1, revision: 201, spanCount: 1, agentCount: 1), lanes: [lane], spans: [span],
            nextBefore: nil)
        let events: [CoreTraceEvent] = (1...201).map { id in
            .init(
                eventID: UInt64(id), workflowID: 1, spanID: 1, timestamp: UInt64(id), kind: .workflowEvent,
                message: id == 201 ? "Finished responding" : "Tool activity",
                anchor: .init(terminalID: 41, byteOffset: UInt64(id)))
        }
        let client = CoreClient(
            transport: TranscriptFixtureTransport(bytes: nil, trace: trace, recordedEvents: events))
        client.start()
        try await client.waitUntilRunning()
        defer { Task { await client.stop() } }
        let navigation = TraceTerminalNavigation()
        await navigation.activity.refresh(workflowID: 1, client: client)
        navigation.selectSpan(1)
        await navigation.activity.loadEvents(client: client)
        #expect(navigation.activity.events.count == 200)
        await navigation.jumpToSelectedSpan(client: client)
        let target = try #require(navigation.scrollTarget)
        #expect(target.anchor.byteOffset == 201)
        #expect(!target.readToCurrentEnd)
        #expect(navigation.activity.events.count == 200)
        #expect(navigation.requestedSpanID == nil)
    }
}
