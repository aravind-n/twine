import SwiftUI

/// Pane frames change without moving terminal views between branches of the view tree.
struct WorkflowPaneCanvas: View {
    @TerminalTheme private var palette
    @Environment(CoreClient.self) private var coreClient
    @Environment(WorkflowLayouts.self) private var layouts
    let folder: String
    let workflows: [CoreWorkflow]
    let sessionID: UInt64?
    @Binding var selection: WorkflowTabSelection
    let isVisible: Bool
    let reportFailure: (String) -> Void
    let closePane: (UInt64) -> Void

    private func root(_ id: UInt64) -> UInt64 {
        layouts.splitRoot(for: id, in: folder, workflows: workflows)
    }

    private func minimumPaneHeight(in split: TerminalSplit) -> CGFloat {
        let includesNotice = workflows.contains { split.ids.contains($0.id) && $0.showsRestoredNotice }
        return BentoLayout.minimumTerminalPaneHeight(for: coreClient.terminalFont, includesNotice: includesNotice)
    }

    var body: some View {
        GeometryReader { geometry in
            let bounds = CGRect(origin: .zero, size: geometry.size)
            let selectedRoot = selection.selectedID.map(root)
            ZStack(alignment: .topLeading) {
                ForEach(workflows) { workflow in
                    let split = layouts.terminalSplit(for: root(workflow.id), in: folder)
                    let paneHeight = minimumPaneHeight(in: split)
                    let tiled = split.ids.count > 1
                    let gutter = min(BentoLayout.gutter, min(bounds.width, bounds.height) / 2)
                    let content = tiled ? bounds.insetBy(dx: gutter, dy: gutter) : bounds
                    let frame = split.geometry(in: content, paneHeight: paneHeight).panes[workflow.id] ?? bounds
                    let shown = isVisible && workflow.sessionID == sessionID && root(workflow.id) == selectedRoot
                    let focused = shown && workflow.id == selection.selectedID
                    VStack(spacing: 0) {
                        if tiled {
                            HStack {
                                Label(workflow.name, systemImage: workflow.kind == .singleAgent ? "person" : "terminal")
                                    .lineLimit(1)
                                Spacer()
                                Button {
                                    closePane(workflow.id)
                                } label: {
                                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                                }
                                .buttonStyle(.plain)
                                .help("Close Pane (⌘W)")
                                .accessibilityLabel("Close \(workflow.name) pane")
                                .accessibilityIdentifier("closeTerminalPane-\(workflow.id)")
                            }
                            .tabTitleStyle(isSelected: focused, foreground: Color(nsColor: palette.text))
                            .padding(.horizontal, BentoLayout.headerPadding).frame(height: BentoLayout.headerHeight)
                            .contentShape(Rectangle())
                            .onTapGesture { selection.selectedID = workflow.id }
                        }
                        WorkflowTerminalSurface(
                            folder: folder, workflow: workflow, isSelected: focused, isVisible: shown, isTiled: tiled,
                            didFocus: { selection.selectedID = workflow.id }, reportFailure: reportFailure)
                    }
                    .frame(width: frame.width, height: frame.height)
                    .bentoPane(isTiled: tiled, isFocused: focused)
                    .position(x: frame.midX, y: frame.midY)
                    .opacity(shown ? 1 : 0).allowsHitTesting(shown).accessibilityHidden(!shown)
                }
                if let selectedRoot, isVisible {
                    let split = layouts.terminalSplit(for: selectedRoot, in: folder)
                    let gutter = min(BentoLayout.gutter, min(bounds.width, bounds.height) / 2)
                    let dividers = split.geometry(
                        in: bounds.insetBy(dx: gutter, dy: gutter), paneHeight: minimumPaneHeight(in: split)
                    ).dividers
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
            .background(
                selectedRoot.map { layouts.terminalSplit(for: $0, in: folder).ids.count > 1 } == true
                    ? Color.workflowTint : Color(nsColor: palette.background))
        }
    }
}

#Preview {
    @Previewable @State var selection = WorkflowTabSelection()
    WorkflowPaneCanvas(
        folder: "/", workflows: [], sessionID: nil, selection: $selection,
        isVisible: true, reportFailure: { _ in NSSound.beep() }, closePane: { _ in NSSound.beep() }
    )
    .environment(WorkflowLayouts(fileURL: AppPaths.previewDirectory.appending(path: "workflow-layouts.json")))
    .environment(CoreClient(transport: CoreWorker(dataDirectory: AppPaths.previewDirectory)))
}
