import SwiftUI

struct TracesHeader: View {
    let isExpanded: Bool
    let summary: CoreTraceSummary?
    @Binding var viewMode: TraceViewMode
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            toggleButton
            if isExpanded {
                Picker("Trace view", selection: $viewMode) {
                    ForEach(TraceViewMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
                }
                .pickerStyle(.segmented)
                .frame(width: 155)
                .accessibilityIdentifier("traceViewMode")
                .padding(.trailing, TracesLayout.headerHorizontalPadding)
            }
        }
    }

    private var toggleButton: some View {
        Button(action: toggle) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Traces").panelTitleStyle()
                    if isExpanded { Text("Steps in start order").panelSubtitleStyle() }
                }
                Spacer(minLength: 0)
                if summary != nil {
                    Text(countLabel)
                        .font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: TracesLayout.chevronSize, height: TracesLayout.chevronSize)
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
        .accessibilityHint("Toggle the trace sequence")
        .accessibilityIdentifier("tracesHeader")
    }
    private var countLabel: String {
        guard let summary else { return "" }
        let spans = summary.spanCount == 1 ? "step" : "steps"
        let agents = summary.agentCount == 1 ? "agent" : "agents"
        return "\(summary.spanCount) \(spans) · \(summary.agentCount) \(agents)"
    }

}

#Preview { TracesHeader(isExpanded: false, summary: nil, viewMode: .constant(.standard)) {} }
