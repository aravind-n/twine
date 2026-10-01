/// Assignment completion leaves an interactive harness alive. Show a status only after its
/// terminal stops, retaining assignment outcomes for completed roles.
nonisolated enum TerminalStatusMessage {
    static func text(
        subject: String, terminalStatus: CoreTerminalState.Status?,
        agentStatus: CoreWorkflowRun.AgentStatus? = nil, isCancelled: Bool = false,
        failureMessage: String? = nil
    ) -> String? {
        if let failureMessage { return failureMessage }
        if terminalStatus == .running { return nil }
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
