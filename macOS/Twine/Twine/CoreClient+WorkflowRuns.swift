import Foundation

extension CoreClient {
    func startWorkflowRun(
        workflowID: UInt64, workflowType: CoreWorkflowType.Reference, roles: [CoreRoleLaunch]
    ) async throws {
        try await sendRunCommand(
            .startWorkflowRun(
                workflowID: workflowID, workflowType: workflowType, roles: roles,
                size: .init(rows: 24, columns: 80, pixelWidth: 800, pixelHeight: 480)))
    }

    func completeWorkflowRole(
        workflowID: UInt64, agentID: UInt64, generation: UInt64, signal: CoreCompletionSignal
    ) async throws {
        try await sendRunCommand(
            .completeWorkflowRole(
                workflowID: workflowID, agentID: agentID, generation: generation, signal: signal))
    }

    func cancelWorkflowRun(workflowID: UInt64) async throws {
        try await sendRunCommand(.cancelWorkflowRun(workflowID: workflowID))
    }

    /// Typing to a first-stage agent after completion starts another automatic cycle.
    func continueWorkflowIfNeeded(workflowID: UInt64, agentID: UInt64) async throws {
        try await prepareWorkflowInput(workflowID: workflowID, agentID: agentID)()
    }

    /// Capture the user's intent when input is queued, before waiting for earlier PTY writes.
    func prepareWorkflowInput(workflowID: UInt64, agentID: UInt64) -> TerminalInputPreparation {
        let observedRun = snapshot?.workflows.workflows.first(where: { $0.id == workflowID })?.run
        let change = workflowModeChanges[workflowID]
        let individualMode = change?.individualMode ?? observedRun?.individualMode ?? true
        let generation = change?.generation ?? observedRun?.generation
        let modeRevision = change?.modeRevision ?? observedRun?.modeRevision
        return { [weak self] in
            guard let self else { return }
            // Await any switch already in flight, even for private input, so stale feedback has
            // been cleared before the bytes reach the harness. Later switches invalidate this revision.
            try await change?.completion.value
            guard !individualMode, let run = observedRun, let generation, let modeRevision,
                let role = run.agents.first(where: { $0.id == agentID })?.role,
                run.workflowType?.definition.stages.first?.roles.contains(role) == true
            else { return }
            try await sendRunCommand(
                .continueWorkflowRun(
                    workflowID: workflowID, agentID: agentID, generation: generation,
                    modeRevision: modeRevision))
        }
    }

    func setWorkflowIndividualMode(workflowID: UInt64, individualMode: Bool) async throws {
        guard workflowModeChanges[workflowID] == nil,
            let run = snapshot?.workflows.workflows.first(where: { $0.id == workflowID })?.run
        else { return }
        let expectedRevision =
            run.modeRevision + (run.individualMode == individualMode || run.modeRevision == .max ? 0 : 1)
        let completion = Task {
            try await sendRunCommand(
                .setWorkflowIndividualMode(
                    workflowID: workflowID, generation: run.generation, modeRevision: run.modeRevision,
                    individualMode: individualMode))
            // A receipt precedes event delivery. Let the regular pump acknowledge this revision
            // so concurrent command completions are processed before the cursor advances.
            while true {
                try Task.checkCancellation()
                guard runState == .running, !isStopping, !isTerminating,
                    let updated = snapshot?.workflows.workflows.first(where: { $0.id == workflowID })?.run
                else { throw CoreFailure.notRunning }
                if updated.modeRevision >= expectedRevision { return }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        workflowModeChanges[workflowID] = .init(
            individualMode: individualMode, generation: run.generation, modeRevision: expectedRevision,
            completion: completion)
        defer { workflowModeChanges.removeValue(forKey: workflowID) }
        _ = try await completion.value
    }

    private func sendRunCommand(_ command: CoreCommand) async throws {
        let receipt = try await send(command)
        if let error = receipt.error {
            throw CoreFailure.commandRejected(code: error.code, message: error.message)
        }
    }
}
