import AppKit
import SwiftUI

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

    @MainActor static func minimumTerminalPaneHeight(for font: NSFont, includesNotice: Bool = false) -> CGFloat {
        let notice = includesNotice ? RestoredNoticeLayout.height : 0
        return max(
            100,
            headerHeight + notice + 2 * terminalPadding
                + 2 * (font.ascender - font.descender + font.leading).rounded(.up))
    }
}

nonisolated enum RestoredNoticeLayout {
    static let height: CGFloat = 40
}

nonisolated enum WorkflowTabLayout {
    static let height: CGFloat = 32
}

nonisolated enum WorkflowSurfaceLayout {
    @MainActor static func minimumHeight(for workflow: CoreWorkflow?, font: NSFont) -> CGFloat {
        let padding = workflow?.kind == .agents ? Spacing.agentTerminalContent : Spacing.terminalContent
        let strip = workflow?.showsTerminalStrip == true ? AgentSubtabLayout.height : 0
        let notice = workflow?.showsRestoredNotice == true ? RestoredNoticeLayout.height : 0
        let terminal = strip + notice + 2 * padding + 2 * (font.ascender - font.descender + font.leading).rounded(.up)
        return workflow?.kind == .draft
            ? max(
                terminal,
                NewTabLayout.promptClearance + NewTabLayout.minimumChoiceViewportHeight + 2 * NewTabLayout.padding
            ) : terminal
    }
}
