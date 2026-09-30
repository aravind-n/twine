import SwiftUI

/// The strip at the top of a multi-agent workflow's terminal panel, with a subtab for each agent and
/// a picker between tab mode and Bento mode.
struct AgentSubtabs: View {
    let agents: [BridgeAgent]
    /// The agent with the keyboard: the one tab mode shows, or the focused Bento pane's.
    let selectedID: UInt64?
    @Binding var mode: WorkflowLayout.Mode
    /// A hidden workflow leaves out the picker: accessibility would still list its AppKit control.
    let showsLayoutPicker: Bool
    let select: (UInt64) -> Void

    var body: some View {
        HStack(spacing: AgentSubtabLayout.labelSpacing) {
            Text("TERMINAL")
                .sectionLabelStyle()
                .fixedSize()
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: AgentSubtabLayout.spacing) {
                        ForEach(agents) { agent in
                            AgentSubtab(agent: agent, isSelected: agent.id == selectedID) { select(agent.id) }
                                .id(agent.id)
                        }
                    }
                    // Fill the strip's height, so the scroll view doesn't clip the glass capsule's edge.
                    .frame(maxHeight: .infinity)
                }
                // Hidden even when the system always shows scroll bars: one would cover the subtabs.
                .scrollIndicators(.never)
                .onChange(of: selectedID) { _, selectedID in
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
            if showsLayoutPicker { layoutPicker }
        }
        .padding(.horizontal, AgentSubtabLayout.horizontalPadding)
        .frame(height: AgentSubtabLayout.height)
        .background(.workflowTint)
    }

    private var layoutPicker: some View {
        Picker("Layout", selection: $mode) {
            Label("Tabs", systemImage: "rectangle.topthird.inset.filled").tag(WorkflowLayout.Mode.tabs)
            Label("Bento", systemImage: "square.grid.2x2").tag(WorkflowLayout.Mode.bento)
        }
        .pickerStyle(.segmented)
        .labelStyle(.iconOnly)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
        .help("Show one agent at a time, or up to four side by side")
        .accessibilityIdentifier("agentLayout")
    }
}

private struct AgentSubtab: View {
    let agent: BridgeAgent
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        let style = RoleStyle(role: agent.role)
        Button(action: select) {
            HStack(spacing: AgentSubtabLayout.symbolSpacing) {
                Image(systemName: style.symbol)
                    .foregroundStyle(style.color)
                Text(agent.role)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: AgentSubtabLayout.maximumTitleWidth)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .tabTitleStyle(isSelected: isSelected)
            .padding(.horizontal, AgentSubtabLayout.subtabPadding)
            .frame(height: AgentSubtabLayout.subtabHeight)
            .background {
                // Glass behind the label rather than around it, so the label keeps the tab title colors
                // and its role color instead of glass's adaptive vibrancy.
                Color.clear.glassEffect(
                    isSelected ? .regular : .identity,
                    in: .rect(cornerRadius: CornerRadius.selectedSubtab)
                )
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(agent.role)
        .accessibilityValue(isSelected ? "Selected" : "")
        .accessibilityIdentifier("agentSubtab-\(agent.id)")
        .help(agent.role)
    }
}
