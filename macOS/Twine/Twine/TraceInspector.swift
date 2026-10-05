import SwiftUI

struct TraceInspector: View {
    @Environment(CoreClient.self) private var coreClient
    @Environment(\.traceLaneColors) private var laneColors
    let span: CoreTraceSpan
    let lane: CoreTraceLane
    @Bindable var state: TraceActivityState
    let now: UInt64
    @State private var moreRequested = false

    private var activities: [CoreTraceActivity] { state.spanID == span.id ? state.activities : [] }
    private var rows: [TraceActivityTimeline.Row] {
        TraceActivityTimeline.rows(
            activities: activities, collapsed: state.collapsed, search: state.search,
            failuresOnly: state.failuresOnly)
    }

    var body: some View {
        GeometryReader { geometry in
            let narrow = geometry.size.width < 680
            let layout = narrow ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
            layout {
                VStack(alignment: .leading, spacing: 0) {
                    toolbar
                    timeline
                    footer
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let activity = state.selectedActivity, state.spanID == span.id {
                    TraceActivityInspector(activity: activity, span: span, lane: lane, now: now) {
                        state.selectedActivityID = nil
                    }
                    .frame(width: narrow ? nil : min(280, geometry.size.width * 0.34))
                    .frame(height: narrow ? 130 : nil)
                    .overlay(alignment: narrow ? .top : .leading) {
                        if narrow { Divider() } else { Divider().frame(maxHeight: .infinity) }
                    }
                }
            }
        }
        .task(id: moreRequested) {
            if moreRequested {
                await state.refresh(spanID: span.id, workflowID: lane.workflowID, client: coreClient, more: true)
                moreRequested = false
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("traceTimelineInspector")
    }

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(span.title).font(.caption.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 0)
                Text(span.statusLabel).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(spacing: 8) {
                TextField("Find activity…", text: $state.search)
                    .textFieldStyle(.roundedBorder).font(.caption).frame(maxWidth: 210)
                    .accessibilityIdentifier("traceActivitySearch")
                Toggle("Failures", isOn: $state.failuresOnly)
                    .toggleStyle(.button).controlSize(.small)
                    .accessibilityIdentifier("traceFailuresOnly")
                Spacer(minLength: 0)
                Button(state.collapsed.isEmpty ? "Collapse" : "Expand") {
                    state.collapsed = state.collapsed.isEmpty ? Set(activities.compactMap(\.parentActivityID)) : []
                }
                .buttonStyle(.borderless).font(.caption2)
                .disabled(!activities.contains { $0.parentActivityID != nil })
                .accessibilityLabel(state.collapsed.isEmpty ? "Collapse all agents" : "Expand all agents")
                .accessibilityIdentifier("traceCollapseActivities")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    @ViewBuilder
    private var timeline: some View {
        if activities.isEmpty {
            VStack(spacing: 6) {
                if state.isLoading {
                    ProgressView("Loading activity…").controlSize(.small)
                } else {
                    Image(systemName: "timeline.selection").foregroundStyle(.secondary)
                    Text("No detailed activity recorded").font(.caption.weight(.semibold))
                    Text(emptyExplanation)
                        .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }
            .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("traceActivitiesEmpty")
        } else if rows.isEmpty {
            Text("No matching activity")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("traceActivitiesNoMatches")
        } else {
            TraceActivityChart(
                rows: rows, timeline: TraceActivityTimeline(span: span, activities: activities, now: now),
                state: state, color: TraceLaneStyle.color(for: lane, colors: laneColors), now: now)
        }
    }

    private var emptyExplanation: String {
        if lane.harness == "opencode" || lane.harness == "antigravity" {
            return "Detailed activity is not available for this harness yet. "
                + "Recorded steps and terminal output remain available in Standard."
        }
        return "This step has no recorded tools or subagents. Its event log is available in Standard."
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if let failure = state.failureMessage {
                Text(failure).lineLimit(2)
            } else {
                let tools = activities.filter { $0.kind == .tool }.count
                let agents = activities.filter { $0.kind == .subagent }.count
                Text("\(tools) tool calls · \(agents) subagents").lineLimit(1)
            }
            Spacer(minLength: 0)
            if state.isLoading && !activities.isEmpty { ProgressView().controlSize(.mini) }
            if state.nextAfter != nil {
                Button("More activity") { moreRequested = true }
                    .buttonStyle(.borderless).disabled(state.isLoading)
                    .accessibilityIdentifier("traceMoreActivity")
            }
        }
        .font(.caption2).foregroundStyle(.secondary)
        .padding(.horizontal, 12).padding(.vertical, 6)
    }
}
