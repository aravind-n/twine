use std::path::{Path, PathBuf};

use super::RawTerminalSize;
use crate::error::BridgeError;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use twine_core::{
    Command, Session, SessionId, SessionStatus, TerminalSize, Workflow, WorkflowId, WorkflowKind,
    WorkflowState, WorkflowStatus,
};

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct WireWorkflowState<'a> {
    sessions_initialized: bool,
    sessions: Vec<WireSession<'a>>,
    session: Option<WireSession<'a>>,
    workflows: Vec<WireWorkflow<'a>>,
}

impl<'a> From<&'a WorkflowState> for WireWorkflowState<'a> {
    fn from(state: &'a WorkflowState) -> Self {
        Self {
            sessions_initialized: state.sessions_initialized,
            sessions: state.sessions.iter().map(Into::into).collect(),
            session: state.session.as_ref().map(Into::into),
            workflows: state.workflows.iter().map(Into::into).collect(),
        }
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct WireSession<'a> {
    session_id: u64,
    name: &'a str,
    folder: &'a Path,
    status: &'static str,
    started_at: u64,
    ended_at: Option<u64>,
}

impl<'a> From<&'a Session> for WireSession<'a> {
    fn from(session: &'a Session) -> Self {
        Self {
            session_id: session.session_id.0,
            name: &session.name,
            folder: &session.folder,
            status: match session.status {
                SessionStatus::Active => "active",
                SessionStatus::Closed => "closed",
            },
            started_at: session.started_at,
            ended_at: session.ended_at,
        }
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct WireWorkflow<'a> {
    restored: bool,
    workflow_id: u64,
    session_id: u64,
    name: &'a str,
    kind: &'static str,
    terminal_id: u64,
    status: &'static str,
    started_at: u64,
    ended_at: Option<u64>,
}

impl<'a> From<&'a Workflow> for WireWorkflow<'a> {
    fn from(workflow: &'a Workflow) -> Self {
        Self {
            restored: workflow.restored,
            workflow_id: workflow.workflow_id.0,
            session_id: workflow.session_id.0,
            name: &workflow.name,
            kind: match workflow.kind {
                WorkflowKind::Draft => "draft",
                WorkflowKind::Terminal => "terminal",
            },
            terminal_id: workflow.terminal_id.value(),
            status: match workflow.status {
                WorkflowStatus::Running => "running",
                WorkflowStatus::Exited => "exited",
                WorkflowStatus::Failed => "failed",
                WorkflowStatus::Closed => "closed",
            },
            started_at: workflow.started_at,
            ended_at: workflow.ended_at,
        }
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawCreateWorkflow {
    session_id: Option<u64>,
    folder: PathBuf,
    kind: RawWorkflowKind,
    size: RawTerminalSize,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
enum RawWorkflowKind {
    Draft,
    Terminal,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawWorkflowId {
    workflow_id: u64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawDraftName {
    workflow_id: u64,
    name: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawCreateSession {
    folder: PathBuf,
    name: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawSessionCommand {
    session_id: u64,
    name: Option<String>,
}

pub(super) fn decode_command(command_type: &str, raw: &Value) -> Result<Command, BridgeError> {
    match command_type {
        "createSession" => {
            let command: RawCreateSession =
                serde_json::from_value(raw.clone()).map_err(|_| BridgeError::MalformedCommand)?;
            Ok(Command::CreateSession {
                folder: command.folder,
                name: command.name,
            })
        }
        "renameSession" | "selectSession" | "deleteSession" => {
            let command: RawSessionCommand =
                serde_json::from_value(raw.clone()).map_err(|_| BridgeError::MalformedCommand)?;
            let session_id = SessionId(command.session_id);
            Ok(match command_type {
                "renameSession" => Command::RenameSession {
                    session_id,
                    name: command.name.ok_or(BridgeError::MalformedCommand)?,
                },
                "selectSession" => Command::SelectSession { session_id },
                _ => Command::DeleteSession { session_id },
            })
        }
        "createWorkflow" => {
            let command: RawCreateWorkflow =
                serde_json::from_value(raw.clone()).map_err(|_| BridgeError::MalformedCommand)?;
            Ok(Command::CreateWorkflow {
                folder: command.folder,
                session_id: command.session_id.map(SessionId),
                kind: match command.kind {
                    RawWorkflowKind::Draft => WorkflowKind::Draft,
                    RawWorkflowKind::Terminal => WorkflowKind::Terminal,
                },
                size: TerminalSize {
                    rows: command.size.rows,
                    columns: command.size.columns,
                    pixel_width: command.size.pixel_width,
                    pixel_height: command.size.pixel_height,
                },
            })
        }
        "activateWorkflow" => {
            let command: RawWorkflowId =
                serde_json::from_value(raw.clone()).map_err(|_| BridgeError::MalformedCommand)?;
            Ok(Command::ActivateWorkflow {
                workflow_id: WorkflowId(command.workflow_id),
            })
        }
        "nameDraftWorkflow" => {
            let command: RawDraftName =
                serde_json::from_value(raw.clone()).map_err(|_| BridgeError::MalformedCommand)?;
            Ok(Command::NameDraftWorkflow {
                workflow_id: WorkflowId(command.workflow_id),
                name: command.name,
            })
        }
        "closeWorkflow" => {
            let command: RawWorkflowId =
                serde_json::from_value(raw.clone()).map_err(|_| BridgeError::MalformedCommand)?;
            Ok(Command::CloseWorkflow {
                workflow_id: WorkflowId(command.workflow_id),
            })
        }
        _ => Err(BridgeError::MalformedCommand),
    }
}
