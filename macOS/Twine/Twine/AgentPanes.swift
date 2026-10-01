import SwiftUI

/// Every agent's live terminal, arranged by the workflow's layout: the focused agent alone in tab
/// mode, or up to four side by side in Bento mode. The terminals stay in one layout in both modes,
/// so switching modes, panes, or window sizes only moves and resizes them. No shell starts or stops,
/// and no terminal loses its screen.
struct AgentPanes: View {
    let workflow: CoreWorkflow
    @Binding var layout: WorkflowLayout
    let isSelected: Bool
    /// Tells the strip whether the panes are tiled, each with a header naming its agent.
    let reportTiling: (Bool) -> Void
    /// The panel's size, which decides how many Bento panes fit.
    @State private var size: CGSize?
    @State private var focusRequest = 0
    // A divider's fraction while it's dragged. It's saved when the drag ends, so a drag doesn't update
    // the shared layouts, which every workflow reads, on each step.
    @State private var draggedColumnFraction: Double?
    @State private var draggedRow: (column: Int, fraction: Double)?

    var body: some View {
        let agents = workflow.agents
        let focusedID = layout.focusedAgent(in: agents)?.id
        let paneIDs = layout.panes(of: agents).map(\.id)
        let arrangement =
            if layout.mode == .bento, let focusedID, let size {
                PaneArrangement(panes: paneIDs, focusedAgentID: focusedID, size: size)
            } else {
                PaneArrangement(focusedAgentID: focusedID)
            }
        PaneLayout(
            arrangement: arrangement, columnFraction: columnFraction, rowFractions: [rowFraction(0), rowFraction(1)]
        ) {
            ForEach(agents) { agent in
                AgentPane(
                    agent: agent, workflow: workflow,
                    isShown: arrangement.visibleAgentIDs.contains(agent.id), isTiled: arrangement.isTiled,
                    isFocused: agent.id == focusedID, isWorkflowSelected: isSelected, focusRequest: focusRequest,
                    focus: { layout.focus(agent.id, in: agents) },
                    place: { chosen in
                        if let index = paneIDs.firstIndex(of: agent.id) {
                            layout.place(chosen, inPane: index, of: agents)
                        }
                    }
                )
                .layoutValue(key: PaneSlot.self, value: .agent(agent.id))
            }
            if arrangement.columns.count > 1, let size {
                PaneDivider(
                    axis: .horizontal,
                    fraction: clampedFraction(columnFraction, along: .horizontal, in: size),
                    sharedLength: PaneArrangement.sharedLength(size.width),
                    drag: { draggedColumnFraction = clampedFraction($0, along: .horizontal, in: size) },
                    save: {
                        layout.columnFraction = clampedFraction($0, along: .horizontal, in: size)
                        draggedColumnFraction = nil
                    }
                )
                .layoutValue(key: PaneSlot.self, value: .columnDivider)
            }
            ForEach(arrangement.columns.filter { $0.agentIDs.count > 1 }, id: \.index) { column in
                if let size {
                    PaneDivider(
                        axis: .vertical,
                        fraction: clampedFraction(rowFraction(column.index), along: .vertical, in: size),
                        sharedLength: PaneArrangement.sharedLength(size.height),
                        drag: { draggedRow = (column.index, clampedFraction($0, along: .vertical, in: size)) },
                        save: {
                            saveRowFraction(clampedFraction($0, along: .vertical, in: size), column: column.index)
                            draggedRow = nil
                        }
                    )
                    .layoutValue(key: PaneSlot.self, value: .rowDivider(column.index))
                }
            }
        }
        .background(arrangement.isTiled ? Color.workflowTint : .terminalBackground)
        .onGeometryChange(for: CGSize.self, of: { $0.size }, action: { size = $0 })
        // Clicking the layout picker can take the keyboard, so give it back to the focused terminal.
        .onChange(of: layout.mode) { focusRequest += 1 }
        .onChange(of: arrangement.isTiled, initial: true) { _, isTiled in reportTiling(isTiled) }
    }

    private var columnFraction: Double { draggedColumnFraction ?? layout.columnFraction }

    private func rowFraction(_ column: Int) -> Double {
        if let draggedRow, draggedRow.column == column { return draggedRow.fraction }
        return layout.rowFractions.indices.contains(column) ? layout.rowFractions[column] : 0.5
    }

    private func saveRowFraction(_ fraction: Double, column: Int) {
        while layout.rowFractions.count <= column { layout.rowFractions.append(0.5) }
        layout.rowFractions[column] = fraction
    }

    private func clampedFraction(_ fraction: Double, along axis: Axis, in size: CGSize) -> Double {
        let minimum = BentoLayout.minimumPaneSize
        return axis == .horizontal
            ? PaneArrangement.clampedFraction(fraction, panelLength: size.width, minimum: minimum.width)
            : PaneArrangement.clampedFraction(fraction, panelLength: size.height, minimum: minimum.height)
    }
}

/// One agent's terminal: filling the panel, or in Bento mode a rounded pane under a header whose
/// menu picks the pane's agent.
private struct AgentPane: View {
    @Environment(CoreClient.self) private var coreClient
    @Environment(TraceTerminalNavigation.self) private var navigation
    let agent: CoreAgent
    let workflow: CoreWorkflow
    let isShown: Bool
    let isTiled: Bool
    /// Whether this agent has the keyboard when its workflow is selected.
    let isFocused: Bool
    let isWorkflowSelected: Bool
    let focusRequest: Int
    let focus: () -> Void
    let place: (UInt64) -> Void
    private var isWorking: Bool {
        workflow.run?.agents.contains { $0.id == agent.id && $0.isWorking } == true
    }
    private var history: TraceTerminalTarget? {
        navigation.target.flatMap { target in
            target.agentID == agent.id || (target.agentID == nil && target.anchor.terminalID == agent.terminalID)
                ? target : nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Hidden panes drop their header, whose AppKit menu accessibility would still list.
            if isTiled && isShown { header }
            if agent.terminalID == 0 {
                ContentUnavailableView(
                    idleTitle, systemImage: "terminal",
                    description: Text(
                        workflow.run != nil && workflow.status == .running
                            ? "This role starts when its stage begins."
                            : "Open a new workflow to try again.")
                )
                .onTapGesture(perform: focus)
            } else {
                TerminalSurface(
                    terminalID: agent.terminalID,
                    historyTerminalIDs: workflow.terminalHistory?.filter { $0.agentID == agent.id }.map(\.terminalID)
                        ?? [],
                    restoresOutput: workflow.restored,
                    isVisible: isWorkflowSelected && isShown && history == nil,
                    isSelected: isWorkflowSelected && isFocused && history == nil, focusRequest: focusRequest,
                    padding: isTiled ? BentoLayout.terminalPadding : Spacing.agentTerminalContent,
                    subject: workflow.run == nil ? "Shell" : "Agent", isCancelled: workflow.status == .cancelled,
                    agentStatus: workflow.run?.agents.first(where: { $0.id == agent.id })?.status,
                    beforeUserInput: {
                        try await coreClient.continueWorkflowIfNeeded(workflowID: workflow.id, agentID: agent.id)
                    },
                    didFocus: focus
                )
                // A stage that starts the agent gives it a new terminal, so the emulator must be rebuilt for it.
                .id(agent.terminalID)
            }
        }
        .overlay {
            if let history {
                TerminalHistorySurface(target: history) {
                    focus()
                    navigation.target = nil
                }
                .id(history.id)
            }
        }
        .bentoPane(isTiled: isTiled, isFocused: isFocused)
        .opacity(isShown ? 1 : 0)
        .allowsHitTesting(isShown)
        .accessibilityHidden(!isShown)
    }

    private var idleTitle: String {
        if workflow.run == nil { return "Shell Couldn't Restart" }
        if let status = workflow.run?.agents.first(where: { $0.id == agent.id })?.status {
            switch status {
            case .interrupted: return "Agent Interrupted"
            case .completed: return "Agent Completed"
            case .cancelled: return "Agent Cancelled"
            case .exited: return "Agent Exited"
            case .failed: return "Agent Failed"
            case .waiting, .running: break
            }
        }
        return workflow.status == .running ? "Agent Waiting" : "Agent Stopped"
    }

    private var title: some View {
        let style = RoleStyle(role: agent.role)
        return HStack(spacing: AgentSubtabLayout.symbolSpacing) {
            Image(systemName: style.symbol)
                .foregroundStyle(style.color)
            Text(agent.role)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: AgentSubtabLayout.maximumTitleWidth)
            if isWorking { WorkingDot() }
            MenuChevron()
        }
        .tabTitleStyle(isSelected: isFocused)
        .contentShape(.rect)
        // One control, not one per symbol and title.
        .accessibilityElement(children: .combine)
    }

    private var header: some View {
        HStack(spacing: 0) {
            // A hidden workflow shows the title alone: accessibility would still list its AppKit menu.
            if isWorkflowSelected {
                Menu {
                    Picker("Agent", selection: Binding(get: { agent.id }, set: { place($0) })) {
                        ForEach(workflow.agents) { agent in
                            Label(agent.role, systemImage: RoleStyle(role: agent.role).symbol).tag(agent.id)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } label: {
                    title
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
                // As wide as its title, so the rest of the header focuses the pane.
                .fixedSize()
                .accessibilityLabel(isWorking ? "\(agent.role) pane, working" : "\(agent.role) pane")
                .accessibilityValue(isFocused ? "Focused" : "")
                .accessibilityIdentifier("agentPane-\(agent.id)")
                .help("Choose this pane's agent")
            } else {
                title.fixedSize()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, BentoLayout.headerPadding)
        .frame(height: BentoLayout.headerHeight)
        .background {
            // Clicking the rest of the header focuses the pane. The menu and ⌘] do so accessibly.
            Color.clear
                .contentShape(.rect)
                .onTapGesture(perform: focus)
                .accessibilityHidden(true)
        }
    }
}
