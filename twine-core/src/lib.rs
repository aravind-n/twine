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
