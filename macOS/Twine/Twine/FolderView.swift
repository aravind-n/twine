import Foundation
import OSLog
import SwiftUI

private let gitLogger = Logger(subsystem: "com.twineproject.Twine", category: "git")

/// The window content while a folder is open.
struct FolderView: View {
    @Environment(CoreClient.self) private var coreClient
    @Environment(WorkflowLayouts.self) private var layouts
    @Environment(FileTabsModel.self) private var tabs
    @Environment(\.appZoom) private var zoom
    let path: String
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .all
    @State private var selection = WorkflowTabSelection()
    @State private var files = FileBrowserModel()
    @State private var traceNavigation = TraceTerminalNavigation()
    @State private var isTracesExpanded = false
    private var scale: CGFloat { zoom?.scale ?? 1 }

    var body: some View {
        NavigationSplitView(columnVisibility: $sidebarVisibility) {
            FolderSidebar(path: path, files: files)
                .appZoom()
                .frame(
                    minWidth: SidebarLayout.minimumWidth * scale,
                    idealWidth: SidebarLayout.idealWidth * scale,
                    maxWidth: SidebarLayout.maximumWidth * scale
                )
                .navigationSplitViewColumnWidth(
                    min: SidebarLayout.minimumWidth * scale,
                    ideal: SidebarLayout.idealWidth * scale,
                    max: SidebarLayout.maximumWidth * scale
                )
        } detail: {
            GeometryReader { geometry in
                WorkspaceViewport(
                    contentHeight: (workspaceHeight(in: geometry.size.height / scale) + workspaceChromeHeight) * scale
                ) {
                    VStack(spacing: Spacing.windowSections) {
                        WorkflowWorkspace(folder: path, selection: $selection, files: files)
                            .frame(height: workspaceHeight(in: geometry.size.height / scale))
                        if tabs.selected == nil {
                            TracesPanel(workflows: traceWorkflows, isExpanded: $isTracesExpanded)
                        }
                        StatusFooter(
                            branch: coreClient.snapshot?.folders.currentBranch,
                            workflow: selectedWorkflow
                        )
                    }
                    .padding(Spacing.windowMargins)
                    .appZoom()
                }
                .accessibilityIdentifier("workspaceViewport")
            }
            .background(.windowBackground)
            .navigationTitle(URL(filePath: path).lastPathComponent)
            .navigationSubtitle((path as NSString).abbreviatingWithTildeInPath)
        }
        .environment(traceNavigation)
        .environment(\.traceLaneColors, traceNavigation.laneColors)
        .onChange(of: traceNavigation.activity.lanes) { traceNavigation.updateLaneColors() }
        .onChange(of: traceNavigation.destination) {
            if let target = traceNavigation.destination {
                selection.selectedID = target.workflowID
                tabs.showWorkflows()
            }
        }
        .navigationSplitViewStyle(.balanced)
        .windowToolbarFullScreenVisibility(.visible)
        .task(id: path) { await refreshGitBranch() }
        .task(id: files.request(folder: path, file: tabs.selected?.path)) {
            let editor = tabs.selected
            await files.watch(files.request(folder: path, file: editor?.path), client: coreClient, editor: editor)
        }
        .focusedSceneValue(\.openFilePath, tabs.selected?.path)
    }

    /// Keep two terminal rows usable when zoom leaves less room than the surrounding panels need.
    /// The workspace scrolls in that case, retaining the window's physical size.
    private func workspaceHeight(in height: CGFloat) -> CGFloat {
        let font = coreClient.terminalFont
        var minimum = WorkflowTabLayout.height + WorkflowSurfaceLayout.minimumHeight(for: selectedWorkflow, font: font)
        if let selectedWorkflow {
            let root = layouts.splitRoot(
                for: selectedWorkflow.id, in: path, workflows: coreClient.snapshot?.workflows.workflows ?? [])
            let split = layouts.terminalSplit(for: root, in: path)
            if split.ids.count > 1 {
                let paneHeight = BentoLayout.minimumTerminalPaneHeight(
                    for: font, includesNotice: traceWorkflows.contains(where: \.showsRestoredNotice))
                minimum =
                    WorkflowTabLayout.height + 2 * BentoLayout.gutter + split.minimumHeight(paneHeight: paneHeight)
            }
        }
        return max(minimum, height - workspaceChromeHeight)
    }

    private var workspaceChromeHeight: CGFloat {
        let traces: CGFloat =
            tabs.selected == nil ? (isTracesExpanded ? TracesLayout.expandedHeight : TracesLayout.collapsedHeight) : 0
        let gaps = Spacing.windowSections * (tabs.selected == nil ? 2 : 1)
        return Spacing.windowMargins.top + Spacing.windowMargins.bottom + gaps + FooterLayout.height + traces
    }

    private var selectedWorkflow: CoreWorkflow? {
        guard let state = coreClient.snapshot?.workflows, state.session?.folder == path else { return nil }
        return state.workflows.first { $0.id == selection.selectedID && $0.sessionID == state.session?.sessionID }
    }

    private var traceWorkflows: [CoreWorkflow] {
        guard let selectedWorkflow, let state = coreClient.snapshot?.workflows else { return [] }
        let root = layouts.splitRoot(for: selectedWorkflow.id, in: path, workflows: state.workflows)
        return layouts.terminalSplit(for: root, in: path).ids.compactMap { id in
            state.workflows.first { $0.id == id && $0.sessionID == selectedWorkflow.sessionID }
        }
    }

    private func refreshGitBranch() async {
        do {
            while !Task.isCancelled {
                guard coreClient.runState == .running, coreClient.snapshot?.folders.openFolder == path
                else { return }
                do {
                    try await coreClient.refreshGitBranch(folder: path)
                } catch let error as CoreFailure where error.isGitBranchReadFailure {
                    gitLogger.error("Git branch refresh failed: \(error.localizedDescription, privacy: .public)")
                }
                try await Task.sleep(for: .seconds(5))
            }
        } catch is CancellationError {
            return
        } catch {
            gitLogger.error("Git branch refresh failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
