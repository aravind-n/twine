import Foundation
import SwiftTerm
import SwiftUI
import Testing

@testable import Twine

struct TerminalControllerTests {
    @Test @MainActor func enhancedReturnUsesTheUserInputRoute() async throws {
        var snapshot = CoreSnapshot.testReady()
        snapshot.terminals = [.init(terminalID: 41, status: .running)]
        let transport = DelayedStartTransport(snapshot: snapshot)
        let client = CoreClient(transport: transport)
        client.start()
        defer { Task { await client.stop() } }
        try await client.waitUntilRunning()
        let controller = TerminalController(coreClient: client, terminalID: 41, failureMessage: .constant(nil))
        let view = MetalTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        view.terminalDelegate = controller
        controller.start(view: view)
        defer { controller.stop() }
        view.feed(byteArray: Array("\u{1B}[>8u".utf8)[...])
        view.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        try await waitUntil { !(await transport.userInput).isEmpty }
        #expect(await transport.userInput == Data("\u{1B}[13u".utf8))
        #expect(await transport.terminalResponses.isEmpty)
    }

    @Test @MainActor func automaticRepliesDoNotActivateAndUserBytesWaitForActivationInOrder() async throws {
        var snapshot = CoreSnapshot.testReady()
        snapshot.terminals = [.init(terminalID: 41, status: .running)]
        let transport = DelayedStartTransport(snapshot: snapshot)
        let client = CoreClient(transport: transport)
        client.start()
        defer { Task { await client.stop() } }
        try await client.waitUntilRunning()
        let controller = TerminalController(coreClient: client, terminalID: 41, failureMessage: .constant(nil))
        let view = MetalTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        view.terminalDelegate = controller
        controller.start(view: view)
        defer { controller.stop() }
        var activationCount = 0
        controller.beforeUserInput = {
            activationCount += 1
            try await Task.sleep(for: .milliseconds(30))
        }
        view.feed(byteArray: Array("\u{1B}[6n".utf8)[...])
        try await waitUntil { !(await transport.input).isEmpty }
        #expect(activationCount == 0)
        let automaticReply = await transport.input
        #expect(await transport.terminalResponses == automaticReply)
        #expect(await transport.userInput.isEmpty)

        view.insertText("first", replacementRange: NSRange(location: NSNotFound, length: 0))
        view.insertText("second", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(await transport.input == automaticReply)
        try await waitUntil { await transport.input == automaticReply + Data("firstsecond".utf8) }
        #expect(activationCount == 2)
        #expect(await transport.userInput == Data("firstsecond".utf8))
        #expect(await transport.terminalResponses == automaticReply)
    }

    @Test(arguments: [
        CoreTerminalState.Status.exited(.init(exitCode: 0, signal: nil)),
        .failed(message: "Process stopped"), nil,
    ])
    @MainActor func endedTerminalsKeepOutputWithoutForwardingInputOrResizes(
        status: CoreTerminalState.Status?
    ) async throws {
        var snapshot = CoreSnapshot.testReady()
        snapshot.terminals = status.map { [.init(terminalID: 41, status: $0)] } ?? []
        let transport = DelayedStartTransport(snapshot: snapshot)
        let client = CoreClient(transport: transport)
        client.start()
        defer { Task { await client.stop() } }
        try await client.waitUntilRunning()
        var failure: String?
        var activations = 0
        let controller = TerminalController(
            coreClient: client, terminalID: 41,
            failureMessage: Binding(get: { failure }, set: { failure = $0 })
        )
        controller.beforeUserInput = { activations += 1 }
        let view = MetalTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        view.terminalDelegate = controller
        controller.start(view: view)
        defer { controller.stop() }
        await transport.enqueueOutput(
            CoreTerminalChunk(terminalID: 41, offset: 0, bytes: Data("final-output\u{1B}[6n".utf8))
        )
        view.insertText("late input", replacementRange: NSRange(location: NSNotFound, length: 0))
        controller.sizeChanged(source: view, newCols: 100, newRows: 30)
        try await waitUntil {
            String(data: view.getTerminal().getBufferAsData(), encoding: .utf8)?.contains("final-output") == true
        }
        #expect(await transport.inputAttempts == 0)
        #expect(await transport.lastResize == nil)
        #expect(activations == 0)
        #expect(failure == nil)
    }

    @Test @MainActor func exitDuringInputActivationDropsQueuedInput() async throws {
        var snapshot = CoreSnapshot.testReady()
        snapshot.terminals = [.init(terminalID: 41, status: .running)]
        let transport = DelayedStartTransport(snapshot: snapshot)
        let client = CoreClient(transport: transport)
        client.start()
        defer { Task { await client.stop() } }
        try await client.waitUntilRunning()
        var failure: String?
        let controller = TerminalController(
            coreClient: client, terminalID: 41,
            failureMessage: Binding(get: { failure }, set: { failure = $0 })
        )
        defer { controller.stop() }
        var activated = false
        controller.beforeUserInput = {
            await transport.exitTerminal(41)
            try await waitUntil { client.terminalStatus(for: 41) != .running }
            activated = true
        }
        let view = MetalTerminalView(frame: .zero)
        controller.send(source: view, data: Array("first".utf8)[...])
        controller.send(source: view, data: Array("second".utf8)[...])
        try await waitUntil { activated }
        // Let both queued writes resume after activation.
        try await Task.sleep(for: .milliseconds(30))
        #expect(await transport.inputAttempts == 0)
        #expect(failure == nil)
    }

    @Test(arguments: [CoreFailure.terminalNotRunning, .internalError])
    @MainActor func inputFailureDistinguishesProcessExitFromInternalError(error: CoreFailure) async throws {
        var snapshot = CoreSnapshot.testReady()
        snapshot.terminals = [.init(terminalID: 41, status: .running)]
        let transport = DelayedStartTransport(snapshot: snapshot)
        await transport.failInput(with: error)
        let client = CoreClient(transport: transport)
        client.start()
        defer { Task { await client.stop() } }
        try await client.waitUntilRunning()
        var failure: String?
        let controller = TerminalController(
            coreClient: client, terminalID: 41,
            failureMessage: Binding(get: { failure }, set: { failure = $0 })
        )
        defer { controller.stop() }
        let view = MetalTerminalView(frame: .zero)
        controller.send(source: view, data: Array("first".utf8)[...])
        controller.send(source: view, data: Array("second".utf8)[...])
        try await waitUntil { await transport.inputAttempts > 0 }
        try await Task.sleep(for: .milliseconds(30))
        if error == .terminalNotRunning {
            #expect(await transport.inputAttempts == 1)
            #expect(failure == nil)
        } else {
            #expect(failure == error.localizedDescription)
        }
    }

    @Test @MainActor func stopDuringStartupClosesTheLateShell() async throws {
        let transport = DelayedStartTransport()
        let client = CoreClient(transport: transport)
        client.start()
        let controller = TerminalController(
            coreClient: client, workingDirectory: URL(filePath: "/"),
            terminalID: .constant(nil), failureMessage: .constant(nil)
        )
        let view = MetalTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        controller.start(view: view)
        try await waitUntil { await transport.hasStartRequest }
        controller.stop()
        await transport.completeStart(terminalID: 41)
        try await waitUntil {
            let closed = await transport.closedTerminalIDs.contains(41)
            return closed && client.snapshot?.terminals.isEmpty == true
        }
        #expect(client.snapshot?.terminals.isEmpty == true)
        await client.stop()
    }

    @Test @MainActor func inputTypedBeforeTheShellStartsIsSentOnceItHas() async throws {
        let transport = DelayedStartTransport()
        let client = CoreClient(transport: transport)
        client.start()
        defer { Task { await client.stop() } }
        let controller = TerminalController(
            coreClient: client,
            workingDirectory: URL(filePath: "/"),
            terminalID: .constant(nil),
            failureMessage: .constant(nil)
        )
        let view = MetalTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        defer { controller.stop() }

        controller.start(view: view)
        try await waitUntil { await transport.hasStartRequest }

        controller.send(source: view, data: Array("ls\r".utf8)[...])
        await transport.completeStart(terminalID: 1)

        try await waitUntil { await transport.input == Data("ls\r".utf8) }
    }

    @Test @MainActor func terminalAppliesResizeReceivedDuringStartup() async throws {
        let transport = DelayedStartTransport()
        let client = CoreClient(transport: transport)
        client.start()
        try await waitUntil { client.runState == .running }

        var boundTerminalID: UInt64?
        var failureMessage: String?
        let controller = TerminalController(
            coreClient: client,
            workingDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
            terminalID: Binding(
                get: { boundTerminalID },
                set: { boundTerminalID = $0 }
            ),
            failureMessage: Binding(
                get: { failureMessage },
                set: { failureMessage = $0 }
            )
        )
        let terminal = MetalTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        controller.start(view: terminal)
        try await waitUntil { await transport.hasStartRequest }

        controller.sizeChanged(source: terminal, newCols: 120, newRows: 40)
        await transport.completeStart(terminalID: 41)
        try await waitUntil { await transport.lastResize != nil }

        let resize = try #require(await transport.lastResize)
        #expect(resize.columns == 120)
        #expect(resize.rows == 40)
        #expect(boundTerminalID == 41)
        #expect(failureMessage == nil)

        controller.stop()
        try await Task.sleep(for: .milliseconds(20))
        await client.stop()
    }

    @Test @MainActor func shellWaitsForCoreToStart() async throws {
        let transport = DelayedStartTransport()
        let client = CoreClient(transport: transport)
        defer { Task { await client.stop() } }
        let controller = TerminalController(
            coreClient: client,
            workingDirectory: URL(filePath: "/"),
            terminalID: .constant(nil),
            failureMessage: .constant(nil)
        )
        let view = MetalTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        defer { controller.stop() }

        controller.start(view: view)
        try await Task.sleep(for: .milliseconds(50))
        #expect(client.runState == .idle)
        #expect(await !transport.hasStartRequest)

        client.start()
        try await waitUntil { await transport.hasStartRequest }
    }
}
