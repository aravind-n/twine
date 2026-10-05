import SwiftUI

struct TraceActivityChart: View {
    let rows: [TraceActivityTimeline.Row]
    let timeline: TraceActivityTimeline
    @Bindable var state: TraceActivityState
    let color: Color
    let now: UInt64
    private let labelWidth: CGFloat = 160

    var body: some View {
        GeometryReader { geometry in
            let width = max(520, geometry.size.width - 24)
            let chartWidth = width - labelWidth
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(spacing: 0) {
                    axis(width: chartWidth)
                    ForEach(rows) { row in
                        activityRow(row, width: chartWidth)
                    }
                }
                .frame(width: width)
                .padding(.horizontal, 12).padding(.bottom, 8)
            }
            .accessibilityIdentifier("traceActivityTimeline")
        }
    }

    private func axis(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            Text("Elapsed within step").font(.system(size: 9)).foregroundStyle(.secondary)
                .frame(width: labelWidth, alignment: .leading)
            HStack(spacing: 0) {
                ForEach(0..<5) { tick in
                    if tick != 0 { Spacer(minLength: 0) }
                    Text("+\(TraceActivityTimeline.duration((timeline.end - timeline.start) / 4 * UInt64(tick)))")
                        .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            .frame(width: width)
        }
        .frame(height: 20)
    }

    private func activityRow(_ row: TraceActivityTimeline.Row, width: CGFloat) -> some View {
        let activity = row.activity
        let selected = state.selectedActivityID == activity.id
        let tint = tint(for: activity)
        return HStack(spacing: 0) {
            rowLabel(row, color: tint)
            Button {
                state.selectedActivityID = activity.id
            } label: {
                bar(activity, width: width, color: tint, selected: selected)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Inspect \(activity.title)")
            .accessibilityIdentifier("traceActivityBar-\(activity.id)")
        }
        .frame(height: 29)
        .background(tint.opacity(selected ? 0.09 : 0))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .help(
            "\(activity.title) · \(activity.statusLabel) · "
                + activity.durationLabel(at: now)
        )
    }

    private func rowLabel(_ row: TraceActivityTimeline.Row, color: Color) -> some View {
        let activity = row.activity
        return HStack(spacing: 4) {
            if row.hasChildren {
                Button {
                    if !state.collapsed.insert(activity.id).inserted { state.collapsed.remove(activity.id) }
                } label: {
                    Image(systemName: state.collapsed.contains(activity.id) ? "chevron.right" : "chevron.down")
                        .font(.system(size: 8, weight: .semibold)).frame(width: 14, height: 24)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    "\(state.collapsed.contains(activity.id) ? "Expand" : "Collapse") \(activity.title)"
                )
                .accessibilityIdentifier("traceActivityDisclosure-\(activity.id)")
            } else {
                Image(systemName: activity.kind.symbol).font(.system(size: 9)).frame(width: 14)
            }
            Button {
                state.selectedActivityID = activity.id
            } label: {
                Text(activity.title).font(
                    .system(size: 10, weight: activity.kind == .subagent ? .semibold : .regular)
                )
                .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                "\(activity.kind.label): \(activity.title), \(activity.statusLabel)"
            )
            .accessibilityIdentifier("traceActivity-\(activity.id)")
        }
        .foregroundStyle(color)
        .padding(.leading, CGFloat(min(row.depth, 5)) * 10)
        .padding(.trailing, 6).frame(width: labelWidth)
    }

    private func bar(_ activity: CoreTraceActivity, width: CGFloat, color: Color, selected: Bool) -> some View {
        ZStack(alignment: .leading) {
            HStack(spacing: 0) {
                ForEach(0..<5) { tick in
                    if tick != 0 { Spacer(minLength: 0) }
                    Rectangle().fill(.primary.opacity(0.08)).frame(width: 1)
                }
            }
            if let start = activity.startedAt {
                let offset = timeline.fraction(start) * max(0, width - 8)
                let end = activity.end(at: now)
                let length = max(6, (timeline.fraction(end ?? start) - timeline.fraction(start)) * (width - 8))
                RoundedRectangle(cornerRadius: 4)
                    .fill(color.opacity(end == nil ? 0.08 : 0.18))
                    .overlay {
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(color.opacity(selected ? 1 : 0.65), lineWidth: selected ? 2 : 0.7)
                    }
                    .overlay {
                        if length > 58 {
                            Text(activity.durationLabel(at: now))
                                .font(.system(size: 9)).foregroundStyle(color).lineLimit(1).padding(.horizontal, 4)
                        }
                    }
                    .frame(width: length, height: activity.kind == .subagent ? 20 : 16)
                    .offset(x: offset)
            } else {
                Text("Start not recorded").font(.system(size: 9)).foregroundStyle(.secondary).padding(.leading, 6)
            }
        }
        .frame(width: width, height: 29)
        .contentShape(Rectangle())
    }

    private func tint(for activity: CoreTraceActivity) -> Color {
        if activity.status == .failed { return .roleOrange }
        if activity.status == .interrupted { return .secondary }
        return activity.kind == .subagent ? .rolePurple : color
    }
}
