import SwiftUI

extension FocusedValues {
    /// Whether the focused window shows the folder picker.
    @Entry var isChoosingFolder: Binding<Bool>?
}

/// File menu commands that open a folder and close it, returning the window to the start page.
///
/// They replace New Window: the core has one open folder, so a second window could only mirror it.
struct FolderCommands: Commands {
    let bridgeClient: BridgeClient
    @FocusedBinding(\.isChoosingFolder) private var isChoosingFolder

    var body: some Commands {
        let isRunning = bridgeClient.connectionState == .running
        CommandGroup(replacing: .newItem) {
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
