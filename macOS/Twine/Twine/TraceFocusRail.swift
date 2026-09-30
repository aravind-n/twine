import SwiftUI

struct TraceFocusRail: View {
    let steps: [TraceSequenceLayout.Step]
    let lanes: [CoreTraceLane]
    let selectedSpanID: UInt64?
    let now: UInt64
    let select: (UInt64) -> Void

    var body: some View {
        GeometryReader { geometry in
            let width = max(84, min(116, (geometry.size.width - 28) / CGFloat(TraceSequenceLayout.focusCount)))
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(steps) { step in
                            if let lane = lanes.first(where: { $0.id == step.span.laneID }) {
                                stepButton(step, lane: lane).frame(width: width).id(step.id)
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                }
                .scrollIndicators(.hidden)
                .onChange(of: selectedSpanID, initial: true) { revealSelection(proxy) }
                .onChange(of: steps.map(\.id)) { revealSelection(proxy) }
                .onChange(of: geometry.size.width) { revealSelection(proxy) }
            }
        }
        .frame(height: TracesLayout.focusRailHeight)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("traceFocusRail")
    }

    private func revealSelection(_ proxy: ScrollViewProxy) {
        if let id = selectedSpanID ?? steps.last?.id { proxy.scrollTo(id, anchor: .center) }
    }

    private func stepButton(_ step: TraceSequenceLayout.Step, lane: CoreTraceLane) -> some View {
        let selected = selectedSpanID == step.id
        return Button {
            select(step.id)
        } label: {
            VStack(spacing: 3) {
                Text(step.number).timeAxisStyle()
                ZStack {
                    Rectangle().fill(.primary.opacity(0.12)).frame(height: 1)
                    TraceStepPoint(span: step.span, lane: lane, selected: selected, size: 10)
                }
                .frame(height: 22)
                Text(step.span.title)
                    .font(.system(size: 10, weight: selected ? .semibold : .medium))
                    .lineLimit(2).frame(height: 27, alignment: .top)
                    .frame(maxWidth: .infinity).padding(.horizontal, 4)
                Text(lane.name).font(.system(size: 9)).foregroundStyle(TraceLaneStyle.color(for: lane))
                    .lineLimit(1).padding(.horizontal, 4)
                Text(durationLabel(step.span)).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 3)
            .background(Color.accentColor.opacity(selected ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(lane.name): \(step.span.title) · \(step.span.statusLabel)")
        .accessibilityLabel("Step \(step.index + 1), \(lane.name): \(step.span.title), \(step.span.statusLabel)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("traceFocusSpan-\(step.id)")
    }

    private func durationLabel(_ span: CoreTraceSpan) -> String {
        if span.isLive { return "Running · \(TraceFormatting.elapsed(span.end(at: now) - span.startedAt))" }
        if span.status == .failed { return "Failed" }
        guard span.endedAt != nil else { return span.statusLabel }
        return TraceFormatting.elapsed(span.end(at: now) - span.startedAt)
    }
}

struct TraceStepPoint: View {
    let span: CoreTraceSpan
    let lane: CoreTraceLane
    let selected: Bool
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(.windowBackground).frame(width: size + 5, height: size + 5)
            if span.status == .failed {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                    .font(.system(size: size + 2, weight: .bold))
            } else {
                Circle().fill(TraceLaneStyle.color(for: lane)).frame(width: size, height: size)
                if span.isLive {
                    Circle().strokeBorder(TraceLaneStyle.color(for: lane), lineWidth: 1)
                        .frame(width: size + 5, height: size + 5)
                }
            }
            if selected {
                Circle().strokeBorder(.primary, lineWidth: 1).frame(width: size + 9, height: size + 9)
            }
        }
        .accessibilityHidden(true)
    }
}
