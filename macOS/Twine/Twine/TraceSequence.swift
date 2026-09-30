import SwiftUI

struct TraceSequence: View {
    let lanes: [CoreTraceLane]
    let spans: [CoreTraceSpan]
    let selectedSpanID: UInt64?
    let now: UInt64
    let labelWidth: CGFloat
    let select: (UInt64) -> Void

    var body: some View {
        let layout = TraceSequenceLayout(spans: spans)
        let tracks = lanes.sorted { $0.id < $1.id }
        let range = layout.focusRange(selectedID: selectedSpanID)
        VStack(spacing: 0) {
            TraceOverview(
                tracks: tracks, steps: layout.steps, focusRange: range,
                selectedSpanID: selectedSpanID, labelWidth: labelWidth, select: select)
            Divider().padding(.horizontal, 14)
            focusHeader(layout: layout, range: range)
            TraceFocusRail(
                steps: Array(layout.steps[range]), lanes: tracks,
                selectedSpanID: selectedSpanID, now: now, select: select)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("traceSequence")
        .onMoveCommand { direction in
            let offset = direction == .left ? -1 : direction == .right ? 1 : 0
            if offset != 0, let id = layout.neighbor(selectedID: selectedSpanID, offset: offset) { select(id) }
        }
    }

    private func focusHeader(layout: TraceSequenceLayout, range: Range<Int>) -> some View {
        HStack(spacing: 6) {
            Text("FOCUS").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                .fixedSize(horizontal: true, vertical: false)
            if !range.isEmpty {
                Text("\(range.lowerBound + 1)–\(range.upperBound) of \(layout.steps.count)")
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityIdentifier("traceFocusRange")
            }
            Spacer(minLength: 0)
            navigationButton("Previous step", symbol: "chevron.left", offset: -1, layout: layout)
            navigationButton("Next step", symbol: "chevron.right", offset: 1, layout: layout)
        }
        .padding(.horizontal, 14)
        .frame(height: TracesLayout.focusHeaderHeight)
    }

    private func navigationButton(
        _ title: String, symbol: String, offset: Int, layout: TraceSequenceLayout
    ) -> some View {
        let id = layout.neighbor(selectedID: selectedSpanID, offset: offset)
        return Button {
            if let id { select(id) }
        } label: {
            Image(systemName: symbol).font(.system(size: 9, weight: .semibold)).frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .disabled(id == nil)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityIdentifier(offset < 0 ? "previousTraceStep" : "nextTraceStep")
    }
}
