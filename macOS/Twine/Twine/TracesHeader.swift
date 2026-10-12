import SwiftUI

struct TracesHeader: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isExpanded: Bool
    let summary: CoreTraceSummary?
    @Binding var viewMode: TraceViewMode
    var height: CGFloat = TracesLayout.collapsedHeight
    let toggle: () -> Void

    private var expansion: CGFloat {
        min(
            1,
            max(
                0,
                (height - TracesLayout.collapsedHeight)
                    / (TracesLayout.expandedHeaderHeight - TracesLayout.collapsedHeight)))
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            headerRow(compact: false)
            headerRow(compact: true)
        }
        .padding(
            .horizontal,
            TracesLayout.headerHorizontalPadding
                + (TracesLayout.expandedHeaderHorizontalPadding - TracesLayout.headerHorizontalPadding) * expansion
        )
        .frame(height: height)
    }

    private func headerRow(compact: Bool) -> some View {
        HStack(spacing: compact ? 6 : 10) {
            titleButton
            if isExpanded, (summary?.spanCount ?? 0) > 0 {
                if compact {
                    Menu {
                        viewPicker.pickerStyle(.inline)
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .frame(width: TracesLayout.chevronSize, height: TracesLayout.chevronSize)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .help("Trace view")
                    .accessibilityLabel("Trace view")
                    .accessibilityValue(viewMode.rawValue)
                    .accessibilityIdentifier("traceViewMode")
                } else {
                    viewPicker.pickerStyle(.segmented)
                }
            }
            disclosureButton(showsCount: !compact)
        }
    }

    private var viewPicker: some View {
        Picker("Trace view", selection: $viewMode) {
            ForEach(TraceViewMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
        }
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
        .accessibilityIdentifier("traceViewMode")
    }

    private var titleButton: some View {
        Button(action: toggle) {
            HStack(spacing: 0) {
                Text("Traces").font(.system(size: 12 + 4 * expansion, weight: .semibold)).lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
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

    private func disclosureButton(showsCount: Bool) -> some View {
        Button(action: toggle) {
            HStack(spacing: 12) {
                if showsCount, summary != nil {
                    Text(countLabel)
                        .font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Image(systemName: "chevron.up")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    .animation(reduceMotion ? nil : Motion.sectionToggle, value: isExpanded)
                    .frame(
                        width: TracesLayout.chevronSize + (TracesLayout.expandedChevronSize - TracesLayout.chevronSize)
                            * expansion,
                        height: TracesLayout.chevronSize + (TracesLayout.expandedChevronSize - TracesLayout.chevronSize)
                            * expansion)
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
