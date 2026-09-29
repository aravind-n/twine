import SwiftUI

/// Keeps the live terminal mounted while its draft choices appear and disappear above it.
struct WorkflowTerminalSurface: View {
    @Environment(BridgeClient.self) private var bridgeClient
    let workflow: BridgeWorkflow
    let isSelected: Bool
    let newButtonFrame: CGRect
    let reportFailure: (String) -> Void
    @State private var draft = WorkflowDraftPresentation()
    @State private var choicesFrame = CGRect.zero
    @State private var showsChoices = false
    @State private var focusRequest = 0

    var body: some View {
        TerminalSurface(workflow: workflow, isSelected: isSelected, focusRequest: focusRequest) {
            try await draft.activate(client: bridgeClient, workflowID: workflow.id)
        }
        .overlay {
            GeometryReader { geometry in
                if workflow.kind == .draft && showsChoices {
                    NewTabChoices(name: workflow.name, availableHeight: geometry.size.height, choose: choose)
                        .frame(
                            maxWidth: min(
                                NewTabLayout.maximumWidth, max(0, geometry.size.width - 2 * Spacing.terminalContent))
                        )
                        .onGeometryChange(
                            for: CGRect.self, of: { $0.frame(in: .named("workflowWorkspace")) },
                            action: { if workflow.kind == .draft { choicesFrame = $0 } }
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
                .combined(with: .scale(scale: Motion.draftTabToTerminalCardScale))
                .combined(
                    with: .offset(
                        x: newButtonFrame.midX - choicesFrame.midX, y: newButtonFrame.midY - choicesFrame.midY))
        )
    }

    private func choose(_ choice: WorkflowChoice) {
        Task {
            do {
                if choice == .terminal {
                    try await draft.activate(client: bridgeClient, workflowID: workflow.id)
                } else {
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
