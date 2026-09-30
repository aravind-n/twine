import SwiftUI

struct WorkflowTabs: View {
    let workflows: [CoreWorkflow]
    let selectedID: UInt64?
    let select: (UInt64) -> Void
    let close: (UInt64) -> Void
    let cancelAgent: (UInt64) -> Void
    let create: () -> Void
    @State private var tabsWidth: CGFloat?

    var body: some View {
        HStack(alignment: .bottom, spacing: 12) {
            Text("WORKFLOWS")
                .sectionLabelStyle()
                .fixedSize()
                .padding(.bottom, 11)
            scrollingTabs
                .frame(maxWidth: tabsWidth)
                .layoutPriority(1)
            createButton
            Spacer(minLength: 0)
        }
        .frame(height: 42, alignment: .bottom)
    }

    private var tabs: some View {
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(workflows) { workflow in
                WorkflowTab(
                    workflow: workflow,
                    isSelected: workflow.id == selectedID,
                    select: { select(workflow.id) },
                    close: { close(workflow.id) },
                    cancelAgent: { cancelAgent(workflow.id) }
                )
                .id(workflow.id)
            }
        }
        .padding(.horizontal, 1)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }, action: { tabsWidth = $0 })
    }

    private var scrollingTabs: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) { tabs }
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
    }

    private var createButton: some View {
        Button("New Workflow", systemImage: "plus", action: create)
            .labelStyle(.iconOnly)
            .font(.system(size: 11, weight: .semibold))
            .buttonStyle(.glass)
            .buttonBorderShape(.roundedRectangle(radius: CornerRadius.glassIconButton))
            .controlSize(.small)
            .frame(width: 26, height: 26)
            .padding(.bottom, 5)
            .help("New Workflow (⌘T)")
            .accessibilityIdentifier("newWorkflow")
    }
}

private struct WorkflowTab: View {
    let workflow: CoreWorkflow
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void
    let cancelAgent: () -> Void
    @State private var isHovered = false
    @FocusState private var focusedControl: Control?

    private enum Control: Hashable { case select, close }

    private var showsClose: Bool { isHovered || focusedControl != nil }

    var body: some View {
        Button(action: select) {
            HStack(spacing: 6) {
                Image(systemName: workflow.tabSymbol)
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
                // The selected tab shares the fill of the panel's top edge: the subtab strip, or the terminal.
                tabShape.fill(workflow.showsAgentSubtabs ? Color.workflowTint : .terminalBackground)
                    .overlay {
                        tabShape.strokeBorder(.hairline, lineWidth: Surface.hairlineWidth)
                            .mask { Rectangle().padding(.bottom, Surface.hairlineWidth) }
                    }
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
        .contextMenu {
            if workflow.isRunningAgent {
                Button("Cancel Agent", systemImage: "stop.circle", action: cancelAgent)
            }
            Button("Close Workflow", systemImage: "xmark", action: close)
        }
        .onHover { isHovered = $0 }
        .animation(Motion.tabCloseButton, value: showsClose)
        .help(workflow.name)
    }

    private var tabShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: CornerRadius.selectedTab, topTrailingRadius: CornerRadius.selectedTab)
    }
}
