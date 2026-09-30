//! UI-independent application core for Twine.

mod application;
pub mod config;
mod event;
mod files;
mod folder;
mod git;
mod store;
mod terminal;
mod workflow;
mod workflow_type;

pub use application::{
    Application, ApplicationError, ApplicationState, Command, CommandDisposition, CommandReceipt,
    RequestId, Snapshot,
};
pub use event::{CommandResult, Event, EventError, EventKind, StateEvent};
pub use files::{
    DirectoryListing, FileContent, FileEntry, FileError, FileKind, FilePreview, FileSnapshot,
    TEXT_LIMIT,
};
pub use folder::{FolderState, RecentFolder, UnavailableFolder, UnavailableReason};
pub use store::StoreError;
pub use terminal::{
    TerminalChunk, TerminalError, TerminalExit, TerminalId, TerminalSize, TerminalState,
    TerminalStatus,
};

pub use workflow::{
    Session, SessionId, SessionStatus, Workflow, WorkflowId, WorkflowKind, WorkflowState,
    WorkflowStatus,
};
pub use workflow_type::{
    BuiltinType, CatalogError, Completion, ElementPath, Handoff, HandoffContent, InstanceCount,
    MAX_PARALLEL_AGENTS, MAX_REVIEW_ROUNDS, ReviewLoop, Role, RoleId, Stage, StageId, StageRole,
    ValidationIssue, ValidationProblem, WorkflowType, WorkflowTypeDefinition, WorkflowTypeRef,
    validate,
};
