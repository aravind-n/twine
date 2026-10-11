import SwiftUI

struct TracesHeader: View {
    let isExpanded: Bool
    let summary: CoreTraceSummary?
    @Binding var viewMode: TraceViewMode
    let toggle: () -> Void

    private var height: CGFloat { isExpanded ? TracesLayout.expandedHeaderHeight : TracesLayout.collapsedHeight }

    var body: some View {
        HStack(spacing: 10) {
            titleButton
            if isExpanded {
                Picker("Trace view", selection: $viewMode) {
                    ForEach(TraceViewMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                .accessibilityIdentifier("traceViewMode")
            }
            disclosureButton
        }
        .padding(.horizontal, isExpanded ? TracesLayout.headerHorizontalPadding : 14)
        .frame(height: height)
    }

    private var titleButton: some View {
        Button(action: toggle) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Traces").font(.system(size: isExpanded ? 16 : 12, weight: .semibold))
                    if isExpanded { Text("Steps in start order").panelSubtitleStyle() }
                }
                .lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(isExpanded ? "Traces, expanded" : "Traces, collapsed")
        .accessibilityHint("Toggle the trace sequence")
        .accessibilityIdentifier("tracesHeader")
    }

    private var disclosureButton: some View {
        Button(action: toggle) {
            HStack(spacing: 12) {
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
            .frame(height: height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(isExpanded ? "Collapse traces" : "Expand traces")
        .accessibilityValue(countLabel)
        .accessibilityIdentifier("tracesDisclosure")
    }

    private var countLabel: String {
        guard let summary else { return "" }
        let spans = summary.spanCount == 1 ? "step" : "steps"
        let agents = summary.agentCount == 1 ? "agent" : "agents"
        return "\(summary.spanCount) \(spans) · \(summary.agentCount) \(agents)"
    }

}

#Preview { TracesHeader(isExpanded: false, summary: nil, viewMode: .constant(.overview)) {} }
