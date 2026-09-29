//! Sessions and live workflow state for the open folder.

use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

use crate::terminal::TerminalId;

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub struct SessionId(pub u64);

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub struct WorkflowId(pub u64);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum WorkflowKind {
    Draft,
    Terminal,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum WorkflowStatus {
    Running,
    Exited,
    Failed,
    Closed,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SessionStatus {
    Active,
    Closed,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Session {
    pub session_id: SessionId,
    pub name: String,
    pub folder: PathBuf,
    pub status: SessionStatus,
    /// Unix time in milliseconds.
    pub started_at: u64,
    pub ended_at: Option<u64>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Workflow {
    pub workflow_id: WorkflowId,
    pub session_id: SessionId,
    pub name: String,
    pub kind: WorkflowKind,
    pub terminal_id: TerminalId,
    pub status: WorkflowStatus,
    pub started_at: u64,
    pub ended_at: Option<u64>,
    /// Restored workflow metadata now backed by a fresh shell, without its previous transcript.
    pub restored: bool,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct WorkflowState {
    /// Remembers that this folder has had sessions, even after the user deletes the last one.
    pub sessions_initialized: bool,
    /// The selected session. Selection is remembered per folder.
    pub session: Option<Session>,
    pub sessions: Vec<Session>,
    /// All workflows in the open folder, including sessions that aren't selected.
    pub workflows: Vec<Workflow>,
}

pub(crate) fn timestamp() -> u64 {
    u64::try_from(
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis(),
    )
    .unwrap_or(u64::MAX)
}
