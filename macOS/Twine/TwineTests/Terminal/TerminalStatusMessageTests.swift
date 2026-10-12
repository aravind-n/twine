import Testing

@testable import Twine

struct TerminalStatusMessageTests {
    private let hangup = CoreTerminalState.Status.exited(.init(exitCode: 1, signal: "Hangup: 1"))

    @Test func acceptedCompletionLeavesALiveTerminalUnobstructed() {
        #expect(
            TerminalStatusMessage.text(subject: "Agent", terminalStatus: .running, agentStatus: .completed)
                == nil)
    }

    @Test func aCompletedAssignmentRemainsVisibleAfterItsTerminalExits() {
        #expect(
            TerminalStatusMessage.text(subject: "Agent", terminalStatus: hangup, agentStatus: .completed)
                == "Agent completed")
    }

    @Test func anUnexpectedHangupStillShowsTheProcessOutcome() {
        for status in [CoreWorkflowRun.AgentStatus.running, .exited, .failed, nil] {
            #expect(
                TerminalStatusMessage.text(subject: "Agent", terminalStatus: hangup, agentStatus: status)
                    == "Agent exited with code 1 (Hangup: 1)")
        }
        #expect(
            TerminalStatusMessage.text(subject: "Shell", terminalStatus: hangup)
                == "Shell exited with code 1 (Hangup: 1)")
    }

    @Test func cancellingTheNextStageDoesNotRelabelACompletedAgent() {
        #expect(
            TerminalStatusMessage.text(
                subject: "Agent", terminalStatus: hangup, agentStatus: .completed, isCancelled: true)
                == "Agent completed")
        #expect(
            TerminalStatusMessage.text(subject: "Agent", terminalStatus: hangup, agentStatus: .cancelled)
                == "Agent cancelled")
        #expect(
            TerminalStatusMessage.text(subject: "Agent", terminalStatus: hangup, isCancelled: true)
                == "Agent cancelled")
    }

    @Test func terminalFailuresRemainVisible() {
        #expect(
            TerminalStatusMessage.text(
                subject: "Agent", terminalStatus: hangup, agentStatus: .completed, failureMessage: "Output unavailable")
                == "Output unavailable")
        #expect(
            TerminalStatusMessage.text(subject: "Agent", terminalStatus: .failed(message: "Read failed"))
                == "Agent failed: Read failed")
    }
}
