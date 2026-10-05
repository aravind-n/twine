import SwiftUI

struct TraceActivityInspector: View {
    @Environment(TraceTerminalNavigation.self) private var navigation
    let activity: CoreTraceActivity
    let span: CoreTraceSpan
    let lane: CoreTraceLane
    let now: UInt64
    let close: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(activity.kind.label.uppercased(), systemImage: activity.kind.symbol)
                        .font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("Close activity", systemImage: "xmark", action: close)
                        .labelStyle(.iconOnly).buttonStyle(.plain).font(.caption2)
                        .accessibilityIdentifier("closeTraceActivity")
                }
                Text(activity.title).font(.caption.weight(.semibold)).textSelection(.enabled)
                HStack(spacing: 4) {
                    Image(systemName: statusSymbol)
                    Text(activity.statusLabel)
                    Text("· \(activity.durationLabel(at: now))")
                }
                .font(.caption2).foregroundStyle(activity.status == .failed ? Color.orange : .secondary)
                if let start = activity.startedAt {
                    Text("Started \(TraceFormatting.timestamp(start))")
                        .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                }
                preview(activity.kind == .subagent ? "ASSIGNMENT" : "INPUT", text: activity.input)
                preview("RESULT", text: activity.output)
                if activity.anchor != nil {
                    Button("Show recorded output", systemImage: "arrow.up.forward") {
                        navigation.jump(to: activity, lane: lane, fallbackTime: span.startedAt)
                    }
                    .controlSize(.small)
                    .accessibilityIdentifier("traceActivityJump")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }
        .background(.windowBackground)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("traceActivityInspector")
    }

    private var statusSymbol: String {
        switch activity.status {
        case .running: "circle.fill"
        case .completed: "checkmark.circle"
        case .failed: "exclamationmark.circle"
        case .interrupted: "stop.circle"
        }
    }

    private func preview(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
            Text(text.isEmpty ? "Not recorded" : text)
                .font(.system(size: 10, design: .monospaced))
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                .padding(7).background(.primary.opacity(0.035))
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(.primary.opacity(0.1), lineWidth: 0.5) }
        }
    }
}
