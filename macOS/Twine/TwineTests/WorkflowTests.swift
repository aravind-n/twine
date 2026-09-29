import AppKit
import Foundation
import SwiftTerm
import SwiftUI
import Testing

@testable import Twine

struct WorkflowTests {
    @Test @MainActor func selectionUsesNeighborsAndHandlesAnExistingSnapshot() {
        var selection = WorkflowTabSelection()
        selection.reconcile(previous: [], current: [1, 2, 3])
        #expect(selection.selectedID == 1)
        selection.selectedID = 2
        selection.reconcile(previous: [1, 2, 3], current: [1, 3])
        #expect(selection.selectedID == 3)
        selection.reconcile(previous: [1, 3], current: [1])
        #expect(selection.selectedID == 1)
        selection.reconcile(previous: [1], current: [])
        #expect(selection.selectedID == nil)
    }

    @Test @MainActor func draftActivationAndWorkflowCloseRoundTripThroughTheRealBridge() async throws {
        let directory = TemporaryPath()
        try FileManager.default.createDirectory(at: directory.url, withIntermediateDirectories: true)
        let client = BridgeClient(transport: BridgeWorker(dataDirectory: directory.url.appending(path: ".twine")))
        client.start()
        do {
            try await client.waitUntilRunning()
            _ = try await client.send(.openFolder(path: directory.url.path))
            try await waitUntil { client.snapshot?.folders.openFolder == directory.url.path }
            let id = try await client.createWorkflow(folder: directory.url.path, kind: .draft)
            let draft = try #require(client.snapshot?.workflows.workflows.first)
            #expect(draft.id == id)
            #expect(draft.kind == .draft)
            #expect(draft.status == .running)
            #expect(draft.endedAt == nil)
            #expect(client.snapshot?.workflows.session?.sessionID == draft.sessionID)
            try await client.activateWorkflow(workflowID: id)
            let activated = try #require(client.snapshot?.workflows.workflows.first)
            #expect(activated.kind == .terminal)
            #expect(activated.name == "Terminal")
            #expect(activated.terminalID == draft.terminalID)
            #expect(activated.startedAt == draft.startedAt)
            try await client.closeWorkflow(workflowID: id)
            #expect(client.snapshot?.workflows.workflows.isEmpty == true)
            #expect(client.snapshot?.terminals.isEmpty == true)
            await client.stop()
        } catch {
            await client.stop()
            throw error
        }
    }

    @Test @MainActor func hiddenWorkflowDrainsMoreThanTheRouterCapacityWhileSelectedTerminalResponds() async throws {
        let directory = TemporaryPath()
        try FileManager.default.createDirectory(at: directory.url, withIntermediateDirectories: true)
        let client = BridgeClient(transport: BridgeWorker(dataDirectory: directory.url.appending(path: ".twine")))
        client.start()
        var controllers: [TerminalController] = []
        do {
            try await client.waitUntilRunning()
            _ = try await client.send(.openFolder(path: directory.url.path))
            try await waitUntil { client.snapshot?.folders.openFolder == directory.url.path }
            _ = try await client.createWorkflow(folder: directory.url.path)
            _ = try await client.createWorkflow(folder: directory.url.path)
            let workflows = try #require(client.snapshot?.workflows.workflows)
            #expect(workflows.count == 2)
            let background = makeTerminal(client: client, workflow: workflows[0], isSelected: false)
            let selected = makeTerminal(client: client, workflow: workflows[1], isSelected: true)
            controllers = [background.controller, selected.controller]
            try await prepareShell(client: client, terminalID: workflows[0].terminalID, view: background.view)
            try await prepareShell(client: client, terminalID: workflows[1].terminalID, view: selected.view)
            // The marker is split in the command so echoed input cannot satisfy the assertion.
            try await client.writeTerminalInput(
                terminalID: workflows[0].terminalID,
                bytes: Data("yes background | head -c 2097152; printf '\\n%s\\n' BACKGROUND_\"\"DONE\r".utf8)
            )
            try await client.writeTerminalInput(
                terminalID: workflows[1].terminalID,
                bytes: Data("printf '%s\\n' FOREGROUND_\"\"READY\r".utf8)
            )
            try await waitForTerminal(selected.view, toContain: "FOREGROUND_READY")
            try await waitForTerminal(background.view, toContain: "BACKGROUND_DONE")
            #expect(background.failure.value == nil)
            #expect(selected.failure.value == nil)
            #expect(background.view.isHidden)
            #expect(terminalText(selected.view).contains("FOREGROUND_READY"))
            // Changing visibility preserves the very same emulator and screen contents.
            background.view.isHidden = false
            background.view.isSelected = true
            selected.view.isSelected = false
            selected.view.isHidden = true
            #expect(terminalText(background.view).contains("BACKGROUND_DONE"))
            #expect(terminalText(selected.view).contains("FOREGROUND_READY"))
            for controller in controllers { controller.stop() }
            #expect(client.snapshot?.workflows.workflows.count == 2)
            await client.stop()
        } catch {
            for controller in controllers { controller.stop() }
            await client.stop()
            throw error
        }
    }

    @MainActor
    private func prepareShell(client: BridgeClient, terminalID: UInt64, view: MetalTerminalView) async throws {
        // Wait for the replacement shell's prompt before sending the next command. A shell can
        // read ahead and discard queued input when exec replaces it.
        let command = "exec /bin/sh -c 'PS1=TWINE_\"\"READY; export PS1; exec /bin/sh'\n"
        try await client.writeTerminalInput(terminalID: terminalID, bytes: Data(command.utf8))
        try await waitForTerminal(view, toContain: "TWINE_READY")
    }

    @MainActor
    private func makeTerminal(client: BridgeClient, workflow: BridgeWorkflow, isSelected: Bool) -> TestTerminal {
        let view = MetalTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        view.isSelected = isSelected
        view.isHidden = !isSelected
        let failure = TerminalFailure()
        let controller = TerminalController(
            bridgeClient: client, terminalID: workflow.terminalID,
            failureMessage: Binding(get: { failure.value }, set: { failure.value = $0 })
        )
        view.terminalDelegate = controller
        controller.start(view: view)
        return TestTerminal(view: view, controller: controller, failure: failure)
    }

    @MainActor
    private func terminalText(_ view: MetalTerminalView) -> String {
        String(data: view.getTerminal().getBufferAsData(), encoding: .utf8) ?? ""
    }

    @MainActor
    private func waitForTerminal(_ view: MetalTerminalView, toContain marker: String) async throws {
        for _ in 0..<1_000 {
            if terminalText(view).contains(marker) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(terminalText(view).contains(marker))
    }
}

@MainActor
private final class TerminalFailure { var value: String? }

@MainActor
private struct TestTerminal {
    let view: MetalTerminalView
    let controller: TerminalController
    let failure: TerminalFailure
}
