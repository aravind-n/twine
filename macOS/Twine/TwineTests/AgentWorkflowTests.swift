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
             "harness": "claudeCode", "terminalId": 9, "status": "cancelled", "startedAt": 1,
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
}
