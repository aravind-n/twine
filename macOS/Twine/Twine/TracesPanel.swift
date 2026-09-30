import AppKit
import SwiftUI

struct TracesPanel: View {
    @Environment(CoreClient.self) private var coreClient
    @Environment(TraceTerminalNavigation.self) private var navigation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let workflow: CoreWorkflow?
    @State private var isExpanded = false
    @State private var state = TracePanelState()
    @State private var loadOlderRequested = false
    @State private var jumpRequestedSpanID: UInt64?
    @State private var jumpRequestID = UUID()

    private var summary: CoreTraceSummary? {
        coreClient.snapshot?.traces.first { $0.workflowID == workflow?.id }
    }

    private var readKey: String {
        "\(workflow?.id ?? 0):\(summary?.revision ?? 0):\(coreClient.traceSnapshotGeneration):\(isExpanded)"
    }

    private var logKey: String {
        "\(workflow?.id ?? 0):\(state.selectedSpanID ?? 0):\(summary?.revision ?? 0):\(isExpanded):\(jumpRequestID)"
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
            if isExpanded {
                await state.loadEvents(client: coreClient)
                jumpToRequestedCommand()
            }
        }
        .task(id: loadOlderRequested) {
            if loadOlderRequested {
                await state.loadOlder(client: coreClient)
                loadOlderRequested = false
            }
        }
        .onChange(of: workflow?.id) {
            jumpRequestedSpanID = nil
            state.reset(workflowID: workflow?.id)
        }
    }

    private func jumpToRequestedCommand() {
        guard let id = jumpRequestedSpanID, state.selectedSpanID == id,
            let lane = state.selectedLane,
            let span = state.selectedSpan,
            state.events.contains(where: { $0.message == "Command started." && $0.anchor != nil })
        else { return }
        navigation.jump(toCommand: span, events: state.events, lane: lane)
        jumpRequestedSpanID = nil
    }

    private func expandedContent(now: UInt64) -> some View {
        GeometryReader { geometry in
            let layout = TracePanelLayout(width: geometry.size.width, showsDetails: state.selectedSpan != nil)
            HStack(spacing: 0) {
                sequenceContent(now: now, labelWidth: layout.labelWidth)
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
    private func sequenceContent(now: UInt64, labelWidth: CGFloat) -> some View {
        if state.spans.isEmpty {
            if state.isLoading {
                ProgressView("Loading activity…").controlSize(.small)
            } else if let failure = state.failureMessage {
                ContentUnavailableView(
                    "Activity Couldn't Load", systemImage: "exclamationmark.triangle",
                    description: Text(failure))
            } else {
                ContentUnavailableView(
                    "No activity yet", systemImage: "waveform.path",
                    description: Text("Activity appears here when a workflow runs.")
                )
                .accessibilityIdentifier("tracesEmptyState")
            }
        } else {
            VStack(spacing: 0) {
                TraceSequence(
                    lanes: state.lanes, spans: state.spans,
                    selectedSpanID: state.selectedSpanID, now: now,
                    labelWidth: labelWidth
                ) { id in
                    jumpRequestedSpanID = id
                    jumpRequestID = UUID()
                    withAnimation(reduceMotion ? nil : Motion.traceDetailPanel) { state.selectedSpanID = id }
                }
                HStack {
                    Text(state.failureMessage ?? "Steps are spaced by start order.")
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
