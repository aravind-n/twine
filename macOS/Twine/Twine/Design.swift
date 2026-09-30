import AppKit
import SwiftUI

// Shared design values from macOS/DESIGN.md. The terminal and role colors are named colors in
// Assets.xcassets, used through their generated symbols, such as `.terminalBackground` and `.roleBlue`.
// The window background is SwiftUI's `.windowBackground`.

// MARK: - Corner radii

/// Corner radii, named for the components that use them.
nonisolated enum CornerRadius {
    /// All corners of the terminal panel, the Traces panel, and other rounded solid panels.
    static let panel: CGFloat = 17
    static let choicesCard: CGFloat = 14
    static let emptyRecentsCard: CGFloat = 12
    static let graphNode: CGFloat = 12
    /// The selected workflow tab's top corners.
    static let selectedTab: CGFloat = 10
    static let recentFolderCard: CGFloat = 10
    /// The terminal panel's radius less the Bento gutter, so each pane's corners follow the panel's.
    static let bentoPane: CGFloat = 11
    static let choiceTile: CGFloat = 9
    static let selectedSubtab: CGFloat = 9
    static let fileRowSelection: CGFloat = 8
    /// Glass icon buttons, such as `+` and the Traces chevron.
    static let glassIconButton: CGFloat = 8
    static let spanPill: CGFloat = 5
}

// MARK: - Spacing

nonisolated enum Spacing {
    /// Margins between the window's edges and its content.
    static let windowMargins = EdgeInsets(top: 14, leading: 14, bottom: 11, trailing: 14)
    /// Vertical space between the terminal block, the Traces panel, and the footer.
    static let windowSections: CGFloat = 13
    static let terminalContent: CGFloat = 24
    /// Agents workflows' strip already frames the panel, so their terminals sit closer to it.
    static let agentTerminalContent: CGFloat = 14
}

// MARK: - Folder window layout

nonisolated enum SidebarLayout {
    static let minimumWidth: CGFloat = 245
    static let idealWidth: CGFloat = 285
    static let maximumWidth: CGFloat = 325
    static let contentInset: CGFloat = 10
    static let sectionHeaderHeight: CGFloat = 48
    static let sectionHeaderPadding: CGFloat = 17
    static let rowHeight: CGFloat = 27
    static let rowInset: CGFloat = 13
    static let rowFontSize: CGFloat = 12.5
}

nonisolated enum TracesLayout {
    static let collapsedHeight: CGFloat = 48
    static let expandedHeight: CGFloat = 272
    static let axisHeight: CGFloat = 14
    static let laneHeight: CGFloat = 18
    static let labelWidth: CGFloat = 126
    static let detailLabelWidth: CGFloat = 104
    static let compactLabelWidth: CGFloat = 36
    static let timelineMinimumViewport: CGFloat = 100
    static let timelineTrailingInset: CGFloat = 14
    static let focusHeaderHeight: CGFloat = 24
    static let focusRailHeight: CGFloat = 102
    static let hintHeight: CGFloat = 28
    static let detailMinimumWidth: CGFloat = 280
    static let detailMaximumWidth: CGFloat = 440
    static let headerHorizontalPadding: CGFloat = 21
    static let chevronSize: CGFloat = 26
}

// MARK: - Surfaces and colors

nonisolated enum NewTabLayout {
    static let maximumWidth: CGFloat = 740
    /// Leave the terminal's first row visible when the choices need to scroll.
    static let promptClearance: CGFloat = 2 * Spacing.terminalContent
    static let padding: CGFloat = 16
    static let spacing: CGFloat = 8
    static let sectionSpacing: CGFloat = 14
    static let headingSpacing: CGFloat = 10
    static let choiceTextSpacing: CGFloat = 4
    static let minimumChoiceWidth: CGFloat = 160
    static let minimumChoiceHeight: CGFloat = 64
    static let choicePadding: CGFloat = 10
    static let symbolWidth: CGFloat = 16
}

/// The subtab strip at the top of a multi-agent workflow's terminal panel.
nonisolated enum AgentSubtabLayout {
    static let height: CGFloat = 34
    static let horizontalPadding: CGFloat = 18
    /// Between the "TERMINAL" label and the first subtab.
    static let labelSpacing: CGFloat = 13
    static let spacing: CGFloat = 5
    static let subtabHeight: CGFloat = 26
    /// Between the run's actions and the layout picker at the strip's trailing edge.
    static let actionSpacing: CGFloat = 6
    static let workingDotSize: CGFloat = 6
    static let subtabPadding: CGFloat = 10
    static let symbolSpacing: CGFloat = 6
    /// Longer role names truncate, as workflow tab titles do.
    static let maximumTitleWidth: CGFloat = 180
}

/// Bento mode: an agents workflow's terminals side by side, as rounded panes on the workflow tint.
nonisolated enum BentoLayout {
    /// Between the panes, and between the panes and the terminal panel's edges.
    static let gutter: CGFloat = 6
    /// The smallest pane Bento mode shows. A smaller panel shows fewer panes.
    static let minimumPaneSize = CGSize(width: 260, height: 150)
    static let headerHeight: CGFloat = 28
    static let headerPadding: CGFloat = 10
    static let terminalPadding: CGFloat = 12
    static let focusRingWidth: CGFloat = 2
    /// The draggable band centered on the gutter between two panes.
    static let dividerThickness: CGFloat = 10
}

nonisolated enum FooterLayout {
    static let height: CGFloat = 22
    static let horizontalPadding: CGFloat = 4
    static let spacing: CGFloat = 8
    static let dividerHeight: CGFloat = 10
}

nonisolated enum Surface {
    /// The width of the hairline that outlines panels, cards, and tiles.
    static let hairlineWidth: CGFloat = 1
}

extension View {
    func terminalPanelShadow() -> some View {
        shadow(color: .black.opacity(0.08), radius: 12, y: 4)
    }
}

extension ShapeStyle where Self == Color {
    /// Outlines on panels, cards, and tiles.
    static var hairline: Color { .primary.opacity(0.12) }

    /// The Traces panel's fainter outline.
    static var tracesPanelHairline: Color { .primary.opacity(0.08) }

    /// Start page cards and other secondary surfaces.
    static var secondarySurface: Color { Color(nsColor: .controlBackgroundColor) }

    /// The selected tab and subtab strip of a workflow with more than one agent.
    static var workflowTint: Color { secondarySurface.mix(with: .accentColor, by: 0.12, in: .device) }

    static var fileSelection: Color { .accentColor.opacity(0.12) }

    /// The outline of the Bento pane that has the keyboard.
    static var paneFocus: Color { Color(nsColor: .keyboardFocusIndicatorColor) }

    static var folderIcon: Color { .accentColor.opacity(0.8) }

    static var statusRunning: Color { .green }

    static var statusComplete: Color { .secondary }

    static var statusNeedsAttention: Color { .orange }
}

// MARK: - Symbols

/// The small chevron on a control that opens a menu.
struct MenuChevron: View {
    var body: some View {
        Image(systemName: "chevron.down")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.secondary)
    }
}

// MARK: - Typography

extension View {
    /// Section labels, such as "WORKFLOWS" and "TERMINAL".
    func sectionLabelStyle() -> some View {
        uppercaseLabelStyle(tracking: 1)
    }

    /// Sidebar section labels, such as "FILES".
    func sidebarSectionLabelStyle() -> some View {
        uppercaseLabelStyle(tracking: 1.2)
    }

    /// Workflow tabs and agent subtabs.
    func tabTitleStyle(isSelected: Bool) -> some View {
        font(.caption.weight(isSelected ? .semibold : .regular))
            .foregroundStyle(isSelected ? .primary : .secondary)
    }

    /// Panel titles, such as "Traces".
    func panelTitleStyle() -> some View {
        font(.system(size: 16, weight: .semibold))
    }

    func panelSubtitleStyle() -> some View {
        font(.caption2).foregroundStyle(.secondary)
    }

    func startPageTitleStyle() -> some View {
        font(.system(size: 30, weight: .semibold))
    }

    /// Tick labels on trace time axes.
    func timeAxisStyle() -> some View {
        font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundStyle(.tertiary)
    }

    /// Log timestamps and kinds.
    func logMetadataStyle() -> some View {
        font(.system(size: 10, weight: .medium, design: .monospaced))
    }

    func footerStyle() -> some View {
        font(.caption2).foregroundStyle(.secondary)
    }

    private func uppercaseLabelStyle(tracking: CGFloat) -> some View {
        font(.caption2.weight(.semibold))
            .textCase(.uppercase)
            .tracking(tracking)
            .foregroundStyle(.secondary)
    }
}

extension NSFont {
    static let terminal = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    static let denseTerminal = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
}

// MARK: - Motion

/// Animations, each tied to a user action.
nonisolated enum Motion {
    /// The close button fading in over a tab's icon on hover.
    static let tabCloseButton = Animation.easeInOut(duration: 0.12)
    static let scrollToSelectedTab = Animation.easeInOut(duration: 0.18)
    /// The Traces panel collapsing and expanding.
    static let tracesToggle = Animation.easeInOut(duration: 0.18)
    /// The trace detail panel sliding in from the trailing edge with a fade.
    static let traceDetailPanel = Animation.easeInOut(duration: 0.22)
    /// Typing in a draft tab turns it into a Terminal while the choices card fades out in place.
    static let draftTabToTerminal = Animation.easeInOut(duration: 0.32)
    /// The new-tab choices card fading in from `choicesCardAppearScale`.
    static let choicesCardAppear = Animation.easeInOut
    static let choicesCardAppearScale: CGFloat = 0.96
}
