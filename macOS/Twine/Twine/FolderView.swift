import Foundation
import OSLog
import SwiftUI

private let gitLogger = Logger(subsystem: "com.twineproject.Twine", category: "git")

/// The window content while a folder is open.
struct FolderView: View {
    @Environment(BridgeClient.self) private var bridgeClient
    let path: String
    let closeFolder: () -> Void
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .detailOnly
    @State private var selection = WorkflowTabSelection()

    var body: some View {
        NavigationSplitView(columnVisibility: $sidebarVisibility) {
            FolderSidebar(path: path)
                .navigationSplitViewColumnWidth(
                    min: SidebarLayout.minimumWidth,
                    ideal: SidebarLayout.idealWidth,
                    max: SidebarLayout.maximumWidth
                )
                .toolbar(removing: .sidebarToggle)
        } detail: {
            VStack(spacing: Spacing.windowSections) {
                WorkflowWorkspace(folder: path, selection: $selection)
                TracesHeader()
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
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(sidebarIsVisible ? "Hide Sidebar" : "Show Sidebar", systemImage: "sidebar.left") {
                    sidebarVisibility = sidebarIsVisible ? .detailOnly : .all
                }
                .keyboardShortcut("s", modifiers: [.command, .control])
                .help(sidebarIsVisible ? "Hide Sidebar" : "Show Sidebar")
                .accessibilityIdentifier("sidebarToggle")
            }
            ToolbarItem(placement: .navigation) {
                Button("Start Page", systemImage: "house", action: closeFolder)
                    .help("Close the folder and return to the start page")
            }
        }
    }

    private var sidebarIsVisible: Bool { sidebarVisibility != .detailOnly }

    private var selectedWorkflow: BridgeWorkflow? {
        guard let state = bridgeClient.snapshot?.workflows, state.session?.folder == path else { return nil }
        return state.workflows.first { $0.id == selection.selectedID }
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
