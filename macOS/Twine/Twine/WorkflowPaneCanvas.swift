import SwiftUI

/// Pane frames change without moving terminal views between branches of the view tree.
struct WorkflowPaneCanvas: View {
    @Environment(WorkflowLayouts.self) private var layouts
    let folder: String
    let workflows: [CoreWorkflow]
    let sessionID: UInt64?
    @Binding var selection: WorkflowTabSelection
    let isVisible: Bool
    let reportFailure: (String) -> Void

    private func root(_ id: UInt64) -> UInt64 {
        layouts.splitRoot(for: id, in: folder, workflows: workflows)
    }

    var body: some View {
        GeometryReader { geometry in
            let bounds = CGRect(origin: .zero, size: geometry.size)
            let selectedRoot = selection.selectedID.map(root)
            ZStack(alignment: .topLeading) {
                ForEach(workflows) { workflow in
                    let split = layouts.terminalSplit(for: root(workflow.id), in: folder)
                    let frame = split.geometry(in: bounds).panes[workflow.id] ?? bounds
                    let shown = isVisible && workflow.sessionID == sessionID && root(workflow.id) == selectedRoot
                    let focused = shown && workflow.id == selection.selectedID
                    VStack(spacing: 0) {
                        if split.ids.count > 1 {
                            HStack {
                                Text(workflow.name).lineLimit(1)
                                Spacer()
                            }
                            .font(.caption2).foregroundStyle(focused ? .primary : .secondary)
                            .padding(.horizontal, 12).frame(height: 22)
                            .contentShape(Rectangle())
                            .onTapGesture { selection.selectedID = workflow.id }
                        }
                        WorkflowTerminalSurface(
                            folder: folder, workflow: workflow, isSelected: focused, isVisible: shown,
                            didFocus: { selection.selectedID = workflow.id }, reportFailure: reportFailure)
                    }
                    .frame(width: frame.width, height: frame.height)
                    .overlay {
                        if split.ids.count > 1 {
                            Rectangle().strokeBorder(focused ? Color.primary.opacity(0.16) : .clear, lineWidth: 1)
                                .allowsHitTesting(false)
                        }
                    }
                    .position(x: frame.midX, y: frame.midY)
                    .opacity(shown ? 1 : 0).allowsHitTesting(shown).accessibilityHidden(!shown)
                }
                if let selectedRoot, isVisible {
                    let dividers = layouts.terminalSplit(for: selectedRoot, in: folder).geometry(in: bounds).dividers
                    ForEach(dividers) { divider in
                        TerminalSplitDivider(divider: divider) { fraction in
                            var layout = layouts.layout(for: selectedRoot, in: folder)
                            layout.terminalSplit = layout.terminalSplit?.resizing(divider.id, fraction: fraction)
                            layouts.setLayout(layout, for: selectedRoot, in: folder)
                        }
                        .frame(width: divider.frame.width, height: divider.frame.height)
                        .position(x: divider.frame.midX, y: divider.frame.midY)
                    }
                }
            }
        }
    }
}

#Preview {
    @Previewable @State var selection = WorkflowTabSelection()
    WorkflowPaneCanvas(
        folder: "/", workflows: [], sessionID: nil, selection: $selection,
        isVisible: true, reportFailure: { _ in NSSound.beep() }
    )
    .environment(WorkflowLayouts(fileURL: URL(filePath: "/tmp/twine-preview-layouts.json")))
}
