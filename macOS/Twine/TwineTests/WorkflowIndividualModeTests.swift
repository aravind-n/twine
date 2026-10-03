import Foundation
import Testing

@testable import Twine

@MainActor
struct WorkflowIndividualModeTests {
    @Test func olderRunSnapshotsDefaultToIndividualModeOff() throws {
        let json = #"{"generation":2,"stage":"Review","status":"completed","needsTask":false,"agents":[]}"#
        let run = try JSONDecoder().decode(CoreWorkflowRun.self, from: Data(json.utf8))
        #expect(!run.individualMode)
        #expect(run.modeRevision == 0)
    }

    @Test(arguments: [true, false])
    func modeCommandCarriesTheChoiceAndObservedRevisions(individualMode: Bool) throws {
        let envelope = CommandEnvelope(
            requestID: 1,
            command: .setWorkflowIndividualMode(
                workflowID: 3, generation: 5, modeRevision: 2, individualMode: individualMode))
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(envelope)) as? [String: Any])
        let command = try #require(object["command"] as? [String: Any])
        #expect(command["type"] as? String == "setWorkflowIndividualMode")
        #expect(command["workflowId"] as? Int == 3)
        #expect(command["generation"] as? Int == 5)
        #expect(command["modeRevision"] as? Int == 2)
        #expect(command["individualMode"] as? Bool == individualMode)
    }

    @Test func privateQueuedInputStaysPrivateAfterTurningIndividualModeOff() async throws {
        let transport = WorkflowModeTransport(snapshot: Self.snapshot(individualMode: true))
        let client = CoreClient(transport: transport)
        client.start()
        defer { Task { await client.stop() } }
        try await client.waitUntilRunning()
        let privateInput = client.prepareWorkflowInput(workflowID: 3, agentID: 4)
        try await client.setWorkflowIndividualMode(workflowID: 3, individualMode: false)
        try await privateInput()
        #expect(await transport.continuations.isEmpty)
        try await client.continueWorkflowIfNeeded(workflowID: 3, agentID: 4)
        #expect(await transport.continuations == [1])
    }

    @Test(arguments: [true, false])
    func inputDuringASwitchWaitsForAuthoritativeState(individualMode: Bool) async throws {
        let transport = WorkflowModeTransport(snapshot: Self.snapshot(individualMode: !individualMode))
        await transport.holdEvents()
        let client = CoreClient(transport: transport)
        client.start()
        defer { Task { await client.stop() } }
        try await client.waitUntilRunning()
        let switchTask = Task {
            try await client.setWorkflowIndividualMode(workflowID: 3, individualMode: individualMode)
        }
        try await waitUntil { await transport.hasModeChange }
        #expect(client.snapshot?.workflows.workflows.first?.run?.individualMode == !individualMode)
        let preparation = client.prepareWorkflowInput(workflowID: 3, agentID: 4)
        var prepared = false
        let input = Task {
            try await preparation()
            prepared = true
        }
        await Task.yield()
        #expect(!prepared)
        #expect(await transport.continuations.isEmpty)
        await transport.releaseEvents()
        try await switchTask.value
        try await input.value
        #expect(client.workflowModeChanges.isEmpty)
        #expect(client.snapshot?.workflows.workflows.first?.run?.individualMode == individualMode)
        #expect(await transport.continuations == (individualMode ? [] : [1]))
    }

    @Test func switchingModeDoesNotSkipConcurrentCommandCompletions() async throws {
        let transport = WorkflowModeTransport(snapshot: Self.snapshot(individualMode: false))
        await transport.holdEvents()
        let client = CoreClient(transport: transport)
        client.start()
        defer { Task { await client.stop() } }
        try await client.waitUntilRunning()
        var pingResult: CoreCommandResult?
        let ping = Task { pingResult = try await client.sendAndAwaitCompletion(.ping) }
        try await waitUntil { await transport.hasPing }
        let change = Task { try await client.setWorkflowIndividualMode(workflowID: 3, individualMode: true) }
        try await waitUntil { await transport.hasModeChange }
        await transport.releaseEvents()
        try await waitUntil { pingResult != nil && client.workflowModeChanges.isEmpty }
        try await ping.value
        try await change.value
        #expect(pingResult == .pong)
    }

    @Test func anOlderWorkflowInputKeepsItsRevisionAcrossTwoSwitches() async throws {
        let transport = WorkflowModeTransport(snapshot: Self.snapshot(individualMode: false))
        let client = CoreClient(transport: transport)
        client.start()
        defer { Task { await client.stop() } }
        try await client.waitUntilRunning()
        let queued = client.prepareWorkflowInput(workflowID: 3, agentID: 4)
        try await client.setWorkflowIndividualMode(workflowID: 3, individualMode: true)
        try await client.setWorkflowIndividualMode(workflowID: 3, individualMode: false)
        try await queued()
        #expect(await transport.continuations == [0])
        // Core rejects this old revision as a no-op; fresh input carries the current revision.
        try await client.continueWorkflowIfNeeded(workflowID: 3, agentID: 4)
        #expect(await transport.continuations == [0, 2])
    }

    @Test func aRejectedSwitchKeepsThePreviousMode() async throws {
        let transport = WorkflowModeTransport(snapshot: Self.snapshot(individualMode: false))
        await transport.rejectSwitch()
        let client = CoreClient(transport: transport)
        client.start()
        defer { Task { await client.stop() } }
        try await client.waitUntilRunning()
        await #expect(throws: CoreFailure.self) {
            try await client.setWorkflowIndividualMode(workflowID: 3, individualMode: true)
        }
        #expect(client.workflowModeChanges.isEmpty)
        #expect(client.snapshot?.workflows.workflows.first?.run?.individualMode == false)
    }

    private static func snapshot(individualMode: Bool) -> CoreSnapshot {
        let type = CoreWorkflowType(
            reference: .init(builtin: "adversarial"),
            definition: .init(
                name: "Adversarial", description: "", roles: [],
                stages: [
                    .init(
                        id: "implement", name: "Implement", roles: ["implementer"],
                        completion: .init(rule: .allRolesDone))
                ]))
        let run = CoreWorkflowRun(
            generation: 2, stage: "Review", status: .completed, message: nil, needsTask: false,
            agents: [
                .init(
                    agentId: 4, active: false, done: true, reviewer: false, harness: .codex, targets: [],
                    role: "implementer")
            ],
            workflowType: type, individualMode: individualMode)
        var snapshot = CoreSnapshot.testReady()
        snapshot.workflows.workflows = [
            .init(
                workflowID: 3, sessionID: 1, name: "Adversarial", kind: .agents, terminalID: 0, status: .completed,
                startedAt: 1, endedAt: 2, run: run)
        ]
        return snapshot
    }
}

private actor WorkflowModeTransport {
    private var state: CoreSnapshot
    private var holdsEvents = false
    private var rejectsSwitch = false
    private var pendingEvents: [CoreEvent] = []
    private var nextRequestID: UInt64 = 1
    private(set) var continuations: [UInt64] = []
    private(set) var hasModeChange = false
    private(set) var hasPing = false

    init(snapshot: CoreSnapshot) { state = snapshot }
    func holdEvents() { holdsEvents = true }
    func rejectSwitch() { rejectsSwitch = true }
    func releaseEvents() { holdsEvents = false }
    func open() -> CoreSnapshot { state }
    func close() {}
    func snapshot() -> CoreSnapshot { state }
    func send(_ command: CoreCommand) -> CoreCommandReceipt {
        let requestID = nextRequestID
        nextRequestID += 1
        switch command {
        case .setWorkflowIndividualMode(_, _, _, let individualMode):
            if rejectsSwitch {
                return .init(
                    requestID: requestID, status: .rejected, error: .init(code: "stale", message: "The run changed."))
            }
            state.workflows.workflows[0].run?.individualMode = individualMode
            state.workflows.workflows[0].run?.modeRevision += 1
            state.sequence += 1
            hasModeChange = true
            pendingEvents.append(.init(sequence: state.sequence, event: .workflowChanged(state.workflows.workflows[0])))
        case .ping:
            state.sequence += 1
            hasPing = true
            pendingEvents.append(
                .init(sequence: state.sequence, event: .commandCompleted(requestID: requestID, result: .pong)))
        case .continueWorkflowRun(_, _, _, let revision): continuations.append(revision)
        default: break
        }
        return .init(requestID: requestID, status: .accepted, error: nil)
    }
    func events(after sequence: UInt64, limit: UInt32) -> [CoreEvent] {
        holdsEvents ? [] : Array(pendingEvents.filter { $0.sequence > sequence }.prefix(Int(limit)))
    }
    func nextTerminalChunk() -> CoreTerminalChunk? { nil }
    func writeTerminalInput(terminalID: UInt64, bytes: Data) {}
    func resizeTerminal(terminalID: UInt64, size: CoreTerminalSize) {}
    func saveFile(_ request: FileSaveRequest) throws -> FileSaveResult { throw CoreFailure.invalidArgument }
    func pollFiles(_ request: FileBrowserRequest) throws -> FileBrowserSnapshot? { throw CoreFailure.invalidArgument }
}

extension WorkflowModeTransport: CoreTransport {}
