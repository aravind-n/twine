//! UI-independent application core for Twine.

mod application;
pub mod config;
mod event;
mod folder;
mod store;
mod terminal;

pub use application::{
    Application, ApplicationError, ApplicationState, Command, CommandDisposition, CommandReceipt,
    RequestId, Snapshot,
};
pub use event::{CommandResult, Event, EventError, EventKind, StateEvent};
pub use folder::{FolderState, RecentFolder, UnavailableFolder, UnavailableReason};
pub use store::StoreError;
pub use terminal::{
    TerminalChunk, TerminalError, TerminalExit, TerminalId, TerminalSize, TerminalState,
    TerminalStatus,
};
