import OSLog
import SwiftUI

private let workflowLogger = Logger(subsystem: "com.twineproject.Twine", category: "workflows")

/// Every workflow stays mounted, including its output pump and terminal emulator, until it closes.
struct WorkflowWorkspace: View {
    @Environment(BridgeClient.self) private var bridgeClient
    let folder: String
    @Binding var selection: WorkflowTabSelection
    @State private var failureMessage: String?

    private var allWorkflows: [BridgeWorkflow] {
        guard bridgeClient.snapshot?.folders.openFolder == folder else { return [] }
        return bridgeClient.snapshot?.workflows.workflows ?? []
    }

    private var sessionID: UInt64? { bridgeClient.snapshot?.workflows.session?.sessionID }
    private var workflows: [BridgeWorkflow] { allWorkflows.filter { $0.sessionID == sessionID } }
    private var selectionKey: [UInt64] { [sessionID ?? 0] + workflows.map(\.id) }

    var body: some View {
        VStack(spacing: 0) {
            WorkflowTabs(
                workflows: workflows,
                selectedID: selection.selectedID,
                select: { selection.selectedID = $0 },
                close: close,
                create: { Task { await create() } }
            )
            .zIndex(1)
            ZStack {
                if workflows.isEmpty {
                    ContentUnavailableView(
                        "No Open Tabs", systemImage: "terminal",
                        description: Text("Open a workflow with + or ⌘T.")
                    )
                }
                ForEach(allWorkflows) { workflow in
                    let isSelected = workflow.sessionID == sessionID && workflow.id == selection.selectedID
                    WorkflowTerminalSurface(
                        workflow: workflow, isSelected: isSelected,
                        reportFailure: { failureMessage = $0 }
                    )
                    .opacity(isSelected ? 1 : 0)
                    .allowsHitTesting(isSelected)
                    .accessibilityHidden(!isSelected)
                }
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
            if bridgeClient.snapshot?.workflows.sessionsInitialized == false { await create() }
        }
        .onChange(of: selectionKey) {
            selection.reconcile(sessionID: sessionID, current: workflows.map(\.id))
        }
        .focusedSceneValue(
            \.workflowActions,
            WorkflowActions(
                create: { Task { await create() } },
                close: selection.selectedID.map { id in { close(id) } }
            )
        )
        .alert(
            "Workflow Couldn't Start",
            isPresented: Binding(
                get: { failureMessage != nil }, set: { if !$0 { failureMessage = nil } }
            )
        ) {
            Button("OK") { failureMessage = nil }
        } message: {
            Text(failureMessage ?? "")
        }
    }

    private var panelShape: RoundedRectangle { RoundedRectangle(cornerRadius: CornerRadius.panel) }

    private func create() async {
        do {
            let targetSession = sessionID
            let id = try await bridgeClient.createWorkflow(folder: folder, sessionID: targetSession, kind: .draft)
            if Task.isCancelled {
                try await bridgeClient.closeWorkflow(workflowID: id)
            } else if targetSession == sessionID || targetSession == nil {
                selection.selectedID = id
            }
        } catch {
            if Task.isCancelled || bridgeClient.snapshot?.folders.openFolder != folder { return }
            failureMessage = error.localizedDescription
            workflowLogger.error("Could not create workflow: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func close(_ id: UInt64) {
        Task {
            do {
                try await bridgeClient.closeWorkflow(workflowID: id)
            } catch {
                if !workflows.contains(where: { $0.id == id }) { return }
                failureMessage = error.localizedDescription
                workflowLogger.error("Could not close workflow: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
