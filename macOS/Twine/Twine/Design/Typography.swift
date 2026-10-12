import SwiftUI

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
    func tabTitleStyle(isSelected: Bool, foreground: Color? = nil) -> some View {
        font(.caption.weight(isSelected ? .semibold : .regular))
            .foregroundStyle(foreground?.opacity(isSelected ? 1 : 0.7) ?? (isSelected ? Color.primary : .secondary))
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
        font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(.tertiary)
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
