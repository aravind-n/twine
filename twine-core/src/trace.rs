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
    pub name: String,
    pub is_agent: bool,
    pub role: Option<String>,
    pub harness: Option<String>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TraceSpanStatus {
    Running,
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
    /// True only while this application owns the corresponding running process.
    /// A historical open span has an unrecorded ending, rather than an invented completion.
    pub is_live: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct TraceAnchor {
    pub terminal_id: TerminalId,
    /// The exclusive boundary after output observed when the event happened.
    pub byte_offset: u64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TraceEventKind {
    ProcessStarted,
    ProcessExited,
    ProcessFailed,
    ProcessStopped,
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
