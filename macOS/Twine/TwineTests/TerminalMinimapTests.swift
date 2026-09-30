import AppKit
import SwiftTerm
import Testing

@testable import Twine

@MainActor
struct TerminalMinimapTests {
    static func marker(id: UInt64 = 7, terminalID: UInt64 = 41, offset: UInt64) -> TraceMinimapMarker {
        let span = CoreTraceSpan(
            spanID: id, laneID: 3, title: "Check output", startedAt: 10, endedAt: nil,
            status: .running, terminalID: terminalID, isLive: true)
        let lane = CoreTraceLane(
            laneID: 3, workflowID: 1, name: "Implementer", isAgent: true, role: "Implementer", harness: "codex")
        let event = CoreTraceEvent(
            eventID: id + 100, workflowID: 1, spanID: id, timestamp: 10, kind: .workflowEvent,
            message: "Command started.", anchor: .init(terminalID: terminalID, byteOffset: offset))
        return .init(step: .init(span: span, index: 2), lane: lane, event: event)
    }

    @Test func viewportAndScrubbingUseRowsRatherThanByteOffsets() {
        let geometry = TerminalMinimapGeometry(rows: 1_000, visibleRows: 40, topRow: 400)
        #expect(geometry.viewport == 0.4...0.44)
        #expect(geometry.row(at: 0) == 0)
        #expect(geometry.row(at: 1) == 960)
        #expect(geometry.row(at: 0.5) == 480)
        #expect(!geometry.isLive)
        #expect(TerminalMinimapGeometry(rows: 5, visibleRows: 20).isLive)
    }

    @Test func byteAnchorsResolveThroughANSIAndWrappingAndKeepActivityIdentity() async throws {
        let prefix = "old\r\u{1B}[2Kfirst\r\n\u{1B}[31msecond\u{1B}[0m\r\n"
        let bytes = Data((prefix + String(repeating: "x", count: 90) + "\r\nlast").utf8)
        let marker = Self.marker(offset: UInt64(prefix.utf8.count))
        let other = Self.marker(id: 9, terminalID: 99, offset: 0)
        let client = CoreClient(transport: TranscriptFixtureTransport(bytes: bytes))
        client.start()
        try await client.waitUntilRunning()
        defer { Task { await client.stop() } }
        let index = TerminalMinimapReplay()
        try await index.load(terminalID: 41, endOffset: UInt64(bytes.count), markers: [other, marker], client: client)
        let live = MetalTerminalView(frame: .zero)
        live.resize(cols: 80, rows: 24)
        live.feed(byteArray: Array(bytes)[...])
        let anchors = index.liveAnchors(in: live.getTerminal())
        #expect(anchors[marker.id]?.row == 2)
        #expect(anchors[other.id] == nil)
        #expect(marker.id == marker.step.span.id)
        #expect(marker.title == "03 · Check output")
        let history = TerminalHistoryState()
        let target = TraceTerminalTarget(
            workflowID: 1, agentID: nil, anchor: .init(terminalID: 41, byteOffset: UInt64(bytes.count)),
            timestamp: 10, message: "Recorded output")
        await history.load(target, client: client)
        await history.updateMinimap([marker], target: target, client: client)
        #expect(history.minimapRows[marker.id] == 2)
    }

    @Test func recycledAndAlternateScreenRowsCannotReuseAnActivityPoint() throws {
        let index = TerminalMinimapReplay()
        index.capture(id: 7)
        let flood = Data(String(repeating: "retained\r\n", count: 5_000).utf8)
        try index.replay.append(
            .init(
                offset: 0, nextOffset: UInt64(flood.count), endOffset: UInt64(flood.count),
                sizes: [], bytes: flood, replayAvailable: true))
        index.discardExpiredAnchors()
        #expect(index.rows[7] == nil)
        let view = MetalTerminalView(frame: .zero)
        view.feed(text: "\u{1B}[?1049hfullscreen")
        #expect(index.liveAnchors(in: view.getTerminal()).isEmpty)
    }

    @Test func minimapNavigationSelectsTheSameActivityStep() {
        let navigation = TraceTerminalNavigation()
        navigation.selectSpan(7)
        #expect(navigation.activity.selectedSpanID == 7)
        #expect(navigation.requestedSpanID == 7)
        let revision = navigation.selectionRevision
        navigation.selectSpan(7)
        #expect(navigation.selectionRevision != revision)
    }

    @Test func replayRetainsNormalPointsAcrossAnAlternateScreenPageBoundary() async throws {
        let prefix = "normal\r\n\u{1B}[?1049hfullscreen"
        let bytes = Data((prefix + "\r\nmore fullscreen\u{1B}[?1049lreturned").utf8)
        let client = CoreClient(transport: TranscriptFixtureTransport(bytes: bytes))
        client.start()
        try await client.waitUntilRunning()
        defer { Task { await client.stop() } }
        let index = TerminalMinimapReplay()
        try await index.load(
            terminalID: 41, endOffset: UInt64(bytes.count),
            markers: [Self.marker(offset: 0), Self.marker(id: 8, offset: UInt64(prefix.utf8.count))], client: client)
        #expect(index.rows[7] == 0)
        #expect(index.rows[8] == nil)
        let live = MetalTerminalView(frame: .zero)
        live.resize(cols: 80, rows: 24)
        live.feed(byteArray: Array(bytes)[...])
        #expect(index.liveAnchors(in: live.getTerminal())[7]?.row == 0)
    }

    @Test func replayUsesTheCheckpointEvenIfNewOutputExtendsTheMarkedLine() throws {
        let index = TerminalMinimapReplay()
        let live = MetalTerminalView(frame: .zero)
        live.resize(cols: 80, rows: 25)
        index.capture(id: 7)
        let checkpoint = TerminalMinimapCheckpoint(terminal: live.getTerminal())
        live.feed(text: "output that arrived during the disk read")
        #expect(index.liveAnchors(at: checkpoint)[7]?.line === live.getTerminal().bufferLine(atRow: 0))
    }

    @Test func anchorsSurviveIdleResizeAndAnAlternateScreenRoundTrip() async throws {
        let prefix = "first\r\n"
        let bytes = Data((prefix + "marked line\r\nlast").utf8)
        let client = CoreClient(transport: TranscriptFixtureTransport(bytes: bytes))
        client.start()
        try await client.waitUntilRunning()
        defer { Task { await client.stop() } }
        let view = MetalTerminalView(frame: .zero)
        view.resize(cols: 80, rows: 24)
        let state = TerminalMinimapState()
        state.view = view
        state.beginFeed()
        view.feed(byteArray: Array(bytes)[...])
        state.received(through: UInt64(bytes.count))
        state.refresh()
        await state.loadMarkers([Self.marker(offset: UInt64(prefix.utf8.count))], terminalID: 41, client: client)
        #expect(state.markerRows[7] == 1)
        view.resize(cols: 100, rows: 30)
        state.refresh()
        #expect(state.markerRows[7] == 1)
        view.feed(text: "\u{1B}[?1049hfullscreen")
        state.refresh()
        #expect(state.markerRows.isEmpty)
        view.feed(text: "\u{1B}[?1049l")
        state.refresh()
        #expect(state.markerRows[7] == 1)
    }

    @Test func liveResizeBeforeCoreAcknowledgementKeepsTheExactMarkedRow() async throws {
        let prefix = Data((String(repeating: "0123456789", count: 6) + "\r\n").utf8)
        let bytes = prefix + Data("TARGET\r\n".utf8)
        let client = CoreClient(transport: TranscriptFixtureTransport(bytes: bytes))
        client.start()
        try await client.waitUntilRunning()
        defer { Task { await client.stop() } }
        let view = MetalTerminalView(frame: .zero)
        view.resize(cols: 80, rows: 24)
        view.feed(byteArray: Array(prefix)[...])
        view.resize(cols: 10, rows: 24)
        view.feed(text: "TARGET\r\n")
        let index = TerminalMinimapReplay()
        try await index.load(
            terminalID: 41, endOffset: UInt64(bytes.count),
            markers: [Self.marker(offset: UInt64(prefix.count))], client: client,
            liveSizes: [
                .init(offset: 0, rows: 24, columns: 80),
                .init(offset: UInt64(prefix.count), rows: 24, columns: 10),
            ])
        let anchor = try #require(index.liveAnchors(in: view.getTerminal())[7])
        #expect(anchor.line.translateToString(trimRight: true) == "TARGET")
        #expect(anchor.row > 1)
    }
}
