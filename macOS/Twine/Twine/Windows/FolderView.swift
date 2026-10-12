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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let path: String
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .all
    @State private var selection = WorkflowTabSelection()
    @State private var files = FileBrowserModel()
    @State private var traceNavigation = TraceTerminalNavigation()
    @State private var isTracesExpanded = false
    @State private var tracesRevealProgress: CGFloat = 0
    @State private var committedTracesExpansion = false
    @State private var tracesMotionID: UUID?
    @State private var designerWorkflowIDs: Set<UInt64> = []
    @State private var memories = MemoryModel()
    private var scale: CGFloat { zoom?.scale ?? 1 }

    init(path: String) {
        self.path = path
        let model = MemoryModel(folder: path)
        _memories = State(initialValue: model)
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $sidebarVisibility) {
            FolderSidebar(path: path, files: files, memories: memories)
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
                let availableHeight = max(0, geometry.size.height / scale - collapsedChromeHeight)
                let reservedWorkflowHeight = min(
                    availableHeight, max(WorkflowTabLayout.height, min(minimumWorkspaceHeight, availableHeight / 2)))
                let traceSpace = max(0, availableHeight - reservedWorkflowHeight)
                // Give the scrollable body space before growing the header in short windows.
                let headerExpansion = min(
                    TracesLayout.expandedHeaderHeight - TracesLayout.collapsedHeight,
                    max(0, traceSpace - TracesLayout.axisHeight - TracesLayout.laneHeight))
                let traceBodyHeight = min(
                    traceNavigation.activity.viewMode.expandedHeight - TracesLayout.expandedHeaderHeight,
                    max(0, traceSpace - headerExpansion))
                let workflowViewportHeight =
                    availableHeight - (showsTraces && committedTracesExpansion ? headerExpansion + traceBodyHeight : 0)
                let workflowHeight = max(minimumWorkspaceHeight, workflowViewportHeight)
                WorkspacePaneLayout(
                    revealProgress: tracesRevealProgress, traceBodyHeight: traceBodyHeight * scale,
                    traceHeaderHeight: TracesLayout.collapsedHeight * scale,
                    traceHeaderExpansion: headerExpansion * scale,
                    footerHeight: FooterLayout.height * scale,
                    spacing: Spacing.windowSections * scale, showsTraces: showsTraces
                ) {
                    WorkflowWorkspace(
                        folder: path, selection: $selection, files: files,
                        contentHeight: workflowHeight,
                        designerVisibilityChanged: {
                            designerWorkflowIDs = $0
                        }
                    )
                    .transaction { if tracesMotionID != nil { $0.animation = nil } }
                    if showsTraces {
                        TracesPanel(
                            workflows: traceWorkflows, isExpanded: $isTracesExpanded, bodyHeight: traceBodyHeight,
                            expandedHeaderHeight: TracesLayout.collapsedHeight + headerExpansion
                        )
                        .appZoom()
                        .transaction { if tracesMotionID != nil { $0.animation = nil } }
                    }
                    StatusFooter(
                        branch: coreClient.snapshot?.folders.currentBranch,
                        workflow: selectedWorkflow
                    )
                    .appZoom()
                    .transaction { if tracesMotionID != nil { $0.animation = nil } }
                }
                .padding(
                    EdgeInsets(
                        top: Spacing.windowMargins.top * scale, leading: Spacing.windowMargins.leading * scale,
                        bottom: Spacing.windowMargins.bottom * scale, trailing: Spacing.windowMargins.trailing * scale))
            }
            .background(.windowBackground)
            .navigationTitle(URL(filePath: path).lastPathComponent)
            .toolbar(removing: .title)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    HStack(spacing: 10) {
                        Text(URL(filePath: path).lastPathComponent)
                            .font(.system(size: 13, weight: .semibold))
                            .layoutPriority(1)
                        Text((path as NSString).abbreviatingWithTildeInPath)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .truncationMode(.middle)
                    }
                    .lineLimit(1)
                    .padding(.leading, 6)
                    .help(path)
                }
                .sharedBackgroundVisibility(.hidden)
            }
        }
        .modifier(MemoryLoading(folder: path, model: memories))
        .environment(traceNavigation)
        .environment(\.traceLaneColors, traceNavigation.laneColors)
        .onChange(of: isTracesExpanded) { _, expanded in
            let motionID = UUID()
            withAnimation(reduceMotion ? nil : Motion.sectionToggle, completionCriteria: .removed) {
                tracesMotionID = motionID
                tracesRevealProgress = expanded ? 1 : 0
            } completion: {
                guard tracesMotionID == motionID else { return }
                committedTracesExpansion = expanded
                tracesMotionID = nil
            }
        }
        .onChange(of: traceNavigation.activity.lanes) { traceNavigation.updateLaneColors() }
        .onChange(of: traceNavigation.destination) {
            if let target = traceNavigation.destination {
                selection.selectedID = target.workflowID
                tabs.showWorkflows()
            }
        }
        .navigationSplitViewStyle(.balanced)
        .windowToolbarFullScreenVisibility(.visible)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .task(id: path) { await refreshGitBranch() }
        .task(id: files.request(folder: path, file: watchedEditor?.path)) {
            let editor = watchedEditor
            await files.watch(files.request(folder: path, file: editor?.path), client: coreClient, editor: editor)
        }
        .focusedSceneValue(\.openFilePath, tabs.selected?.path)
    }

    private var watchedEditor: FileEditorModel? {
        guard let editor = tabs.selected, editor.memoryRequest == nil else { return nil }
        return editor
    }

    /// Workflow contents keep their minimum height and scroll inside their own viewport when needed.
    private var minimumWorkspaceHeight: CGFloat {
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
        return minimum
    }

    private var showsTraces: Bool {
        guard tabs.selected == nil else { return false }
        guard let selectedID = selection.selectedID else { return true }
        return !designerWorkflowIDs.contains(selectedID)
    }

    private var collapsedChromeHeight: CGFloat {
        let traces: CGFloat = showsTraces ? TracesLayout.collapsedHeight : 0
        let gaps = Spacing.windowSections * (showsTraces ? 2 : 1)
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
