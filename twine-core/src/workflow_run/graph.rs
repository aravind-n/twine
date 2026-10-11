//! Explicit, bounded agent coordination. Busy receivers keep a queue; producers never wait.
use std::collections::{BTreeMap, BTreeSet, VecDeque};

use serde::{Deserialize, Serialize};

use super::{
    CompletionSignal, Decision, MAX_TASK_BYTES, RunAgentStatus, RunError, RunStatus, WorkflowRun,
};
use crate::workflow::timestamp;
use crate::workflow_type::{AgentGraph, GraphEvent, GraphFinish, GraphReceive};

const MAX_QUEUED: usize = 32;

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GraphRun {
    pub started: bool,
    pub ready: BTreeSet<u64>,
    #[serde(default)]
    pub assigned: BTreeSet<u64>,
    #[serde(default)]
    pub assignment_generations: BTreeMap<u64, u64>,
    pub queues: BTreeMap<u64, BTreeMap<String, VecDeque<String>>>,
    pub activations: BTreeMap<u64, u16>,
    pub started_at: BTreeMap<u64, u64>,
    pub finished_links: BTreeSet<String>,
    pub outputs: BTreeMap<u64, GraphOutput>,
    pub selected: Option<u64>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GraphOutput {
    pub agent_id: u64,
    pub label: String,
    pub summary: String,
    pub elapsed_ms: u64,
}

fn feedback_key(definition: &AgentGraph, role: &str, key: &str) -> bool {
    definition.edges.iter().any(|edge| {
        edge.to == role
            && edge.event == GraphEvent::Feedback
            && key.rsplit_once(':').map(|(id, _)| id) == Some(edge.id.as_str())
    })
}

fn sender_message(agents: &[super::RunAgent], key: &str, value: &str) -> String {
    let sender = key
        .rsplit_once(':')
        .and_then(|(_, id)| id.parse::<u64>().ok());
    let label = agents
        .iter()
        .find(|agent| Some(agent.agent_id) == sender)
        .map_or("Agent", |agent| agent.label.as_str());
    format!("From {label}:\n{value}")
}

impl WorkflowRun {
    /// Final review messages use this review's result, never a previous activation's input.
    pub(crate) fn final_review_messages(&self, reviewer_id: u64) -> BTreeMap<u64, String> {
        let Some(graph) = &self.workflow_type.definition.graph else {
            return self.incoming.clone();
        };
        let Some(reviewer) = self
            .agents
            .iter()
            .find(|agent| agent.agent_id == reviewer_id)
        else {
            return BTreeMap::new();
        };
        let Some(signal) = self.completions.get(&reviewer_id) else {
            return BTreeMap::new();
        };
        self.agents
            .iter()
            .filter(|target| {
                graph.edges.iter().any(|edge| {
                    edge.from == reviewer.role
                        && edge.to == target.role
                        && edge.event == GraphEvent::Feedback
                })
            })
            .map(|target| {
                (
                    target.agent_id,
                    format!("From {}:\n{}", reviewer.label, signal.summary),
                )
            })
            .collect()
    }

    #[must_use]
    pub fn stage_name(&self) -> &str {
        if self.graph.is_some() {
            "Graph"
        } else {
            &self.workflow_type.definition.stages[self.stage_index].name
        }
    }
    #[must_use]
    pub fn stage_id(&self) -> &str {
        if self.graph.is_some() {
            "graph"
        } else {
            &self.workflow_type.definition.stages[self.stage_index].id.0
        }
    }

    #[must_use]
    pub fn assignment_generation(&self, agent_id: u64) -> u64 {
        self.graph
            .as_ref()
            .and_then(|graph| graph.assignment_generations.get(&agent_id).copied())
            .unwrap_or(self.generation)
    }

    pub(crate) fn prepare_graph_resume(&mut self) -> Result<(), RunError> {
        if self.graph.is_none() {
            return Ok(());
        }
        let active: Vec<_> = self
            .active_agents()
            .iter()
            .map(|agent| agent.agent_id)
            .collect();
        let counters = active
            .iter()
            .map(|&agent| {
                self.assignment_generation(agent)
                    .checked_add(1)
                    .map(|generation| (agent, generation))
                    .ok_or(RunError::StaleSignal)
            })
            .collect::<Result<Vec<_>, _>>()?;
        for agent in &mut self.agents {
            if active.contains(&agent.agent_id) {
                agent.status = RunAgentStatus::Waiting;
            }
        }
        let graph = self.graph.as_mut().expect("graph");
        graph.ready.extend(active.iter().copied());
        graph.assigned.clear();
        graph.assignment_generations.extend(counters);
        Ok(())
    }

    pub(crate) fn graph_roots(&self) -> Vec<String> {
        self.workflow_type
            .definition
            .graph
            .as_ref()
            .map(|graph| {
                self.workflow_type
                    .definition
                    .roles
                    .iter()
                    .filter(|role| graph.is_start(&role.id.0))
                    .map(|role| role.id.0.clone())
                    .collect()
            })
            .unwrap_or_default()
    }

    pub(crate) fn start_graph_task(&mut self, task: String) -> Result<(), RunError> {
        if self.graph.as_ref().is_none_or(|graph| graph.started)
            || self.status != RunStatus::Running
        {
            return Err(RunError::StaleSignal);
        }
        if task.trim().is_empty() || task.len() > MAX_TASK_BYTES {
            return Err(RunError::Prompt);
        }
        let roots = self.graph_roots();
        self.prompt = task;
        let graph = self.graph.as_mut().expect("graph checked");
        graph.started = true;
        let started = timestamp();
        for agent in &mut self.agents {
            if roots.contains(&agent.role) {
                graph.ready.insert(agent.agent_id);
                graph.started_at.insert(agent.agent_id, started);
                graph.activations.insert(agent.agent_id, 1);
                graph
                    .assignment_generations
                    .entry(agent.agent_id)
                    .or_insert(1);
                self.incoming.insert(agent.agent_id, self.prompt.clone());
                agent.status = RunAgentStatus::Waiting;
            }
        }
        self.trace(
            "taskSubmitted",
            None,
            None,
            "Task sent to the graph's starting roles",
        );
        Ok(())
    }

    /// The first native prompt starts the graph without sending it back to its author.
    pub(crate) fn adopt_graph_task(
        &mut self,
        agent_id: u64,
        task: String,
    ) -> Result<bool, RunError> {
        if self.graph.as_ref().is_none_or(|graph| graph.started) {
            return Ok(false);
        }
        if !self.agents.iter().any(|agent| {
            agent.agent_id == agent_id
                && self
                    .workflow_type
                    .definition
                    .graph
                    .as_ref()
                    .is_some_and(|graph| graph.is_start(&agent.role))
        }) {
            return Err(RunError::StaleSignal);
        }
        self.start_graph_task(task)?;
        self.graph_agent_launched(agent_id);
        self.agents
            .iter_mut()
            .find(|agent| agent.agent_id == agent_id)
            .expect("start agent checked")
            .status = RunAgentStatus::Running;
        Ok(true)
    }

    pub(crate) fn graph_agent_launched(&mut self, agent: u64) {
        if let Some(graph) = &mut self.graph {
            graph.ready.remove(&agent);
            if graph.started {
                graph.assigned.insert(agent);
                graph.started_at.entry(agent).or_insert_with(timestamp);
            }
        }
    }

    pub(crate) fn complete_graph(
        &mut self,
        agent_id: u64,
        generation: u64,
        signal: &CompletionSignal,
    ) -> Result<bool, RunError> {
        // Queue overflow or a bad join must not consume a completion or part of its fan-out.
        let mut next = self.clone();
        let advance = next.complete_graph_inner(agent_id, generation, signal)?;
        *self = next;
        Ok(advance)
    }

    fn complete_graph_inner(
        &mut self,
        agent_id: u64,
        generation: u64,
        signal: &CompletionSignal,
    ) -> Result<bool, RunError> {
        if self.status != RunStatus::Running
            || generation != self.assignment_generation(agent_id)
            || !self
                .active_agents()
                .iter()
                .any(|agent| agent.agent_id == agent_id)
            || self.completions.contains_key(&agent_id)
        {
            return Err(RunError::StaleSignal);
        }
        if serde_json::to_vec(signal)
            .map_err(|_| RunError::SignalTooLarge)?
            .len()
            > super::completion::MAX_SIGNAL_BYTES
        {
            return Err(RunError::SignalTooLarge);
        }
        if !signal.assignments.is_empty() {
            return Err(RunError::Assignments);
        }
        let sender = self
            .agents
            .iter()
            .find(|agent| agent.agent_id == agent_id)
            .ok_or(RunError::StaleSignal)?
            .clone();
        let definition = self
            .workflow_type
            .definition
            .graph
            .as_ref()
            .ok_or(RunError::InvalidType)?
            .clone();
        let event = match signal.decision {
            Decision::Done if !self.is_reviewer(agent_id) => GraphEvent::Done,
            Decision::Approve if self.is_reviewer(agent_id) => GraphEvent::Approved,
            Decision::RequestChanges if self.is_reviewer(agent_id) => GraphEvent::Feedback,
            Decision::PieceReady
                if definition.edges.iter().any(|edge| {
                    edge.from == sender.role && edge.event == GraphEvent::PieceReady
                }) =>
            {
                GraphEvent::PieceReady
            }
            _ => return Err(RunError::Decision),
        };
        if matches!(event, GraphEvent::Feedback | GraphEvent::PieceReady)
            && signal.summary.trim().is_empty()
        {
            return Err(RunError::Feedback);
        }
        if !self.graph.as_ref().expect("graph").started {
            self.adopt_graph_task(agent_id, signal.task.clone())?;
        }
        let piece = event == GraphEvent::PieceReady;
        if !piece {
            self.graph
                .as_mut()
                .expect("graph")
                .assigned
                .remove(&agent_id);
            self.completions.insert(agent_id, signal.clone());
            self.agents
                .iter_mut()
                .find(|agent| agent.agent_id == agent_id)
                .expect("sender")
                .status = RunAgentStatus::Completed;
        }
        self.trace(
            if piece { "pieceReady" } else { "roleCompleted" },
            Some(agent_id),
            None,
            &signal.summary,
        );
        self.dispatch_graph_signal(&sender, event, &signal.summary)?;
        if let Err(error) = self.activate_graph_receivers() {
            if matches!(error, RunError::ActivationLimit) {
                self.finish(RunStatus::LimitReached, "Graph activation limit reached.");
                return Ok(true);
            }
            return Err(error);
        }
        Ok(self.check_graph_finish(piece))
    }

    fn graph_finish_ready(&self) -> bool {
        let Some(graph) = &self.graph else {
            return false;
        };
        let Some(definition) = &self.workflow_type.definition.graph else {
            return false;
        };
        graph.started
            && graph.ready.is_empty()
            && graph.assigned.is_empty()
            && graph
                .queues
                .values()
                .all(|queues| queues.values().all(VecDeque::is_empty))
            && self
                .agents
                .iter()
                .filter(|agent| definition.is_result(&agent.role))
                .all(|agent| graph.outputs.contains_key(&agent.agent_id))
    }

    pub(crate) fn graph_choice_ready(&self) -> bool {
        self.workflow_type
            .definition
            .graph
            .as_ref()
            .is_some_and(|definition| definition.finish == GraphFinish::Choose)
            && self.graph_finish_ready()
    }

    fn check_graph_finish(&mut self, piece: bool) -> bool {
        let active = self
            .graph
            .as_ref()
            .is_some_and(|graph| !graph.ready.is_empty() || !graph.assigned.is_empty());
        if self.graph_finish_ready() {
            if self.graph_choice_ready() {
                self.message = Some("All results are ready. Choose a result.".to_owned());
            } else {
                self.finish(RunStatus::Completed, "Workflow completed");
            }
        } else if !active && !piece {
            self.finish(
                RunStatus::Failed,
                "The graph stopped before all results arrived. Check the links and receive rules.",
            );
        }
        !self.graph.as_ref().expect("graph").ready.is_empty() || self.status != RunStatus::Running
    }

    fn dispatch_graph_signal(
        &mut self,
        sender: &super::RunAgent,
        event: GraphEvent,
        summary: &str,
    ) -> Result<(), RunError> {
        let definition = self
            .workflow_type
            .definition
            .graph
            .as_ref()
            .expect("graph")
            .clone();
        let legacy_results = definition.edges.iter().any(|edge| edge.to == "finish");
        let returns_result = if legacy_results {
            definition
                .edges
                .iter()
                .any(|edge| edge.from == sender.role && edge.to == "finish" && edge.event == event)
        } else {
            definition.is_result(&sender.role)
                && matches!(event, GraphEvent::Done | GraphEvent::Approved)
        };
        if returns_result {
            let graph = self.graph.as_mut().expect("graph");
            graph.outputs.insert(
                sender.agent_id,
                GraphOutput {
                    agent_id: sender.agent_id,
                    label: sender.label.clone(),
                    summary: summary.to_owned(),
                    elapsed_ms: timestamp().saturating_sub(
                        *graph
                            .started_at
                            .get(&sender.agent_id)
                            .unwrap_or(&timestamp()),
                    ),
                },
            );
        }
        for edge in definition
            .edges
            .iter()
            .filter(|edge| edge.from == sender.role && edge.event == event)
        {
            if edge.to == "finish" {
                let graph = self.graph.as_mut().expect("graph");
                graph
                    .finished_links
                    .insert(format!("{}:{}", edge.id, sender.agent_id));
                graph.outputs.insert(
                    sender.agent_id,
                    GraphOutput {
                        agent_id: sender.agent_id,
                        label: sender.label.clone(),
                        summary: summary.to_owned(),
                        elapsed_ms: timestamp().saturating_sub(
                            *graph
                                .started_at
                                .get(&sender.agent_id)
                                .unwrap_or(&timestamp()),
                        ),
                    },
                );
                continue;
            }
            let receivers: Vec<_> = self
                .agents
                .iter()
                .filter(|agent| agent.role == edge.to)
                .map(|agent| agent.agent_id)
                .collect();
            for target in receivers {
                let graph = self.graph.as_mut().expect("graph");
                let queues = graph.queues.entry(target).or_default();
                if queues.values().map(VecDeque::len).sum::<usize>() >= MAX_QUEUED {
                    return Err(RunError::QueueFull);
                }
                queues
                    .entry(format!("{}:{}", edge.id, sender.agent_id))
                    .or_default()
                    .push_back(summary.to_owned());
                self.trace("itemQueued", Some(sender.agent_id), Some(target), summary);
            }
        }
        Ok(())
    }

    fn activate_graph_receivers(&mut self) -> Result<(), RunError> {
        let definition = self
            .workflow_type
            .definition
            .graph
            .as_ref()
            .expect("graph")
            .clone();
        let senders = self.agents.clone();
        for agent in &mut self.agents {
            let graph = self.graph.as_mut().expect("graph");
            if graph.assigned.contains(&agent.agent_id) {
                continue;
            }
            if graph.ready.contains(&agent.agent_id) {
                continue;
            }
            let Some(queues) = graph.queues.get_mut(&agent.agent_id) else {
                continue;
            };
            let required: Vec<_> = definition
                .edges
                .iter()
                .filter(|edge| {
                    edge.to == agent.role
                        && edge.from != "task"
                        && edge.event != GraphEvent::Feedback
                })
                .flat_map(|edge| {
                    senders
                        .iter()
                        .filter(|sender| sender.role == edge.from)
                        .map(move |sender| format!("{}:{}", edge.id, sender.agent_id))
                })
                .collect();
            let all = definition.receive.get(&agent.role) == Some(&GraphReceive::All);
            let feedback = queues.iter().any(|(key, queue)| {
                !queue.is_empty() && feedback_key(&definition, &agent.role, key)
            });
            if all
                && !feedback
                && required
                    .iter()
                    .any(|key| queues.get(key).is_none_or(VecDeque::is_empty))
            {
                continue;
            }
            let mut messages = Vec::new();
            if all && !feedback {
                for key in required {
                    if let Some(value) = queues.get_mut(&key).and_then(VecDeque::pop_front) {
                        messages.push(sender_message(&senders, &key, &value));
                    }
                }
            } else if let Some((key, queue)) = queues.iter_mut().find(|(key, queue)| {
                !queue.is_empty() && (!feedback || feedback_key(&definition, &agent.role, key))
            }) && let Some(value) = queue.pop_front()
            {
                messages.push(sender_message(&senders, key, &value));
            }
            if messages.is_empty() {
                continue;
            }
            let count = graph.activations.entry(agent.agent_id).or_default();
            if *count >= definition.max_activations {
                return Err(RunError::ActivationLimit);
            }
            *count += 1;
            graph.ready.insert(agent.agent_id);
            *graph
                .assignment_generations
                .entry(agent.agent_id)
                .or_default() += 1;
            graph.started_at.insert(agent.agent_id, timestamp());
            graph.outputs.remove(&agent.agent_id);
            for edge in definition
                .edges
                .iter()
                .filter(|edge| edge.from == agent.role && edge.to == "finish")
            {
                graph
                    .finished_links
                    .remove(&format!("{}:{}", edge.id, agent.agent_id));
            }
            self.completions.remove(&agent.agent_id);
            self.incoming.insert(agent.agent_id, messages.join("\n\n"));
            agent.status = RunAgentStatus::Waiting;
        }
        Ok(())
    }

    pub(crate) fn choose_graph_result(
        &mut self,
        agent_id: u64,
        generation: u64,
    ) -> Result<(), RunError> {
        let graph = self.graph.as_ref().ok_or(RunError::InvalidType)?;
        if self.generation != generation
            || self.status != RunStatus::Running
            || !self.graph_choice_ready()
            || !graph.outputs.contains_key(&agent_id)
        {
            return Err(RunError::StaleSignal);
        }
        self.graph.as_mut().expect("graph").selected = Some(agent_id);
        self.trace(
            "resultSelected",
            Some(agent_id),
            None,
            "User selected this result",
        );
        self.finish(RunStatus::Completed, "Result selected");
        Ok(())
    }

    pub(crate) fn graph_instructions(&self, agent_id: u64, command: &str) -> String {
        let agent = self
            .agents
            .iter()
            .find(|agent| agent.agent_id == agent_id)
            .expect("agent");
        let role = self
            .workflow_type
            .definition
            .roles
            .iter()
            .find(|role| role.id.0 == agent.role)
            .expect("role");
        let graph = self.workflow_type.definition.graph.as_ref().expect("graph");
        let routes = graph
            .edges
            .iter()
            .filter(|edge| edge.from == agent.role)
            .map(|edge| format!("{:?} -> {}", edge.event, edge.to))
            .collect::<Vec<_>>()
            .join("\n");
        let decision = if self.is_reviewer(agent_id) {
            "approve"
        } else {
            "done"
        };
        format!(
            "You are {} in a Twine workflow.\n{}\n\nThese are role instructions. Wait for an actual task or handoff. Do not start work at launch.\nAll agents work in this folder. Do not create an isolated checkout.\n\nOutgoing links:\n{routes}\n\nSubmit explicit signals with this command:\n{command} <<'TWINE_COMPLETION'\n{{\"decision\":\"{decision}\",\"summary\":\"Your complete result\",\"task\":\"The user's full task\"}}\nTWINE_COMPLETION\n\nUse pieceReady to send a completed piece without stopping your work. Put the full piece or file references in summary. Do not include assignments. Use done when your assignment is complete. Review roles use approve or requestChanges. A request for changes needs actionable feedback in summary. Include the user's full task in task when you submit the first result or piece. Keep this command for later assignments. Do not infer completion from terminal output. A full receiver queue rejects the signal; retry after the receiver completes work.",
            agent.label, role.instructions
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::workflow_type::{
        AgentGraph, GraphEdge, InstanceCount, Role, RoleId, WorkflowType, WorkflowTypeDefinition,
        WorkflowTypeRef,
    };
    use crate::{HarnessId, RoleLaunch};

    fn run(edges: &[(&str, &str, GraphEvent)], finish: GraphFinish) -> WorkflowRun {
        let roles: BTreeSet<_> = edges
            .iter()
            .flat_map(|(from, to, _)| [*from, *to])
            .filter(|id| *id != "task" && *id != "finish")
            .collect();
        let definition = WorkflowTypeDefinition {
            name: "Graph test".into(),
            description: String::new(),
            roles: roles
                .iter()
                .map(|id| Role {
                    id: RoleId((*id).into()),
                    name: (*id).into(),
                    instructions: "Complete incoming work".into(),
                    instances: InstanceCount::default(),
                    color: None,
                    agent_defaults: None,
                })
                .collect(),
            stages: vec![],
            handoffs: vec![],
            review_loops: vec![],
            graph: Some(AgentGraph {
                edges: edges
                    .iter()
                    .enumerate()
                    .map(|(index, (from, to, event))| GraphEdge {
                        id: index.to_string(),
                        from: (*from).into(),
                        to: (*to).into(),
                        event: *event,
                    })
                    .collect(),
                receive: BTreeMap::new(),
                review_agents: BTreeSet::new(),
                positions: BTreeMap::new(),
                finish,
                max_activations: 32,
            }),
        };
        let choices = roles
            .iter()
            .map(|role| RoleLaunch {
                role: (*role).into(),
                harness: HarnessId::Pi,
                model: None,
                effort: None,
                yolo: false,
            })
            .collect::<Vec<_>>();
        let mut run = WorkflowRun::new(
            WorkflowType {
                reference: WorkflowTypeRef::User {
                    type_id: 1,
                    version: 1,
                },
                definition,
            },
            String::new(),
            &choices,
        )
        .unwrap();
        for (index, agent) in run.agents.iter_mut().enumerate() {
            agent.agent_id = u64::try_from(index + 1).unwrap();
        }
        run.start_graph_task("The exact same user task\nincluding all details".into())
            .unwrap();
        launch_ready(&mut run);
        run
    }

    fn example_run(type_id: u64, file: &str) -> WorkflowRun {
        // Load through the catalog: this tests the actual shareable file envelope and validation.
        let mut store = crate::store::Store::open_in_memory().unwrap();
        std::fs::create_dir_all(&store.workflow_directory).unwrap();
        std::fs::write(store.workflow_directory.join("example.toml"), file).unwrap();
        let workflow_type = crate::workflow_type::WorkflowCatalog::new(&mut store)
            .get(WorkflowTypeRef::User {
                type_id,
                version: 1,
            })
            .unwrap();
        let choices = workflow_type
            .definition
            .roles
            .iter()
            .flat_map(|role| {
                (0..role.instances.min).map(|_| RoleLaunch {
                    role: role.id.0.clone(),
                    harness: HarnessId::Pi,
                    model: None,
                    effort: None,
                    yolo: false,
                })
            })
            .collect::<Vec<_>>();
        let mut run = WorkflowRun::new(workflow_type, String::new(), &choices).unwrap();
        for (index, agent) in run.agents.iter_mut().enumerate() {
            agent.agent_id = u64::try_from(index + 1).unwrap();
        }
        assert_ne!(run.active_agents(), [] as [&super::super::RunAgent; 0]);
        run.start_graph_task("The original user task".into())
            .unwrap();
        launch_ready(&mut run);
        run
    }

    fn adversarial_example() -> WorkflowRun {
        example_run(
            202_610_100_001,
            include_str!("../../../examples/workflows/adversarial.toml"),
        )
    }

    #[test]
    fn idle_resume_advances_the_effective_root_generation() {
        let mut run = adversarial_example();
        run.graph = Some(GraphRun::default());
        run.prompt.clear();
        let old = run.assignment_generation(1);
        run.prepare_graph_resume().unwrap();
        assert_eq!(run.assignment_generation(1), old + 1);
        let mut completion = signal(Decision::Done, "Implementation");
        completion.task = "New task".into();
        assert!(run.complete(1, old, completion.clone()).is_err());
        assert!(run.complete(1, old + 1, completion).is_ok());
    }

    #[test]
    fn adversarial_follow_up_resets_cycle_and_keeps_completion_tokens_fresh() {
        for limit in [false, true] {
            let mut run = adversarial_example();
            if limit {
                run.workflow_type
                    .definition
                    .graph
                    .as_mut()
                    .unwrap()
                    .max_activations = 1;
            }
            let old_root = run.assignment_generation(1);
            run.complete(1, old_root, signal(Decision::Done, "First work"))
                .unwrap();
            launch_ready(&mut run);
            let old_review = run.assignment_generation(2);
            run.complete(
                2,
                old_review,
                signal(
                    if limit {
                        Decision::RequestChanges
                    } else {
                        Decision::Approve
                    },
                    "First review",
                ),
            )
            .unwrap();
            assert_eq!(
                run.status,
                if limit {
                    RunStatus::LimitReached
                } else {
                    RunStatus::Completed
                }
            );
            assert!(run.continue_with(2, run.generation, 0).is_err());
            assert!(run.continue_with(1, run.generation, 0).unwrap());
            assert!(run.needs_task());
            let graph = run.graph.as_ref().unwrap();
            assert!(
                graph.outputs.is_empty() && graph.queues.is_empty() && graph.activations.is_empty()
            );
            assert!(
                run.complete(1, old_root, signal(Decision::Done, "Stale"))
                    .is_err()
            );
            run.adopt_graph_task(1, "Second user task".into()).unwrap();
            let root = run.assignment_generation(1);
            assert!(root > old_root);
            run.complete(1, root, signal(Decision::Done, "Second work"))
                .unwrap();
            launch_ready(&mut run);
            assert!(
                run.complete(2, old_review, signal(Decision::Approve, "Stale"))
                    .is_err()
            );
            run.complete(
                2,
                run.assignment_generation(2),
                signal(Decision::Approve, "Second review"),
            )
            .unwrap();
            assert_eq!(run.status, RunStatus::Completed);
            assert_eq!(run.prompt, "Second user task");
            assert!(!run.continue_with(1, 1, 0).unwrap());
        }
    }

    #[test]
    fn graph_continuation_uses_cycle_generation_after_multiple_review_activations() {
        let mut run = adversarial_example();
        for cycle in 1..=3 {
            for changes in [true, false] {
                run.complete(
                    1,
                    run.assignment_generation(1),
                    signal(Decision::Done, "Work"),
                )
                .unwrap();
                launch_ready(&mut run);
                run.complete(
                    2,
                    run.assignment_generation(2),
                    signal(
                        if changes {
                            Decision::RequestChanges
                        } else {
                            Decision::Approve
                        },
                        "Review",
                    ),
                )
                .unwrap();
                launch_ready(&mut run);
            }
            assert_eq!(run.status, RunStatus::Completed);
            assert_eq!(run.generation, cycle);
            assert!(run.continue_with(1, cycle, 0).unwrap());
            assert_eq!(run.traces.last().unwrap().generation, cycle + 1);
            run.adopt_graph_task(1, format!("Task {}", cycle + 1))
                .unwrap();
        }
    }

    #[test]
    fn adversarial_file_supports_approval_after_zero_to_three_change_requests() {
        for changes in 0..=3_u16 {
            let mut run = adversarial_example();
            for round in 0..=changes {
                let generation = run.assignment_generation(1);
                run.complete(1, generation, signal(Decision::Done, "Implementation"))
                    .unwrap();
                assert!(
                    run.follow_up_instructions(2)
                        .contains("The original user task")
                );
                launch_ready(&mut run);
                let generation = run.assignment_generation(2);
                if round < changes {
                    run.complete(
                        2,
                        generation,
                        signal(Decision::RequestChanges, "Change this"),
                    )
                    .unwrap();
                    assert!(
                        run.follow_up_instructions(1)
                            .contains("The original user task")
                    );
                    launch_ready(&mut run);
                } else {
                    run.complete(2, generation, signal(Decision::Approve, "Final approval"))
                        .unwrap();
                }
            }
            assert_eq!(run.status, RunStatus::Completed);
            assert_eq!(
                run.final_review_messages(2),
                BTreeMap::from([(1, "From Reviewer:\nFinal approval".into())])
            );
            assert_eq!(run.graph.as_ref().unwrap().activations[&1], changes + 1);
        }
    }

    #[test]
    fn adversarial_file_delivers_latest_rejection_without_a_fifth_implementation() {
        let mut run = adversarial_example();
        for round in 1..=4 {
            run.complete(
                1,
                run.assignment_generation(1),
                signal(Decision::Done, "Implementation"),
            )
            .unwrap();
            launch_ready(&mut run);
            run.complete(
                2,
                run.assignment_generation(2),
                signal(Decision::RequestChanges, &format!("Feedback {round}")),
            )
            .unwrap();
            launch_ready(&mut run);
        }
        assert_eq!(run.status, RunStatus::LimitReached);
        assert_eq!(run.active_agents().len(), 0);
        assert_eq!(run.graph.as_ref().unwrap().activations[&1], 4);
        assert_eq!(
            run.final_review_messages(2),
            BTreeMap::from([(1, "From Reviewer:\nFeedback 4".into())])
        );
    }

    #[test]
    fn coordinator_file_reuses_one_coordinator_and_gathers_named_parallel_results() {
        let mut run = example_run(
            202_610_100_002,
            include_str!("../../../examples/workflows/coordinator-shared-plan.toml"),
        );
        assert_eq!(run.active_agents().len(), 1);
        run.complete(1, 1, signal(Decision::PieceReady, "1. Task A\n2. Task B"))
            .unwrap();
        launch_ready(&mut run);
        assert_eq!(run.active_agents().len(), 3);
        assert_eq!(run.incoming[&2], run.incoming[&3]);
        // Results can arrive while the coordinator is still in its split turn.
        run.complete(2, 1, signal(Decision::Done, "Result A"))
            .unwrap();
        assert_eq!(run.assignment_generation(1), 1);
        run.complete(1, 1, signal(Decision::Done, "Plan sent"))
            .unwrap();
        assert_eq!(run.status, RunStatus::Running);
        assert_eq!(run.active_agents().len(), 1);
        run.complete(3, 1, signal(Decision::Done, "Result B"))
            .unwrap();
        assert_eq!(run.assignment_generation(1), 2);
        assert_eq!(
            run.incoming[&1],
            "From Worker 1:\nResult A\n\nFrom Worker 2:\nResult B"
        );
        assert!(
            run.follow_up_instructions(1)
                .contains("The original user task")
        );
        assert!(run.graph.as_ref().unwrap().outputs.is_empty());
        launch_ready(&mut run);
        run.complete(1, 2, signal(Decision::Done, "Combined result"))
            .unwrap();
        assert_eq!(run.status, RunStatus::Completed);
        let graph = run.graph.as_ref().unwrap();
        assert_eq!(graph.activations, BTreeMap::from([(1, 2), (2, 1), (3, 1)]));
        assert_eq!(graph.outputs[&1].summary, "Combined result");
    }

    fn launch_ready(run: &mut WorkflowRun) {
        let ready = run.graph.as_ref().unwrap().ready.clone();
        for id in ready {
            run.graph_agent_launched(id);
            run.agents
                .iter_mut()
                .find(|agent| agent.agent_id == id)
                .unwrap()
                .status = RunAgentStatus::Running;
        }
    }

    fn signal(decision: Decision, summary: &str) -> CompletionSignal {
        CompletionSignal {
            decision,
            summary: summary.into(),
            assignments: vec![],
            task: String::new(),
        }
    }

    #[test]
    fn parallel_results_wait_for_selection_and_keep_both_outputs() {
        let mut run = run(
            &[
                ("task", "a", GraphEvent::Task),
                ("task", "b", GraphEvent::Task),
                ("a", "finish", GraphEvent::Done),
                ("b", "finish", GraphEvent::Done),
            ],
            GraphFinish::Choose,
        );
        assert_eq!(run.initial_task(1), run.initial_task(2));
        assert_eq!(run.active_agents().len(), 2);
        run.complete(1, 1, signal(Decision::Done, "First result"))
            .unwrap();
        assert_eq!(run.active_agents().len(), 1);
        assert!(run.choose_graph_result(1, 1).is_err());
        run.complete(2, 1, signal(Decision::Done, "Second result"))
            .unwrap();
        assert_eq!(run.status, RunStatus::Running);
        assert_eq!(run.graph.as_ref().unwrap().outputs.len(), 2);
        run.status = RunStatus::Interrupted;
        run.prepare_graph_resume().unwrap();
        run.status = RunStatus::Running;
        run.message = None;
        run.generation += 1;
        assert_eq!(run.active_agents().len(), 0);
        run.choose_graph_result(2, 2).unwrap();
        assert_eq!(run.status, RunStatus::Completed);
        assert_eq!(run.graph.as_ref().unwrap().selected, Some(2));
    }

    #[test]
    fn pieces_start_the_receiver_while_the_producer_runs_and_queue_busy_work() {
        let mut run = run(
            &[
                ("task", "a", GraphEvent::Task),
                ("a", "b", GraphEvent::PieceReady),
                ("b", "finish", GraphEvent::Done),
            ],
            GraphFinish::All,
        );
        assert!(
            run.complete(1, 1, signal(Decision::PieceReady, "Piece one"))
                .unwrap()
        );
        assert_eq!(run.agents[0].status, RunAgentStatus::Running);
        assert!(!run.completions.contains_key(&1));
        launch_ready(&mut run);
        assert!(
            !run.complete(1, 1, signal(Decision::PieceReady, "Piece two"))
                .unwrap()
        );
        run.complete(1, 1, signal(Decision::Done, "Producer done"))
            .unwrap();
        assert!(
            run.complete(2, 1, signal(Decision::Done, "Port one"))
                .unwrap()
        );
        assert!(run.incoming[&2].contains("Piece two"));
        assert_eq!(run.assignment_generation(2), 2);
        launch_ready(&mut run);
        assert!(matches!(
            run.complete(2, 1, signal(Decision::Done, "Stale")),
            Err(RunError::StaleSignal)
        ));
        run.complete(2, 2, signal(Decision::Done, "Port two"))
            .unwrap();
        assert_eq!(run.status, RunStatus::Completed);
        assert_eq!(run.graph.as_ref().unwrap().outputs[&2].summary, "Port two");
        assert_eq!(
            run.traces
                .iter()
                .filter(|event| event.kind == "roleCompleted" && event.agent_id == Some(2))
                .map(|event| event.generation)
                .collect::<Vec<_>>(),
            [1, 2]
        );
    }

    #[test]
    fn a_full_queue_rejects_the_whole_fan_out_without_consuming_the_signal() {
        let mut run = run(
            &[
                ("task", "a", GraphEvent::Task),
                ("a", "b", GraphEvent::PieceReady),
                ("b", "finish", GraphEvent::Done),
            ],
            GraphFinish::All,
        );
        run.complete(1, 1, signal(Decision::PieceReady, "First"))
            .unwrap();
        launch_ready(&mut run);
        for _ in 0..MAX_QUEUED {
            run.complete(1, 1, signal(Decision::PieceReady, "Queued"))
                .unwrap();
        }
        let before = run.clone();
        assert!(matches!(
            run.complete(1, 1, signal(Decision::PieceReady, "Overflow")),
            Err(RunError::QueueFull)
        ));
        assert_eq!(run, before);
    }

    #[test]
    fn all_inputs_join_only_after_every_sender_and_blocked_joins_end() {
        let mut run = run(
            &[
                ("task", "a", GraphEvent::Task),
                ("task", "b", GraphEvent::Task),
                ("a", "c", GraphEvent::Done),
                ("b", "c", GraphEvent::Done),
                ("c", "finish", GraphEvent::Done),
            ],
            GraphFinish::All,
        );
        run.workflow_type
            .definition
            .graph
            .as_mut()
            .unwrap()
            .receive
            .insert("c".into(), GraphReceive::All);
        run.complete(1, 1, signal(Decision::Done, "A")).unwrap();
        assert!(run.graph.as_ref().unwrap().ready.is_empty());
        run.complete(2, 1, signal(Decision::Done, "B")).unwrap();
        assert!(run.incoming[&3].contains('A') && run.incoming[&3].contains('B'));
        launch_ready(&mut run);
        run.complete(3, 1, signal(Decision::Done, "Joined"))
            .unwrap();
        assert_eq!(run.status, RunStatus::Completed);

        let mut blocked = tests::run(
            &[
                ("task", "a", GraphEvent::Task),
                ("a", "b", GraphEvent::PieceReady),
                ("a", "b", GraphEvent::Done),
                ("b", "finish", GraphEvent::Done),
            ],
            GraphFinish::All,
        );
        blocked
            .workflow_type
            .definition
            .graph
            .as_mut()
            .unwrap()
            .receive
            .insert("b".into(), GraphReceive::All);
        blocked
            .complete(1, 1, signal(Decision::Done, "No piece"))
            .unwrap();
        assert_eq!(blocked.status, RunStatus::Failed);
    }

    #[test]
    fn feedback_uses_exact_link_ids_and_does_not_consume_a_pending_join_item() {
        let mut run = run(
            &[
                ("task", "b", GraphEvent::Task),
                ("task", "c", GraphEvent::Task),
                ("b", "a", GraphEvent::Done),
                ("c", "a", GraphEvent::PieceReady),
                ("c", "a", GraphEvent::Feedback),
                ("c", "finish", GraphEvent::Approved),
                ("a", "finish", GraphEvent::Done),
            ],
            GraphFinish::All,
        );
        let graph = run.workflow_type.definition.graph.as_mut().unwrap();
        graph.receive.insert("a".into(), GraphReceive::All);
        for edge in &mut graph.edges {
            if edge.event == GraphEvent::Feedback {
                edge.id = "a".into();
            }
            if edge.from == "b" && edge.to == "a" {
                edge.id = "a:x".into();
            }
        }
        let encoded = toml::to_string(&run.workflow_type.definition).unwrap();
        run.workflow_type.definition = toml::from_str(&encoded).unwrap();
        crate::workflow_type::validate(&run.workflow_type.definition).unwrap();
        run.complete(2, 1, signal(Decision::Done, "Pending normal item"))
            .unwrap();
        assert!(!run.graph.as_ref().unwrap().ready.contains(&1));
        run.complete(3, 1, signal(Decision::RequestChanges, "Actual feedback"))
            .unwrap();
        assert!(run.graph.as_ref().unwrap().ready.contains(&1));
        assert!(run.incoming[&1].contains("Actual feedback"));
        assert!(!run.incoming[&1].contains("Pending normal item"));
        assert_eq!(run.graph.as_ref().unwrap().queues[&1]["a:x:2"].len(), 1);
    }

    #[test]
    fn graph_recovery_keeps_the_assignment_and_elapsed_times_are_independent() {
        let mut run = run(
            &[
                ("task", "a", GraphEvent::Task),
                ("task", "b", GraphEvent::Task),
                ("a", "finish", GraphEvent::Done),
                ("b", "finish", GraphEvent::Done),
            ],
            GraphFinish::Timed,
        );
        let now = timestamp();
        run.graph
            .as_mut()
            .unwrap()
            .started_at
            .insert(1, now.saturating_sub(100));
        run.graph
            .as_mut()
            .unwrap()
            .started_at
            .insert(2, now.saturating_sub(20));
        run.complete(1, 1, signal(Decision::Done, "A")).unwrap();
        run.agents[1].status = RunAgentStatus::Interrupted;
        run.status = RunStatus::Interrupted;
        assert_eq!(run.active_agents()[0].agent_id, 2);
        run.prepare_graph_resume().unwrap();
        run.status = RunStatus::Running;
        launch_ready(&mut run);
        run.complete(2, run.assignment_generation(2), signal(Decision::Done, "B"))
            .unwrap();
        assert_eq!(run.status, RunStatus::Completed);
        assert!(run.graph.as_ref().unwrap().outputs[&1].elapsed_ms >= 100);
        assert!(run.graph.as_ref().unwrap().outputs[&2].elapsed_ms >= 20);
    }

    #[test]
    fn an_approved_only_role_can_finish_and_feedback_loops_are_bounded() {
        let mut approved = run(
            &[
                ("task", "a", GraphEvent::Task),
                ("a", "finish", GraphEvent::Approved),
            ],
            GraphFinish::All,
        );
        assert!(approved.is_reviewer(1));
        approved
            .complete(1, 1, signal(Decision::Approve, "Approved"))
            .unwrap();
        assert_eq!(approved.status, RunStatus::Completed);
        let mut run = run(
            &[
                ("task", "a", GraphEvent::Task),
                ("a", "b", GraphEvent::Done),
                ("b", "a", GraphEvent::Feedback),
                ("b", "finish", GraphEvent::Approved),
            ],
            GraphFinish::All,
        );
        run.workflow_type
            .definition
            .graph
            .as_mut()
            .unwrap()
            .max_activations = 1;
        run.complete(1, 1, signal(Decision::Done, "Result"))
            .unwrap();
        launch_ready(&mut run);
        run.complete(2, 1, signal(Decision::RequestChanges, "Change this"))
            .unwrap();
        assert_eq!(run.status, RunStatus::LimitReached);
    }
}
