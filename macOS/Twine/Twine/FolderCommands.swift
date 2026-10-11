import AppKit
import SwiftUI

extension FocusedValues {
    @Entry var folderWindow: FolderWindowSession?
    /// Whether the focused window shows the folder picker.
    @Entry var isChoosingFolder: Binding<Bool>?
    @Entry var workflowActions: WorkflowActions?
    @Entry var newWorkflowType: Binding<Bool>?
    /// The path of the file open in the focused window.
    @Entry var openFilePath: String?
    @Entry var saveAction: SaveAction?
}

struct SaveAction {
    let isEnabled: Bool
    let perform: () -> Void
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
struct FolderCommands: Commands {
    let windows: FolderWindows
    var settings: SettingsPopup?
    #if DEBUG
        private static let testRoles = ["Implementer", "Reviewer", "Coordinator", "Worker"]
    #endif

    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.folderWindow) private var session
    @FocusedBinding(\.isChoosingFolder) private var isChoosingFolder
    @FocusedBinding(\.newWorkflowType) private var newWorkflowType
    @FocusedValue(\.workflowActions) private var workflowActions
    @FocusedValue(\.openFilePath) private var openFilePath
    @FocusedValue(\.saveAction) private var saveAction

    var body: some Commands {
        let showsSettings = settings?.isPresented == true && settings?.presentedWindowID == session?.id
        let isRunning = !showsSettings && session?.coreClient.runState == .running
        let editor = showsSettings ? settings?.editor : session?.tabs.selected
        let formSave = showsSettings ? nil : saveAction
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                if let session { settings?.show(in: session) }
            }
            .keyboardShortcut(",")
            .disabled(session == nil)
        }
        CommandGroup(replacing: .newItem) {
            Button("New Window") { openWindow(id: "folder", value: UUID()) }
                .keyboardShortcut("n")
            Divider()
            Button("New Workflow") { workflowActions?.create() }
                .keyboardShortcut("t")
                .disabled(workflowActions == nil || !isRunning)
            Button("Create Workflow Type…") { newWorkflowType = true }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(newWorkflowType == nil || !isRunning)
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
                windows.chooseFolder(from: session) { openWindow(id: "folder", value: $0) }
            }
            .keyboardShortcut("o")
            .disabled(session != nil && !isRunning)
            Button("Close Folder") {
                guard let session, session.tabs.closeAll() else { return }
                Task { await session.coreClient.perform(.closeFolder) }
            }
            .disabled(!isRunning || session?.coreClient.snapshot?.folders.openFolder == nil)
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
            Button("Save") {
                if let formSave { formSave.perform() } else { editor?.requestSave() }
            }
            .keyboardShortcut("s")
            .disabled(formSave.map { !$0.isEnabled } ?? (editor?.canSave != true || (!showsSettings && !isRunning)))
            Button(closeTitle) {
                if showsSettings {
                    settings?.close()
                } else if openFilePath != nil {
                    if let tabs = session?.tabs, let selected = tabs.selected { tabs.close(selected.id) }
                } else if let close = workflowActions?.close {
                    close()
                } else {
                    NSApp.keyWindow?.performClose(nil)
                }
            }
            .keyboardShortcut("w")
            .disabled(isChoosingFolder == nil && !showsSettings)
        }
    }

    private var closeTitle: String {
        if settings?.isPresented == true && settings?.presentedWindowID == session?.id { return "Close Settings" }
        if openFilePath != nil { return "Close File" }
        return workflowActions?.close == nil ? "Close Window" : "Close Workflow"
    }
}
