use serde::Serialize;
use twine_core::{
    TraceEvent, TraceEventKind, TraceEventsPage, TraceLane, TraceSpan, TraceSpanStatus,
    TraceSummary, WorkflowTracePage,
};

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct WireTraceSummary {
    workflow_id: u64,
    revision: u64,
    span_count: u64,
    agent_count: u64,
}

impl From<&TraceSummary> for WireTraceSummary {
    fn from(summary: &TraceSummary) -> Self {
        Self {
            workflow_id: summary.workflow_id.0,
            revision: summary.revision,
            span_count: summary.span_count,
            agent_count: summary.agent_count,
        }
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct WireLane<'a> {
    lane_id: u64,
    workflow_id: u64,
    agent_id: Option<u64>,
    name: &'a str,
    is_agent: bool,
    role: Option<&'a str>,
    harness: Option<&'a str>,
}

impl<'a> From<&'a TraceLane> for WireLane<'a> {
    fn from(lane: &'a TraceLane) -> Self {
        Self {
            lane_id: lane.lane_id.0,
            workflow_id: lane.workflow_id.0,
            agent_id: lane.agent_id.map(|id| id.0),
            name: &lane.name,
            is_agent: lane.is_agent,
            role: lane.role.as_deref(),
            harness: lane.harness.as_deref(),
        }
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct WireSpan<'a> {
    span_id: u64,
    lane_id: u64,
    title: &'a str,
    started_at: u64,
    ended_at: Option<u64>,
    status: &'static str,
    terminal_id: Option<u64>,
    is_live: bool,
}

impl<'a> From<&'a TraceSpan> for WireSpan<'a> {
    fn from(span: &'a TraceSpan) -> Self {
        Self {
            span_id: span.span_id.0,
            lane_id: span.lane_id.0,
            title: &span.title,
            started_at: span.started_at,
            ended_at: span.ended_at,
            terminal_id: span.terminal_id.map(twine_core::TerminalId::value),
            is_live: span.is_live,
            status: match span.status {
                TraceSpanStatus::Running => "running",
                TraceSpanStatus::Completed => "completed",
                TraceSpanStatus::Exited => "exited",
                TraceSpanStatus::Failed => "failed",
                TraceSpanStatus::Stopped => "stopped",
            },
        }
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct WireAnchor {
    terminal_id: u64,
    byte_offset: u64,
    boundary_sizes: Option<Vec<WireSize>>,
}

#[derive(Serialize)]
struct WireSize {
    rows: u16,
    columns: u16,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct WireTraceEvent<'a> {
    event_id: u64,
    workflow_id: u64,
    span_id: Option<u64>,
    timestamp: u64,
    kind: &'static str,
    message: &'a str,
    anchor: Option<WireAnchor>,
}

impl<'a> From<&'a TraceEvent> for WireTraceEvent<'a> {
    fn from(event: &'a TraceEvent) -> Self {
        Self {
            event_id: event.event_id.0,
            workflow_id: event.workflow_id.0,
            span_id: event.span_id.map(|id| id.0),
            timestamp: event.timestamp,
            message: &event.message,
            anchor: event.anchor.as_ref().map(|anchor| WireAnchor {
                terminal_id: anchor.terminal_id.value(),
                byte_offset: anchor.byte_offset,
                boundary_sizes: anchor.boundary_sizes.as_ref().map(|sizes| {
                    sizes
                        .iter()
                        .map(|size| WireSize {
                            rows: size.rows,
                            columns: size.columns,
                        })
                        .collect()
                }),
            }),
            kind: match event.kind {
                TraceEventKind::ProcessStarted => "processStarted",
                TraceEventKind::ProcessExited => "processExited",
                TraceEventKind::ProcessFailed => "processFailed",
                TraceEventKind::ProcessStopped => "processStopped",
                TraceEventKind::WorkflowEvent => "workflowEvent",
            },
        }
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct WireWorkflowTracePage<'a> {
    summary: WireTraceSummary,
    lanes: Vec<WireLane<'a>>,
    spans: Vec<WireSpan<'a>>,
    next_before: Option<u64>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct WireTraceEventsPage<'a> {
    workflow_id: u64,
    span_id: u64,
    revision: u64,
    events: Vec<WireTraceEvent<'a>>,
    next_after: Option<u64>,
}

pub(crate) fn encode_workflow_trace(
    page: &WorkflowTracePage,
) -> Result<Vec<u8>, serde_json::Error> {
    serde_json::to_vec(&WireWorkflowTracePage {
        summary: (&page.summary).into(),
        lanes: page.lanes.iter().map(Into::into).collect(),
        spans: page.spans.iter().map(Into::into).collect(),
        next_before: page.next_before.map(|id| id.0),
    })
}

pub(crate) fn encode_trace_events(page: &TraceEventsPage) -> Result<Vec<u8>, serde_json::Error> {
    serde_json::to_vec(&WireTraceEventsPage {
        workflow_id: page.workflow_id.0,
        span_id: page.span_id.0,
        revision: page.revision,
        events: page.events.iter().map(Into::into).collect(),
        next_after: page.next_after.map(|id| id.0),
    })
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct WireActivity<'a> {
    activity_id: u64,
    span_id: u64,
    parent_activity_id: Option<u64>,
    kind: &'static str,
    title: &'a str,
    started_at: Option<u64>,
    ended_at: Option<u64>,
    status: &'static str,
    input: &'a str,
    output: &'a str,
    anchor: Option<WireAnchor>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct WireActivitiesPage<'a> {
    workflow_id: u64,
    span_id: u64,
    revision: u64,
    activities: Vec<WireActivity<'a>>,
    next_after: Option<u64>,
}

pub(crate) fn encode_trace_activities(
    page: &twine_core::TraceActivitiesPage,
) -> Result<Vec<u8>, serde_json::Error> {
    use twine_core::{TraceActivityKind, TraceActivityStatus};
    serde_json::to_vec(&WireActivitiesPage {
        workflow_id: page.workflow_id.0,
        span_id: page.span_id.0,
        revision: page.revision,
        next_after: page.next_after.map(|id| id.0),
        activities: page
            .activities
            .iter()
            .map(|a| WireActivity {
                activity_id: a.activity_id.0,
                span_id: a.span_id.0,
                parent_activity_id: a.parent_activity_id.map(|id| id.0),
                kind: match a.kind {
                    TraceActivityKind::Tool => "tool",
                    TraceActivityKind::Subagent => "subagent",
                },
                title: &a.title,
                started_at: a.started_at,
                ended_at: a.ended_at,
                status: match a.status {
                    TraceActivityStatus::Running => "running",
                    TraceActivityStatus::Completed => "completed",
                    TraceActivityStatus::Failed => "failed",
                    TraceActivityStatus::Interrupted => "interrupted",
                },
                input: &a.input,
                output: &a.output,
                anchor: a.anchor.as_ref().map(|anchor| WireAnchor {
                    terminal_id: anchor.terminal_id.value(),
                    byte_offset: anchor.byte_offset,
                    boundary_sizes: anchor.boundary_sizes.as_ref().map(|sizes| {
                        sizes
                            .iter()
                            .map(|size| WireSize {
                                rows: size.rows,
                                columns: size.columns,
                            })
                            .collect()
                    }),
                }),
            })
            .collect(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use twine_core::{TerminalId, TraceAnchor, TraceEventId, TraceSpanId, WorkflowId};

    #[test]
    fn work_completion_is_distinct_from_legacy_process_exit_on_the_wire() {
        for (status, name) in [
            (TraceSpanStatus::Completed, "completed"),
            (TraceSpanStatus::Exited, "exited"),
        ] {
            let span = TraceSpan {
                span_id: TraceSpanId(1),
                lane_id: twine_core::TraceLaneId(1),
                title: "Work".into(),
                started_at: 100,
                ended_at: Some(200),
                status,
                terminal_id: Some(TerminalId::from_value(99)),
                is_live: false,
            };
            let value = serde_json::to_value(WireSpan::from(&span)).unwrap();
            assert_eq!(value["status"], name);
        }
    }

    #[test]
    fn event_pages_keep_optional_anchors_and_cursor_ids() {
        let mut page = TraceEventsPage {
            workflow_id: WorkflowId(4),
            span_id: TraceSpanId(5),
            revision: 7,
            next_after: Some(TraceEventId(7)),
            events: vec![TraceEvent {
                event_id: TraceEventId(7),
                workflow_id: WorkflowId(4),
                span_id: Some(TraceSpanId(5)),
                timestamp: 123,
                kind: TraceEventKind::ProcessExited,
                message: "Process exited with code 0.".into(),
                anchor: Some(TraceAnchor {
                    terminal_id: TerminalId::from_value(99),
                    byte_offset: 42,
                    boundary_sizes: Some(Vec::new()),
                }),
            }],
        };
        let json: serde_json::Value =
            serde_json::from_slice(&encode_trace_events(&page).unwrap()).unwrap();
        assert_eq!(
            json["events"][0]["anchor"],
            serde_json::json!({"terminalId": 99, "byteOffset": 42, "boundarySizes": []})
        );
        assert_eq!(json["nextAfter"], 7);
        page.events[0].anchor = None;
        page.next_after = None;
        let json: serde_json::Value =
            serde_json::from_slice(&encode_trace_events(&page).unwrap()).unwrap();
        assert!(json["events"][0]["anchor"].is_null());
        assert!(json["nextAfter"].is_null());
    }
}
