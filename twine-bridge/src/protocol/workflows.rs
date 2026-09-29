use std::path::Path;

use serde::Serialize;
use twine_core::{Session, SessionStatus, Workflow, WorkflowKind, WorkflowState, WorkflowStatus};

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct WireWorkflowState<'a> {
    session: Option<WireSession<'a>>,
    workflows: Vec<WireWorkflow<'a>>,
}

impl<'a> From<&'a WorkflowState> for WireWorkflowState<'a> {
    fn from(state: &'a WorkflowState) -> Self {
        Self {
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
