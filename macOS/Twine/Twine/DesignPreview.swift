#if DEBUG
    import AppKit
    import SwiftUI

    /// The shared design values in light and dark mode, side by side, for checking against DESIGN.md.
    struct DesignPreview: View {
        var body: some View {
            HStack(spacing: 0) {
                DesignSamples()
                    .environment(\.colorScheme, .light)
                DesignSamples()
                    .environment(\.colorScheme, .dark)
            }
            .fixedSize()
        }
    }

    private struct DesignSamples: View {
        private static let terminalTones: [(name: String, color: Color)] = [
            ("normal", .terminalText),
            ("muted", .terminalTextMuted),
            ("green", .terminalTextGreen),
            ("blue", .terminalTextBlue),
            ("amber", .terminalTextAmber),
        ]

        private static let roleColors: [(name: String, color: Color)] = [
            ("Blue", .roleBlue),
            ("Orange", .roleOrange),
            ("Purple", .rolePurple),
            ("Green", .roleGreen),
        ]

        var body: some View {
            VStack(alignment: .leading, spacing: Spacing.windowSections) {
                terminal
                roles
                textStyles
            }
            .frame(width: 300, alignment: .leading)
            .padding(Spacing.windowMargins)
            .background(.windowBackground)
        }

        private var terminal: some View {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 0) {
                    Text(verbatim: "❯ ").foregroundStyle(.terminalTextGreen)
                    Text(verbatim: "swift test")
                }
                ForEach(Self.terminalTones, id: \.name) { tone in
                    Text(tone.name).foregroundStyle(tone.color)
                }
            }
            .font(Font(NSFont.terminal as CTFont))
            .foregroundStyle(.terminalText)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.terminalBackground, in: .rect(cornerRadius: CornerRadius.panel))
            .overlay {
                RoundedRectangle(cornerRadius: CornerRadius.panel)
                    .strokeBorder(.hairline, lineWidth: Surface.hairlineWidth)
            }
            .terminalPanelShadow()
        }

        private var roles: some View {
            HStack(spacing: 8) {
                ForEach(Self.roleColors, id: \.name) { role in
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: CornerRadius.spanPill)
                            .fill(role.color)
                            .frame(height: 25)
                        Text(role.name)
                            .font(.caption)
                            .foregroundStyle(role.color)
                    }
                }
            }
        }

        private var textStyles: some View {
            VStack(alignment: .leading, spacing: 12) {
                Text(verbatim: "Workflows").sectionLabelStyle()
                Text(verbatim: "Files").sidebarSectionLabelStyle()
                HStack(spacing: 12) {
                    Label {
                        Text(verbatim: "Terminal")
                    } icon: {
                        Image(systemName: "terminal")
                    }
                    .tabTitleStyle(isSelected: true)
                    Label {
                        Text(verbatim: "Reviewer")
                    } icon: {
                        Image(systemName: "checkmark.bubble")
                    }
                    .tabTitleStyle(isSelected: false)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "Traces").panelTitleStyle()
                    Text(verbatim: "Steps in start order").panelSubtitleStyle()
                }
            }
        }
    }

    #Preview {
        DesignPreview()
    }
#endif
