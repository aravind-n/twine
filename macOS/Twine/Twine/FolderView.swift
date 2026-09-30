import Foundation
import OSLog
import SwiftUI

private let gitLogger = Logger(subsystem: "com.twineproject.Twine", category: "git")

/// The window content while a folder is open.
struct FolderView: View {
    @Environment(BridgeClient.self) private var bridgeClient
    let path: String
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .detailOnly
    @State private var selection = WorkflowTabSelection()
    @State private var files = FileBrowserModel()

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
                ZStack {
                    WorkflowWorkspace(folder: path, selection: $selection, isVisible: files.selectedPath == nil)
                        .opacity(files.selectedPath == nil ? 1 : 0)
                        .allowsHitTesting(files.selectedPath == nil)
                        .accessibilityHidden(true, isEnabled: files.selectedPath != nil)
                    if let selectedPath = files.selectedPath {
                        FileViewer(
                            path: selectedPath, folder: path, preview: files.snapshot?.file,
                            failure: files.failure, close: { files.selectedPath = nil }
                        )
                        .id(selectedPath)
                    }
                }
                if files.selectedPath == nil { TracesHeader() }
                StatusFooter(
                    branch: bridgeClient.snapshot?.folders.currentBranch,
                    workflow: selectedWorkflow
                )
            }
            .padding(Spacing.windowMargins)
            .background(.windowBackground)
        }
        .background { FolderWindowLifetime(bridgeClient: bridgeClient, folder: path).frame(width: 0, height: 0) }
        .navigationSplitViewStyle(.balanced)
        .navigationTitle(URL(filePath: path).lastPathComponent)
        .navigationSubtitle((path as NSString).abbreviatingWithTildeInPath)
        .task(id: path) { await refreshGitBranch() }
        .task(id: files.request(folder: path)) { await files.watch(files.request(folder: path), client: bridgeClient) }
        .onChange(of: selection.selectedID) { files.selectedPath = nil }
        .focusedSceneValue(\.closeFile, files.selectedPath.map { _ in { files.selectedPath = nil } })
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

    private var selectedWorkflow: BridgeWorkflow? {
        guard let state = bridgeClient.snapshot?.workflows, state.session?.folder == path else { return nil }
        return state.workflows.first { $0.id == selection.selectedID && $0.sessionID == state.session?.sessionID }
    }

    private func refreshGitBranch() async {
        do {
            while !Task.isCancelled {
                guard bridgeClient.connectionState == .running, bridgeClient.snapshot?.folders.openFolder == path
                else { return }
                try await bridgeClient.refreshGitBranch(folder: path)
                try await Task.sleep(for: .seconds(5))
            }
        } catch is CancellationError {
            return
        } catch {
            gitLogger.error("Git branch refresh failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
