import AppKit
import SwiftTerm
import SwiftUI
import Testing

@testable import Twine

@MainActor
struct TerminalRestorationTests {
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
}
