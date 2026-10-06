import AppKit
import SwiftTerm
import SwiftUI
import Testing

@testable import Twine

@MainActor
struct TerminalRestorationTests {
    @Test func resumedAgentOwnsItsNewTerminalWhileArchivedTerminalsStayReadOnly() {
        let workflow = CoreWorkflow(
            workflowID: 1, sessionID: 1, name: "Codex", kind: .singleAgent, terminalID: 20,
            status: .running, startedAt: 0, endedAt: nil, restored: true,
            terminalHistory: [.init(terminalID: 10, agentID: nil)])
        #expect(workflow.terminalIDs == [20])
        var archived = workflow
        archived.terminalHistory = [.init(terminalID: 20, agentID: nil)]
        #expect(archived.terminalIDs.isEmpty)
    }

    @Test func savedOutputRetainsScrollbackBeyondTheOldFiveHundredLineLimit() async throws {
        let bytes = Data(("FIRST_RETAINED_LINE\r\n" + String(repeating: "output\r\n", count: 800) + "last").utf8)
        let client = CoreClient(transport: TranscriptFixtureTransport(bytes: bytes))
        client.start()
        try await client.waitUntilRunning()
        defer { Task { await client.stop() } }
        let view = MetalTerminalView(frame: .zero)
        let offset = try await TerminalRestoration.restore(history: [], current: 41, client: client, view: view)
        #expect(offset == bytes.count)
        let text = (String(data: view.getTerminal().getBufferAsData(), encoding: .utf8) ?? "")
        #expect(text.contains("FIRST_RETAINED_LINE"))
        #expect(text.contains("last"))
    }

    @Test func restoredPrefixKeepsNewActivityOnItsActualRow() async throws {
        let bytes = Data("new command\r\nnew result".utf8)
        let client = CoreClient(transport: TranscriptFixtureTransport(bytes: bytes))
        client.start()
        try await client.waitUntilRunning()
        defer { Task { await client.stop() } }
        let prefix = TerminalReplayPrefix(text: String(repeating: "old output\r\n", count: 40), columns: 80, rows: 24)
        let live = MetalTerminalView(frame: .zero)
        live.resize(cols: 80, rows: 24)
        live.feed(text: prefix.text)
        live.feed(byteArray: Array(bytes)[...])
        let index = TerminalMinimapReplay()
        try await index.load(
            terminalID: 41, endOffset: UInt64(bytes.count),
            markers: [TerminalMinimapTests.marker(offset: 0)], client: client,
            liveSizes: [.init(offset: 0, rows: 24, columns: 80)], prefix: [prefix])
        #expect(index.liveAnchors(in: live.getTerminal())[7]?.row == 40)
    }

    @Test func archivedControllerReplaysOutputWithoutAnsweringOldDeviceQueries() async throws {
        let transport = TranscriptFixtureTransport(bytes: Data("saved agent\u{1B}[6n".utf8))
        let client = CoreClient(transport: transport)
        client.start()
        try await client.waitUntilRunning()
        defer { Task { await client.stop() } }
        var failure: String?
        let controller = TerminalController(
            coreClient: client, terminalID: 41,
            failureMessage: Binding(get: { failure }, set: { failure = $0 }))
        controller.restoresOutput = true
        let view = MetalTerminalView(frame: .zero)
        view.terminalDelegate = controller
        controller.start(view: view)
        defer { controller.stop() }
        try await waitUntil {
            (String(data: view.getTerminal().getBufferAsData(), encoding: .utf8) ?? "").contains("saved agent")
        }
        #expect(failure == nil)
    }

    @Test(arguments: [12, 100])
    func oldCommandTraceScrollsItsRestoredOutputAfterReflow(columns: Int) async throws {
        let input = "earlier\r\n$ printf 'a long command to restore'\r\n"
        let old = Data((input + "\u{1B}[32mOLD_OUTPUT\u{1B}[0m\r\n").utf8)
        let current = Data(String(repeating: "new output\r\n", count: 100).utf8)
        let client = CoreClient(transport: TranscriptFixtureTransport(bytes: nil, transcripts: [10: old, 41: current]))
        client.start()
        try await client.waitUntilRunning()
        defer { Task { await client.stop() } }
        let view = MetalTerminalView(frame: .zero)
        view.resize(cols: 80, rows: 24)
        let state = TerminalMinimapState()
        state.view = view
        view.minimapState = state
        _ = try await TerminalRestoration.restore(history: [10], current: 41, client: client, view: view)
        view.resize(cols: columns, rows: 24)
        state.refresh()
        let before = view.getTerminal().getBufferAsData()
        #expect(state.geometry.isLive)
        let found = try await state.scroll(
            to: .init(terminalID: 10, byteOffset: UInt64(input.utf8.count)), in: 41,
            includingInput: true, client: client)
        #expect(found)
        #expect(!state.geometry.isLive)
        #expect(
            TerminalMinimapGeometry.logicalLine(at: state.geometry.topRow, in: view.getTerminal())
                == "$ printf 'a long command to restore'")
        #expect(view.getTerminal().getBufferAsData() == before)
        state.returnToLive()
        #expect(state.geometry.isLive)
    }

    @Test(arguments: [false, true])
    func clearedRestoredOutputKeepsTheSavedOutputFallback(clearedBeforeRestoration: Bool) async throws {
        let input = "$ old-command\r\n"
        let clear = "\u{1B}[2J\u{1B}[Hnew output"
        let old = Data((input + "old output\r\n" + (clearedBeforeRestoration ? clear : "")).utf8)
        let current = Data((clearedBeforeRestoration ? "current output" : "\u{1B}[3J" + clear).utf8)
        let client = CoreClient(transport: TranscriptFixtureTransport(bytes: nil, transcripts: [10: old, 41: current]))
        client.start()
        try await client.waitUntilRunning()
        defer { Task { await client.stop() } }
        let view = MetalTerminalView(frame: .zero)
        view.resize(cols: 80, rows: 24)
        let state = TerminalMinimapState()
        state.view = view
        view.minimapState = state
        _ = try await TerminalRestoration.restore(history: [10], current: 41, client: client, view: view)
        state.refresh()
        let request = TraceTerminalTarget(
            workflowID: 1, agentID: nil, anchor: .init(terminalID: 10, byteOffset: UInt64(input.utf8.count)),
            timestamp: 1, message: "old-command")
        let navigation = TraceTerminalNavigation()
        navigation.scrollTarget = request
        let found = try await state.scroll(to: request.anchor, in: 41, includingInput: true, client: client)
        navigation.finishScroll(request, found: found)
        #expect(!found)
        #expect(navigation.target == request)
    }

    @Test func clearDuringRestoredTraceReadCannotRevealBlankInput() async throws {
        let input = "$ old-command\r\n"
        let old = Data((input + "old output\r\n").utf8)
        let transport = TranscriptFixtureTransport(bytes: nil, transcripts: [10: old, 41: Data("new\r\n".utf8)])
        let client = CoreClient(transport: transport)
        let view = MetalTerminalView(frame: .zero)
        view.resize(cols: 80, rows: 24)
        let state = TerminalMinimapState()
        state.view = view
        view.minimapState = state
        _ = try await TerminalRestoration.restore(history: [10], current: 41, client: client, view: view)
        view.resize(cols: 80, rows: 100)
        state.refresh()
        #expect(TerminalMinimapGeometry.logicalLine(at: 0, in: view.getTerminal()) == "$ old-command")
        await transport.setDelayed(true)
        let read = Task {
            try await state.scroll(
                to: .init(terminalID: 10, byteOffset: UInt64(input.utf8.count)), in: 41,
                includingInput: true, client: client)
        }
        try await waitUntil { await transport.hasPendingRead }
        view.feed(text: "\u{1B}[2J\u{1B}[H$ ")
        state.refresh()
        await transport.setDelayed(false)
        await transport.release()
        #expect(try await !read.value)
    }
}
