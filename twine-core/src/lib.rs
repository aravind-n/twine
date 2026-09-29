//! UI-independent application core for Twine.

mod application;
pub mod config;
mod event;
mod terminal;

pub use application::{
    Application, ApplicationError, ApplicationState, Command, CommandDisposition, CommandReceipt,
    RequestId, Snapshot,
};
pub use event::{CommandResult, Event, EventError, EventKind, StateEvent};
pub use terminal::{TerminalChunk, TerminalError, TerminalId};
