import AppKit
import SwiftUI

extension FocusedValues {
    /// Whether the focused window shows the folder picker.
    @Entry var isChoosingFolder: Binding<Bool>?
    @Entry var workflowActions: WorkflowActions?
    /// The path of the file open in the focused window.
    @Entry var openFilePath: String?
}

struct WorkflowActions {
    let create: () -> Void
    /// Opens an agents workflow with one agent per role, in order.
    let createAgents: ([String]) -> Void
    let close: (() -> Void)?
    let cancelAgent: (() -> Void)?
    /// The selected workflow's layout mode, when it has agents to arrange.
    let layoutMode: Binding<WorkflowLayout.Mode>?
    /// Moves the keyboard forward or back by a number of agents: subtabs in tab mode, panes in Bento mode.
    let moveFocus: ((Int) -> Void)?
    var splitTerminal: ((TerminalSplit.Direction) -> Void)?
}

/// File menu commands that open a folder and close it, returning the window to the start page.
///
/// They replace New Window: the core has one open folder, so a second window could only mirror it.
struct FolderCommands: Commands {
    #if DEBUG
        private static let testRoles = ["Implementer", "Reviewer", "Coordinator", "Worker"]
    #endif

    let coreClient: CoreClient
    let editor: FileEditorModel
    @FocusedBinding(\.isChoosingFolder) private var isChoosingFolder
    @FocusedValue(\.workflowActions) private var workflowActions
    @FocusedValue(\.openFilePath) private var openFilePath

    var body: some Commands {
        let isRunning = coreClient.runState == .running
        CommandGroup(replacing: .newItem) {
            Button("New Workflow") { workflowActions?.create() }
                .keyboardShortcut("t")
                .disabled(workflowActions == nil || !isRunning)
            Button("Cancel Agent") { workflowActions?.cancelAgent?() }
                .keyboardShortcut(".")
                .disabled(workflowActions?.cancelAgent == nil || !isRunning)
            #if DEBUG
                // Until harnesses can launch, agents run shells, and only debug builds open them.
                Menu("New Test Workflow") {
                    ForEach(1...Self.testRoles.count, id: \.self) { count in
                        Button(count == 1 ? "1 Agent" : "\(count) Agents") {
                            workflowActions?.createAgents(Array(Self.testRoles.prefix(count)))
                        }
                    }
                }
                .disabled(workflowActions == nil || !isRunning)
            #endif
            Divider()
            Button("Open Folder…") {
                isChoosingFolder = true
            }
            .keyboardShortcut("o")
            .disabled(isChoosingFolder == nil || !isRunning)
            Button("Close Folder") {
                guard editor.select(nil) else { return }
                Task { await coreClient.perform(.closeFolder) }
            }
            .disabled(!isRunning || coreClient.snapshot?.folders.openFolder == nil)
        }
        CommandGroup(after: .sidebar) {
            Button("Split Right") { workflowActions?.splitTerminal?(.right) }
                .keyboardShortcut("d")
                .disabled(workflowActions?.splitTerminal == nil)
            Button("Split Down") { workflowActions?.splitTerminal?(.down) }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(workflowActions?.splitTerminal == nil)
            Divider()
            Toggle(
                "Bento Panes",
                isOn: Binding(
                    get: { workflowActions?.layoutMode?.wrappedValue == .bento },
                    set: { workflowActions?.layoutMode?.wrappedValue = $0 ? .bento : .tabs })
            )
            .disabled(workflowActions?.layoutMode == nil)
            Button("Next Agent") { workflowActions?.moveFocus?(1) }
                .keyboardShortcut("]")
                .disabled(workflowActions?.moveFocus == nil)
            Button("Previous Agent") { workflowActions?.moveFocus?(-1) }
                .keyboardShortcut("[")
                .disabled(workflowActions?.moveFocus == nil)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { editor.requestSave() }
                .keyboardShortcut("s")
                .disabled(!editor.canSave || !isRunning)
            Button(closeTitle) {
                if openFilePath != nil {
                    editor.select(nil)
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
        if openFilePath != nil { return "Close File" }
        return workflowActions?.close == nil ? "Close Window" : "Close Workflow"
    }
}
