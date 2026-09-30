use serde::{Deserialize, Serialize};
use serde_json::Value;
use twine_core::{
    AgentId, Command, CompletionSignal, RoleLaunch, RunStatus, TerminalSize, WorkflowId,
    WorkflowRun, WorkflowTypeRef,
};

use super::RawTerminalSize;
use crate::error::BridgeError;

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct WireRun<'a> {
    generation: u64,
    stage: &'a str,
    status: RunStatus,
    message: Option<&'a str>,
    agents: Vec<WireRunAgent<'a>>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct WireRunAgent<'a> {
    agent_id: u64,
    active: bool,
    done: bool,
    reviewer: bool,
    harness: twine_core::HarnessId,
    targets: Vec<WireTarget<'a>>,
}

#[derive(Serialize)]
struct WireTarget<'a> {
    role: &'a str,
    instance: u8,
    label: &'a str,
}

impl<'a> From<&'a WorkflowRun> for WireRun<'a> {
    fn from(run: &'a WorkflowRun) -> Self {
        let active = run.active_agents();
        Self {
            generation: run.generation,
            stage: &run.workflow_type.definition.stages[run.stage_index].name,
            status: run.status,
            message: run.message.as_deref(),
            agents: run
                .agents
                .iter()
                .map(|agent| WireRunAgent {
                    agent_id: agent.agent_id,
                    active: run.status == RunStatus::Running && active.contains(&agent),
                    done: run.completions.contains_key(&agent.agent_id),
                    reviewer: run.is_reviewer(agent.agent_id),
                    harness: agent.harness,
                    targets: run
                        .assignment_targets(agent.agent_id)
                        .iter()
                        .map(|target| WireTarget {
                            role: &target.role,
                            instance: target.instance,
                            label: &target.label,
                        })
                        .collect(),
                })
                .collect(),
        }
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawStart {
    workflow_id: u64,
    workflow_type: WorkflowTypeRef,
    prompt: String,
    #[serde(rename = "roleLaunches")]
    roles: Vec<RoleLaunch>,
    size: RawTerminalSize,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawComplete {
    workflow_id: u64,
    agent_id: u64,
    generation: u64,
    signal: CompletionSignal,
}

pub(super) fn decode_command(kind: &str, raw: &Value) -> Result<Command, BridgeError> {
    match kind {
        "startWorkflowRun" => {
            let raw: RawStart =
                serde_json::from_value(raw.clone()).map_err(|_| BridgeError::MalformedCommand)?;
            Ok(Command::StartWorkflowRun {
                workflow_id: WorkflowId(raw.workflow_id),
                workflow_type: raw.workflow_type,
                prompt: raw.prompt,
                roles: raw.roles,
                size: TerminalSize {
                    rows: raw.size.rows,
                    columns: raw.size.columns,
                    pixel_width: raw.size.pixel_width,
                    pixel_height: raw.size.pixel_height,
                },
            })
        }
        "completeWorkflowRole" => {
            let raw: RawComplete =
                serde_json::from_value(raw.clone()).map_err(|_| BridgeError::MalformedCommand)?;
            Ok(Command::CompleteWorkflowRole {
                workflow_id: WorkflowId(raw.workflow_id),
                agent_id: AgentId(raw.agent_id),
                generation: raw.generation,
                signal: raw.signal,
            })
        }
        "cancelWorkflowRun" => raw
            .get("workflowId")
            .and_then(Value::as_u64)
            .map(|id| Command::CancelWorkflowRun {
                workflow_id: WorkflowId(id),
            })
            .ok_or(BridgeError::MalformedCommand),
        _ => Err(BridgeError::MalformedCommand),
    }
}
