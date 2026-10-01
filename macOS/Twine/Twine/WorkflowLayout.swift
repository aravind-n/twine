/// How an agents workflow shows its agents: one at a time under subtabs, or up to four at once in
/// resizable Bento panes. Presentation state only. `WorkflowLayouts` keeps it across relaunch, and
/// restored agents keep their IDs, so a saved layout still fits them.
nonisolated struct WorkflowLayout: Codable, Equatable, Sendable {
    enum Mode: String, Codable, Sendable {
        case tabs
        case bento
    }

    static let maximumPanes = 4

    var mode = Mode.tabs
    var terminalSplit: TerminalSplit?
    /// The agent with the keyboard: the one tab mode shows, or the focused Bento pane's.
    var focusedAgentID: UInt64?
    /// The agent in each Bento pane, in pane order. `panes(of:)` fits it to the workflow's agents.
    var paneAgentIDs: [UInt64] = []
    /// The leading column's share of the panes' width.
    var columnFraction = 0.5
    /// The top pane's share of each column's height, for a column with two panes.
    var rowFractions = [0.5, 0.5]

    /// The focused agent while it exists, otherwise the first.
    func focusedAgent(in agents: [CoreAgent]) -> CoreAgent? {
        agents.first { $0.id == focusedAgentID } ?? agents.first
    }

    /// A new run opens on the first stage's agent, which asks the user for the task. A layout that
    /// already has a focused agent keeps it.
    mutating func openOnFirstStage(activeAgentIDs: [UInt64], in agents: [CoreAgent]) {
        guard focusedAgentID == nil, let first = activeAgentIDs.first else { return }
        focus(first, in: agents)
    }

    /// One agent per Bento pane: the saved order for agents that still exist, then the rest in role
    /// order, up to four. The focused agent always has a pane.
    func panes(of agents: [CoreAgent]) -> [CoreAgent] {
        var panes: [CoreAgent] = []
        for id in paneAgentIDs {
            if let agent = agents.first(where: { $0.id == id }), !panes.contains(agent) { panes.append(agent) }
        }
        panes += agents.filter { !panes.contains($0) }
        panes = Array(panes.prefix(Self.maximumPanes))
        if let focused = focusedAgent(in: agents), !panes.contains(focused) {
            panes[panes.count - 1] = focused
        }
        return panes
    }

    /// Gives an agent the keyboard. In Bento mode the panes stay as they are on screen, and an agent
    /// without a pane takes the focused one's.
    mutating func focus(_ agentID: UInt64, in agents: [CoreAgent]) {
        guard agents.contains(where: { $0.id == agentID }) else { return }
        if mode == .bento {
            let ids = panes(of: agents).map(\.id)
            let focusedID = focusedAgent(in: agents)?.id
            paneAgentIDs = ids.contains(agentID) ? ids : ids.map { $0 == focusedID ? agentID : $0 }
        }
        focusedAgentID = agentID
    }

    /// Puts an agent in a pane and focuses it. An agent that had another pane swaps places.
    mutating func place(_ agentID: UInt64, inPane index: Int, of agents: [CoreAgent]) {
        var ids = panes(of: agents).map(\.id)
        guard ids.indices.contains(index), agents.contains(where: { $0.id == agentID }) else { return }
        if let current = ids.firstIndex(of: agentID) {
            ids.swapAt(current, index)
        } else {
            ids[index] = agentID
        }
        paneAgentIDs = ids
        focusedAgentID = agentID
    }

    /// Moves the keyboard forward or back, wrapping around: through the agents in tab mode, and through
    /// the panes as they are on screen in Bento mode.
    mutating func moveFocus(by offset: Int, in agents: [CoreAgent]) {
        let ids = mode == .bento ? panes(of: agents).map(\.id) : agents.map(\.id)
        guard let focused = focusedAgent(in: agents), let index = ids.firstIndex(of: focused.id) else { return }
        if mode == .bento { paneAgentIDs = ids }
        let count = ids.count
        focusedAgentID = ids[((index + offset) % count + count) % count]
    }
}
