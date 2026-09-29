import AppKit
import SwiftUI

// Shared design values from macOS/DESIGN.md. The terminal and role colors are named colors in
// Assets.xcassets, used through their generated symbols, such as `.terminalBackground` and `.roleBlue`.
// The window background is SwiftUI's `.windowBackground`.

// MARK: - Corner radii

/// Corner radii, named for the components that use them.
nonisolated enum CornerRadius {
    /// The terminal panel's bottom corners, the Traces panel, and other rounded solid panels.
    static let panel: CGFloat = 17
    static let appIconTile: CGFloat = 16
    static let choicesCard: CGFloat = 14
    static let emptyRecentsCard: CGFloat = 12
    /// The selected workflow tab's top corners.
    static let selectedTab: CGFloat = 10
    static let recentFolderCard: CGFloat = 10
    static let sidebarFolderHeader: CGFloat = 10
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
}

// MARK: - Surfaces and colors

nonisolated enum Surface {
    /// The width of the hairline that outlines panels, cards, and tiles and underlines the tab row.
    static let hairlineWidth: CGFloat = 1
}

extension View {
    func terminalPanelShadow() -> some View {
        shadow(color: .black.opacity(0.08), radius: 12, y: 4)
    }
}

extension ShapeStyle where Self == Color {
    /// Outlines on panels, cards, and tiles, and the tab row's baseline.
    static var hairline: Color { .primary.opacity(0.12) }

    /// The Traces panel's fainter outline.
    static var tracesPanelHairline: Color { .primary.opacity(0.08) }

    /// The trace detail panel and start page cards.
    static var secondarySurface: Color { Color(nsColor: .controlBackgroundColor) }

    /// The selected tab and subtab strip of a workflow with more than one agent.
    static var workflowTint: Color { secondarySurface.mix(with: .accentColor, by: 0.12, in: .device) }

    static var fileSelection: Color { .accentColor.opacity(0.12) }

    static var folderIcon: Color { .accentColor.opacity(0.8) }

    static var statusRunning: Color { .green }

    static var statusComplete: Color { .secondary }

    static var statusNeedsAttention: Color { .orange }
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
    /// Typing in a draft tab turns it into a Terminal: the choices card fades and scales down to
    /// `draftTabToTerminalCardScale` toward the `+` button.
    static let draftTabToTerminal = Animation.easeInOut(duration: 0.32)
    static let draftTabToTerminalCardScale: CGFloat = 0.12
    /// The new-tab choices card fading in from `choicesCardAppearScale`.
    static let choicesCardAppear = Animation.easeInOut
    static let choicesCardAppearScale: CGFloat = 0.96
}
