import SwiftUI

struct WorkflowTabs: View {
    let workflows: [BridgeWorkflow]
    let selectedID: UInt64?
    let select: (UInt64) -> Void
    let close: (UInt64) -> Void
    let create: () -> Void
    @Binding var newButtonFrame: CGRect

    var body: some View {
        HStack(alignment: .bottom, spacing: 12) {
            Text("WORKFLOWS")
                .sectionLabelStyle()
                .fixedSize()
                .padding(.bottom, 11)
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(alignment: .bottom, spacing: 6) {
                        ForEach(workflows) { workflow in
                            WorkflowTab(
                                workflow: workflow,
                                isSelected: workflow.id == selectedID,
                                select: { select(workflow.id) },
                                close: { close(workflow.id) }
                            )
                            .id(workflow.id)
                        }
                    }
                    .padding(.horizontal, 1)
                }
                .scrollIndicators(.hidden)
                .onChange(of: selectedID) { _, selectedID in
                    if let selectedID {
                        withAnimation(Motion.scrollToSelectedTab) { proxy.scrollTo(selectedID) }
                    }
                }
                .onChange(of: workflows.map(\.id)) {
                    if let selectedID {
                        withAnimation(Motion.scrollToSelectedTab) { proxy.scrollTo(selectedID) }
                    }
                }
                .onGeometryChange(
                    for: CGFloat.self, of: { $0.size.width },
                    action: { _ in
                        if let selectedID { proxy.scrollTo(selectedID) }
                    })
            }
            Button("New Workflow", systemImage: "plus", action: create)
                .labelStyle(.iconOnly)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 26, height: 26)
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: CornerRadius.glassIconButton))
                .padding(.bottom, 5)
                .help("New Workflow (⌘T)")
                .accessibilityIdentifier("newWorkflow")
                .onGeometryChange(
                    for: CGRect.self, of: { $0.frame(in: .named("workflowWorkspace")) },
                    action: { newButtonFrame = $0 }
                )
        }
        .frame(height: 42, alignment: .bottom)
        .background(alignment: .bottom) { Rectangle().fill(.hairline).frame(height: Surface.hairlineWidth) }
    }
}

private struct WorkflowTab: View {
    let workflow: BridgeWorkflow
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
                Image(systemName: workflow.kind == .draft ? "square.dashed" : "terminal")
                    .frame(width: 15)
                    .opacity(showsClose ? 0 : 1)
                Text(workflow.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 180)
            }
            .tabTitleStyle(isSelected: isSelected)
            .padding(.horizontal, 12)
            .frame(height: isSelected ? 35 : 29)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .focused($focusedControl, equals: .select)
        .accessibilityLabel(workflow.name)
        .accessibilityValue(isSelected ? "Selected" : "")
        .accessibilityIdentifier("workflowTab-\(workflow.id)")
        .background {
            if isSelected {
                tabShape.fill(.terminalBackground)
                    .overlay { tabShape.stroke(.hairline, lineWidth: Surface.hairlineWidth) }
                    // Cover the bottom stroke and row baseline with the terminal's fill.
                    .overlay(alignment: .bottom) { Rectangle().fill(.terminalBackground).frame(height: 1) }
            }
        }
        .overlay(alignment: .leading) {
            Button("Close \(workflow.name)", systemImage: "xmark", action: close)
                .labelStyle(.iconOnly)
                .font(.system(size: 9, weight: .semibold))
                .frame(width: 20, height: 23)
                .buttonStyle(.plain)
                .focused($focusedControl, equals: .close)
                .padding(.leading, 9)
                .opacity(showsClose ? 1 : 0)
                .allowsHitTesting(showsClose)
                .accessibilityHidden(!showsClose)
                .accessibilityIdentifier("closeWorkflow-\(workflow.id)")
        }
        .onHover { isHovered = $0 }
        .animation(Motion.tabCloseButton, value: showsClose)
        .help(workflow.name)
    }

    private var tabShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: CornerRadius.selectedTab, topTrailingRadius: CornerRadius.selectedTab)
    }
}
