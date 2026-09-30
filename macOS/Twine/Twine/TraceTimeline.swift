import SwiftUI

struct TraceTimeline: View {
    let lanes: [CoreTraceLane]
    let spans: [CoreTraceSpan]
    let selectedSpanID: UInt64?
    let now: UInt64
    let labelWidth: CGFloat
    let select: (UInt64) -> Void

    var body: some View {
        GeometryReader { geometry in
            let layout = TraceTimelineLayout(spans: spans, now: now)
            let width = max(
                40, geometry.size.width - labelWidth - TracesLayout.timelineTrailingInset,
                min(2_400, CGFloat(spans.count) * 70))
            let rows = lanes.map { lane in
                layout.placements(spans: spans.filter { $0.laneID == lane.id }, width: width, now: now)
            }
            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        Color.clear.frame(height: TracesLayout.axisHeight)
                        ForEach(Array(lanes.enumerated()), id: \.element.id) { index, lane in
                            laneLabel(lane, height: laneHeight(rows[index]))
                        }
                    }
                    .frame(width: labelWidth)
                    ScrollView(.horizontal) {
                        VStack(spacing: 0) {
                            timeAxis(layout, width: width)
                            ForEach(Array(lanes.enumerated()), id: \.element.id) { index, lane in
                                laneContent(lane, placements: rows[index], width: width)
                            }
                        }
                        .frame(width: width)
                    }
                    .scrollIndicators(.hidden)
                }
                .padding(.trailing, TracesLayout.timelineTrailingInset)
            }
            .accessibilityIdentifier("traceTimeline")
        }
    }

    private func laneHeight(_ placements: [TraceTimelineLayout.Placement]) -> CGFloat {
        CGFloat(max(1, (placements.map(\.row).max() ?? 0) + 1)) * TracesLayout.laneHeight
    }

    private func laneLabel(_ lane: CoreTraceLane, height: CGFloat) -> some View {
        HStack(spacing: 6) {
            Image(systemName: TraceLaneStyle.symbol(for: lane)).foregroundStyle(TraceLaneStyle.color(for: lane))
                .frame(width: 14)
            if labelWidth > TracesLayout.compactLabelWidth {
                Text(lane.name).font(.caption).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, labelWidth > TracesLayout.compactLabelWidth ? 12 : 6)
        .padding(.top, 10)
        .frame(height: height, alignment: .top)
        .overlay(alignment: .bottom) { Divider() }
        .help(lane.name)
        .accessibilityLabel(lane.name)
    }

    private func timeAxis(_ layout: TraceTimelineLayout, width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            ForEach(0..<5) { index in
                Text(layout.tickLabel(index)).timeAxisStyle()
                    .frame(width: 52, alignment: index == 4 ? .trailing : .leading)
                    .offset(x: min(width - 52, width * CGFloat(index) / 4))
            }
        }
        .frame(width: width, height: TracesLayout.axisHeight, alignment: .leading)
    }

    private func laneContent(
        _ lane: CoreTraceLane, placements: [TraceTimelineLayout.Placement], width: CGFloat
    ) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<5) { index in
                Rectangle().fill(.primary.opacity(0.06)).frame(width: 1)
                    .offset(x: min(width - 1, width * CGFloat(index) / 4))
                    .allowsHitTesting(false)
            }
            ForEach(placements) { placement in
                spanButton(placement.span, lane: lane)
                    .frame(width: placement.width, height: TracesLayout.pillHeight)
                    .offset(x: placement.offset, y: CGFloat(placement.row) * TracesLayout.laneHeight + 5)
            }
        }
        .frame(width: width, height: laneHeight(placements), alignment: .topLeading)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func spanButton(_ span: CoreTraceSpan, lane: CoreTraceLane) -> some View {
        let selected = selectedSpanID == span.id
        return Button {
            select(span.id)
        } label: {
            HStack(spacing: 4) {
                if selected { Circle().fill(.white).frame(width: 4, height: 4) }
                Text(span.title).font(.system(size: 10, weight: .medium)).lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                TraceLaneStyle.color(for: lane).opacity(selected ? 1 : 0.75),
                in: RoundedRectangle(cornerRadius: CornerRadius.spanPill)
            )
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: CornerRadius.spanPill).strokeBorder(
                        .white.opacity(0.7), lineWidth: 1)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(lane.name): \(span.title), \(span.statusLabel)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("traceSpan-\(span.id)")
    }
}
