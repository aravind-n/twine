import SwiftUI

/// Commands for the selected workflow live in the native toolbar, above retained terminal views.
struct WorkspaceActions: View {
    @Environment(WorkflowLayouts.self) private var layouts
    let folder: String
    let workflow: CoreWorkflow
    let canSplit: Bool
    let compact: Bool
    let split: (TerminalSplit.Direction) -> Void
    let cancelAgent: () -> Void
    let reportFailure: (String) -> Void

    var body: some View {
        let layout = layouts.layout(for: workflow.id, in: folder)
        let focused = layout.focusedAgent(in: workflow.agents)
        if let run = workflow.run {
            WorkflowRunControls(
                workflowID: workflow.id, run: run, selectedAgentID: focused?.id,
                selectedRole: focused?.role, compact: compact, reportFailure: reportFailure
            ) { layoutPicker }
            .id(workflow.id)
        } else {
            HStack(spacing: 6) {
                Menu {
                    if compact {
                        layoutPicker
                        Divider()
                    }
                    Button("Split Right", systemImage: "rectangle.split.2x1") { split(.right) }
                        .disabled(!canSplit).accessibilityIdentifier("splitTerminalRight")
                    Button("Split Down", systemImage: "rectangle.split.1x2") { split(.down) }
                        .disabled(!canSplit).accessibilityIdentifier("splitTerminalDown")
                } label: {
                    Label("Workflow", systemImage: "ellipsis.circle")
                }
                .labelStyle(compact ? WorkspaceToolbarLabelStyle.icon : WorkspaceToolbarLabelStyle.title)
                .menuIndicator(compact ? .hidden : .visible)
                .frame(width: compact ? 26 : nil)
                .disabled(!canSplit && !workflow.showsAgentSubtabs)
                .accessibilityIdentifier("workflowActionsMenu")
                if !compact { layoutPicker }
                if workflow.isRunningAgent {
                    Button("Cancel Agent", systemImage: "stop.fill", action: cancelAgent)
                        .labelStyle(compact ? WorkspaceToolbarLabelStyle.icon : WorkspaceToolbarLabelStyle.titleAndIcon)
                        .frame(width: compact ? 26 : nil)
                        .accessibilityIdentifier("cancelAgent")
                }
            }
        }
    }

    @ViewBuilder
    private var layoutPicker: some View {
        if workflow.showsAgentSubtabs {
            if compact {
                picker.pickerStyle(.inline)
            } else {
                picker.pickerStyle(.segmented).labelStyle(.iconOnly).labelsHidden().controlSize(.small)
                    .fixedSize()
            }
        }
    }

    private var picker: some View {
        Picker(
            "Layout",
            selection: Binding(
                get: { layouts.layout(for: workflow.id, in: folder).mode },
                set: { mode in
                    var layout = layouts.layout(for: workflow.id, in: folder)
                    layout.mode = mode
                    layouts.setLayout(layout, for: workflow.id, in: folder)
                })
        ) {
            Label("Tabs", systemImage: "rectangle.topthird.inset.filled").tag(WorkflowLayout.Mode.tabs)
            Label("Bento", systemImage: "square.grid.2x2").tag(WorkflowLayout.Mode.bento)
        }
        .help("Show one agent at a time, or up to four side by side")
        .accessibilityIdentifier("agentLayout")
    }
}

/// An explicit native label policy lets narrow titlebars keep Cancel visible.
struct WorkspaceToolbarLabelStyle: LabelStyle {
    enum Content { case icon, title, titleAndIcon }
    let content: Content
    static let icon = Self(content: .icon)
    static let title = Self(content: .title)
    static let titleAndIcon = Self(content: .titleAndIcon)

    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        switch content {
        case .icon: configuration.icon
        case .title: configuration.title
        case .titleAndIcon:
            HStack(spacing: 4) {
                configuration.icon
                configuration.title
            }
        }
    }
}
