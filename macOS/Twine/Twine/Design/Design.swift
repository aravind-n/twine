import SwiftUI

// Shared presentation values. Core supplies terminal palettes; role and interface
// colors use generated asset symbols such as `.roleBlue`.
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
    static let windowMargins = EdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14)
    /// Vertical space between the terminal block, the Traces panel, and the footer.
    static let windowSections: CGFloat = 6
    static let terminalContent: CGFloat = 24
    /// Agents workflows' strip already frames the panel, so their terminals sit closer to it.
    static let agentTerminalContent: CGFloat = 14
}

// MARK: - Surfaces and colors

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

// MARK: - Motion

/// Animations, each tied to a user action.
nonisolated enum Motion {
    /// The close button fading in over a tab's icon on hover.
    static let tabCloseButton = Animation.easeInOut(duration: 0.12)
    static let scrollToSelectedTab = Animation.easeInOut(duration: 0.18)
    /// Sidebar sections and the Traces panel collapsing and expanding.
    static let sectionToggle = Animation.smooth(duration: 0.2)
    /// The trace detail panel sliding in from the trailing edge with a fade.
    static let traceDetailPanel = Animation.easeInOut(duration: 0.22)
    /// Typing in a draft tab turns it into a Terminal while the choices card fades out in place.
    static let draftTabToTerminal = Animation.easeInOut(duration: 0.32)
    /// The new-tab choices card fading in from `choicesCardAppearScale`.
    static let choicesCardAppear = Animation.easeInOut
    static let choicesCardAppearScale: CGFloat = 0.96
}
