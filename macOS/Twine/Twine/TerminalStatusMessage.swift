/// An accepted role completion explains why Twine stops its harness. Keep the raw process
/// outcome for terminals that ended without a workflow completion signal.
nonisolated enum TerminalStatusMessage {
    static func text(
        subject: String, terminalStatus: CoreTerminalState.Status?,
        agentStatus: CoreWorkflowRun.AgentStatus? = nil, isCancelled: Bool = false,
        failureMessage: String? = nil
    ) -> String? {
        if let failureMessage { return failureMessage }
        if agentStatus == .completed { return "Agent completed" }
        if agentStatus == .cancelled || isCancelled { return "Agent cancelled" }
        if agentStatus == .interrupted { return "Agent interrupted" }
        switch terminalStatus {
        case .exited(let exit):
            if let signal = exit.signal {
                return "\(subject) exited with code \(exit.exitCode) (\(signal))"
            }
            return "\(subject) exited with code \(exit.exitCode)"
        case .failed(let message):
            return "\(subject) failed: \(message)"
        case .running, .none:
            return nil
        }
    }
}
