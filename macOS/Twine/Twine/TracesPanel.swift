import AppKit
import SwiftUI

struct TracesPanel: View {
    @Environment(CoreClient.self) private var coreClient
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let workflow: CoreWorkflow?
    @State private var isExpanded = false
    @State private var state = TracePanelState()
    @State private var loadOlderRequested = false

    private var summary: CoreTraceSummary? {
        coreClient.snapshot?.traces.first { $0.workflowID == workflow?.id }
    }

    private var readKey: String {
        "\(workflow?.id ?? 0):\(summary?.revision ?? 0):\(coreClient.traceSnapshotGeneration):\(isExpanded)"
    }

    private var logKey: String {
        "\(workflow?.id ?? 0):\(state.selectedSpanID ?? 0):\(summary?.revision ?? 0):\(isExpanded)"
    }

    var body: some View {
        VStack(spacing: 0) {
            TracesHeader(isExpanded: isExpanded, summary: summary) {
                withAnimation(reduceMotion ? nil : Motion.tracesToggle) { isExpanded.toggle() }
            }
            if isExpanded {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    expandedContent(now: TraceFormatting.milliseconds(context.date))
                }
                .frame(height: TracesLayout.expandedHeight - TracesLayout.collapsedHeight)
                .clipped()
            }
        }
        .background(.windowBackground)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.panel))
        .overlay {
            RoundedRectangle(cornerRadius: CornerRadius.panel)
                .strokeBorder(.tracesPanelHairline, lineWidth: Surface.hairlineWidth)
                .allowsHitTesting(false)
        }
        .task(id: readKey) {
            if isExpanded { await state.refresh(workflowID: workflow?.id, client: coreClient) }
        }
        .task(id: logKey) {
            if isExpanded { await state.loadEvents(client: coreClient) }
        }
        .task(id: loadOlderRequested) {
            if loadOlderRequested {
                await state.loadOlder(client: coreClient)
                loadOlderRequested = false
            }
        }
        .onChange(of: workflow?.id) { state.reset(workflowID: workflow?.id) }
    }

    private func expandedContent(now: UInt64) -> some View {
        GeometryReader { geometry in
            let layout = TracePanelLayout(width: geometry.size.width, showsDetails: state.selectedSpan != nil)
            HStack(spacing: 0) {
                timelineContent(now: now, labelWidth: layout.labelWidth)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let span = state.selectedSpan, let lane = state.selectedLane {
                    TraceDetailPanel(span: span, lane: lane, state: state, now: now) {
                        withAnimation(reduceMotion ? nil : Motion.traceDetailPanel) { state.selectedSpanID = nil }
                    }
                    .frame(width: layout.detailWidth)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
    }

    @ViewBuilder
    private func timelineContent(now: UInt64, labelWidth: CGFloat) -> some View {
        if state.spans.isEmpty {
            if state.isLoading {
                ProgressView("Loading traces…").controlSize(.small)
            } else if let failure = state.failureMessage {
                ContentUnavailableView(
                    "Traces Couldn't Load", systemImage: "exclamationmark.triangle",
                    description: Text(failure))
            } else {
                ContentUnavailableView(
                    "No traces yet", systemImage: "waveform.path",
                    description: Text("Activity appears here when a workflow runs.")
                )
                .accessibilityIdentifier("tracesEmptyState")
            }
        } else {
            VStack(spacing: 0) {
                TraceTimeline(
                    lanes: state.lanes, spans: state.spans,
                    selectedSpanID: state.selectedSpanID, now: now,
                    labelWidth: labelWidth
                ) { id in
                    withAnimation(reduceMotion ? nil : Motion.traceDetailPanel) { state.selectedSpanID = id }
                }
                HStack {
                    Text(state.failureMessage ?? "Select a span to inspect its events.")
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if state.nextBefore != nil {
                        Button("Older activity") { loadOlderRequested = true }
                            .buttonStyle(.borderless)
                            .disabled(state.isLoading)
                    }
                }
                .font(.caption2).foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .frame(height: TracesLayout.hintHeight)
            }
        }
    }
}
