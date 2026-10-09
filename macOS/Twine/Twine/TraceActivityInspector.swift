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
                if let metadata = activity.metadata {
                    if let model = metadata.model { Text(model).font(.caption).textSelection(.enabled) }
                    if let input = metadata.inputTokens { Text("\(input) input tokens").font(.caption2) }
                    if let output = metadata.outputTokens { Text("\(output) output tokens").font(.caption2) }
                    if let cached = metadata.cacheReadTokens { Text("\(cached) cached tokens").font(.caption2) }
                    if let written = metadata.cacheWriteTokens { Text("\(written) cache write tokens").font(.caption2) }
                    if let reasoning = metadata.reasoningTokens {
                        Text("\(reasoning) reasoning tokens").font(.caption2)
                    }
                    if let total = metadata.totalTokens { Text("\(total) total tokens").font(.caption2) }
                    if let reason = metadata.stopReason { Text("Stop reason: \(reason)").font(.caption2) }
                    if let response = metadata.responseId {
                        Text("Response: \(response)").font(.caption2).textSelection(.enabled)
                    }
                    if let event = metadata.event { Text(event).font(.caption2) }
                    if let trigger = metadata.trigger { Text("Trigger: \(trigger)").font(.caption2) }
                    if let kind = metadata.notificationType { Text(kind).font(.caption2) }
                    if let format = metadata.recordFormat { Text("Full details: \(format)").font(.caption2) }
                    if let cost = metadata.cost {
                        Text("Cost: \(cost, format: .currency(code: "USD").precision(.fractionLength(6)))").font(
                            .caption2)
                    }
                    if let source = metadata.source { Text(source).font(.caption2).foregroundStyle(.secondary) }
                }
                if let start = activity.startedAt {
                    Text("Started \(TraceFormatting.timestamp(start))")
                        .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                }
                TraceDetailText(
                    activityID: activity.id, output: false,
                    title: activity.kind == .subagent ? "ASSIGNMENT" : (activity.metadata?.inputKind ?? "INPUT"),
                    preview: activity.input, fullBytes: activity.inputBytes, version: activity.inputVersion
                )
                .id("\(activity.id)-input-\(activity.inputVersion ?? String(activity.input.hashValue))")
                TraceDetailText(
                    activityID: activity.id, output: true,
                    title: activity.kind == .model ? "RESPONSE / SUMMARY" : "RESULT",
                    preview: activity.output, fullBytes: activity.outputBytes, version: activity.outputVersion
                )
                .id("\(activity.id)-output-\(activity.outputVersion ?? String(activity.output.hashValue))")
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

private struct TraceDetailText: View {
    @Environment(CoreClient.self) private var client
    let activityID: UInt64
    let output: Bool
    let title: String
    let preview: String
    let fullBytes: UInt64?
    let version: String?
    @State private var text: String?
    @State private var next: UInt64?
    @State private var requestedOffset: UInt64?
    @State private var loading = false
    @State private var failure: String?
    @State private var requestNonce = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
            Text(text ?? (preview.isEmpty ? "Not recorded" : preview))
                .font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(7).background(.primary.opacity(0.035))
            if text == nil, let fullBytes, fullBytes > UInt64(preview.utf8.count) {
                Button("Show full details") {
                    requestedOffset = 0
                    requestNonce += 1
                }.disabled(loading)
                    .accessibilityIdentifier(output ? "traceFullOutput" : "traceFullInput")
            } else if let next {
                Button("More details") {
                    requestedOffset = next
                    requestNonce += 1
                }.disabled(loading)
            }
            if let failure { Text(failure).font(.caption2).foregroundStyle(.secondary) }
        }
        .task(id: requestNonce) {
            guard let offset = requestedOffset else { return }
            loading = true
            defer { loading = false }
            do {
                let page = try await client.traceDetail(activityID: activityID, output: output, offset: offset)
                try Task.checkCancellation()
                guard page.activityId == activityID, page.output == output, page.offset == offset,
                    page.version == version,
                    page.nextOffset == nil || (page.nextOffset ?? 0) > offset
                else {
                    throw CoreFailure.unexpectedCommandResult
                }
                text = offset == 0 ? page.text : (text ?? "") + page.text
                next = page.nextOffset
                failure = nil
            } catch is CancellationError { return } catch {
                failure = "Full details couldn't load. The recorded preview is shown."
            }
        }
    }
}
