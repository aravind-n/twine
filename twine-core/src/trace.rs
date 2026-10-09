//! Durable records of activity Twine performs or observes, separate from terminal bytes.

use thiserror::Error;

use crate::{TerminalId, WorkflowId};

pub const MAX_TRACE_PAGE_SIZE: usize = 200;

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub struct TraceLaneId(pub u64);

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub struct TraceSpanId(pub u64);

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub struct TraceEventId(pub u64);

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TraceLane {
    pub lane_id: TraceLaneId,
    pub workflow_id: WorkflowId,
    pub agent_id: Option<crate::AgentId>,
    pub name: String,
    pub is_agent: bool,
    pub role: Option<String>,
    pub harness: Option<String>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TraceSpanStatus {
    Running,
    Completed,
    Exited,
    Failed,
    Stopped,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TraceSpan {
    pub span_id: TraceSpanId,
    pub lane_id: TraceLaneId,
    pub title: String,
    /// Unix milliseconds; ordering is also preserved by stable record IDs.
    pub started_at: u64,
    pub ended_at: Option<u64>,
    pub status: TraceSpanStatus,
    pub terminal_id: Option<TerminalId>,
    /// True while this application owns the active assignment or corresponding running process.
    /// A historical open span has an unrecorded ending, rather than an invented completion.
    pub is_live: bool,
}

#[derive(Clone, Debug, Eq, PartialEq, serde::Deserialize, serde::Serialize)]
pub struct TraceAnchor {
    pub terminal_id: TerminalId,
    /// The exclusive boundary after output observed when the event happened.
    pub byte_offset: u64,
    /// Ordered resizes at this exact boundary when the event was observed. `None` means unavailable.
    pub boundary_sizes: Option<Vec<crate::TerminalSize>>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TraceEventKind {
    ProcessStarted,
    ProcessExited,
    ProcessFailed,
    ProcessStopped,
    WorkflowEvent,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TraceEvent {
    pub event_id: TraceEventId,
    pub workflow_id: WorkflowId,
    pub span_id: Option<TraceSpanId>,
    pub timestamp: u64,
    pub kind: TraceEventKind,
    pub message: String,
    pub anchor: Option<TraceAnchor>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TraceSummary {
    pub workflow_id: WorkflowId,
    /// Last durable event ID for this workflow. Independent of the transient event journal.
    pub revision: u64,
    pub span_count: u64,
    pub agent_count: u64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WorkflowTracePage {
    pub summary: TraceSummary,
    pub lanes: Vec<TraceLane>,
    /// Most recent spans first. The cursor reads older spans.
    pub spans: Vec<TraceSpan>,
    pub next_before: Option<TraceSpanId>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TraceEventsPage {
    pub workflow_id: WorkflowId,
    pub span_id: TraceSpanId,
    pub revision: u64,
    pub events: Vec<TraceEvent>,
    pub next_after: Option<TraceEventId>,
}

/// Durable native tool or subagent identity within a prompt or assignment.
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub struct TraceActivityId(pub u64);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TraceActivityKind {
    Tool,
    Subagent,
    Model,
    Note,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TraceActivityStatus {
    Running,
    Completed,
    Failed,
    Interrupted,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TraceActivity {
    pub activity_id: TraceActivityId,
    pub span_id: TraceSpanId,
    pub parent_activity_id: Option<TraceActivityId>,
    pub kind: TraceActivityKind,
    pub title: String,
    /// Missing endpoints remain missing; observers do not invent elapsed time.
    pub started_at: Option<u64>,
    pub ended_at: Option<u64>,
    pub status: TraceActivityStatus,
    pub input: String,
    pub output: String,
    pub anchor: Option<TraceAnchor>,
    pub metadata: serde_json::Value,
    pub input_bytes: Option<u64>,
    pub output_bytes: Option<u64>,
    pub input_version: Option<String>,
    pub output_version: Option<String>,
}

#[derive(Clone, Debug, Default, Eq, PartialEq, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TraceActivityCounts {
    pub tools: u64,
    pub subagents: u64,
    pub models: u64,
    pub notes: u64,
    pub failures: u64,
}

#[derive(Clone, Debug, Eq, PartialEq, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TraceDetailPage {
    pub activity_id: u64,
    pub output: bool,
    pub offset: u64,
    pub next_offset: Option<u64>,
    pub total_bytes: u64,
    pub text: String,
    pub version: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TraceStorageStatus {
    pub payload_bytes: u64,
    pub payload_files: u64,
    pub budget_bytes: u64,
    pub retention_days: u32,
    pub updated_at: u64,
    pub pinned: bool,
    pub clear_generation: u64,
    pub completed_clear_generation: u64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TraceActivitiesPage {
    pub workflow_id: WorkflowId,
    pub span_id: TraceSpanId,
    pub revision: u64,
    pub activities: Vec<TraceActivity>,
    pub next_after: Option<TraceActivityId>,
    pub counts: TraceActivityCounts,
}

#[derive(Debug, Error)]
pub enum TraceError {
    #[error("trace page size must be between 1 and {MAX_TRACE_PAGE_SIZE}")]
    InvalidLimit,
    #[error("the workflow does not exist")]
    WorkflowNotFound,
    #[error("the trace span does not exist")]
    SpanNotFound,
    #[error(transparent)]
    Store(#[from] crate::StoreError),
}

pub(crate) fn validate_limit(limit: usize) -> Result<(), TraceError> {
    if !(1..=MAX_TRACE_PAGE_SIZE).contains(&limit) {
        return Err(TraceError::InvalidLimit);
    }
    Ok(())
}
