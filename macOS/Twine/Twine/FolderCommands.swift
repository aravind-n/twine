import SwiftUI

extension FocusedValues {
    /// Whether the focused window shows the folder picker.
    @Entry var isChoosingFolder: Binding<Bool>?
    @Entry var workflowActions: WorkflowActions?
}

struct WorkflowActions {
    let create: () -> Void
    let close: (() -> Void)?
}

/// File menu commands that open a folder and close it, returning the window to the start page.
///
/// They replace New Window: the core has one open folder, so a second window could only mirror it.
struct FolderCommands: Commands {
    let bridgeClient: BridgeClient
    @FocusedBinding(\.isChoosingFolder) private var isChoosingFolder
    @FocusedValue(\.workflowActions) private var workflowActions

    var body: some Commands {
        let isRunning = bridgeClient.connectionState == .running
        CommandGroup(replacing: .newItem) {
            Button("New Workflow") { workflowActions?.create() }
                .keyboardShortcut("t")
                .disabled(workflowActions == nil || !isRunning)
            Button("Close Workflow") { workflowActions?.close?() }
                .keyboardShortcut("w")
                .disabled(workflowActions?.close == nil || !isRunning)
            Divider()
            Button("Open Folder…") {
                isChoosingFolder = true
            }
            .keyboardShortcut("o")
            .disabled(isChoosingFolder == nil || !isRunning)
            Button("Close Folder") {
                Task { await bridgeClient.perform(.closeFolder) }
            }
            .disabled(!isRunning || bridgeClient.snapshot?.folders.openFolder == nil)
        }
    }
}
