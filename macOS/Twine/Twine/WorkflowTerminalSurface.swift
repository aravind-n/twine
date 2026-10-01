import SwiftUI

/// Keeps the live terminal mounted while its draft choices appear and disappear above it.
struct WorkflowTerminalSurface: View {
    @Environment(CoreClient.self) private var coreClient
    @Environment(TraceTerminalNavigation.self) private var navigation
    let folder: String
    let workflow: CoreWorkflow
    let isSelected: Bool
    var isVisible: Bool?
    var isTiled = false
    var didFocus: (() -> Void)?
    let reportFailure: (String) -> Void
    @State private var draft = WorkflowDraftPresentation()
    @State private var showsChoices = false
    @State private var focusRequest = 0
    @State private var selectedType: CoreWorkflowType?
    @State private var startingHarness: CoreHarness?
    private var history: TraceTerminalTarget? {
        navigation.target.flatMap { $0.workflowID == workflow.id ? $0 : nil }
    }

    var body: some View {
        if workflow.kind == .agents {
            AgentWorkflowSurface(
                folder: folder, workflow: workflow, isSelected: isSelected, reportFailure: reportFailure)
        } else {
            VStack(spacing: 0) {
                if workflow.restored || (workflow.kind == .singleAgent && workflow.status != .running) {
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
            .overlay {
                if let history {
                    TerminalHistorySurface(target: history) {
                        navigation.target = nil
                        focusRequest += 1
                    }
                    .id(history.id)
                }
            }
        }
    }

    /// Legacy workflows without a recorded terminal can still explain their lifecycle.
    private var restoredAgent: some View {
        let (title, detail) =
            switch workflow.status {
            case .exited: ("Agent Exited", "No saved terminal output is available.")
            case .cancelled: ("Agent Cancelled", "No saved terminal output is available.")
            case .failed: ("Agent Failed", "No saved terminal output is available.")
            default: ("Agent Interrupted", "Twine quit while this agent was running. Its work didn't finish.")
            }
        return ContentUnavailableView(title, systemImage: "person", description: Text(detail))
    }

    private var terminal: some View {
        TerminalSurface(
            terminalID: workflow.terminalID,
            historyTerminalIDs: workflow.terminalHistory?.map(\.terminalID) ?? [], restoresOutput: workflow.restored,
            isVisible: (isVisible ?? isSelected) && history == nil,
            isSelected: isSelected && history == nil, focusRequest: focusRequest,
            automaticallyFocuses: workflow.kind != .draft || (selectedType == nil && startingHarness == nil),
            padding: isTiled ? BentoLayout.terminalPadding : Spacing.terminalContent,
            subject: workflow.kind == .singleAgent ? "Agent" : "Shell", isCancelled: workflow.status == .cancelled,
            beforeUserInput: {
                try await draft.activate(client: coreClient, workflowID: workflow.id)
            }, didFocus: didFocus
        )
        // A started agent gets a new terminal, so the emulator must be rebuilt for it.
        .id(workflow.terminalID)
        .overlay {
            GeometryReader { geometry in
                if workflow.kind == .draft && showsChoices {
                    NewTabChoices(
                        workflowID: workflow.id, availableHeight: geometry.size.height,
                        isSelected: isSelected,
                        choose: choose, startAgent: startAgent, focusTerminal: { focusRequest += 1 },
                        selectedType: $selectedType, startingHarness: $startingHarness
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

    private func startAgent(_ choice: HarnessChoice) async throws {
        try await coreClient.startAgent(workflowID: workflow.id, choice: choice)
        focusRequest += 1
    }

    private func choose(_ choice: WorkflowChoice) {
        Task {
            do {
                if choice == .terminal {
                    try await draft.activate(client: coreClient, workflowID: workflow.id)
                }
                focusRequest += 1
            } catch {
                // Typing can activate or closing can remove a draft while a choice is being sent.
                guard
                    coreClient.snapshot?.workflows.workflows.contains(
                        where: { $0.id == workflow.id && $0.kind == .draft }
                    ) == true
                else { return }
                reportFailure(error.localizedDescription)
            }
        }
    }
}
