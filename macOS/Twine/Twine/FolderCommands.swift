import AppKit
import SwiftUI

extension FocusedValues {
    /// Whether the focused window shows the folder picker.
    @Entry var isChoosingFolder: Binding<Bool>?
    @Entry var workflowActions: WorkflowActions?
    @Entry var closeFile: (() -> Void)?
}

struct WorkflowActions {
    let create: () -> Void
    let close: (() -> Void)?
    let cancelAgent: (() -> Void)?
}

/// File menu commands that open a folder and close it, returning the window to the start page.
///
/// They replace New Window: the core has one open folder, so a second window could only mirror it.
struct FolderCommands: Commands {
    let bridgeClient: BridgeClient
    let editor: FileEditorModel
    @FocusedBinding(\.isChoosingFolder) private var isChoosingFolder
    @FocusedValue(\.workflowActions) private var workflowActions
    @FocusedValue(\.closeFile) private var closeFile

    var body: some Commands {
        let isRunning = bridgeClient.connectionState == .running
        CommandGroup(replacing: .newItem) {
            Button("New Workflow") { workflowActions?.create() }
                .keyboardShortcut("t")
                .disabled(workflowActions == nil || !isRunning)
            Button("Cancel Agent") { workflowActions?.cancelAgent?() }
                .keyboardShortcut(".")
                .disabled(workflowActions?.cancelAgent == nil || !isRunning)
            Divider()
            Button("Open Folder…") {
                isChoosingFolder = true
            }
            .keyboardShortcut("o")
            .disabled(isChoosingFolder == nil || !isRunning)
            Button("Close Folder") {
                guard editor.select(nil) else { return }
                Task { await bridgeClient.perform(.closeFolder) }
            }
            .disabled(!isRunning || bridgeClient.snapshot?.folders.openFolder == nil)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { editor.requestSave() }
                .keyboardShortcut("s")
                .disabled(!editor.canSave || !isRunning)
            Button(closeTitle) {
                if let closeFile {
                    closeFile()
                } else if let close = workflowActions?.close {
                    close()
                } else {
                    NSApp.keyWindow?.performClose(nil)
                }
            }
            .keyboardShortcut("w")
            .disabled(isChoosingFolder == nil)
        }
    }

    private var closeTitle: String {
        if closeFile != nil { return "Close File" }
        return workflowActions?.close == nil ? "Close Window" : "Close Workflow"
    }
}
