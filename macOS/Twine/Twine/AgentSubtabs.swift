import SwiftUI

/// The strip at the top of an agents workflow's terminal panel: a subtab for each agent in tab mode,
/// then the run's actions and a picker between tab mode and Bento mode, whose panes name their agents.
struct AgentSubtabs<Actions: View>: View {
    let agents: [CoreAgent]
    /// The agent with the keyboard: the one tab mode shows, or the focused Bento pane's.
    let selectedID: UInt64?
    /// Agents doing their stage's work now, marked with a dot.
    var workingIDs: Set<UInt64> = []
    /// Each agent's harness, named in its subtab's tooltip.
    var harnesses: [UInt64: String] = [:]
    @Binding var mode: WorkflowLayout.Mode
    /// Tiled Bento panes name their agents in their headers, so the strip leaves the subtabs out.
    let showsSubtabs: Bool
    /// A hidden workflow leaves out the picker: accessibility would still list its AppKit control.
    let showsLayoutPicker: Bool
    let select: (UInt64) -> Void
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: AgentSubtabLayout.labelSpacing) {
            Text("TERMINAL")
                .sectionLabelStyle()
                .fixedSize()
            if showsSubtabs { subtabs } else { Spacer(minLength: 0) }
            HStack(spacing: AgentSubtabLayout.actionSpacing) {
                actions
                if showsLayoutPicker && agents.count > 1 { layoutPicker }
            }
            .fixedSize()
        }
        .padding(.horizontal, AgentSubtabLayout.horizontalPadding)
        .frame(height: AgentSubtabLayout.height)
        .background(.workflowTint)
    }

    private var subtabs: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: AgentSubtabLayout.spacing) {
                    ForEach(agents) { agent in
                        AgentSubtab(
                            agent: agent, isSelected: agent.id == selectedID,
                            isWorking: workingIDs.contains(agent.id), harness: harnesses[agent.id]
                        ) { select(agent.id) }
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
    let agent: CoreAgent
    let isSelected: Bool
    let isWorking: Bool
    let harness: String?
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
                if isWorking { WorkingDot() }
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
        .accessibilityLabel(isWorking ? "\(agent.role), working" : agent.role)
        .accessibilityValue(isSelected ? "Selected" : "")
        .accessibilityIdentifier("agentSubtab-\(agent.id)")
        .help(harness.map { "\(agent.role) · \($0)" } ?? agent.role)
    }
}

/// Marks an agent doing its stage's work now, on its subtab or its Bento pane's header.
struct WorkingDot: View {
    var body: some View {
        Circle()
            .fill(Color.statusRunning)
            .frame(width: AgentSubtabLayout.workingDotSize, height: AgentSubtabLayout.workingDotSize)
            // Its subtab or pane names the state, since those replace their children's labels.
            .accessibilityHidden(true)
    }
}
