import AppKit
import SwiftUI

struct TracesPanel: View {
    @Environment(CoreClient.self) private var coreClient
    @Environment(TraceTerminalNavigation.self) private var navigation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let workflows: [CoreWorkflow]
    private var workflowIDs: [UInt64] { workflows.map(\.id) }
    @State private var isExpanded = false
    private var state: TracePanelState { navigation.activity }
    @State private var loadOlderRequested = false

    private var summaries: [CoreTraceSummary] {
        coreClient.snapshot?.traces.filter { workflowIDs.contains($0.workflowID) } ?? []
    }

    private var summary: CoreTraceSummary? {
        guard let id = workflowIDs.first else { return nil }
        return CoreTraceSummary(
            workflowID: id, revision: summaries.map(\.revision).max() ?? 0,
            spanCount: summaries.reduce(0) { $0 + $1.spanCount },
            agentCount: summaries.reduce(0) { $0 + $1.agentCount })
    }

    private var readKey: String {
        workflowIDs.map(String.init).joined(separator: ",") + ":"
            + summaries.map { "\($0.workflowID):\($0.revision)" }.joined(separator: ",")
            + ":\(coreClient.traceSnapshotGeneration)"
    }

    private var logKey: String {
        "\(readKey):\(state.selectedSpanID ?? 0):\(isExpanded):\(navigation.selectionRevision)"
    }

    private var displayLanes: [CoreTraceLane] {
        state.lanes.map { lane in
            guard workflows.count > 1, let index = workflowIDs.firstIndex(of: lane.workflowID) else { return lane }
            return CoreTraceLane(
                laneID: lane.id, workflowID: lane.workflowID,
                name: "\(workflows[index].name) · \(index + 1)", isAgent: lane.isAgent,
                role: lane.role, harness: lane.harness, agentID: lane.agentID)
        }
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
            await state.refresh(workflowIDs: workflowIDs, client: coreClient)
            if !Task.isCancelled { await navigation.minimap.refresh(activity: state, client: coreClient) }
        }
        .task(id: logKey) {
            if isExpanded {
                await state.loadEvents(client: coreClient)
                if !Task.isCancelled { await navigation.jumpToSelectedSpan(client: coreClient) }
            }
        }
        .task(id: loadOlderRequested) {
            if loadOlderRequested {
                await state.loadOlder(client: coreClient)
                if !Task.isCancelled { await navigation.minimap.refresh(activity: state, client: coreClient) }
                loadOlderRequested = false
            }
        }
        .onChange(of: workflowIDs) {
            navigation.requestedSpanID = nil
        }
        .onChange(of: navigation.selectionRevision) {
            withAnimation(reduceMotion ? nil : Motion.tracesToggle) { isExpanded = true }
        }
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
                ProgressView("Loading traces…").controlSize(.small)
            } else if let failure = state.failureMessage {
                ContentUnavailableView(
                    "Traces Couldn't Load", systemImage: "exclamationmark.triangle",
                    description: Text(failure))
            } else {
                ContentUnavailableView(
                    "No traces yet", systemImage: "waveform.path",
                    description: Text("Traces appear here when a workflow runs.")
                )
                .accessibilityIdentifier("tracesEmptyState")
            }
        } else {
            VStack(spacing: 0) {
                TraceSequence(
                    lanes: displayLanes, spans: state.spans,
                    selectedSpanID: state.selectedSpanID, now: now,
                    labelWidth: labelWidth
                ) { id in
                    withAnimation(reduceMotion ? nil : Motion.traceDetailPanel) { navigation.selectSpan(id) }
                }
                HStack {
                    Text(navigation.failureMessage ?? state.failureMessage ?? "Steps are spaced by start order.")
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if state.nextBefore != nil {
                        Button("Older traces") { loadOlderRequested = true }
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
