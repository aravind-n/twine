import SwiftUI

/// Keeps the live terminal mounted while its draft choices appear and disappear above it.
struct WorkflowTerminalSurface: View {
    @Environment(BridgeClient.self) private var bridgeClient
    let folder: String
    let workflow: BridgeWorkflow
    let isSelected: Bool
    let reportFailure: (String) -> Void
    @State private var draft = WorkflowDraftPresentation()
    @State private var showsChoices = false
    @State private var focusRequest = 0
    @State private var selectedHarness: BridgeHarness?
    @State private var selectedType: BridgeWorkflowType?

    var body: some View {
        if workflow.kind == .agents {
            AgentWorkflowSurface(folder: folder, workflow: workflow, isSelected: isSelected)
        } else {
            VStack(spacing: 0) {
                if workflow.restored && workflow.kind != .singleAgent {
                    RestoredWorkflowNotice(workflow: workflow)
                }
                if workflow.terminalID == 0 {
                    if workflow.kind == .singleAgent {
                        restoredAgent
                    } else {
                        ContentUnavailableView(
                            "Shell Couldn't Restart", systemImage: "terminal",
                            description: Text("Open a new workflow to try again."))
                    }
                } else {
                    terminal
                }
            }
        }
    }

    /// A restored agent has no process or terminal contents, only how it last ended.
    private var restoredAgent: some View {
        let (title, detail) =
            switch workflow.status {
            case .exited: ("Agent Exited", "This agent's process ended. Its terminal output isn't restored.")
            case .cancelled: ("Agent Cancelled", "You cancelled this agent. Its terminal output isn't restored.")
            case .failed: ("Agent Failed", "This agent's process failed. Its terminal output isn't restored.")
            default: ("Agent Interrupted", "Twine quit while this agent was running. Its work didn't finish.")
            }
        return ContentUnavailableView(title, systemImage: "person", description: Text(detail))
    }

    private var terminal: some View {
        TerminalSurface(
            terminalID: workflow.terminalID, isVisible: isSelected, isSelected: isSelected, focusRequest: focusRequest,
            automaticallyFocuses: workflow.kind != .draft || (selectedHarness == nil && selectedType == nil),
            subject: workflow.kind == .singleAgent ? "Agent" : "Shell", isCancelled: workflow.status == .cancelled
        ) {
            try await draft.activate(client: bridgeClient, workflowID: workflow.id)
        }
        // A started agent gets a new terminal, so the emulator must be rebuilt for it.
        .id(workflow.terminalID)
        .overlay {
            GeometryReader { geometry in
                if workflow.kind == .draft && showsChoices {
                    NewTabChoices(
                        workflowID: workflow.id, name: workflow.name, availableHeight: geometry.size.height,
                        isSelected: isSelected,
                        choose: choose, startAgent: startAgent, focusTerminal: { focusRequest += 1 },
                        harness: $selectedHarness, selectedType: $selectedType
                    )
                    .frame(
                        maxWidth: min(
                            NewTabLayout.maximumWidth, max(0, geometry.size.width - 2 * Spacing.terminalContent))
                    )
                    .transition(choicesTransition)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .animation(Motion.draftTabToTerminal, value: workflow.kind)
        .onAppear {
            withAnimation(Motion.choicesCardAppear) { showsChoices = true }
        }
    }

    private var choicesTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: Motion.choicesCardAppearScale)),
            removal: .opacity
        )
    }

    private func startAgent(harness: BridgeHarness, prompt: String) async throws {
        try await bridgeClient.startAgent(workflowID: workflow.id, harness: harness, prompt: prompt)
        focusRequest += 1
    }

    private func choose(_ choice: WorkflowChoice) {
        Task {
            do {
                if choice == .terminal {
                    try await draft.activate(client: bridgeClient, workflowID: workflow.id)
                } else if choice != .singleAgent {
                    try await bridgeClient.nameDraftWorkflow(workflowID: workflow.id, name: choice.rawValue)
                }
                focusRequest += 1
            } catch {
                // Typing can activate or closing can remove a draft while a choice is being sent.
                guard
                    bridgeClient.snapshot?.workflows.workflows.contains(
                        where: { $0.id == workflow.id && $0.kind == .draft }
                    ) == true
                else { return }
                reportFailure(error.localizedDescription)
            }
        }
    }
}
