import OSLog
import SwiftUI

private let workflowLogger = Logger(subsystem: "com.twineproject.Twine", category: "workflows")

/// Every workflow stays mounted, including its output pump and terminal emulator, until it closes.
struct WorkflowWorkspace: View {
    @Environment(CoreClient.self) private var coreClient
    @Environment(WorkflowLayouts.self) private var layouts
    let folder: String
    @Binding var selection: WorkflowTabSelection
    var isVisible = true
    @State private var failureMessage: String?
    @State private var isSplitting = false

    private var allWorkflows: [CoreWorkflow] {
        guard coreClient.snapshot?.folders.openFolder == folder else { return [] }
        return coreClient.snapshot?.workflows.workflows ?? []
    }

    private var sessionID: UInt64? { coreClient.snapshot?.workflows.session?.sessionID }
    private var workflows: [CoreWorkflow] { allWorkflows.filter { $0.sessionID == sessionID } }
    private var selectionKey: [UInt64] { [sessionID ?? 0] + workflows.map(\.id) }
    private var selectedRoot: UInt64? {
        selection.selectedID.map { layouts.splitRoot(for: $0, in: folder, workflows: workflows) }
    }
    private var tabWorkflows: [CoreWorkflow] {
        workflows.filter { layouts.splitRoot(for: $0.id, in: folder, workflows: workflows) == $0.id }
    }
    private var canSplit: Bool {
        isVisible && !isSplitting && selectedWorkflow?.kind != .agents
            && selectedRoot.map { layouts.terminalSplit(for: $0, in: folder).ids.count < 4 } == true
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: 0) {
                WorkflowTabs(
                    workflows: tabWorkflows,
                    selectedID: selectedRoot,
                    select: { selection.selectedID = $0 },
                    close: closeGroup,
                    cancelAgent: cancelAgent,
                    create: { Task { await create() } }
                )
                TerminalSplitControls(split: split, isEnabled: canSplit)
            }
            .zIndex(1)
            ZStack {
                if workflows.isEmpty {
                    ContentUnavailableView(
                        "No Open Tabs", systemImage: "terminal",
                        description: Text("Open a workflow with + or ⌘T.")
                    )
                }
                WorkflowPaneCanvas(
                    folder: folder, workflows: allWorkflows, sessionID: sessionID,
                    selection: $selection, isVisible: isVisible, reportFailure: { failureMessage = $0 },
                    closePane: close)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.terminalBackground)
            .clipShape(panelShape)
            .overlay {
                panelShape.stroke(.hairline, lineWidth: Surface.hairlineWidth)
                    .mask { Rectangle().padding(.top, Surface.hairlineWidth) }
                    .allowsHitTesting(false)
            }
            .terminalPanelShadow()
        }
        .task {
            selection.reconcile(sessionID: sessionID, current: workflows.map(\.id))
            if coreClient.snapshot?.workflows.sessionsInitialized == false { await create() }
        }
        .onChange(of: selectionKey) {
            selection.reconcile(sessionID: sessionID, current: workflows.map(\.id))
        }
        .onChange(of: allWorkflows.map(\.id), initial: true) {
            layouts.removeClosedWorkflows(in: folder, state: coreClient.snapshot?.workflows)
        }
        .focusedSceneValue(\.workflowActions, actions)
        .alert(
            "Workflow Error",
            isPresented: Binding(
                get: { failureMessage != nil }, set: { if !$0 { failureMessage = nil } }
            )
        ) {
            Button("OK") { failureMessage = nil }
        } message: {
            Text(failureMessage ?? "")
        }
    }

    private var actions: WorkflowActions {
        WorkflowActions(
            create: { Task { await create() } },
            createAgents: { roles in Task { await create(kind: .agents, roles: roles) } },
            close: selection.selectedID.map { id in { close(id) } },
            cancelAgent: workflows.first(where: { $0.id == selection.selectedID && $0.isRunningAgent })
                .map { workflow in { cancelAgent(workflow.id) } },
            layoutMode: isVisible ? selectedWorkflow.flatMap(layoutMode(for:)) : nil,
            moveFocus: isVisible ? selectedWorkflow.flatMap(focusMover(for:)) : nil,
            splitTerminal: canSplit ? { split($0) } : nil
        )
    }

    private var panelShape: RoundedRectangle { RoundedRectangle(cornerRadius: CornerRadius.panel) }

    private var selectedWorkflow: CoreWorkflow? { workflows.first { $0.id == selection.selectedID } }

    /// The workflow's layout mode, when it has agents to arrange.
    private func layoutMode(for workflow: CoreWorkflow) -> Binding<WorkflowLayout.Mode>? {
        guard workflow.showsAgentSubtabs else { return nil }
        return Binding(
            get: { layouts.layout(for: workflow.id, in: folder).mode },
            set: { mode in
                var layout = layouts.layout(for: workflow.id, in: folder)
                layout.mode = mode
                layouts.setLayout(layout, for: workflow.id, in: folder)
            })
    }

    /// Moves the keyboard between the workflow's agents, when it has more than one.
    private func focusMover(for workflow: CoreWorkflow) -> ((Int) -> Void)? {
        if let selectedRoot {
            let ids = layouts.terminalSplit(for: selectedRoot, in: folder).ids
            if ids.count > 1 {
                return { offset in
                    let index = ids.firstIndex(of: selection.selectedID ?? 0) ?? 0
                    selection.selectedID = ids[(index + offset + ids.count) % ids.count]
                }
            }
        }
        guard workflow.showsAgentSubtabs else { return nil }
        return { offset in
            var layout = layouts.layout(for: workflow.id, in: folder)
            layout.moveFocus(by: offset, in: workflow.agents)
            layouts.setLayout(layout, for: workflow.id, in: folder)
        }
    }

    private func split(_ direction: TerminalSplit.Direction) {
        guard canSplit, let root = selectedRoot, let selected = selection.selectedID else { return }
        isSplitting = true
        Task {
            defer { isSplitting = false }
            do {
                let targetSession = sessionID
                if selectedWorkflow?.kind == .draft { try await coreClient.activateWorkflow(workflowID: selected) }
                let id = try await coreClient.createWorkflow(folder: folder, sessionID: targetSession, kind: .terminal)
                guard !Task.isCancelled, targetSession == sessionID,
                    workflows.contains(where: { $0.id == selected })
                else {
                    try await coreClient.closeWorkflow(workflowID: id)
                    return
                }
                var layout = layouts.layout(for: root, in: folder)
                layout.terminalSplit = (layout.terminalSplit ?? .pane(root)).inserting(
                    id, beside: selected, direction: direction)
                layouts.setLayout(layout, for: root, in: folder)
                selection.selectedID = id
            } catch { failureMessage = error.localizedDescription }
        }
    }

    private func closeGroup(_ id: UInt64) {
        for pane in layouts.terminalSplit(for: id, in: folder).ids { close(pane) }
    }

    private func create(kind: CoreWorkflow.Kind = .draft, roles: [String] = []) async {
        do {
            let targetSession = sessionID
            let id = try await coreClient.createWorkflow(
                folder: folder, sessionID: targetSession, kind: kind, roles: roles)
            if Task.isCancelled {
                try await coreClient.closeWorkflow(workflowID: id)
            } else if targetSession == sessionID || targetSession == nil {
                selection.selectedID = id
            }
        } catch {
            if Task.isCancelled || coreClient.snapshot?.folders.openFolder != folder { return }
            failureMessage = error.localizedDescription
            workflowLogger.error("Could not create workflow: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func cancelAgent(_ id: UInt64) {
        Task {
            do {
                try await coreClient.cancelAgent(workflowID: id)
            } catch {
                // The agent can end on its own just as Cancel is chosen.
                if (error as? CoreFailure)?.isAgentNotRunning == true { return }
                if !workflows.contains(where: { $0.id == id && $0.isRunningAgent }) { return }
                failureMessage = error.localizedDescription
                workflowLogger.error("Could not cancel agent: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func close(_ id: UInt64) {
        let root = layouts.splitRoot(for: id, in: folder, workflows: workflows)
        let sibling = layouts.terminalSplit(for: root, in: folder).ids.first { $0 != id }
        if selection.selectedID == id, let sibling { selection.selectedID = sibling }
        Task {
            do {
                try await coreClient.closeWorkflow(workflowID: id)
            } catch {
                if !workflows.contains(where: { $0.id == id }) { return }
                failureMessage = error.localizedDescription
                workflowLogger.error("Could not close workflow: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
