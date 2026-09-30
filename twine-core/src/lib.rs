//! UI-independent application core for Twine.

mod application;
pub mod config;
mod event;
mod files;
mod folder;
mod git;
mod harness;
mod store;
mod terminal;
mod trace;
mod workflow;
mod workflow_run;
mod workflow_type;
pub use workflow_run::{
    Assignment, CompletionSignal, Decision, RoleLaunch, RunAgent, RunAgentStatus, RunError,
    RunStatus, WorkflowRun, WorkflowTrace,
};

pub use application::{
    Application, ApplicationError, ApplicationState, Command, CommandDisposition, CommandReceipt,
    RequestId, Snapshot,
};
pub use event::{CommandResult, Event, EventError, EventKind, StateEvent};
pub use files::{
    DirectoryListing, FileContent, FileEntry, FileError, FileKind, FilePreview, FileSaveOutcome,
    FileSaveRequest, FileSnapshot, FileVersion, TEXT_LIMIT,
};
pub use folder::{FolderState, RecentFolder, UnavailableFolder, UnavailableReason};
pub use harness::{HarnessError, HarnessId};
pub use store::StoreError;
pub use terminal::{
    MAX_TRANSCRIPT_READ_BYTES, TerminalChunk, TerminalError, TerminalExit, TerminalId,
    TerminalSize, TerminalState, TerminalStatus, TranscriptError, TranscriptPage, TranscriptRead,
    TranscriptRequest, TranscriptSize,
};

pub use workflow::{
    Agent, AgentId, Session, SessionId, SessionStatus, Workflow, WorkflowId, WorkflowKind,
    WorkflowState, WorkflowStatus,
};
pub use workflow_type::{
    BuiltinType, CatalogError, Completion, ElementPath, Handoff, HandoffContent, InstanceCount,
    MAX_PARALLEL_AGENTS, MAX_REVIEW_ROUNDS, ReviewLoop, Role, RoleId, Stage, StageId, StageRole,
    ValidationIssue, ValidationProblem, WorkflowType, WorkflowTypeDefinition, WorkflowTypeRef,
    validate,
};

pub use trace::{
    MAX_TRACE_PAGE_SIZE, TraceAnchor, TraceError, TraceEvent, TraceEventId, TraceEventKind,
    TraceEventsPage, TraceLane, TraceLaneId, TraceSpan, TraceSpanId, TraceSpanStatus, TraceSummary,
    WorkflowTracePage,
};
