import AppKit
import SwiftTerm
import Testing

@testable import Twine

@MainActor
struct TerminalMinimapInteractionTests {
    @Test func idleResizeUpdatesTheViewportWithoutWaitingForMoreOutput() async throws {
        let view = MetalTerminalView(frame: .zero)
        view.resize(cols: 80, rows: 24)
        let state = TerminalMinimapState()
        state.view = view
        state.refresh()
        let revision = state.geometryRevision
        view.resize(cols: 100, rows: 30)
        state.recordSize(columns: 100, rows: 30)
        try await waitUntil { state.geometry.visibleRows == 30 && state.geometry.columns == 100 }
        #expect(state.geometryRevision > revision)
    }

    @Test(arguments: ["Response to the old prompt", "Repeat completed successfully"])
    func missingAgentInputCannotSelectAnEarlierRepeatedPrompt(response: String) {
        let terminal = TerminalReplay().terminal
        terminal.feed(text: "❯ Repeat\r\n\(response)\r\n──────────\r\n")
        let row = terminal.getTopVisibleRow() + terminal.getCursorLocation().y
        #expect(TerminalMinimapGeometry.inputRow(before: row, matching: "Repeat", in: terminal) == nil)
    }

    @Test func multilineAgentInputUsesItsFirstLineWhenLaterLinesShareItsPrefix() {
        let terminal = TerminalReplay().terminal
        terminal.feed(text: "earlier\r\n❯ Fix tests\r\n  Fix tests for the minimap\r\n──────────\r\n")
        let row = terminal.getTopVisibleRow() + terminal.getCursorLocation().y
        #expect(
            TerminalMinimapGeometry.inputRow(
                before: row, matching: "Fix tests\nFix tests for the minimap", in: terminal) == 1)
    }

    @Test(arguments: [false, true])
    func replacementAnchorCannotKeepItsPreviousDotWhenItIsUnavailable(pending: Bool) async throws {
        let bytes = Data("first\r\nsecond\r\n".utf8)
        let client = CoreClient(transport: TranscriptFixtureTransport(bytes: bytes))
        let view = MetalTerminalView(frame: .zero)
        view.resize(cols: 80, rows: 24)
        let state = TerminalMinimapState()
        state.view = view
        state.beginFeed()
        view.feed(byteArray: Array(bytes)[...])
        state.received(through: UInt64(bytes.count))
        state.refresh()
        let marker = TerminalMinimapTests.marker(offset: 0)
        await state.loadMarkers([marker], terminalID: 41, client: client)
        #expect(state.markerRows[marker.id] == 0)
        let event = CoreTraceEvent(
            eventID: 200, workflowID: 1, spanID: marker.id, timestamp: 20, kind: .workflowEvent,
            message: "New boundary",
            anchor: .init(terminalID: 41, byteOffset: pending ? UInt64(bytes.count + 1) : 0, boundarySizes: nil))
        await state.loadMarkers(
            [.init(step: marker.step, lane: marker.lane, event: event)], terminalID: 41, client: client)
        #expect(state.markerRows[marker.id] == nil)
    }

    @Test(arguments: [12, 80])
    func agentPromptBoxesUseTheSameInputRowForMarkersAndTraceJumps(columns: Int) async throws {
        let prefix = "earlier\r\n› Check output\r\n──────────\r\n? for shortcuts\r\n"
        let bytes = Data((prefix + String(repeating: "later\r\n", count: 100)).utf8)
        let marker = TerminalMinimapTests.marker(offset: UInt64(prefix.utf8.count))
        let client = CoreClient(transport: TranscriptFixtureTransport(bytes: bytes))
        let view = MetalTerminalView(frame: .zero)
        view.resize(cols: columns, rows: 24)
        let state = TerminalMinimapState()
        state.view = view
        state.beginFeed()
        view.feed(byteArray: Array(bytes)[...])
        state.received(through: UInt64(bytes.count))
        state.refresh()
        await state.loadMarkers([marker], terminalID: 41, client: client)
        #expect(state.markerRows[marker.id] == 1)
        let found = try await state.scroll(
            to: #require(marker.anchor), includingInput: true, inputText: marker.inputText, client: client)
        #expect(found)
        #expect(state.geometry.topRow == state.markerRows[marker.id])
    }

    @Test func pendingMarkerDoesNotHideThePointsWhoseOutputHasArrived() async throws {
        let prefix = Data("first\r\n".utf8)
        let bytes = prefix + Data("second\r\nthird\r\n".utf8)
        let client = CoreClient(transport: TranscriptFixtureTransport(bytes: bytes))
        let view = MetalTerminalView(frame: .zero)
        view.resize(cols: 80, rows: 24)
        let state = TerminalMinimapState()
        state.view = view
        state.beginFeed()
        view.feed(byteArray: Array(prefix)[...])
        state.received(through: UInt64(prefix.count))
        state.refresh()
        let markers = [
            TerminalMinimapTests.marker(offset: 0), TerminalMinimapTests.marker(id: 8, offset: UInt64(bytes.count)),
        ]
        await state.loadMarkers(markers, terminalID: 41, client: client)
        #expect(state.markerRows[7] == 0)
        #expect(state.markerRows[8] == nil)
        state.beginFeed()
        view.feed(byteArray: Array(bytes.dropFirst(prefix.count))[...])
        state.received(through: UInt64(bytes.count))
        state.refresh()
        await state.loadMarkers(markers, terminalID: 41, client: client)
        #expect(state.markerRows[7] == 0)
        #expect(state.markerRows[8] == 3)
    }

}
