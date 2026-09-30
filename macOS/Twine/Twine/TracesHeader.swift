import SwiftUI

struct TracesHeader: View {
    let isExpanded: Bool
    let summary: BridgeTraceSummary?
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Traces").panelTitleStyle()
                    if isExpanded { Text("Agent activity over time").panelSubtitleStyle() }
                }
                Spacer(minLength: 0)
                if summary != nil {
                    Text(countLabel)
                        .font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: TracesLayout.chevronSize, height: TracesLayout.chevronSize)
                    .glassEffect(in: .rect(cornerRadius: CornerRadius.glassIconButton))
            }
            .padding(.horizontal, TracesLayout.headerHorizontalPadding)
            .frame(maxWidth: .infinity)
            .frame(height: TracesLayout.collapsedHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(isExpanded ? "Traces, expanded" : "Traces, collapsed")
        .accessibilityHint("Toggle the activity timeline")
        .accessibilityIdentifier("tracesHeader")
    }
    private var countLabel: String {
        guard let summary else { return "" }
        let spans = summary.spanCount == 1 ? "span" : "spans"
        let agents = summary.agentCount == 1 ? "agent" : "agents"
        return "\(summary.spanCount) \(spans) · \(summary.agentCount) \(agents)"
    }

}

#Preview { TracesHeader(isExpanded: false, summary: nil) {} }
