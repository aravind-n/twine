//! Sessions and live workflow state for the open folder.

use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

use crate::harness::HarnessId;
use crate::terminal::TerminalId;

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub struct SessionId(pub u64);

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub struct WorkflowId(pub u64);

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub struct AgentId(pub u64);

/// The most agents one workflow can run. They all run at once, so this is the workflow types' limit
/// on agents running in parallel.
pub(crate) const MAX_AGENTS: usize = crate::workflow_type::MAX_PARALLEL_AGENTS as usize;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum WorkflowKind {
    Draft,
    Terminal,
    SingleAgent,
    /// One agent per role, each with its own terminal. Until harnesses can launch, every agent runs
    /// the default shell.
    Agents,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum WorkflowStatus {
    Running,
    Exited,
    Failed,
    /// The user stopped the agent.
    Cancelled,
    /// Twine quit or crashed while the work was running; it did not finish.
    Interrupted,
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
    /// The harness filling a single-agent workflow's role.
    pub harness: Option<HarnessId>,
    /// The workflow's own shell, or a single agent's harness. Zero when it couldn't restart, and for
    /// agents workflows, whose agents have the terminals instead.
    pub terminal_id: TerminalId,
    /// In role order. Empty unless the workflow's kind is [`WorkflowKind::Agents`].
    pub agents: Vec<Agent>,
    pub status: WorkflowStatus,
    pub started_at: u64,
    pub ended_at: Option<u64>,
    /// Restored workflow metadata now backed by fresh shells and new terminal transcripts.
    pub restored: bool,
}

/// One process filling one role in a workflow.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Agent {
    pub agent_id: AgentId,
    pub role: String,
    /// Zero when the agent's shell couldn't restart.
    pub terminal_id: TerminalId,
}

impl Workflow {
    /// Every process the workflow owns: its agents' in an agents workflow, and otherwise its own
    /// shell or harness. One that couldn't restart is zero.
    pub(crate) fn shells(&self) -> Vec<TerminalId> {
        match self.kind {
            WorkflowKind::Draft | WorkflowKind::Terminal | WorkflowKind::SingleAgent => {
                vec![self.terminal_id]
            }
            WorkflowKind::Agents => self.agents.iter().map(|agent| agent.terminal_id).collect(),
        }
    }

    /// The workflow's live shells.
    pub(crate) fn terminal_ids(&self) -> Vec<TerminalId> {
        self.shells()
            .into_iter()
            .filter(|terminal_id| terminal_id.value() != 0)
            .collect()
    }
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

/// Whether a session name or agent role is 1–200 characters on one line.
pub(crate) fn valid_name(name: &str) -> bool {
    !name.is_empty() && name.chars().count() <= 200 && !name.chars().any(char::is_control)
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
