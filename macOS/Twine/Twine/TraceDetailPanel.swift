import AppKit
import SwiftUI

struct TraceDetailPanel: View {
    @Environment(BridgeClient.self) private var bridgeClient
    let span: BridgeTraceSpan
    let lane: BridgeTraceLane
    @Bindable var state: TracePanelState
    let now: UInt64
    let close: () -> Void
    @State private var copyRequested: UInt64?
    @State private var moreRequested = false
    @State private var copyFailure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            HStack(spacing: 6) {
                Image(systemName: span.statusSymbol)
                    .foregroundStyle(span.status == .failed ? Color.orange : .secondary)
                Text(copyFailure ?? state.events.last?.message ?? span.statusLabel)
                    .lineLimit(1).font(.caption)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(state.events) { event in logRow(event) }
                    if state.isLoadingEvents { ProgressView().controlSize(.small).padding(8) }
                    if let failure = state.logFailureMessage {
                        Text(failure).font(.caption).foregroundStyle(.secondary).padding(8)
                    }
                    if state.nextAfter != nil {
                        Button("More events") { moreRequested = true }.buttonStyle(.borderless).padding(8)
                            .disabled(state.isLoadingEvents)
                    }
                }
            }
            .accessibilityIdentifier("traceEventLog")
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.secondarySurface)
        .overlay(alignment: .leading) { Divider() }
        .accessibilityIdentifier("traceDetailPanel")
        .task(id: copyRequested) {
            guard let id = copyRequested else { return }
            defer { copyRequested = nil }
            do {
                let log = try await state.completeLog(spanID: id, client: bridgeClient)
                try Task.checkCancellation()
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(log, forType: .string)
                copyFailure = nil
            } catch is CancellationError {
                return
            } catch {
                copyFailure = "Log couldn't be copied."
            }
        }
        .task(id: moreRequested) {
            if moreRequested {
                await state.loadEvents(client: bridgeClient, more: true)
                moreRequested = false
            }
        }
        .onChange(of: span.id) {
            copyRequested = nil
            copyFailure = nil
        }
    }

    private var durationLabel: String {
        span.isLive || span.endedAt != nil
            ? TraceFormatting.elapsed(span.end(at: now) - span.startedAt) : "end unknown"
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: TraceLaneStyle.symbol(for: lane)).foregroundStyle(TraceLaneStyle.color(for: lane))
            VStack(alignment: .leading, spacing: 2) {
                Text(span.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(
                    "\(lane.name) · \(durationLabel)"
                )
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Button("Copy log", systemImage: "doc.on.doc") { copyRequested = span.id }
                .labelStyle(.iconOnly).buttonStyle(.glass).controlSize(.small)
                .disabled(copyRequested != nil || state.logFailureMessage != nil)
                .accessibilityIdentifier("copyTraceLog")
            Button("Close details", systemImage: "xmark", action: close)
                .labelStyle(.iconOnly).buttonStyle(.glass).controlSize(.small)
                .accessibilityIdentifier("closeTraceDetails")
        }
        .padding(.horizontal, 12)
        .frame(height: TracesLayout.collapsedHeight)
    }

    private func logRow(_ event: BridgeTraceEvent) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(TraceFormatting.timestamp(event.timestamp)).foregroundStyle(.secondary)
                Text(event.kind.label).foregroundStyle(TraceLaneStyle.color(for: lane))
            }
            .logMetadataStyle()
            Text(event.message).font(.caption).textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .overlay(alignment: .bottom) { Divider().opacity(0.5) }
    }
}
