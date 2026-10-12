import AppKit
import SwiftTerm
import SwiftUI
import Testing

@testable import Twine

@MainActor
struct TerminalDeliveryTests {
    @Test func startupQueriesReturnColorsTogetherWithoutActivatingTheWorkflow() async throws {
        var snapshot = CoreSnapshot.testReady()
        snapshot.terminals = [.init(terminalID: 41, status: .running)]
        let transport = DelayedStartTransport(snapshot: snapshot)
        let client = CoreClient(transport: transport)
        client.start()
        try await client.waitUntilRunning()
        defer { Task { await client.stop() } }
        let controller = TerminalController(coreClient: client, terminalID: 41, failureMessage: .constant(nil))
        var activations = 0
        controller.beforeUserInput = { activations += 1 }
        let view = MetalTerminalView(frame: .zero)
        view.terminalDelegate = controller
        view.applyTwinePalette()
        controller.start(view: view)
        defer { controller.stop() }
        let queries = Data("\u{1B}[6n\u{1B}]10;?\u{1B}\\\u{1B}]11;?\u{1B}\\\u{1B}[?u\u{1B}[c".utf8)
        await transport.enqueueOutput(.init(terminalID: 41, offset: 0, bytes: queries))
        try await waitUntil {
            String(data: await transport.terminalResponses, encoding: .utf8)?.contains("11;rgb:") == true
        }
        let reply = try #require(String(data: await transport.terminalResponses, encoding: .utf8))
        #expect(reply.contains("10;rgb:"))
        #expect(reply.contains("[1;1R"))
        #expect(await transport.inputAttempts == 1)
        #expect(await transport.userInput.isEmpty)
        #expect(activations == 0)
    }

    @Test func resizesConvergeOnTheLatestPaneWhileOneResizeIsPending() async throws {
        var snapshot = CoreSnapshot.testReady()
        snapshot.terminals = [.init(terminalID: 41, status: .running)]
        let transport = DelayedStartTransport(snapshot: snapshot)
        let client = CoreClient(transport: transport)
        client.start()
        try await client.waitUntilRunning()
        defer { Task { await client.stop() } }
        await transport.holdResizes()
        let controller = TerminalController(coreClient: client, terminalID: 41, failureMessage: .constant(nil))
        defer { controller.stop() }
        let view = MetalTerminalView(frame: .zero)
        controller.sizeChanged(source: view, newCols: 100, newRows: 30)
        try await waitUntil { await transport.hasPendingResize }
        controller.sizeChanged(source: view, newCols: 120, newRows: 40)
        controller.sizeChanged(source: view, newCols: 140, newRows: 50)
        await transport.releaseResize()
        try await waitUntil { await transport.lastResize?.columns == 140 }
        #expect(await transport.resizeAttempts.map(\.columns) == [100, 140])
        #expect(await transport.lastResize?.rows == 50)
    }

    @Test func animatedPaneResizesReachTheShellOnlyAfterTheGridSettles() async throws {
        var snapshot = CoreSnapshot.testReady()
        snapshot.terminals = [.init(terminalID: 41, status: .running)]
        let transport = DelayedStartTransport(snapshot: snapshot)
        let client = CoreClient(transport: transport)
        client.start()
        try await client.waitUntilRunning()
        defer { Task { await client.stop() } }
        let controller = TerminalController(coreClient: client, terminalID: 41, failureMessage: .constant(nil))
        defer { controller.stop() }
        let view = MetalTerminalView(frame: .zero)
        for columns in stride(from: 100, through: 140, by: 10) {
            controller.sizeChanged(source: view, newCols: columns, newRows: 30)
            try await Task.sleep(for: .milliseconds(10))
        }
        try await waitUntil { await transport.lastResize?.columns == 140 }
        #expect(await transport.resizeAttempts.map(\.columns) == [140])
        #expect(await transport.input.isEmpty)
        #expect(await transport.terminalResponses.isEmpty)
    }

    @Test func remountRestoresExactlyOnceAndKeepsTypingDuringReplay() async throws {
        var snapshot = CoreSnapshot.testReady()
        snapshot.terminals = [.init(terminalID: 41, status: .running)]
        let transport = DelayedStartTransport(snapshot: snapshot)
        let client = CoreClient(transport: transport)
        client.start()
        try await client.waitUntilRunning()
        defer { Task { await client.stop() } }
        let previous = Data("BEFORE_REMOUNT\r\n".utf8)
        client.terminalChunkRouter.enqueue(.init(terminalID: 41, offset: 0, bytes: previous))
        _ = client.terminalChunkRouter.dequeue(for: 41)
        await transport.holdTranscript(previous)
        var failure: String?
        var activations = 0
        let controller = TerminalController(
            coreClient: client, terminalID: 41,
            failureMessage: Binding(get: { failure }, set: { failure = $0 }))
        controller.beforeUserInput = { activations += 1 }
        let view = MetalTerminalView(frame: .zero)
        view.terminalDelegate = controller
        controller.start(view: view)
        defer { controller.stop() }
        try await waitUntil { await transport.hasTranscriptRequest }
        controller.send(source: view, data: Array("typed while restoring\r".utf8)[...])
        await transport.enqueueOutput(.init(terminalID: 41, offset: 0, bytes: previous + Data("AFTER_REMOUNT".utf8)))
        await transport.releaseTranscript()
        try await waitUntil {
            (String(data: view.getTerminal().getBufferAsData(), encoding: .utf8) ?? "").contains("AFTER_REMOUNT")
        }
        try await waitUntil { await transport.input == Data("typed while restoring\r".utf8) }
        let text = (String(data: view.getTerminal().getBufferAsData(), encoding: .utf8) ?? "")
        #expect(text.components(separatedBy: "BEFORE_REMOUNT").count == 2)
        #expect(activations == 1)
        #expect(failure == nil)
    }
}
