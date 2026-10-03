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
    individual_mode: bool,
    mode_revision: u64,
    stage: &'a str,
    stage_id: &'a str,
    workflow_type: &'a twine_core::WorkflowType,
    status: RunStatus,
    message: Option<&'a str>,
    /// The first stage still has to report the task the user gave it.
    needs_task: bool,
    agents: Vec<WireRunAgent<'a>>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct WireRunAgent<'a> {
    agent_id: u64,
    role: &'a str,
    instance: u8,
    active: bool,
    done: bool,
    reviewer: bool,
    harness: twine_core::HarnessId,
    status: twine_core::RunAgentStatus,
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
            individual_mode: run.individual_mode,
            mode_revision: run.mode_revision,
            stage: &run.workflow_type.definition.stages[run.stage_index].name,
            stage_id: &run.workflow_type.definition.stages[run.stage_index].id.0,
            workflow_type: &run.workflow_type,
            status: run.status,
            message: run.message.as_deref(),
            needs_task: run.needs_task(),
            agents: run
                .agents
                .iter()
                .map(|agent| WireRunAgent {
                    agent_id: agent.agent_id,
                    role: &agent.role,
                    instance: agent.instance,
                    active: run.status == RunStatus::Running && active.contains(&agent),
                    done: run.completions.contains_key(&agent.agent_id),
                    reviewer: run.is_reviewer(agent.agent_id),
                    harness: agent.harness,
                    status: agent.status,
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
    /// Without one, the first stage asks the user for the task.
    #[serde(default)]
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

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawContinue {
    workflow_id: u64,
    agent_id: u64,
    generation: u64,
    #[serde(default)]
    mode_revision: u64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawIndividualMode {
    workflow_id: u64,
    generation: u64,
    mode_revision: u64,
    individual_mode: bool,
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
        "continueWorkflowRun" => {
            let raw: RawContinue =
                serde_json::from_value(raw.clone()).map_err(|_| BridgeError::MalformedCommand)?;
            Ok(Command::ContinueWorkflowRun {
                workflow_id: WorkflowId(raw.workflow_id),
                agent_id: AgentId(raw.agent_id),
                generation: raw.generation,
                mode_revision: raw.mode_revision,
            })
        }
        "setWorkflowIndividualMode" => {
            let raw: RawIndividualMode =
                serde_json::from_value(raw.clone()).map_err(|_| BridgeError::MalformedCommand)?;
            Ok(Command::SetWorkflowIndividualMode {
                workflow_id: WorkflowId(raw.workflow_id),
                generation: raw.generation,
                mode_revision: raw.mode_revision,
                individual_mode: raw.individual_mode,
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn individual_mode_commands_require_an_explicit_mode_and_revision() {
        let raw = serde_json::json!({"workflowId": 3, "generation": 5, "modeRevision": 2, "individualMode": true});
        assert!(matches!(
            decode_command("setWorkflowIndividualMode", &raw).unwrap(),
            Command::SetWorkflowIndividualMode {
                workflow_id: WorkflowId(3),
                generation: 5,
                mode_revision: 2,
                individual_mode: true
            }
        ));
        for field in ["individualMode", "modeRevision", "generation"] {
            let mut invalid = raw.clone();
            invalid.as_object_mut().unwrap().remove(field);
            assert!(decode_command("setWorkflowIndividualMode", &invalid).is_err());
        }
    }

    #[test]
    fn run_serializes_the_pinned_definition_stage_id_and_role_assignments() {
        let mut definition = twine_core::BuiltinType::Adversarial.definition();
        // Stage names need not be unique; graph state must use the stable ID.
        for stage in &mut definition.stages {
            stage.name = "Work".to_owned();
        }
        let workflow_type = twine_core::WorkflowType {
            reference: WorkflowTypeRef::User {
                type_id: 7,
                version: 2,
            },
            definition,
        };
        let run: WorkflowRun = serde_json::from_value(serde_json::json!({
            "workflowType": workflow_type,
            "prompt": "Task", "stageIndex": 1, "generation": 2, "status": "running",
            "agents": [{"agentId": 4, "role": "reviewer", "instance": 1,
                "label": "Reviewer", "harness": "claudeCode", "status": "running"}],
            "completions": {}, "rounds": {}, "incoming": {}, "assignments": {},
            "traces": [], "message": null
        }))
        .unwrap();
        let wire = serde_json::to_value(WireRun::from(&run)).unwrap();
        assert_eq!(wire["stage"], "Work");
        assert_eq!(wire["individualMode"], false);
        assert_eq!(wire["modeRevision"], 0);
        assert_eq!(wire["stageId"], "review");
        assert_eq!(
            wire["workflowType"],
            serde_json::to_value(workflow_type).unwrap()
        );
        assert_eq!(wire["agents"][0]["role"], "reviewer");
        assert_eq!(wire["agents"][0]["instance"], 1);
        assert_eq!(wire["agents"][0]["harness"], "claudeCode");
        assert_eq!(wire["agents"][0]["active"], true);
        assert_eq!(wire["agents"][0]["status"], "running");
        assert_eq!(wire["needsTask"], false);
        let mut untold = run.clone();
        untold.prompt = String::new();
        let wire = serde_json::to_value(WireRun::from(&untold)).unwrap();
        assert_eq!(wire["needsTask"], true);
    }
}
