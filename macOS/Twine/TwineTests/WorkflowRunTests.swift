import Foundation
import Testing

@testable import Twine

@MainActor
struct WorkflowRunTests {
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
            ])
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
        let decoded = try JSONDecoder().decode(
            CoreCompletionSignal.self, from: JSONSerialization.data(withJSONObject: encoded))
        #expect(decoded == signal)
    }

    @Test func startCarriesCustomVersionAndEachHarnessChoice() throws {
        let reference = CoreWorkflowType.Reference(user: .init(typeID: 10, version: 2))
        let envelope = CommandEnvelope(
            requestID: 1,
            command: .startWorkflowRun(
                workflowID: 3, workflowType: reference, prompt: "Task",
                roles: [.init(role: "worker", harness: .codex), .init(role: "worker", harness: .claudeCode)],
                size: .init(rows: 24, columns: 80, pixelWidth: 800, pixelHeight: 480)))
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(envelope)) as? [String: Any])
        let command = try #require(object["command"] as? [String: Any])
        let type = try #require(command["workflowType"] as? [String: Any])
        #expect((type["user"] as? [String: Int]) == ["type_id": 10, "version": 2])
        let choices = try #require(command["roleLaunches"] as? [[String: String]])
        #expect(choices.map { $0["harness"] } == ["codex", "claudeCode"])
    }
}
