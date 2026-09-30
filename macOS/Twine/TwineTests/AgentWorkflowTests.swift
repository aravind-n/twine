import Foundation
import Testing

@testable import Twine

@MainActor
struct AgentWorkflowTests {
    @Test func agentStatusesNeverReadAsSuccess() {
        for (status, text) in [
            (BridgeWorkflow.Status.exited, "Exited"), (.cancelled, "Cancelled"), (.interrupted, "Interrupted"),
        ] {
            let workflow = agent(status)
            #expect(WorkflowFooterState(workflow: workflow, now: Date(timeIntervalSince1970: 10)).status == text)
        }
    }

    @Test func onlyARunningAgentCanBeCancelled() {
        #expect(agent(.running).isRunningAgent)
        #expect(!agent(.exited).isRunningAgent)
        #expect(!agent(.cancelled).isRunningAgent)
    }

    @Test func agentWorkflowsDecodeTheirHarness() throws {
        let json = """
            {"workflowId": 3, "sessionId": 1, "name": "Claude Code", "kind": "singleAgent",
             "harness": "claudeCode", "terminalId": 9, "agents": [], "status": "cancelled", "startedAt": 1,
             "endedAt": 2, "restored": false}
            """
        let workflow = try JSONDecoder().decode(BridgeWorkflow.self, from: Data(json.utf8))
        #expect(workflow.kind == .singleAgent)
        #expect(workflow.harness == .claudeCode)
        #expect(workflow.status == .cancelled)
    }

    @Test func startAgentEncodesHarnessPromptAndSize() throws {
        let size = BridgeTerminalSize(rows: 24, columns: 80, pixelWidth: 800, pixelHeight: 480)
        let envelope = CommandEnvelope(
            requestID: 5, command: .startAgent(workflowID: 3, harness: .piAgent, prompt: "-fix", size: size))
        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(envelope)) as? [String: Any])
        let command = try #require(object["command"] as? [String: Any])
        #expect(command["type"] as? String == "startAgent")
        #expect(command["workflowId"] as? UInt64 == 3)
        #expect(command["harness"] as? String == "pi")
        #expect(command["prompt"] as? String == "-fix")
    }

    private func agent(_ status: BridgeWorkflow.Status) -> BridgeWorkflow {
        BridgeWorkflow(
            workflowID: 1, sessionID: 1, name: "pi", kind: .singleAgent, harness: .piAgent, terminalID: 1,
            status: status, startedAt: 1_000, endedAt: nil)
    }

    // MARK: Client behavior against a scripted transport

    @Test @MainActor func startingAnAgentReroutesTerminalOutputFromTheDraftShellToTheAgent() async throws {
        let transport = ScriptedAgentTransport(snapshot: snapshot(terminalID: 1, kind: .draft))
        let client = BridgeClient(transport: transport)
        client.start()
        defer { Task { await client.stop() } }
        try await waitUntil { client.connectionState == .running }
        // Output from the draft shell is buffered for its view, as if that view hadn't read it yet.
        await transport.queue(chunk: BridgeTerminalChunk(terminalID: 1, offset: 0, bytes: Data("draft".utf8)))
        #expect(try await client.nextTerminalChunk(for: 2) == nil)

        await transport.queue(event: .workflowChanged(workflow(terminalID: 2, kind: .singleAgent, status: .running)))
        try await waitUntil { client.snapshot?.workflows.workflows.first?.terminalID == 2 }

        #expect(client.terminalStatus(for: 1) == nil)
        #expect(client.terminalStatus(for: 2) == .running)
        #expect(try await client.nextTerminalChunk(for: 1) == nil, "the placeholder's buffered output is dropped")
        // Output that arrives for the placeholder after the swap is dropped too.
        await transport.queue(chunk: BridgeTerminalChunk(terminalID: 1, offset: 5, bytes: Data("late".utf8)))
        #expect(try await client.nextTerminalChunk(for: 2) == nil)
        await transport.queue(chunk: BridgeTerminalChunk(terminalID: 2, offset: 0, bytes: Data("agent".utf8)))
        let chunk = try #require(try await client.nextTerminalChunk(for: 2))
        #expect(chunk.bytes == Data("agent".utf8))
    }

    @Test @MainActor func startAndCancelRejectACompletionForADifferentWorkflow() async throws {
        let transport = ScriptedAgentTransport(snapshot: snapshot(terminalID: 1, kind: .draft))
        let client = BridgeClient(transport: transport)
        client.start()
        defer { Task { await client.stop() } }
        try await waitUntil { client.connectionState == .running }

        await transport.reply(with: .completes(.agentStarted(workflowID: 99)))
        await #expect(throws: BridgeFailure.unexpectedCommandResult) {
            try await client.startAgent(workflowID: 3, harness: .codex, prompt: "go")
        }
        await transport.reply(with: .completes(.agentCancelled(workflowID: 99)))
        await #expect(throws: BridgeFailure.unexpectedCommandResult) {
            try await client.cancelAgent(workflowID: 3)
        }
        await transport.reply(with: .completes(.agentStarted(workflowID: 3)))
        try await client.startAgent(workflowID: 3, harness: .codex, prompt: "go")
        await transport.reply(with: .completes(.agentCancelled(workflowID: 3)))
        try await client.cancelAgent(workflowID: 3)
    }

    @Test @MainActor func cancellingAnAgentThatAlreadyEndedIsNotAFailureToShow() async throws {
        let transport = ScriptedAgentTransport(snapshot: snapshot(terminalID: 1, kind: .draft))
        let client = BridgeClient(transport: transport)
        client.start()
        defer { Task { await client.stop() } }
        try await waitUntil { client.connectionState == .running }

        await transport.reply(with: .rejects(code: "agentNotRunning", message: "The agent isn't running."))
        let ended = await #expect(throws: BridgeFailure.self) { try await client.cancelAgent(workflowID: 3) }
        await transport.reply(with: .rejects(code: "workflowNotFound", message: "The workflow is no longer open."))
        let missing = await #expect(throws: BridgeFailure.self) { try await client.cancelAgent(workflowID: 3) }

        #expect(ended?.isAgentNotRunning == true)
        #expect(missing?.isAgentNotRunning == false)
    }

    @Test func everyWorkflowCommandResultDecodesToItsOwnCase() throws {
        let types: [(String, BridgeCommandResult)] = [
            ("workflowCreated", .workflowCreated(workflowID: 3)),
            ("workflowActivated", .workflowActivated(workflowID: 3)),
            ("workflowClosed", .workflowClosed(workflowID: 3)),
            ("agentStarted", .agentStarted(workflowID: 3)),
            ("agentCancelled", .agentCancelled(workflowID: 3)),
        ]
        for (type, expected) in types {
            let json = """
                {"sequence": 2, "event": {"type": "commandCompleted", "requestId": 7,
                 "result": {"type": "\(type)", "workflowId": 3}}}
                """
            let event = try JSONDecoder().decode(BridgeEvent.self, from: Data(json.utf8))
            #expect(event.event == .commandCompleted(requestID: 7, result: expected), "\(type)")
        }
    }

    private func workflow(
        terminalID: UInt64, kind: BridgeWorkflow.Kind, status: BridgeWorkflow.Status = .running
    ) -> BridgeWorkflow {
        BridgeWorkflow(
            workflowID: 3, sessionID: 1, name: "Workflow", kind: kind, terminalID: terminalID,
            status: status, startedAt: 1_000, endedAt: nil)
    }

    private func snapshot(terminalID: UInt64, kind: BridgeWorkflow.Kind) -> BridgeSnapshot {
        var snapshot = BridgeSnapshot.testReady()
        snapshot.workflows.workflows = [workflow(terminalID: terminalID, kind: kind)]
        snapshot.terminals = [BridgeTerminalState(terminalID: terminalID, status: .running)]
        return snapshot
    }
}

/// A transport that answers Start Agent and Cancel Agent as the test scripts, and hands back the
/// events and terminal output the test queues.
actor ScriptedAgentTransport {
    enum Reply {
        case completes(BridgeCommandResult)
        case rejects(code: String, message: String)
    }

    private let initialSnapshot: BridgeSnapshot
    private var scriptedReply = Reply.completes(.pong)
    private var eventsToDeliver: [BridgeEvent] = []
    private var chunks: [BridgeTerminalChunk] = []
    private var nextRequestID: UInt64 = 1

    init(snapshot: BridgeSnapshot) {
        initialSnapshot = snapshot
    }

    func reply(with reply: Reply) {
        scriptedReply = reply
    }

    func queue(event: BridgeEvent.Kind) {
        eventsToDeliver.append(
            BridgeEvent(sequence: initialSnapshot.sequence + UInt64(eventsToDeliver.count) + 1, event: event))
    }

    func queue(chunk: BridgeTerminalChunk) {
        chunks.append(chunk)
    }

    func open() -> BridgeSnapshot { initialSnapshot }

    func close() {}

    func send(_ command: BridgeCommand) -> BridgeCommandReceipt {
        let requestID = nextRequestID
        nextRequestID += 1
        switch (command, scriptedReply) {
        case (.startAgent, .completes(let result)), (.cancelAgent, .completes(let result)):
            queue(event: .commandCompleted(requestID: requestID, result: result))
        case (.startAgent, .rejects(let code, let message)), (.cancelAgent, .rejects(let code, let message)):
            return BridgeCommandReceipt(
                requestID: requestID, status: .rejected,
                error: .init(code: code, message: message))
        default:
            break
        }
        return BridgeCommandReceipt(requestID: requestID, status: .accepted, error: nil)
    }

    func snapshot() -> BridgeSnapshot { initialSnapshot }

    func events(after sequence: UInt64, limit: UInt32) -> [BridgeEvent] {
        eventsToDeliver.filter { $0.sequence > sequence }.prefix(Int(limit)).map(\.self)
    }

    func nextTerminalChunk() -> BridgeTerminalChunk? {
        chunks.isEmpty ? nil : chunks.removeFirst()
    }

    func saveFile(_ request: FileSaveRequest) throws -> FileSaveResult {
        throw BridgeFailure.invalidArgument
    }

    func pollFiles(_ request: FileBrowserRequest) throws -> FileBrowserSnapshot? {
        throw BridgeFailure.invalidArgument
    }

    func writeTerminalInput(terminalID: UInt64, bytes: Data) {}

    func resizeTerminal(terminalID: UInt64, size: BridgeTerminalSize) {}
}

// Declaring this conformance on the actor fails to compile in batch mode in Xcode 27.0.
extension ScriptedAgentTransport: BridgeTransport {}
