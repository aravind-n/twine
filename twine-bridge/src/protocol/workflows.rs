use std::path::{Path, PathBuf};

use super::RawTerminalSize;
use crate::error::BridgeError;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use twine_core::{
    Command, HarnessId, Session, SessionId, SessionStatus, TerminalSize, Workflow, WorkflowId,
    WorkflowKind, WorkflowState, WorkflowStatus,
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
    run: Option<super::runs::WireRun<'a>>,
    workflow_id: u64,
    session_id: u64,
    name: &'a str,
    kind: &'static str,
    harness: Option<&'static str>,
    terminal_id: u64,
    agents: Vec<WireAgent<'a>>,
    status: &'static str,
    started_at: u64,
    ended_at: Option<u64>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct WireAgent<'a> {
    agent_id: u64,
    role: &'a str,
    terminal_id: u64,
}

impl<'a> From<&'a Workflow> for WireWorkflow<'a> {
    fn from(workflow: &'a Workflow) -> Self {
        Self {
            restored: workflow.restored,
            run: workflow.run.as_deref().map(Into::into),
            workflow_id: workflow.workflow_id.0,
            session_id: workflow.session_id.0,
            name: &workflow.name,
            kind: match workflow.kind {
                WorkflowKind::Draft => "draft",
                WorkflowKind::Terminal => "terminal",
                WorkflowKind::SingleAgent => "singleAgent",
                WorkflowKind::Agents => "agents",
            },
            harness: workflow.harness.map(|harness| match harness {
                HarnessId::Codex => "codex",
                HarnessId::ClaudeCode => "claudeCode",
                HarnessId::Pi => "pi",
            }),
            terminal_id: workflow.terminal_id.value(),
            agents: workflow
                .agents
                .iter()
                .map(|agent| WireAgent {
                    agent_id: agent.agent_id.0,
                    role: &agent.role,
                    terminal_id: agent.terminal_id.value(),
                })
                .collect(),
            status: match workflow.status {
                WorkflowStatus::Running => "running",
                WorkflowStatus::Completed => "completed",
                WorkflowStatus::Exited => "exited",
                WorkflowStatus::Failed => "failed",
                WorkflowStatus::Cancelled => "cancelled",
                WorkflowStatus::Interrupted => "interrupted",
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
    #[serde(default)]
    roles: Vec<String>,
    size: RawTerminalSize,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
enum RawWorkflowKind {
    Draft,
    Terminal,
    Agents,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
enum RawHarness {
    Codex,
    ClaudeCode,
    Pi,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawStartAgent {
    /// The harness's model, or its own default when absent.
    #[serde(default)]
    model: Option<String>,
    /// The harness's effort level, or its own default when absent.
    #[serde(default)]
    effort: Option<String>,
    #[serde(default)]
    yolo: bool,
    workflow_id: u64,
    harness: RawHarness,
    /// Without one, the agent starts interactively.
    #[serde(default)]
    prompt: String,
    size: RawTerminalSize,
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
                    RawWorkflowKind::Agents => WorkflowKind::Agents,
                },
                roles: command.roles,
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
        "startAgent" => {
            let command: RawStartAgent =
                serde_json::from_value(raw.clone()).map_err(|_| BridgeError::MalformedCommand)?;
            Ok(Command::StartAgent {
                model: command.model,
                effort: command.effort,
                yolo: command.yolo,
                workflow_id: WorkflowId(command.workflow_id),
                harness: match command.harness {
                    RawHarness::Codex => HarnessId::Codex,
                    RawHarness::ClaudeCode => HarnessId::ClaudeCode,
                    RawHarness::Pi => HarnessId::Pi,
                },
                prompt: command.prompt,
                size: TerminalSize {
                    rows: command.size.rows,
                    columns: command.size.columns,
                    pixel_width: command.size.pixel_width,
                    pixel_height: command.size.pixel_height,
                },
            })
        }
        "cancelAgent" => {
            let command: RawWorkflowId =
                serde_json::from_value(raw.clone()).map_err(|_| BridgeError::MalformedCommand)?;
            Ok(Command::CancelAgent {
                workflow_id: WorkflowId(command.workflow_id),
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

#[cfg(test)]
mod tests {
    use serde_json::json;
    use twine_core::{Agent, AgentId, SessionId, TerminalId};

    use super::*;

    #[test]
    fn agent_workflows_serialize_the_names_the_app_decodes() {
        let workflow = |harness, status| Workflow {
            workflow_id: WorkflowId(1),
            session_id: SessionId(1),
            name: "Claude Code".to_owned(),
            kind: WorkflowKind::SingleAgent,
            harness: Some(harness),
            agents: Vec::new(),
            terminal_id: TerminalId::from_value(2),
            status,
            started_at: 1,
            ended_at: None,
            restored: false,
            run: None,
        };
        for (harness, status, harness_name, status_name) in [
            (
                HarnessId::Codex,
                WorkflowStatus::Running,
                "codex",
                "running",
            ),
            (
                HarnessId::ClaudeCode,
                WorkflowStatus::Cancelled,
                "claudeCode",
                "cancelled",
            ),
            (
                HarnessId::Pi,
                WorkflowStatus::Interrupted,
                "pi",
                "interrupted",
            ),
        ] {
            let json =
                serde_json::to_value(WireWorkflow::from(&workflow(harness, status))).unwrap();
            assert_eq!(json["kind"], "singleAgent");
            assert_eq!(json["harness"], harness_name);
            assert_eq!(json["status"], status_name);
        }
    }

    fn create_workflow(command: &Value) -> Result<Command, BridgeError> {
        decode_command("createWorkflow", command)
    }

    #[test]
    fn create_workflow_decodes_agent_roles_and_defaults_to_none() {
        let size = json!({ "rows": 24, "columns": 80, "pixelWidth": 800, "pixelHeight": 480 });
        let Command::CreateWorkflow { kind, roles, .. } = create_workflow(&json!({
            "folder": "/folder",
            "sessionId": 2,
            "kind": "agents",
            "roles": ["Implementer", "Reviewer"],
            "size": size,
        }))
        .unwrap() else {
            panic!("expected a create workflow command");
        };
        assert_eq!(kind, WorkflowKind::Agents);
        assert_eq!(roles, ["Implementer", "Reviewer"]);

        let Command::CreateWorkflow { kind, roles, .. } =
            create_workflow(&json!({ "folder": "/folder", "kind": "terminal", "size": size }))
                .unwrap()
        else {
            panic!("expected a create workflow command");
        };
        assert_eq!(kind, WorkflowKind::Terminal);
        assert!(roles.is_empty());

        assert!(matches!(
            create_workflow(&json!({
                "folder": "/folder", "kind": "agents", "roles": [7], "size": size,
            })),
            Err(BridgeError::MalformedCommand)
        ));
    }

    #[test]
    fn workflows_serialize_their_agents_in_role_order() {
        let workflow = Workflow {
            workflow_id: WorkflowId(3),
            session_id: SessionId(1),
            name: "Agents".to_owned(),
            kind: WorkflowKind::Agents,
            harness: None,
            terminal_id: TerminalId::from_value(0),
            agents: vec![
                Agent {
                    agent_id: AgentId(5),
                    role: "Implementer".to_owned(),
                    terminal_id: TerminalId::from_value(8),
                },
                Agent {
                    agent_id: AgentId(6),
                    role: "Reviewer".to_owned(),
                    terminal_id: TerminalId::from_value(0),
                },
            ],
            status: WorkflowStatus::Running,
            started_at: 10,
            ended_at: None,
            restored: true,
            run: None,
        };
        assert_eq!(
            serde_json::to_value(WireWorkflow::from(&workflow)).unwrap(),
            json!({
                "restored": true,
                "run": null,
                "workflowId": 3,
                "sessionId": 1,
                "name": "Agents",
                "kind": "agents",
                "harness": null,
                "terminalId": 0,
                "agents": [
                    { "agentId": 5, "role": "Implementer", "terminalId": 8 },
                    { "agentId": 6, "role": "Reviewer", "terminalId": 0 },
                ],
                "status": "running",
                "startedAt": 10,
                "endedAt": null,
            })
        );
    }
}
