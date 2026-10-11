import SwiftUI

struct WorkflowTabs: View {
    @Environment(FileTabsModel.self) private var fileTabs
    let workflows: [CoreWorkflow]
    let selectedID: UInt64?
    let availableWidth: CGFloat
    let select: (UInt64) -> Void
    let close: (UInt64) -> Void
    let cancelAgent: (UInt64) -> Void
    let create: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                tabs
                createButton
            }
            .fixedSize()
            HStack(spacing: 6) {
                if availableWidth >= 170 {
                    selectedTab.frame(maxWidth: max(60, availableWidth - 76))
                }
                overflowMenu
                createButton
            }
        }
        .frame(width: availableWidth, alignment: .leading)
        .frame(height: 30)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspaceTabs")
    }

    @ViewBuilder
    private var selectedTab: some View {
        if let editor = fileTabs.selected {
            fileTab(editor)
        } else if let workflow = workflows.first(where: { $0.id == selectedID }) {
            workflowTab(workflow)
        }
    }

    private var overflowMenu: some View {
        Menu {
            ForEach(workflows) { workflow in
                Button {
                    select(workflow.id)
                } label: {
                    Label(workflow.name, systemImage: workflow.id == selectedID ? "checkmark" : workflow.tabSymbol)
                }
                .accessibilityIdentifier("overflowWorkflow-\(workflow.id)")
            }
            if !fileTabs.editors.isEmpty { Divider() }
            ForEach(fileTabs.editors) { editor in
                Button {
                    fileTabs.select(editor.id)
                } label: {
                    Label(
                        URL(filePath: editor.path).lastPathComponent + (editor.isDirty ? " •" : ""),
                        systemImage: editor.id == fileTabs.selectedID ? "checkmark" : "doc.text")
                }
                .help(editor.path)
                .accessibilityIdentifier("overflowFile-\(editor.path)")
            }
        } label: {
            Label("Open tabs", systemImage: "rectangle.stack")
        }
        .labelStyle(.iconOnly)
        .menuIndicator(.hidden)
        .controlSize(.small)
        .frame(width: 26)
        .help("Open workflow and file tabs")
        .accessibilityIdentifier("workspaceTabOverflow")
    }

    private var tabs: some View {
        HStack(spacing: 6) {
            ForEach(workflows) { workflow in workflowTab(workflow) }
            ForEach(fileTabs.editors) { editor in fileTab(editor) }
        }
    }

    private func workflowTab(_ workflow: CoreWorkflow) -> some View {
        WorkspaceTab(
            name: workflow.name, symbol: workflow.tabSymbol,
            tabID: "workflowTab-\(workflow.id)", closeID: "closeWorkflow-\(workflow.id)",
            helpText: workflow.name, fill: .workflowTint,
            isSelected: workflow.id == selectedID,
            select: { select(workflow.id) }, close: { close(workflow.id) }
        )
        .contextMenu {
            if workflow.isRunningAgent {
                Button("Cancel Agent", systemImage: "stop.circle") { cancelAgent(workflow.id) }
            }
            Button("Close Workflow", systemImage: "xmark") { close(workflow.id) }
        }
    }

    private func fileTab(_ editor: FileEditorModel) -> some View {
        WorkspaceTab(
            name: URL(filePath: editor.path).lastPathComponent, symbol: "doc.text",
            tabID: "fileTab-\(editor.path)", closeID: "closeFile-\(editor.path)", helpText: editor.path,
            fill: .workflowTint, isEdited: editor.isDirty,
            isSelected: editor.id == fileTabs.selectedID,
            select: { fileTabs.select(editor.id) }, close: { fileTabs.close(editor.id) }
        )
        .contextMenu {
            Button("Close File", systemImage: "xmark") { fileTabs.close(editor.id) }
        }
    }

    private var createButton: some View {
        Button("New Workflow", systemImage: "plus", action: create)
            .labelStyle(.iconOnly)
            .font(.system(size: 11, weight: .semibold))
            .buttonStyle(.glass)
            .buttonBorderShape(.roundedRectangle(radius: CornerRadius.glassIconButton))
            .controlSize(.small)
            .frame(width: 26, height: 26)
            .help("New Workflow (⌘T)")
            .accessibilityIdentifier("newWorkflow")
    }
}

private struct WorkspaceTab: View {
    let name: String
    let symbol: String
    let tabID: String
    let closeID: String
    let helpText: String
    let fill: Color
    var isEdited = false
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var isHovered = false
    @FocusState private var focusedControl: Control?

    private enum Control: Hashable { case select, close }

    private var showsClose: Bool { isHovered || focusedControl != nil }

    var body: some View {
        Button(action: select) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .frame(width: 15)
                    .opacity(showsClose ? 0 : 1)
                Text(name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 180)
                if isEdited {
                    Circle().fill(.secondary).frame(width: 5, height: 5).accessibilityHidden(true)
                }
            }
            .tabTitleStyle(isSelected: isSelected)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .focused($focusedControl, equals: .select)
        .accessibilityLabel(name)
        .accessibilityValue(
            [isSelected ? "Selected" : nil, isEdited ? "Edited" : nil].compactMap { $0 }.joined(separator: ", ")
        )
        .accessibilityIdentifier(tabID)
        .background {
            if isSelected {
                tabShape.fill(fill)
                    .overlay {
                        tabShape.strokeBorder(.hairline, lineWidth: Surface.hairlineWidth)
                    }
            }
        }
        .overlay(alignment: .leading) {
            Button("Close \(name)", systemImage: "xmark", action: close)
                .labelStyle(.iconOnly)
                .foregroundStyle(.primary)
                .font(.system(size: 9, weight: .semibold))
                .frame(width: 20, height: 23)
                .buttonStyle(.plain)
                .focused($focusedControl, equals: .close)
                .padding(.leading, 9)
                .opacity(showsClose ? 1 : 0)
                .allowsHitTesting(showsClose)
                .accessibilityHidden(!showsClose)
                .accessibilityIdentifier(closeID)
        }
        .onHover { isHovered = $0 }
        .animation(Motion.tabCloseButton, value: showsClose)
        .help(helpText)
    }

    private var tabShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: CornerRadius.selectedTab)
    }
}
