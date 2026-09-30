//! Bounded, ordered workflow execution, independent of terminals and UI.

use std::collections::BTreeMap;
use std::fmt::Write;

use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::harness::HarnessId;
use crate::workflow::timestamp;
use crate::workflow_type::{Completion, HandoffContent, WorkflowType, WorkflowTypeRef, validate};

pub(crate) mod completion;
mod recovery;

/// One harness choice per role instance, fixed at launch.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RoleLaunch {
    pub role: String,
    pub harness: HarnessId,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Decision {
    Done,
    Approve,
    RequestChanges,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Assignment {
    pub role: String,
    /// One-based instance number, as listed in the sender's instructions.
    pub instance: u8,
    pub task: String,
    pub files: Vec<String>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CompletionSignal {
    pub decision: Decision,
    #[serde(default)]
    pub summary: String,
    #[serde(default)]
    pub assignments: Vec<Assignment>,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum RunStatus {
    Running,
    Completed,
    LimitReached,
    Cancelled,
    Failed,
    Interrupted,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RunAgent {
    pub agent_id: u64,
    pub role: String,
    pub instance: u8,
    pub label: String,
    pub harness: HarnessId,
    /// Defaults for records saved before per-agent lifecycle tracking was introduced.
    #[serde(default)]
    pub status: RunAgentStatus,
}

#[derive(Clone, Copy, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum RunAgentStatus {
    #[default]
    Waiting,
    Running,
    Completed,
    Exited,
    Failed,
    Cancelled,
    Interrupted,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkflowTrace {
    pub sequence: u64,
    pub generation: u64,
    pub timestamp: u64,
    pub kind: String,
    pub stage: String,
    pub agent_id: Option<u64>,
    pub target_agent_id: Option<u64>,
    pub message: String,
}

/// Serializable run state. A run pins both its type reference and definition. Processes and
/// completion mailboxes are deliberately absent; restoring an active run interrupts it.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkflowRun {
    pub workflow_type: WorkflowType,
    pub prompt: String,
    pub agents: Vec<RunAgent>,
    pub stage_index: usize,
    /// Changes on every stage entry, including loop backs. UI actions must match this value.
    pub generation: u64,
    pub status: RunStatus,
    pub completions: BTreeMap<u64, CompletionSignal>,
    pub rounds: BTreeMap<String, u8>,
    pub incoming: BTreeMap<u64, String>,
    /// Assignment ownership remains in force when a review loop revisits a worker.
    pub assignments: BTreeMap<u64, Assignment>,
    pub traces: Vec<WorkflowTrace>,
    pub message: Option<String>,
}

impl WorkflowRun {
    pub(crate) fn new(
        workflow_type: WorkflowType,
        prompt: String,
        choices: &[RoleLaunch],
    ) -> Result<Self, RunError> {
        validate(&workflow_type.definition).map_err(|_| RunError::InvalidType)?;
        if prompt.trim().is_empty() || prompt.len() > 32 * 1024 {
            return Err(RunError::Prompt);
        }
        let definition = &workflow_type.definition;
        let mut agents = Vec::new();
        for role in &definition.roles {
            let selected: Vec<_> = choices
                .iter()
                .filter(|choice| choice.role == role.id.0)
                .collect();
            if !(usize::from(role.instances.min)..=usize::from(role.instances.max))
                .contains(&selected.len())
            {
                return Err(RunError::HarnessChoices);
            }
            for (index, choice) in selected.iter().enumerate() {
                let instance = u8::try_from(index + 1).map_err(|_| RunError::HarnessChoices)?;
                agents.push(RunAgent {
                    agent_id: 0,
                    role: role.id.0.clone(),
                    instance,
                    label: if selected.len() > 1 {
                        format!("{} {instance}", role.name)
                    } else {
                        role.name.clone()
                    },
                    harness: choice.harness,
                    status: RunAgentStatus::Waiting,
                });
            }
        }
        if choices.len() != agents.len() {
            return Err(RunError::HarnessChoices);
        }
        Ok(Self {
            workflow_type,
            prompt,
            agents,
            stage_index: 0,
            generation: 1,
            status: RunStatus::Running,
            completions: BTreeMap::new(),
            rounds: BTreeMap::new(),
            incoming: BTreeMap::new(),
            assignments: BTreeMap::new(),
            traces: Vec::new(),
            message: None,
        })
    }

    #[must_use]
    pub fn reference(&self) -> WorkflowTypeRef {
        self.workflow_type.reference
    }

    #[must_use]
    pub fn active_agents(&self) -> Vec<&RunAgent> {
        let stage = &self.workflow_type.definition.stages[self.stage_index];
        self.agents
            .iter()
            .filter(|agent| stage.roles.iter().any(|role| role.0 == agent.role))
            .collect()
    }

    #[must_use]
    pub fn is_reviewer(&self, agent_id: u64) -> bool {
        matches!(&self.workflow_type.definition.stages[self.stage_index].completion,
            Completion::ReviewDecision { reviewer } if self.agents.iter().any(|a| a.agent_id == agent_id && a.role == reviewer.0))
    }

    /// Receivers whose assignments must be supplied by this participant before it can finish.
    #[must_use]
    pub fn assignment_targets(&self, agent_id: u64) -> Vec<&RunAgent> {
        let stage = &self.workflow_type.definition.stages[self.stage_index];
        let Some(sender) = self.agents.iter().find(|a| a.agent_id == agent_id) else {
            return Vec::new();
        };
        self.agents
            .iter()
            .filter(|target| {
                self.workflow_type.definition.handoffs.iter().any(|h| {
                    h.from.stage == stage.id
                        && h.from.role.0 == sender.role
                        && h.to.role.0 == target.role
                        && h.content == HandoffContent::Assignment
                })
            })
            .collect()
    }

    /// Validate fully before accepting a completion; failed signals never partially advance a run.
    pub(crate) fn complete(
        &mut self,
        agent_id: u64,
        generation: u64,
        signal: CompletionSignal,
    ) -> Result<bool, RunError> {
        if self.status != RunStatus::Running
            || generation != self.generation
            || !self.active_agents().iter().any(|a| a.agent_id == agent_id)
            || self.completions.contains_key(&agent_id)
        {
            return Err(RunError::StaleSignal);
        }
        if serde_json::to_vec(&signal)
            .map_err(|_| RunError::SignalTooLarge)?
            .len()
            > completion::MAX_SIGNAL_BYTES
        {
            return Err(RunError::SignalTooLarge);
        }
        let reviewer = self.is_reviewer(agent_id);
        if reviewer == (signal.decision == Decision::Done) {
            return Err(RunError::Decision);
        }
        if signal.decision == Decision::RequestChanges && signal.summary.trim().is_empty() {
            return Err(RunError::Feedback);
        }
        let targets = self.assignment_targets(agent_id);
        if signal.assignments.len() != targets.len()
            || targets.iter().any(|target| {
                let assignments: Vec<_> = signal
                    .assignments
                    .iter()
                    .filter(|a| a.role == target.role && a.instance == target.instance)
                    .collect();
                assignments.len() != 1
                    || assignments[0].task.trim().is_empty()
                    || assignments[0]
                        .files
                        .iter()
                        .any(|file| file.trim().is_empty())
            })
        {
            return Err(RunError::Assignments);
        }
        let decision = self.record_completion(agent_id, signal);
        // A review decision is the completion rule for the whole stage, even when other roles
        // are helping the reviewer. AllRolesDone instead waits for every role instance.
        let stage_done = reviewer
            || self
                .active_agents()
                .iter()
                .all(|a| self.completions.contains_key(&a.agent_id));
        if !stage_done {
            return Ok(false);
        }
        self.trace("stageCompleted", None, None, "Stage completed");
        // A review decision can stop other participants without completing their work.
        for agent in &mut self.agents {
            if agent.status == RunAgentStatus::Running {
                agent.status = RunAgentStatus::Cancelled;
            }
        }
        let definition = &self.workflow_type.definition;
        let stage = &definition.stages[self.stage_index];
        let next = if decision == Decision::RequestChanges {
            let review_loop = definition
                .review_loops
                .iter()
                .find(|item| item.review_stage == stage.id)
                .ok_or(RunError::InvalidType)?;
            let count = self.rounds.entry(stage.id.0.clone()).or_default();
            if *count >= review_loop.max_rounds {
                self.finish(
                    RunStatus::LimitReached,
                    "Review limit reached; approval is still required.",
                );
                return Ok(true);
            }
            *count += 1;
            let index = definition
                .stages
                .iter()
                .position(|s| s.id == review_loop.back_to)
                .ok_or(RunError::InvalidType)?;
            self.trace("reviewLoop", None, None, "Returning for requested changes");
            index
        } else {
            self.stage_index + 1
        };
        if next == self.workflow_type.definition.stages.len() {
            self.finish(RunStatus::Completed, "Workflow completed");
        } else {
            self.deliver_handoffs(next);
            self.stage_index = next;
            self.generation += 1;
            self.completions.clear();
            self.message = None;
            let stage = &self.workflow_type.definition.stages[self.stage_index];
            for agent in &mut self.agents {
                if stage.roles.iter().any(|role| role.0 == agent.role) {
                    agent.status = RunAgentStatus::Waiting;
                }
            }
        }
        Ok(true)
    }

    fn record_completion(&mut self, agent_id: u64, signal: CompletionSignal) -> Decision {
        self.trace(
            "roleCompleted",
            Some(agent_id),
            None,
            match signal.decision {
                Decision::Done => "Marked done",
                Decision::Approve => "Approved",
                Decision::RequestChanges => "Requested changes",
            },
        );
        let decision = signal.decision;
        self.completions.insert(agent_id, signal);
        self.agents
            .iter_mut()
            .find(|a| a.agent_id == agent_id)
            .expect("completion agent was validated")
            .status = RunAgentStatus::Completed;
        decision
    }

    fn deliver_handoffs(&mut self, next: usize) {
        let definition = &self.workflow_type.definition;
        let from = &definition.stages[self.stage_index].id;
        let to = &definition.stages[next].id;
        let mut incoming = BTreeMap::<u64, String>::new();
        let mut deliveries = Vec::new();
        for handoff in definition
            .handoffs
            .iter()
            .filter(|h| &h.from.stage == from && &h.to.stage == to)
        {
            for sender in self.agents.iter().filter(|a| a.role == handoff.from.role.0) {
                let Some(signal) = self.completions.get(&sender.agent_id) else {
                    continue;
                };
                for target in self.agents.iter().filter(|a| a.role == handoff.to.role.0) {
                    let content = match handoff.content {
                        HandoffContent::Assignment => {
                            let Some(assignment) = signal
                                .assignments
                                .iter()
                                .find(|a| a.role == target.role && a.instance == target.instance)
                            else {
                                continue;
                            };
                            self.assignments.insert(target.agent_id, assignment.clone());
                            format!(
                                "Sub-task: {}\nOwned files: {}",
                                assignment.task,
                                assignment.files.join(", ")
                            )
                        }
                        HandoffContent::Result | HandoffContent::Feedback => signal.summary.clone(),
                    };
                    let _ = write!(
                        incoming.entry(target.agent_id).or_default(),
                        "\nFrom {} ({:?}):\n{content}\n",
                        sender.label,
                        handoff.content
                    );
                    deliveries.push((sender.agent_id, target.agent_id));
                }
            }
        }
        self.incoming = incoming;
        for (from, to) in deliveries {
            self.trace("handoff", Some(from), Some(to), "Handoff delivered");
        }
    }

    pub(crate) fn instructions(&self, agent_id: u64, command: &str) -> String {
        let agent = self
            .agents
            .iter()
            .find(|a| a.agent_id == agent_id)
            .expect("a launched agent belongs to the run");
        let role = self
            .workflow_type
            .definition
            .roles
            .iter()
            .find(|r| r.id.0 == agent.role)
            .expect("roles were validated");
        let stage = &self.workflow_type.definition.stages[self.stage_index];
        let targets = self.assignment_targets(agent_id);
        let example = CompletionSignal {
            decision: if self.is_reviewer(agent_id) {
                Decision::Approve
            } else {
                Decision::Done
            },
            summary: "Describe the result or actionable review feedback".to_owned(),
            assignments: targets
                .iter()
                .map(|a| Assignment {
                    role: a.role.clone(),
                    instance: a.instance,
                    task: "The specific sub-task for this worker".to_owned(),
                    files: vec!["relative/file".to_owned()],
                })
                .collect(),
        };
        let assignment = self
            .assignments
            .get(&agent_id)
            .map(|a| format!("Sub-task: {}\nOwned files: {}", a.task, a.files.join(", ")))
            .unwrap_or_default();
        format!(
            "You are {} in the {} stage of a Twine workflow.\n{}\n\nTask:\n{}\n\nYour assignment:\n{assignment}\n\nHandoffs:\n{}\n\nAll agents work directly in this folder. Do not create a worktree or isolated checkout. Give parallel workers non-overlapping file sets; file ownership is advisory.\n\nWhen finished, explicitly submit JSON on stdin to this command:\n{} <<'TWINE_COMPLETION'\n{}\nTWINE_COMPLETION\n\n{}\nSupply an assignment for every receiver listed in the example (with its exact role and instance). Use actual sub-tasks and file sets. A process exit or terminal message does not complete the stage. A rejected submission leaves response.txt beside the command; correct it and submit again. The user can also mark done in Twine.\n",
            agent.label,
            stage.name,
            role.instructions,
            self.prompt,
            self.incoming.get(&agent_id).map_or("None", String::as_str),
            command,
            serde_json::to_string_pretty(&example).expect("signal serializes"),
            if self.is_reviewer(agent_id) {
                "Use decision approve or requestChanges. Requested changes require actionable feedback in summary."
            } else {
                "Use decision done."
            }
        )
    }

    pub(crate) fn trace(
        &mut self,
        kind: &str,
        agent_id: Option<u64>,
        target_agent_id: Option<u64>,
        message: &str,
    ) {
        const MAX_TRACES: usize = 512;
        if self.traces.len() == MAX_TRACES {
            self.traces.remove(0);
        }
        self.traces.push(WorkflowTrace {
            sequence: self.traces.last().map_or(1, |event| event.sequence + 1),
            generation: self.generation,
            timestamp: timestamp(),
            kind: kind.to_owned(),
            stage: self.workflow_type.definition.stages[self.stage_index]
                .name
                .clone(),
            agent_id,
            target_agent_id,
            message: message.to_owned(),
        });
    }

    pub(crate) fn finish(&mut self, status: RunStatus, message: &str) {
        let active: Vec<_> = self.active_agents().iter().map(|a| a.agent_id).collect();
        for agent in &mut self.agents {
            if agent.status == RunAgentStatus::Running
                || (agent.status == RunAgentStatus::Waiting
                    && active.contains(&agent.agent_id)
                    && !self.completions.contains_key(&agent.agent_id))
            {
                agent.status = match status {
                    RunStatus::Interrupted => RunAgentStatus::Interrupted,
                    RunStatus::Failed => RunAgentStatus::Failed,
                    _ => RunAgentStatus::Cancelled,
                };
            }
        }
        self.status = status;
        self.message = Some(message.to_owned());
        self.trace("workflowEnded", None, None, message);
    }
}

#[derive(Debug, Error)]
pub enum RunError {
    #[error("The workflow type is invalid.")]
    InvalidType,
    #[error("Enter a prompt of at most 32 KiB.")]
    Prompt,
    #[error("Choose a harness for each role within the type's instance limits.")]
    HarnessChoices,
    #[error("This stage has already advanced or this agent has already finished.")]
    StaleSignal,
    #[error("This role needs an explicit review decision, or done for a non-review role.")]
    Decision,
    #[error("Requested changes need actionable feedback.")]
    Feedback,
    #[error("Provide exactly one sub-task and file set for each assignment receiver.")]
    Assignments,
    #[error("Completion exceeds 64 KiB.")]
    SignalTooLarge,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{BuiltinType, WorkflowTypeDefinition};

    fn run(definition: WorkflowTypeDefinition) -> WorkflowRun {
        let choices: Vec<_> = definition
            .roles
            .iter()
            .flat_map(|r| {
                (0..r.instances.min).map(|_| RoleLaunch {
                    role: r.id.0.clone(),
                    harness: HarnessId::Codex,
                })
            })
            .collect();
        let mut run = WorkflowRun::new(
            WorkflowType {
                reference: WorkflowTypeRef::Builtin(BuiltinType::Adversarial),
                definition,
            },
            "Task".into(),
            &choices,
        )
        .unwrap();
        for (index, agent) in run.agents.iter_mut().enumerate() {
            agent.agent_id = index as u64 + 1;
        }
        run
    }

    fn signal(decision: Decision) -> CompletionSignal {
        CompletionSignal {
            decision,
            summary: "Specific result or feedback".into(),
            assignments: vec![],
        }
    }

    #[test]
    fn review_signals_are_explicit_and_stale_signals_cannot_advance_a_later_round() {
        let mut run = run(BuiltinType::Adversarial.definition());
        assert!(run.complete(1, 1, signal(Decision::Approve)).is_err());
        assert!(run.complete(2, 1, signal(Decision::Approve)).is_err());
        run.complete(1, 1, signal(Decision::Done)).unwrap();
        run.complete(2, 2, signal(Decision::RequestChanges))
            .unwrap();
        let previous = run.clone();
        assert!(run.complete(1, 1, signal(Decision::Done)).is_err());
        assert_eq!(run, previous);
        assert!(run.incoming[&1].contains("feedback"));
        run.complete(1, 3, signal(Decision::Done)).unwrap();
        run.complete(2, 4, signal(Decision::Approve)).unwrap();
        assert_eq!(run.status, RunStatus::Completed);
    }

    #[test]
    fn coordinator_delivers_each_assignment_and_gathers_all_parallel_results() {
        let mut run = run(BuiltinType::Coordinator.definition());
        assert!(run.complete(1, 1, signal(Decision::Done)).is_err());
        let mut split = signal(Decision::Done);
        split.assignments = (1..=2)
            .map(|instance| Assignment {
                role: "worker".into(),
                instance,
                task: format!("Task {instance}"),
                files: vec![format!("file-{instance}")],
            })
            .collect();
        run.complete(1, 1, split).unwrap();
        for (id, instance) in [(2, 1), (3, 2)] {
            let prompt = run.instructions(id, "complete");
            assert!(prompt.contains(&format!("Task {instance}")));
            assert!(prompt.contains(&format!("file-{instance}")));
            assert!(!prompt.contains(&format!("Task {}", 3 - instance)));
        }
        assert!(!run.complete(2, 2, signal(Decision::Done)).unwrap());
        assert_eq!(run.stage_index, 1);
        run.complete(3, 2, signal(Decision::Done)).unwrap();
        assert!(run.incoming[&1].contains("Worker 1"));
        assert!(run.incoming[&1].contains("Worker 2"));
        run.complete(1, 3, signal(Decision::Done)).unwrap();
        assert_eq!(run.status, RunStatus::Completed);
        assert_eq!(run.traces.iter().filter(|t| t.kind == "handoff").count(), 4);
    }

    #[test]
    fn loop_stops_after_the_configured_number_of_returns() {
        let mut run = run(BuiltinType::Adversarial.definition());
        for round in 0..=3 {
            run.complete(1, run.generation, signal(Decision::Done))
                .unwrap();
            run.complete(2, run.generation, signal(Decision::RequestChanges))
                .unwrap();
            assert_eq!(
                run.status,
                if round == 3 {
                    RunStatus::LimitReached
                } else {
                    RunStatus::Running
                }
            );
        }
        assert_eq!(run.rounds["review"], 3);
        assert!(
            run.complete(1, run.generation, signal(Decision::Done))
                .is_err()
        );
    }

    #[test]
    fn a_custom_review_loop_keeps_each_workers_assignment() {
        let mut definition = BuiltinType::Coordinator.definition();
        let adversarial = BuiltinType::Adversarial.definition();
        definition.roles.push(adversarial.roles[1].clone());
        definition.stages[2] = adversarial.stages[1].clone();
        definition.handoffs[1].to = crate::StageRole {
            stage: crate::StageId("review".into()),
            role: crate::RoleId("reviewer".into()),
        };
        let mut feedback = adversarial.handoffs[1].clone();
        feedback.to = crate::StageRole {
            stage: crate::StageId("work".into()),
            role: crate::RoleId("worker".into()),
        };
        definition.handoffs.push(feedback);
        definition.review_loops.push(crate::ReviewLoop {
            review_stage: crate::StageId("review".into()),
            back_to: crate::StageId("work".into()),
            max_rounds: 2,
        });
        let mut run = run(definition);
        let mut split = signal(Decision::Done);
        split.assignments = (1..=2)
            .map(|instance| Assignment {
                role: "worker".into(),
                instance,
                task: format!("Task {instance}"),
                files: vec![format!("file-{instance}")],
            })
            .collect();
        run.complete(1, 1, split).unwrap();
        run.complete(2, 2, signal(Decision::Done)).unwrap();
        run.complete(3, 2, signal(Decision::Done)).unwrap();
        run.complete(4, 3, signal(Decision::RequestChanges))
            .unwrap();
        for (id, instance) in [(2, 1), (3, 2)] {
            let prompt = run.instructions(id, "complete");
            assert!(prompt.contains(&format!("Task {instance}")));
            assert!(prompt.contains(&format!("file-{instance}")));
            assert!(prompt.contains("Specific result or feedback"));
        }
    }
}
