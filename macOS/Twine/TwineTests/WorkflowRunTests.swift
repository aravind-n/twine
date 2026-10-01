import Foundation
import Testing

@testable import Twine

@MainActor
struct WorkflowRunTests {
    @Test(arguments: ["interrupted", "completed", "cancelled", "exited"])
    func perAgentLifecycleSurvivesDecoding(_ status: String) throws {
        let json = """
            {"generation":1,"stage":"Implement","status":"interrupted","needsTask":false,"agents":[
              {"agentId":4,"active":false,"done":false,"reviewer":false,"harness":"pi","targets":[],
               "status":"\(status)"}]}
            """
        let run = try JSONDecoder().decode(CoreWorkflowRun.self, from: Data(json.utf8))
        #expect(run.agents.first?.status?.rawValue == status)
    }

    @Test(arguments: [
        ("running", true), ("waiting", true), ("exited", false), ("failed", false), ("completed", false),
    ])
    func onlyALiveActiveAgentIsWorking(_ status: String, _ working: Bool) throws {
        let json =
            #"{"agentId":4,"active":true,"done":false,"reviewer":false,"harness":"pi","targets":[],"#
            + #""status":"\#(status)"}"#
        let agent = try JSONDecoder().decode(CoreWorkflowRun.Agent.self, from: Data(json.utf8))
        #expect(agent.isWorking == working)
    }

    @Test func coreCatalogDecodesRolesAndLaunchBounds() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "TwineRunTests-\(UUID().uuidString)")
        let worker = CoreWorker(dataDirectory: directory)
        do {
            let snapshot = try await worker.open()
            let types = try #require(snapshot.workflowTypes)
            #expect(types.map(\.definition.name) == ["Adversarial", "Coordinator"])
            let coordinator = try #require(types.first { $0.reference.builtin == "coordinator" })
            let role = try #require(coordinator.definition.roles.first { $0.id == "worker" })
            #expect(role.instances.min == 2)
            #expect(role.instances.max >= role.instances.min)
            await worker.close()
            try FileManager.default.removeItem(at: directory)
        } catch {
            await worker.close()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    @Test func completionCarriesTheStageGenerationReviewAndWorkerAssignments() throws {
        let signal = CoreCompletionSignal(
            decision: .done, summary: "Split the task",
            assignments: [
                .init(role: "worker", instance: 1, task: "Fix one file", files: ["one.swift"])
            ], task: "Tidy the parser")
        let envelope = CommandEnvelope(
            requestID: 2,
            command: .completeWorkflowRole(
                workflowID: 3, agentID: 4, generation: 5, signal: signal))
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(envelope)) as? [String: Any])
        let command = try #require(object["command"] as? [String: Any])
        #expect(command["type"] as? String == "completeWorkflowRole")
        #expect(command["generation"] as? Int == 5)
        #expect(command["agentId"] as? Int == 4)
        let encoded = try #require(command["signal"] as? [String: Any])
        #expect(encoded["task"] as? String == "Tidy the parser")
        let decoded = try JSONDecoder().decode(
            CoreCompletionSignal.self, from: JSONSerialization.data(withJSONObject: encoded))
        #expect(decoded == signal)
    }

    @Test func startCarriesCustomVersionAndEachHarnessChoice() throws {
        let reference = CoreWorkflowType.Reference(user: .init(typeID: 10, version: 2))
        let envelope = CommandEnvelope(
            requestID: 1,
            command: .startWorkflowRun(
                workflowID: 3, workflowType: reference,
                roles: [.init(role: "worker", harness: .codex), .init(role: "worker", harness: .claudeCode)],
                size: .init(rows: 24, columns: 80, pixelWidth: 800, pixelHeight: 480)))
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(envelope)) as? [String: Any])
        let command = try #require(object["command"] as? [String: Any])
        let type = try #require(command["workflowType"] as? [String: Any])
        #expect((type["user"] as? [String: Int]) == ["type_id": 10, "version": 2])
        let choices = try #require(command["roleLaunches"] as? [[String: String]])
        #expect(choices.map { $0["harness"] } == ["codex", "claudeCode"])
    }

    @Test func continuationIdentifiesTheFirstAgentAndCompletedGeneration() throws {
        let envelope = CommandEnvelope(
            requestID: 1,
            command: .continueWorkflowRun(workflowID: 3, agentID: 4, generation: 5))
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(envelope)) as? [String: Any])
        let command = try #require(object["command"] as? [String: Any])
        #expect(command["type"] as? String == "continueWorkflowRun")
        #expect(command["workflowId"] as? Int == 3)
        #expect(command["agentId"] as? Int == 4)
        #expect(command["generation"] as? Int == 5)
    }

    @Test(arguments: [CoreWorkflowRun.Status.running, .completed, .limitReached])
    func firstStageInputChecksCoreWithAStaleSnapshot(status: CoreWorkflowRun.Status) async throws {
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
            generation: 2, stage: "Review", status: status, message: nil, needsTask: false,
            agents: [
                .init(
                    agentId: 4, active: false, done: false, reviewer: false, harness: .codex, targets: [],
                    role: "implementer"),
                .init(
                    agentId: 5, active: true, done: false, reviewer: true, harness: .claudeCode, targets: [],
                    role: "reviewer"),
            ], workflowType: type)
        var snapshot = CoreSnapshot.testReady()
        snapshot.workflows.workflows = [
            .init(
                workflowID: 3, sessionID: 1, name: "Adversarial", kind: .agents, terminalID: 0,
                status: .running, startedAt: 1, endedAt: nil, run: run)
        ]
        let transport = ScriptedAgentTransport(snapshot: snapshot)
        let client = CoreClient(transport: transport)
        client.start()
        do {
            try await waitUntil { client.runState == .running }
            try await client.continueWorkflowIfNeeded(workflowID: 3, agentID: 5)
            #expect(await transport.continuationAgentIDs.isEmpty)
            try await client.continueWorkflowIfNeeded(workflowID: 3, agentID: 4)
            #expect(await transport.continuationAgentIDs == [4])
            await client.stop()
        } catch {
            await client.stop()
            throw error
        }
    }
}
