import Foundation
import Testing

@testable import Twine

@MainActor
struct WorkflowFooterTests {
    @Test func elapsedUsesCoreMillisecondsClampsClockChangesAndFreezesAtExit() {
        let running = make(.terminal, .running)
        #expect(WorkflowFooterState(workflow: running, now: Date(timeIntervalSince1970: 3_662)).elapsed == "1:01:01")
        #expect(WorkflowFooterState(workflow: running, now: Date(timeIntervalSince1970: 0)).elapsed == "0:00")
        let exited = make(.terminal, .exited, end: 65_000)
        let first = WorkflowFooterState(workflow: exited, now: Date(timeIntervalSince1970: 100))
        let later = WorkflowFooterState(workflow: exited, now: Date(timeIntervalSince1970: 10_000))
        #expect(first.elapsed == "1:04")
        #expect(later.elapsed == first.elapsed)
        #expect(later.status == "Exited")
        #expect(
            WorkflowFooterState(
                workflow: make(.draft, .running), now: Date(timeIntervalSince1970: 10)
            ).status == "Draft")
    }

    @Test func onlyRunMessagesThatNeedAttentionReachTheFooter() throws {
        func message(_ status: String, _ text: String?) throws -> String? {
            let encoded = text.map { "\"\($0)\"" } ?? "null"
            let json =
                #"{"generation":1,"stage":"Review","status":"\#(status)","needsTask":false,"#
                + #""message":\#(encoded),"agents":[]}"#
            var workflow = make(.agents, .running)
            workflow.run = try JSONDecoder().decode(CoreWorkflowRun.self, from: Data(json.utf8))
            return WorkflowFooterState(workflow: workflow, now: .now).message
        }
        #expect(try message("limitReached", "Review limit reached") == "Review limit reached")
        #expect(try message("running", "Completion rejected") == "Completion rejected")
        #expect(try message("failed", "Couldn't reserve a terminal") == "Couldn't reserve a terminal")
        for (status, text) in [
            ("completed", "Workflow completed"), ("cancelled", "Workflow cancelled"),
            ("interrupted", "Twine stopped while the workflow was running."),
        ] {
            #expect(try message(status, text) == nil, "The status already says it")
        }
        #expect(try message("running", nil) == nil)
        #expect(try message("running", "") == nil)
        #expect(WorkflowFooterState(workflow: make(.terminal, .running), now: .now).message == nil)
    }

    private func make(
        _ kind: CoreWorkflow.Kind,
        _ status: CoreWorkflow.Status,
        end: UInt64? = nil
    ) -> CoreWorkflow {
        CoreWorkflow(
            workflowID: 1, sessionID: 1, name: "Terminal", kind: kind, terminalID: 1,
            status: status, startedAt: 1_000, endedAt: end
        )
    }
}
