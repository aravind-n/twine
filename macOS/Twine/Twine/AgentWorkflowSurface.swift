import SwiftUI

/// An agents workflow's panel: every agent's live terminal, with subtabs to switch between them when
/// there is more than one. Each workflow remembers its subtab while it's open, because every
/// workflow stays mounted until it closes.
struct AgentWorkflowSurface: View {
    let workflow: BridgeWorkflow
    let isSelected: Bool
    @State private var selectedAgentID: UInt64?

    var body: some View {
        let shownID = workflow.shownAgent(selectedID: selectedAgentID)?.id
        VStack(spacing: 0) {
            if workflow.showsAgentSubtabs {
                AgentSubtabs(agents: workflow.agents, selectedID: shownID) { selectedAgentID = $0 }
            }
            if workflow.restored {
                RestoredWorkflowNotice(workflow: workflow)
            }
            ZStack {
                ForEach(workflow.agents) { agent in
                    let isShown = agent.id == shownID
                    Group {
                        if agent.terminalID == 0 {
                            ContentUnavailableView(
                                "Shell Couldn't Restart", systemImage: "terminal",
                                description: Text("Open a new workflow to try again."))
                        } else {
                            TerminalSurface(terminalID: agent.terminalID, isSelected: isSelected && isShown)
                        }
                    }
                    .opacity(isShown ? 1 : 0)
                    .allowsHitTesting(isShown)
                    .accessibilityHidden(!isShown)
                }
            }
        }
    }
}
