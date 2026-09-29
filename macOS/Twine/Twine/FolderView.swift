import Foundation
import SwiftUI

/// The window content while a folder is open.
struct FolderView: View {
    let path: String
    let closeFolder: () -> Void
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .detailOnly

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
                TerminalSurface(workingDirectory: URL(filePath: path, directoryHint: .isDirectory))
                TracesHeader()
            }
            .padding(Spacing.windowMargins)
            .background(.windowBackground)
        }
        .navigationSplitViewStyle(.balanced)
        .navigationTitle(URL(filePath: path).lastPathComponent)
        .navigationSubtitle((path as NSString).abbreviatingWithTildeInPath)
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
}
