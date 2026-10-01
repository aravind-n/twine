import Foundation
import OSLog
import SwiftUI

private let gitLogger = Logger(subsystem: "com.twineproject.Twine", category: "git")

/// The window content while a folder is open.
struct FolderView: View {
    @Environment(CoreClient.self) private var coreClient
    @Environment(WorkflowLayouts.self) private var layouts
    @Environment(FileTabsModel.self) private var tabs
    let path: String
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .all
    @State private var selection = WorkflowTabSelection()
    @State private var files = FileBrowserModel()
    @State private var traceNavigation = TraceTerminalNavigation()

    var body: some View {
        NavigationSplitView(columnVisibility: $sidebarVisibility) {
            FolderSidebar(path: path, files: files)
                .frame(
                    minWidth: SidebarLayout.minimumWidth,
                    idealWidth: SidebarLayout.idealWidth,
                    maxWidth: SidebarLayout.maximumWidth
                )
                .navigationSplitViewColumnWidth(
                    min: SidebarLayout.minimumWidth,
                    ideal: SidebarLayout.idealWidth,
                    max: SidebarLayout.maximumWidth
                )
                .toolbar(removing: .sidebarToggle)
        } detail: {
            VStack(spacing: Spacing.windowSections) {
                WorkflowWorkspace(folder: path, selection: $selection, files: files)
                if tabs.selected == nil { TracesPanel(workflows: traceWorkflows) }
                StatusFooter(
                    branch: coreClient.snapshot?.folders.currentBranch,
                    workflow: selectedWorkflow
                )
            }
            .padding(Spacing.windowMargins)
            .background(.windowBackground)
        }
        .background {
            FolderWindowLifetime(coreClient: coreClient, folder: path, tabs: tabs).frame(width: 0, height: 0)
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
        .navigationTitle(URL(filePath: path).lastPathComponent)
        .navigationSubtitle((path as NSString).abbreviatingWithTildeInPath)
        .task(id: path) { await refreshGitBranch() }
        .task(id: files.request(folder: path, file: tabs.selected?.path)) {
            let editor = tabs.selected
            await files.watch(files.request(folder: path, file: editor?.path), client: coreClient, editor: editor)
        }
        .focusedSceneValue(\.openFilePath, tabs.selected?.path)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(sidebarIsVisible ? "Hide Sidebar" : "Show Sidebar", systemImage: "sidebar.left") {
                    sidebarVisibility = sidebarIsVisible ? .detailOnly : .all
                }
                .keyboardShortcut("s", modifiers: [.command, .control])
                .help(sidebarIsVisible ? "Hide Sidebar" : "Show Sidebar")
                .accessibilityIdentifier("sidebarToggle")
            }
        }
    }

    private var sidebarIsVisible: Bool { sidebarVisibility != .detailOnly }

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
