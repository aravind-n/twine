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

    private func make(
        _ kind: BridgeWorkflow.Kind,
        _ status: BridgeWorkflow.Status,
        end: UInt64? = nil
    ) -> BridgeWorkflow {
        BridgeWorkflow(
            workflowID: 1, sessionID: 1, name: "Terminal", kind: kind, terminalID: 1,
            status: status, startedAt: 1_000, endedAt: end
        )
    }
}
