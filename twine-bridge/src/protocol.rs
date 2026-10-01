use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use serde_json::Value;
use twine_core::{
    ApplicationState, Command, CommandDisposition, CommandReceipt, CommandResult, Event, EventKind,
    FolderState, RequestId, Snapshot, StateEvent, TerminalId, TerminalSize, TerminalState,
    TerminalStatus, UnavailableReason,
};

use crate::error::BridgeError;

pub(crate) mod files;
pub(crate) mod harnesses;
mod runs;
mod traces;
mod workflow_types;
mod workflows;
use traces::WireTraceSummary;
pub(crate) use traces::{encode_trace_events, encode_workflow_trace};
use workflows::{WireWorkflow, WireWorkflowState};

#[derive(Debug)]
pub(crate) struct CommandEnvelope {
    pub request_id: RequestId,
    pub command: DecodedCommand,
}

#[derive(Debug)]
pub(crate) enum DecodedCommand {
    Known(Command),
    Unsupported(String),
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawCommandEnvelope {
    request_id: u64,
    command: Value,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawStartTerminal {
    working_directory: String,
    size: RawTerminalSize,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawCloseTerminal {
    terminal_id: u64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawTerminalSize {
    rows: u16,
    columns: u16,
    pixel_width: u16,
    pixel_height: u16,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct WireReceipt<'a> {
    request_id: u64,
    #[serde(flatten)]
    disposition: WireDisposition<'a>,
}

#[derive(Serialize)]
#[serde(tag = "status", rename_all = "camelCase")]
enum WireDisposition<'a> {
    Accepted,
    Rejected { error: WireError<'a> },
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct WireError<'a> {
    code: &'a str,
    message: &'a str,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct WireSnapshot<'a> {
    sequence: u64,
    state: WireApplicationState,
    config: &'a twine_core::config::Config,
    folders: WireFolderState<'a>,
    terminals: Vec<WireTerminalState>,
    workflows: WireWorkflowState<'a>,
    traces: Vec<WireTraceSummary>,
    workflow_types: &'a [twine_core::WorkflowType],
}

/// Paths serialize as strings; serde rejects a path that isn't valid UTF-8.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct WireFolderState<'a> {
    current_branch: Option<&'a str>,
    open_folder: Option<&'a Path>,
    recent_folders: Vec<WireRecentFolder<'a>>,
    unavailable_folder: Option<WireUnavailableFolder<'a>>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct WireRecentFolder<'a> {
    path: &'a Path,
    is_missing: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct WireUnavailableFolder<'a> {
    path: &'a Path,
    reason: WireUnavailableReason,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
enum WireUnavailableReason {
    Missing,
    Inaccessible,
}

impl<'a> From<&'a FolderState> for WireFolderState<'a> {
    fn from(folders: &'a FolderState) -> Self {
        Self {
            current_branch: folders.current_branch.as_deref(),
            open_folder: folders.open_folder.as_deref(),
            recent_folders: folders
                .recent_folders
                .iter()
                .map(|folder| WireRecentFolder {
                    path: &folder.path,
                    is_missing: folder.is_missing,
                })
                .collect(),
            unavailable_folder: folders.unavailable_folder.as_ref().map(|folder| {
                WireUnavailableFolder {
                    path: &folder.path,
                    reason: match folder.reason {
                        UnavailableReason::Missing => WireUnavailableReason::Missing,
                        UnavailableReason::Inaccessible => WireUnavailableReason::Inaccessible,
                    },
                }
            }),
        }
    }
}

#[derive(Serialize)]
#[serde(tag = "status", rename_all = "camelCase")]
enum WireApplicationState {
    Ready,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct WireTerminalState {
    terminal_id: u64,
    #[serde(flatten)]
    status: WireTerminalStatus,
}

#[derive(Serialize)]
#[serde(
    tag = "status",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
enum WireTerminalStatus {
    Running,
    Exited {
        exit_code: u32,
        signal: Option<String>,
    },
    Failed {
        message: String,
    },
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct WireEventBatch<'a> {
    events: Vec<WireEvent<'a>>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct WireEvent<'a> {
    sequence: u64,
    event: WireEventKind<'a>,
}

#[derive(Serialize)]
#[serde(
    tag = "type",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
enum WireEventKind<'a> {
    WorkflowTypesChanged {
        workflow_types: &'a [twine_core::WorkflowType],
    },
    WorkflowsChanged {
        workflows: WireWorkflowState<'a>,
    },
    WorkflowChanged {
        workflow: WireWorkflow<'a>,
    },
    ApplicationReady,
    TraceChanged {
        summary: WireTraceSummary,
    },
    TerminalClosed {
        terminal_id: u64,
    },
    TerminalExited {
        terminal_id: u64,
        exit_code: u32,
        signal: Option<String>,
    },
    TerminalFailed {
        terminal_id: u64,
        message: String,
    },
    CommandCompleted {
        request_id: u64,
        result: WireCommandResult,
    },
    FoldersChanged {
        folders: WireFolderState<'a>,
    },
}

#[derive(Serialize)]
#[serde(
    tag = "type",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
enum WireCommandResult {
    WorkflowTypeValidated {
        issues: Vec<workflow_types::WireValidationIssue>,
    },
    WorkflowTypeSaved {
        reference: twine_core::WorkflowTypeRef,
    },
    SessionCreated {
        session_id: u64,
    },
    SessionRenamed {
        session_id: u64,
    },
    SessionSelected {
        session_id: u64,
    },
    SessionDeleted {
        session_id: u64,
    },
    WorkflowCreated {
        workflow_id: u64,
    },
    WorkflowActivated {
        workflow_id: u64,
    },
    WorkflowClosed {
        workflow_id: u64,
    },
    AgentStarted {
        workflow_id: u64,
    },
    AgentCancelled {
        workflow_id: u64,
    },
    Pong,
    TerminalStarted {
        terminal_id: u64,
    },
    TerminalClosed {
        terminal_id: u64,
    },
}

impl From<&CommandResult> for WireCommandResult {
    fn from(result: &CommandResult) -> Self {
        match result {
            CommandResult::WorkflowTypeValidated { issues } => Self::WorkflowTypeValidated {
                issues: issues.iter().map(Into::into).collect(),
            },
            CommandResult::WorkflowTypeSaved { reference } => Self::WorkflowTypeSaved {
                reference: *reference,
            },
            CommandResult::SessionCreated { session_id } => Self::SessionCreated {
                session_id: session_id.0,
            },
            CommandResult::SessionRenamed { session_id } => Self::SessionRenamed {
                session_id: session_id.0,
            },
            CommandResult::SessionSelected { session_id } => Self::SessionSelected {
                session_id: session_id.0,
            },
            CommandResult::SessionDeleted { session_id } => Self::SessionDeleted {
                session_id: session_id.0,
            },
            CommandResult::WorkflowCreated { workflow_id } => Self::WorkflowCreated {
                workflow_id: workflow_id.0,
            },
            CommandResult::WorkflowActivated { workflow_id } => Self::WorkflowActivated {
                workflow_id: workflow_id.0,
            },
            CommandResult::WorkflowClosed { workflow_id } => Self::WorkflowClosed {
                workflow_id: workflow_id.0,
            },
            CommandResult::AgentStarted { workflow_id } => Self::AgentStarted {
                workflow_id: workflow_id.0,
            },
            CommandResult::AgentCancelled { workflow_id } => Self::AgentCancelled {
                workflow_id: workflow_id.0,
            },
            CommandResult::Pong => Self::Pong,
            CommandResult::TerminalStarted { terminal_id } => Self::TerminalStarted {
                terminal_id: terminal_id.value(),
            },
            CommandResult::TerminalClosed { terminal_id } => Self::TerminalClosed {
                terminal_id: terminal_id.value(),
            },
        }
    }
}

pub(crate) fn decode_command(bytes: &[u8]) -> Result<CommandEnvelope, BridgeError> {
    let text = std::str::from_utf8(bytes).map_err(|_| BridgeError::InvalidUtf8)?;
    let raw: RawCommandEnvelope =
        serde_json::from_str(text).map_err(|_| BridgeError::MalformedCommand)?;
    let command_type = raw
        .command
        .get("type")
        .and_then(Value::as_str)
        .ok_or(BridgeError::MalformedCommand)?;
    let command = match command_type {
        "validateWorkflowType" | "saveWorkflowType" => {
            DecodedCommand::Known(workflow_types::decode_command(command_type, &raw.command)?)
        }
        "startWorkflowRun" | "completeWorkflowRole" | "cancelWorkflowRun" => {
            DecodedCommand::Known(runs::decode_command(command_type, &raw.command)?)
        }
        "ping" => DecodedCommand::Known(Command::Ping),
        "openFolder" => DecodedCommand::Known(Command::OpenFolder {
            path: decode_path(&raw.command)?,
        }),
        "closeFolder" => DecodedCommand::Known(Command::CloseFolder),
        "closeFolderIfOpen" => DecodedCommand::Known(Command::CloseFolderIfOpen {
            path: decode_path(&raw.command)?,
        }),
        "removeRecentFolder" => DecodedCommand::Known(Command::RemoveRecentFolder {
            path: decode_path(&raw.command)?,
        }),
        "refreshGitBranch" => {
            let folder = raw
                .command
                .get("folder")
                .and_then(Value::as_str)
                .ok_or(BridgeError::MalformedCommand)?;
            DecodedCommand::Known(Command::RefreshGitBranch {
                folder: PathBuf::from(folder),
            })
        }
        "createSession" | "renameSession" | "selectSession" | "deleteSession"
        | "createWorkflow" | "activateWorkflow" | "nameDraftWorkflow" | "closeWorkflow"
        | "startAgent" | "resumeAgent" | "cancelAgent" => {
            DecodedCommand::Known(workflows::decode_command(command_type, &raw.command)?)
        }
        "startTerminal" => {
            let command: RawStartTerminal =
                serde_json::from_value(raw.command).map_err(|_| BridgeError::MalformedCommand)?;
            DecodedCommand::Known(Command::StartTerminal {
                working_directory: command.working_directory.into(),
                size: TerminalSize {
                    rows: command.size.rows,
                    columns: command.size.columns,
                    pixel_width: command.size.pixel_width,
                    pixel_height: command.size.pixel_height,
                },
            })
        }
        "closeTerminal" => {
            let command: RawCloseTerminal =
                serde_json::from_value(raw.command).map_err(|_| BridgeError::MalformedCommand)?;
            DecodedCommand::Known(Command::CloseTerminal {
                terminal_id: TerminalId::from_value(command.terminal_id),
            })
        }
        other => DecodedCommand::Unsupported(other.to_owned()),
    };
    Ok(CommandEnvelope {
        request_id: RequestId(raw.request_id),
        command,
    })
}

fn decode_path(command: &Value) -> Result<PathBuf, BridgeError> {
    command
        .get("path")
        .and_then(Value::as_str)
        .map(PathBuf::from)
        .ok_or(BridgeError::MalformedCommand)
}

pub(crate) fn unsupported_receipt(request_id: RequestId, command_type: &str) -> CommandReceipt {
    CommandReceipt {
        request_id,
        disposition: CommandDisposition::Rejected {
            code: "unsupportedCommand".to_owned(),
            message: format!("unsupported command type: {command_type}"),
        },
    }
}

pub(crate) fn encode_receipt(receipt: &CommandReceipt) -> Result<Vec<u8>, serde_json::Error> {
    let disposition = match &receipt.disposition {
        CommandDisposition::Accepted => WireDisposition::Accepted,
        CommandDisposition::Rejected { code, message } => WireDisposition::Rejected {
            error: WireError { code, message },
        },
    };
    serde_json::to_vec(&WireReceipt {
        request_id: receipt.request_id.0,
        disposition,
    })
}

pub(crate) fn encode_snapshot(snapshot: &Snapshot) -> Result<Vec<u8>, serde_json::Error> {
    let state = match snapshot.state {
        ApplicationState::Ready => WireApplicationState::Ready,
    };
    serde_json::to_vec(&WireSnapshot {
        sequence: snapshot.sequence,
        state,
        config: &snapshot.config,
        folders: (&snapshot.folders).into(),
        terminals: snapshot.terminals.iter().map(wire_terminal_state).collect(),
        workflows: (&snapshot.workflows).into(),
        traces: snapshot.traces.iter().map(Into::into).collect(),
        workflow_types: &snapshot.workflow_types,
    })
}

fn wire_terminal_state(terminal: &TerminalState) -> WireTerminalState {
    let status = match &terminal.status {
        TerminalStatus::Running => WireTerminalStatus::Running,
        TerminalStatus::Exited(exit) => WireTerminalStatus::Exited {
            exit_code: exit.exit_code,
            signal: exit.signal.clone(),
        },
        TerminalStatus::Failed { message } => WireTerminalStatus::Failed {
            message: message.clone(),
        },
    };
    WireTerminalState {
        terminal_id: terminal.terminal_id.value(),
        status,
    }
}

pub(crate) fn encode_events(events: &[Event]) -> Result<Vec<u8>, serde_json::Error> {
    let events = events
        .iter()
        .map(|event| WireEvent {
            sequence: event.sequence,
            event: match &event.kind {
                EventKind::State(StateEvent::WorkflowTypesChanged(types)) => {
                    WireEventKind::WorkflowTypesChanged {
                        workflow_types: types,
                    }
                }
                EventKind::State(StateEvent::WorkflowsChanged(workflows)) => {
                    WireEventKind::WorkflowsChanged {
                        workflows: workflows.into(),
                    }
                }
                EventKind::State(StateEvent::WorkflowChanged(workflow)) => {
                    WireEventKind::WorkflowChanged {
                        workflow: workflow.into(),
                    }
                }
                EventKind::CommandCompleted { request_id, result } => {
                    WireEventKind::CommandCompleted {
                        request_id: request_id.0,
                        result: result.into(),
                    }
                }
                EventKind::State(StateEvent::TraceChanged(summary)) => {
                    WireEventKind::TraceChanged {
                        summary: summary.into(),
                    }
                }
                EventKind::State(StateEvent::ApplicationReady) => WireEventKind::ApplicationReady,
                EventKind::State(StateEvent::FoldersChanged(folders)) => {
                    WireEventKind::FoldersChanged {
                        folders: folders.into(),
                    }
                }
                EventKind::State(StateEvent::TerminalClosed { terminal_id }) => {
                    WireEventKind::TerminalClosed {
                        terminal_id: terminal_id.value(),
                    }
                }
                EventKind::State(StateEvent::TerminalExited { terminal_id, exit }) => {
                    WireEventKind::TerminalExited {
                        terminal_id: terminal_id.value(),
                        exit_code: exit.exit_code,
                        signal: exit.signal.clone(),
                    }
                }
                EventKind::State(StateEvent::TerminalFailed {
                    terminal_id,
                    message,
                }) => WireEventKind::TerminalFailed {
                    terminal_id: terminal_id.value(),
                    message: message.clone(),
                },
            },
        })
        .collect();
    serde_json::to_vec(&WireEventBatch { events })
}

#[cfg(test)]
mod tests {
    use super::*;
    use twine_core::config::Config;
    use twine_core::{RecentFolder, UnavailableFolder};

    fn decode(json: &str) -> Command {
        match decode_command(json.as_bytes()).unwrap().command {
            DecodedCommand::Known(command) => command,
            DecodedCommand::Unsupported(kind) => panic!("unsupported command {kind}"),
        }
    }

    #[test]
    fn agent_commands_decode_their_harness_prompt_and_size() {
        let size = r#""size": {"rows": 24, "columns": 80, "pixelWidth": 800, "pixelHeight": 480}"#;
        let start = decode(&format!(
            r#"{{"requestId": 1, "command": {{"type": "startAgent", "workflowId": 7,
                "harness": "claudeCode", "prompt": "-fix it", {size}}}}}"#
        ));
        assert!(matches!(
            start,
            Command::StartAgent { workflow_id, harness: twine_core::HarnessId::ClaudeCode, ref prompt, .. }
                if workflow_id.0 == 7 && prompt == "-fix it"
        ));
        let interactive = decode(&format!(
            r#"{{"requestId": 4, "command": {{"type": "startAgent", "workflowId": 7,
                "harness": "pi", {size}}}}}"#
        ));
        assert!(matches!(interactive, Command::StartAgent { ref prompt, .. } if prompt.is_empty()));
        let antigravity = decode(&format!(
            r#"{{"requestId": 6, "command": {{"type": "startAgent", "workflowId": 7,
                "harness": "antigravity", "prompt": "-fix it", {size}}}}}"#
        ));
        assert!(matches!(
            antigravity,
            Command::StartAgent { harness: twine_core::HarnessId::Antigravity, ref prompt, .. }
                if prompt == "-fix it"
        ));
        let omp = decode(&format!(
            r#"{{"requestId": 7, "command": {{"type": "startAgent", "workflowId": 7,
                "harness": "omp", "prompt": "models", {size}}}}}"#
        ));
        assert!(
            matches!(omp, Command::StartAgent { harness: twine_core::HarnessId::Omp, ref prompt, .. } if prompt == "models")
        );
        let opencode = decode(&format!(
            r#"{{"requestId": 8, "command": {{"type": "startAgent", "workflowId": 7,
                "harness": "opencode", "prompt": "@README.md", "model": "opencode/space-bunny-free", "effort": "high", {size}}}}}"#
        ));
        assert!(
            matches!(opencode, Command::StartAgent { harness: twine_core::HarnessId::Opencode, ref prompt, ref model, ref effort, .. }
            if prompt == "@README.md" && model.as_deref() == Some("opencode/space-bunny-free") && effort.as_deref() == Some("high"))
        );
        let chosen = decode(&format!(
            r#"{{"requestId": 5, "command": {{"type": "startAgent", "workflowId": 7, "harness": "codex",
                "model": "gpt-6", "effort": "high", "yolo": true, {size}}}}}"#
        ));
        assert!(matches!(
            chosen,
            Command::StartAgent { ref model, ref effort, yolo: true, .. }
                if model.as_deref() == Some("gpt-6") && effort.as_deref() == Some("high")
        ));
        assert!(matches!(
            interactive,
            Command::StartAgent {
                model: None,
                effort: None,
                yolo: false,
                ..
            }
        ));
        let cancel =
            decode(r#"{"requestId": 2, "command": {"type": "cancelAgent", "workflowId": 7}}"#);
        assert!(matches!(cancel, Command::CancelAgent { workflow_id } if workflow_id.0 == 7));
        let unknown = decode_command(
            format!(
                r#"{{"requestId": 3, "command": {{"type": "startAgent", "workflowId": 7,
                    "harness": "nope", "prompt": "x", {size}}}}}"#
            )
            .as_bytes(),
        );
        assert!(matches!(unknown, Err(BridgeError::MalformedCommand)));
    }

    #[test]
    fn snapshot_serializes_validated_config() {
        let data = tempfile::tempdir().unwrap();
        let config_path = data.path().join("config.toml");
        std::fs::write(
            &config_path,
            "[appearance]\ncolor_scheme = 'dark'\n[terminal]\nfont_family = 'Menlo'\nfont_size = 15.5\n",
        )
        .unwrap();
        let application =
            twine_core::Application::with_config(data.path(), Config::load(&config_path).config)
                .unwrap();
        let bytes = encode_snapshot(&application.snapshot().unwrap()).unwrap();
        let json: Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(
            json,
            serde_json::json!({
                "sequence": 1,
                "state": { "status": "ready" },
                "config": {
                    "appearance": { "color_scheme": "dark" },
                    "terminal": { "font_family": "Menlo", "font_size": 15.5 }
                },
                "folders": { "openFolder": null, "recentFolders": [], "unavailableFolder": null, "currentBranch": null },
                "terminals": [],
                "traces": [],
                "workflowTypes": application.workflow_types().unwrap(),
                "workflows": { "session": null, "sessions": [], "sessionsInitialized": false, "workflows": [] }
            })
        );
    }

    #[test]
    fn run_commands_decode_type_versions_harnesses_and_explicit_signals() {
        let command = decode(
            r#"{"requestId":1,"command":{"type":"startWorkflowRun","workflowId":3,
            "workflowType":{"user":{"type_id":7,"version":2}},"prompt":"Task",
            "roleLaunches":[{"role":"worker","harness":"codex"},
                {"role":"worker","harness":"claudeCode","model":"opus","effort":"max","yolo":true},
                {"role":"worker","harness":"antigravity","model":"gemini-3.8-flash-high","effort":"high"},
                {"role":"worker","harness":"omp","model":"local/model","effort":"max","yolo":true},
                {"role":"worker","harness":"opencode","model":"opencode/space-bunny-free","effort":"high"}],
            "size":{"rows":24,"columns":80,"pixelWidth":800,"pixelHeight":480}}}"#,
        );
        assert!(
            matches!(command, Command::StartWorkflowRun { workflow_type: twine_core::WorkflowTypeRef::User { type_id: 7, version: 2 }, ref roles, .. }
            if roles.len() == 5 && roles[1].harness == twine_core::HarnessId::ClaudeCode
                && roles[1].model.as_deref() == Some("opus") && roles[1].effort.as_deref() == Some("max")
                && roles[2].harness == twine_core::HarnessId::Antigravity
                && roles[2].model.as_deref() == Some("gemini-3.8-flash-high")
                && roles[2].effort.as_deref() == Some("high")
                && roles[3].harness == twine_core::HarnessId::Omp && roles[3].yolo
                && roles[3].model.as_deref() == Some("local/model") && roles[3].effort.as_deref() == Some("max")
                && roles[4].harness == twine_core::HarnessId::Opencode
                && roles[4].model.as_deref() == Some("opencode/space-bunny-free") && roles[4].effort.as_deref() == Some("high")
                && roles[1].yolo && !roles[0].yolo)
        );
        let command = decode(
            r#"{"requestId":5,"command":{"type":"startWorkflowRun","workflowId":3,
            "workflowType":{"builtin":"adversarial"},"roleLaunches":[],
            "size":{"rows":24,"columns":80,"pixelWidth":800,"pixelHeight":480}}}"#,
        );
        assert!(
            matches!(command, Command::StartWorkflowRun { ref prompt, .. } if prompt.is_empty())
        );
        let command = decode(
            r#"{"requestId":2,"command":{"type":"completeWorkflowRole","workflowId":3,
            "agentId":4,"generation":5,"signal":{"decision":"requestChanges","summary":"Fix the edge case"}}}"#,
        );
        assert!(matches!(
            command,
            Command::CompleteWorkflowRole {
                generation: 5,
                signal: twine_core::CompletionSignal {
                    decision: twine_core::Decision::RequestChanges,
                    ref task,
                    ..
                },
                ..
            } if task.is_empty()
        ));
        let command = decode(
            r#"{"requestId":4,"command":{"type":"completeWorkflowRole","workflowId":3,
            "agentId":4,"generation":1,"signal":{"decision":"done","task":"Add a toggle"}}}"#,
        );
        assert!(matches!(
            command,
            Command::CompleteWorkflowRole { signal: twine_core::CompletionSignal { ref task, .. }, .. }
                if task == "Add a toggle"
        ));
        let command =
            decode(r#"{"requestId":3,"command":{"type":"cancelWorkflowRun","workflowId":3}}"#);
        assert!(
            matches!(command, Command::CancelWorkflowRun { workflow_id } if workflow_id.0 == 3)
        );
    }

    #[test]
    fn snapshot_serializes_folder_state() {
        let snapshot = Snapshot {
            sequence: 3,
            state: ApplicationState::Ready,
            config: Config::default(),
            folders: FolderState {
                current_branch: None,
                open_folder: None,
                recent_folders: vec![
                    RecentFolder {
                        path: PathBuf::from("/projects/locked"),
                        is_missing: false,
                    },
                    RecentFolder {
                        path: PathBuf::from("/projects/deleted"),
                        is_missing: true,
                    },
                ],
                unavailable_folder: Some(UnavailableFolder {
                    path: PathBuf::from("/projects/locked"),
                    reason: UnavailableReason::Inaccessible,
                }),
            },
            terminals: Vec::new(),
            workflows: twine_core::WorkflowState::default(),
            traces: Vec::new(),
            workflow_types: Vec::new(),
        };
        let json: Value = serde_json::from_slice(&encode_snapshot(&snapshot).unwrap()).unwrap();
        assert_eq!(
            json["folders"],
            serde_json::json!({
                "currentBranch": null,
                "openFolder": null,
                "recentFolders": [
                    { "path": "/projects/locked", "isMissing": false },
                    { "path": "/projects/deleted", "isMissing": true }
                ],
                "unavailableFolder": { "path": "/projects/locked", "reason": "inaccessible" }
            })
        );
    }

    #[test]
    fn terminal_command_result_uses_camel_case_identifiers() {
        let events = [
            Event {
                sequence: 2,
                kind: EventKind::CommandCompleted {
                    request_id: RequestId(7),
                    result: CommandResult::TerminalStarted {
                        terminal_id: TerminalId::from_value(41),
                    },
                },
            },
            Event {
                sequence: 3,
                kind: EventKind::CommandCompleted {
                    request_id: RequestId(8),
                    result: CommandResult::TerminalClosed {
                        terminal_id: TerminalId::from_value(41),
                    },
                },
            },
        ];

        let encoded: Value = serde_json::from_slice(
            &encode_events(&events).expect("terminal event should serialize"),
        )
        .expect("terminal event should be valid JSON");

        assert_eq!(encoded["events"][0]["event"]["result"]["terminalId"], 41);
        assert_eq!(encoded["events"][1]["event"]["result"]["terminalId"], 41);
        assert!(
            encoded["events"][0]["event"]["result"]
                .get("terminal_id")
                .is_none()
        );
        assert!(
            encoded["events"][1]["event"]["result"]
                .get("terminal_id")
                .is_none()
        );
    }
}
