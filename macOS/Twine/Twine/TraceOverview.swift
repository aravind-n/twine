import SwiftUI

struct TraceOverview: View {
    @Environment(\.traceLaneColors) private var laneColors
    let tracks: [CoreTraceLane]
    let steps: [TraceSequenceLayout.Step]
    let focusRange: Range<Int>
    let selectedSpanID: UInt64?
    let labelWidth: CGFloat
    let select: (UInt64) -> Void

    var body: some View {
        GeometryReader { geometry in
            let pitch = max(22, min(32, (geometry.size.width - labelWidth - 14) / CGFloat(max(1, steps.count))))
            ScrollViewReader { verticalProxy in
                ScrollView(.vertical) {
                    HStack(alignment: .top, spacing: 0) {
                        VStack(spacing: 0) {
                            Color.clear.frame(height: TracesLayout.axisHeight)
                            ForEach(tracks) { lane in laneLabel(lane).id("lane-\(lane.id)") }
                        }
                        .frame(width: labelWidth)
                        ScrollViewReader { proxy in
                            ScrollView(.horizontal) {
                                LazyHStack(spacing: 0) {
                                    ForEach(steps) { step in
                                        column(step, pitch: pitch).id(step.id)
                                    }
                                }
                            }
                            .scrollIndicators(.hidden)
                            .onChange(of: selectedSpanID, initial: true) { revealSelection(proxy) }
                            .onChange(of: steps.map(\.id)) { revealSelection(proxy) }
                            .onChange(of: geometry.size.width) { revealSelection(proxy) }
                        }
                    }
                    .padding(.trailing, 14)
                }
                .onChange(of: selectedSpanID, initial: true) { revealTrack(verticalProxy) }
                .onChange(of: steps.map(\.id)) { revealTrack(verticalProxy) }
                .onChange(of: tracks.map(\.id)) { revealTrack(verticalProxy) }
                .onChange(of: geometry.size.height) { revealTrack(verticalProxy) }
            }
        }
        .frame(minHeight: TracesLayout.axisHeight + TracesLayout.laneHeight)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("traceOverview")
    }

    private func revealSelection(_ proxy: ScrollViewProxy) {
        if let id = selectedSpanID ?? steps.last?.id { proxy.scrollTo(id, anchor: .center) }
    }

    private func revealTrack(_ proxy: ScrollViewProxy) {
        if let step = steps.first(where: { $0.id == selectedSpanID }) ?? steps.last {
            proxy.scrollTo("lane-\(step.span.laneID)")
        }
    }

    private func laneLabel(_ lane: CoreTraceLane) -> some View {
        HStack(spacing: 5) {
            Image(systemName: TraceLaneStyle.symbol(for: lane))
                .foregroundStyle(TraceLaneStyle.color(for: lane, colors: laneColors)).frame(width: 14)
            if labelWidth > TracesLayout.compactLabelWidth {
                Text(lane.name).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
        }
        .font(.system(size: 10))
        .padding(.horizontal, labelWidth > TracesLayout.compactLabelWidth ? 12 : 6)
        .frame(height: TracesLayout.laneHeight)
        .help(lane.name)
        .accessibilityLabel(lane.name)
    }

    private func column(_ step: TraceSequenceLayout.Step, pitch: CGFloat) -> some View {
        VStack(spacing: 0) {
            Text(step.number).timeAxisStyle().frame(height: TracesLayout.axisHeight)
            ForEach(tracks) { lane in
                ZStack {
                    Rectangle().fill(.primary.opacity(0.1)).frame(height: 1)
                    if step.span.laneID == lane.id {
                        Button {
                            select(step.id)
                        } label: {
                            TraceStepPoint(span: step.span, lane: lane, selected: selectedSpanID == step.id, size: 7)
                                .frame(width: pitch, height: TracesLayout.laneHeight)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("\(lane.name): \(step.span.title) · \(step.span.statusLabel)")
                        .accessibilityLabel(
                            "Step \(step.index + 1), \(lane.name): \(step.span.title), \(step.span.statusLabel)"
                        )
                        .accessibilityAddTraits(selectedSpanID == step.id ? .isSelected : [])
                        .accessibilityIdentifier("traceSpan-\(step.id)")
                    }
                }
                .frame(height: TracesLayout.laneHeight)
            }
        }
        .frame(width: pitch)
        .background(Color.accentColor.opacity(focusRange.contains(step.index) ? 0.08 : 0))
        .overlay {
            if selectedSpanID == step.id {
                Rectangle().fill(Color.accentColor.opacity(0.1)).allowsHitTesting(false)
            }
        }
    }
}
