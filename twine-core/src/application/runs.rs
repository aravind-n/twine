use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use super::run_inputs::AgentInput;
use super::workflows::reject;
use super::{Application, ApplicationError, CommandDisposition};
use crate::event::{EventKind, StateEvent};
use crate::harness::{HarnessId, LocatedHarness};
use crate::terminal::{TerminalId, TerminalSize, TerminalStatus};
use crate::workflow::{
    Agent, AgentId, Workflow, WorkflowId, WorkflowKind, WorkflowStatus, timestamp,
};
use crate::workflow_run::completion::{CompletionCommand, CompletionInbox};
use crate::workflow_run::{CompletionSignal, RoleLaunch, RunStatus, WorkflowRun};
use crate::workflow_type::{WorkflowCatalog, WorkflowType, WorkflowTypeRef};

pub(super) struct RunProcesses {
    folder: PathBuf,
    size: TerminalSize,
    harnesses: HashMap<HarnessId, LocatedHarness>,
    inboxes: HashMap<AgentId, (u64, CompletionInbox)>,
    completion_commands: HashMap<AgentId, CompletionCommand>,
    completion_routing: HashMap<AgentId, CompletionRouting>,
    inputs: HashMap<TerminalId, Arc<Mutex<AgentInput>>>,
    /// Accepted helpers keep their receipt until they consume it; their harness remains alive.
    retired_inboxes: std::collections::VecDeque<(Instant, CompletionInbox)>,
    resumed_sessions: HashMap<AgentId, String>,
}

const PROMPT_HOOK_TIMEOUT: Duration = Duration::from_secs(2);

enum CompletionRouting {
    AwaitingSubmission(u64),
    AwaitingPrompt(u64, Instant),
    Active(u64),
    Private,
}

impl CompletionRouting {
    fn generation(&self) -> Option<u64> {
        match self {
            Self::AwaitingSubmission(generation)
            | Self::AwaitingPrompt(generation, _)
            | Self::Active(generation) => Some(*generation),
            Self::Private => None,
        }
    }
}

impl RunProcesses {
    fn finish_assignment(&mut self, agent: AgentId, advance: bool) {
        if let Some(command) = self.completion_commands.get(&agent) {
            command.deactivate();
        }
        if let Some((_, inbox)) = self.inboxes.remove(&agent) {
            inbox.accept();
            self.retire_inbox(inbox);
        }
        if advance {
            for (_, (_, inbox)) in std::mem::take(&mut self.inboxes) {
                inbox.reject(
                    "This assignment ended before completion. Wait for your next assignment.",
                );
                self.retire_inbox(inbox);
            }
            for command in self.completion_commands.values() {
                command.deactivate();
            }
        }
    }

    fn continuation_prompt(
        &mut self,
        run: &WorkflowRun,
        agent: u64,
        inbox: &CompletionInbox,
        user: bool,
        previous_turn_finished: bool,
    ) -> String {
        if let Some(command) = self.completion_commands.get(&AgentId(agent)) {
            // Manual completion can advance while the old turn is still working. A prompt
            // attributed to this assignment activates its helper after older turns finish.
            command.deactivate();
            if previous_turn_finished
                && !matches!(
                    self.completion_routing.get(&AgentId(agent)),
                    Some(CompletionRouting::Private)
                )
            {
                self.completion_routing.insert(
                    AgentId(agent),
                    CompletionRouting::AwaitingSubmission(run.generation),
                );
                return if user {
                    String::new()
                } else {
                    run.follow_up_instructions(agent)
                };
            }
        }
        self.completion_routing
            .insert(AgentId(agent), CompletionRouting::Private);
        format!(
            "Use this completion command for the current assignment: {}\n{}",
            inbox.command(),
            if user {
                "Continue with the user's next message.".to_owned()
            } else {
                run.follow_up_instructions(agent)
            }
        )
    }

    fn command_for(&mut self, agent: AgentId, inbox: &CompletionInbox) -> std::io::Result<String> {
        let command = match self.completion_commands.entry(agent) {
            std::collections::hash_map::Entry::Occupied(entry) => entry.into_mut(),
            std::collections::hash_map::Entry::Vacant(entry) => {
                entry.insert(CompletionCommand::new()?)
            }
        };
        command.bind(inbox)?;
        Ok(command.command())
    }

    fn retire_inbox(&mut self, inbox: CompletionInbox) {
        self.reap_inboxes();
        if inbox.receipt_pending() {
            // Normally one receipt per live agent is outstanding. Bound abandoned helpers too.
            if self.retired_inboxes.len() == 64 {
                self.retired_inboxes.pop_front();
            }
            self.retired_inboxes.push_back((Instant::now(), inbox));
        }
    }

    fn reap_inboxes(&mut self) {
        self.retired_inboxes.retain(|(accepted_at, inbox)| {
            inbox.receipt_pending() && accepted_at.elapsed() < Duration::from_secs(15)
        });
    }
}

fn workflow_launch_options(agent: &crate::RunAgent) -> crate::harness::launch::LaunchOptions<'_> {
    crate::harness::launch::validate_options(
        agent.harness,
        agent.model.as_deref(),
        agent.effort.as_deref(),
        agent.yolo,
    )
    .unwrap_or_else(|| {
        // A stored choice that no longer validates starts with the harness's defaults.
        tracing::warn!(
            agent_id = agent.agent_id,
            harness = ?agent.harness,
            "stored model choice no longer validates; starting with the harness defaults"
        );
        crate::harness::launch::LaunchOptions::default()
    })
}

fn final_review_feedback(agents: &[Agent], run: &WorkflowRun) -> Vec<(TerminalId, String)> {
    run.incoming.iter().filter_map(|(target, message)| {
                    let terminal = agents.iter().find(|agent| agent.agent_id.0 == *target)?.terminal_id;
                    Some((terminal, format!(
                        "{message}\n{}\n",
                        if run.status == RunStatus::Completed {
                            "The review is complete. Wait for the user's next message."
                        } else {
                            "The review limit was reached. Discuss this feedback with the user before continuing."
                        }
                    )))
                }).collect::<Vec<_>>()
}

struct PreparedAgent {
    agent: crate::RunAgent,
    inbox: CompletionInbox,
    reserved: TerminalId,
    arguments: Vec<std::ffi::OsString>,
    hooks: Option<crate::harness::steps::StepInbox>,
    /// Existing interactive agents receive the next assignment in their terminal.
    continuation: Option<String>,
}

impl Application {
    /// Lists built-in and stored custom types for launch forms.
    ///
    /// # Errors
    /// Returns an error when the catalog cannot be read.
    pub fn workflow_types(&self) -> Result<Vec<WorkflowType>, ApplicationError> {
        Ok(WorkflowCatalog::new(self.lock_inner()?.folders.store()).list()?)
    }

    pub(super) fn start_workflow_run(
        &self,
        workflow_id: WorkflowId,
        reference: WorkflowTypeRef,
        prompt: String,
        choices: &[RoleLaunch],
        size: TerminalSize,
    ) -> Result<CommandDisposition, ApplicationError> {
        let folder = match self.draft_folder(workflow_id)? {
            Ok(folder) => folder,
            Err(rejection) => return Ok(rejection),
        };
        let workflow_type =
            match WorkflowCatalog::new(self.lock_inner()?.folders.store()).get(reference) {
                Ok(workflow_type) => workflow_type,
                Err(error) => return Ok(super::rejection("invalidWorkflowType", &error)),
            };
        let mut run = match WorkflowRun::new(workflow_type, prompt, choices) {
            Ok(run) => run,
            Err(error) => return Ok(super::rejection("invalidWorkflowRun", &error)),
        };
        let mut harnesses = HashMap::new();
        for agent in &run.agents {
            if let std::collections::hash_map::Entry::Vacant(entry) = harnesses.entry(agent.harness)
            {
                match self.locate_harness(agent.harness.definition()) {
                    Ok(located) => {
                        entry.insert(located);
                    }
                    Err(error) => return Ok(super::rejection("harnessNotFound", &error)),
                }
            }
        }
        let placeholder = {
            let mut inner = self.lock_inner()?;
            inner
                .folders
                .store()
                .start_workflow_run(workflow_id, &mut run)?;
            let workflow = inner
                .workflows
                .workflows
                .iter_mut()
                .find(|w| w.workflow_id == workflow_id)
                .expect("draft validated under command lock");
            let placeholder = workflow.terminal_id;
            workflow.kind = WorkflowKind::Agents;
            workflow.restored = false;
            workflow.terminal_history.clear();
            workflow.name.clone_from(&run.workflow_type.definition.name);
            workflow.terminal_id = TerminalId::from_value(0);
            workflow.agents = run
                .agents
                .iter()
                .map(|a| Agent {
                    agent_id: AgentId(a.agent_id),
                    role: a.label.clone(),
                    terminal_id: TerminalId::from_value(0),
                })
                .collect();
            workflow.status = WorkflowStatus::Running;
            workflow.started_at = timestamp();
            workflow.ended_at = None;
            workflow.run = Some(Box::new(run));
            let changed = workflow.clone();
            inner.terminals.remove(&placeholder);
            inner
                .events
                .append(EventKind::State(StateEvent::WorkflowChanged(changed)))?;
            if let Ok(observation) = self.terminals.observe(placeholder)
                && let Err(error) = inner.stop_trace(
                    placeholder,
                    observation,
                    "Shell stopped when its workflow started.",
                )
            {
                tracing::warn!(%error, "couldn't record the placeholder shell ending");
            }
            placeholder
        };
        if placeholder.value() != 0 {
            let _ = self.terminals.close(placeholder);
        }
        self.run_processes
            .lock()
            .map_err(|_| ApplicationError::Poisoned)?
            .insert(
                workflow_id,
                RunProcesses {
                    folder,
                    size,
                    harnesses,
                    inboxes: HashMap::new(),
                    completion_commands: HashMap::new(),
                    completion_routing: HashMap::new(),
                    inputs: HashMap::new(),
                    retired_inboxes: std::collections::VecDeque::new(),
                    resumed_sessions: HashMap::new(),
                },
            );
        self.launch_workflow_stage(workflow_id, false)?;
        Ok(CommandDisposition::Accepted)
    }

    /// Resume only a fully identified interrupted stage. Finished roles keep their completion,
    /// while every unfinished role receives a fresh completion inbox and the same conversation.
    pub(super) fn resume_workflow_run(
        &self,
        saved: &Workflow,
        folder: &std::path::Path,
    ) -> Result<(), ApplicationError> {
        let Some(saved_run) = &saved.run else {
            return Ok(());
        };
        if saved_run.status != RunStatus::Interrupted {
            return Ok(());
        }
        let mut sessions = HashMap::new();
        {
            let mut inner = self.lock_inner()?;
            for agent in saved_run
                .active_agents()
                .into_iter()
                .filter(|a| !saved_run.completions.contains_key(&a.agent_id))
            {
                let Some(tab) = saved.agents.iter().find(|a| a.agent_id.0 == agent.agent_id) else {
                    return Ok(());
                };
                let Some(session) = inner.folders.store().harness_session(tab.terminal_id)? else {
                    return Ok(());
                };
                if crate::harness::resume::arguments(agent.harness, &session).is_none() {
                    return Ok(());
                }
                sessions.insert(tab.agent_id, session);
            }
        }
        if sessions.is_empty() {
            return Ok(());
        }
        let mut harnesses = HashMap::new();
        for agent in &saved_run.agents {
            if let std::collections::hash_map::Entry::Vacant(entry) = harnesses.entry(agent.harness)
            {
                match self.locate_harness(agent.harness.definition()) {
                    Ok(located) => {
                        entry.insert(located);
                    }
                    Err(error) => {
                        tracing::warn!(%error, "couldn't locate a restored workflow harness");
                        return Ok(());
                    }
                }
            }
        }
        let mut workflow = saved.clone();
        let run = workflow.run.as_mut().expect("restored workflow has a run");
        run.status = RunStatus::Running;
        run.generation += 1;
        run.message = None;
        run.trace(
            "workflowResumed",
            None,
            None,
            "Resuming interrupted agent sessions",
        );
        workflow.status = WorkflowStatus::Running;
        workflow.ended_at = None;
        {
            let mut inner = self.lock_inner()?;
            let Some(index) = inner
                .workflows
                .workflows
                .iter()
                .position(|w| w.workflow_id == saved.workflow_id)
            else {
                return Ok(());
            };
            inner.publish_run(index, workflow)?;
        }
        self.run_processes
            .lock()
            .map_err(|_| ApplicationError::Poisoned)?
            .insert(
                saved.workflow_id,
                RunProcesses {
                    folder: folder.to_owned(),
                    size: super::resume_agents::RESTORED_SIZE,
                    harnesses,
                    inboxes: HashMap::new(),
                    completion_commands: HashMap::new(),
                    completion_routing: HashMap::new(),
                    inputs: HashMap::new(),
                    retired_inboxes: std::collections::VecDeque::new(),
                    resumed_sessions: sessions,
                },
            );
        self.launch_workflow_stage(saved.workflow_id, false)
    }

    fn prepare_workflow_stage(
        &self,
        run: &mut WorkflowRun,
        processes: &mut RunProcesses,
        live_terminals: &HashMap<AgentId, TerminalId>,
        user_follow_up: bool,
    ) -> Vec<PreparedAgent> {
        let active: Vec<_> = run
            .active_agents()
            .into_iter()
            .filter(|agent| !run.completions.contains_key(&agent.agent_id))
            .cloned()
            .collect();
        // Reserve every transcript outside application state locks; storage can wait on disk.
        let mut prepared = Vec::new();
        for agent in active {
            let Ok(inbox) = CompletionInbox::new() else {
                run.finish(RunStatus::Failed, "Couldn't create the completion command.");
                break;
            };
            if let Some(&terminal) = live_terminals.get(&AgentId(agent.agent_id)) {
                let finished = self.harness_turn_finished(terminal).unwrap_or(false);
                let prompt = processes.continuation_prompt(
                    run,
                    agent.agent_id,
                    &inbox,
                    user_follow_up,
                    finished,
                );
                prepared.push(PreparedAgent {
                    agent,
                    inbox,
                    reserved: terminal,
                    arguments: Vec::new(),
                    hooks: None,
                    continuation: Some(prompt),
                });
                continue;
            }
            match self.terminals.reserve_terminal() {
                Ok(reserved) => {
                    let options = workflow_launch_options(&agent);
                    let (mut arguments, hooks) =
                        self.harness_arguments(agent.harness, reserved, options, "");
                    let command = if hooks.is_some() {
                        let Ok(command) = processes.command_for(AgentId(agent.agent_id), &inbox)
                        else {
                            let _ = self.terminals.cancel_reserved_terminal(reserved);
                            run.finish(
                                RunStatus::Failed,
                                "Couldn't prepare the agent's completion command.",
                            );
                            break;
                        };
                        processes
                            .completion_routing
                            .remove(&AgentId(agent.agent_id));
                        command
                    } else {
                        processes
                            .completion_commands
                            .remove(&AgentId(agent.agent_id));
                        inbox.command()
                    };
                    let session = processes.resumed_sessions.get(&AgentId(agent.agent_id));
                    if let Some(session) = session {
                        arguments.extend(
                            crate::harness::resume::arguments(agent.harness, session)
                                .expect("resume handles validated before restarting a workflow"),
                        );
                        arguments.extend(agent.harness.definition().arguments(&format!(
                            "Resume this conversation and your current assignment. \
                             Your completion command is now {}; keep using it for subsequent assignments.\n\n{}",
                            command,
                            run.follow_up_instructions(agent.agent_id),
                        )));
                    } else {
                        arguments.extend(
                            agent
                                .harness
                                .definition()
                                .arguments(&run.instructions(agent.agent_id, &command)),
                        );
                    }
                    prepared.push(PreparedAgent {
                        agent,
                        inbox,
                        reserved,
                        arguments,
                        hooks,
                        continuation: None,
                    });
                }
                Err(error) => {
                    run.finish(
                        RunStatus::Failed,
                        &format!("Couldn't reserve a terminal: {error}"),
                    );
                    break;
                }
            }
        }
        prepared
    }

    #[expect(
        clippy::too_many_lines,
        reason = "process, session, inbox, and trace cleanup stay paired during launch"
    )]
    fn launch_workflow_stage(
        &self,
        workflow_id: WorkflowId,
        user_follow_up: bool,
    ) -> Result<(), ApplicationError> {
        let mut process_guard = self
            .run_processes
            .lock()
            .map_err(|_| ApplicationError::Poisoned)?;
        let Some(processes) = process_guard.get_mut(&workflow_id) else {
            return Ok(());
        };
        let inner = self.lock_inner()?;
        let Some(index) = inner
            .workflows
            .workflows
            .iter()
            .position(|w| w.workflow_id == workflow_id)
        else {
            return Ok(());
        };
        let mut workflow = inner.workflows.workflows[index].clone();
        let mut live_terminals: HashMap<_, _> = workflow
            .agents
            .iter()
            .filter_map(|agent| {
                (inner.terminals.get(&agent.terminal_id) == Some(&TerminalStatus::Running))
                    .then_some((agent.agent_id, agent.terminal_id))
            })
            .collect();
        drop(inner);
        live_terminals.retain(|_, terminal| self.terminals.is_running(*terminal));
        let run = workflow.run.as_mut().expect("execution has a run");
        run.trace("stageStarted", None, None, "Stage started");
        let prepared = self.prepare_workflow_stage(run, processes, &live_terminals, user_follow_up);
        let mut inner = self.lock_inner()?;
        let mut replaced = Vec::new();
        let mut unused = Vec::new();
        let mut step_hooks = Vec::new();
        let mut continuations = Vec::new();
        for PreparedAgent {
            agent,
            inbox,
            reserved,
            arguments,
            hooks,
            continuation,
        } in prepared
        {
            if run.status != RunStatus::Running {
                if continuation.is_none() {
                    unused.push(reserved);
                }
                continue;
            }
            let located = &processes.harnesses[&agent.harness];
            let continued = continuation.is_some();
            let launched = if let Some(prompt) = continuation {
                continuations.push((reserved, prompt));
                Ok(reserved)
            } else {
                self.terminals.start_program(
                    reserved,
                    &processes.folder,
                    &located.program,
                    &arguments,
                    &located.path,
                    crate::harness::launch::launch_environment(agent.harness),
                    processes.size,
                    Arc::new(self.exit_callback()),
                )
            };
            match launched {
                Ok(terminal_id) => {
                    processes.inputs.entry(terminal_id).or_default();
                    if let Some(hooks) = hooks {
                        step_hooks.push((terminal_id, hooks));
                    }
                    if let Some(previous) = inner.record_agent_launch(
                        &mut workflow.agents,
                        run,
                        agent.agent_id,
                        terminal_id,
                    ) {
                        replaced.push(previous);
                    }
                    processes
                        .inboxes
                        .insert(AgentId(agent.agent_id), (run.generation, inbox));
                    run.trace(
                        if continued {
                            "agentContinued"
                        } else {
                            "agentStarted"
                        },
                        Some(agent.agent_id),
                        None,
                        if continued {
                            "Assignment continued in the existing harness"
                        } else {
                            "Harness started"
                        },
                    );
                    if continued {
                        run.traces
                            .last_mut()
                            .expect("continuation was traced")
                            .anchor = self.terminals.observe(terminal_id).ok().map(|observation| {
                            crate::TraceAnchor {
                                terminal_id,
                                byte_offset: observation.byte_offset,
                                boundary_sizes: observation.boundary_sizes,
                            }
                        });
                    }
                }
                Err(error) => {
                    run.finish(
                        RunStatus::Failed,
                        &format!("Couldn't start {}: {error}", agent.label),
                    );
                }
            }
        }
        workflow.status = workflow_status(run.status);
        if run.status != RunStatus::Running {
            workflow.ended_at = Some(timestamp());
            processes.inboxes.clear();
        }
        let resumed: Vec<_> = workflow
            .agents
            .iter()
            .filter_map(|agent| {
                processes
                    .resumed_sessions
                    .get(&agent.agent_id)
                    .map(|session| (agent.terminal_id, session.as_str()))
            })
            .collect();
        let saved = inner.publish_launch(index, &mut workflow, &resumed);
        processes.resumed_sessions.clear();
        processes
            .inputs
            .retain(|terminal, _| workflow.terminal_ids().contains(terminal));
        if workflow.status != WorkflowStatus::Running {
            processes.inboxes.clear();
        }
        let failed_terminals = if workflow.status == WorkflowStatus::Failed {
            workflow.terminal_ids()
        } else {
            Vec::new()
        };
        drop(inner);
        drop(process_guard);
        self.register_stage_steps(workflow_id, step_hooks);
        self.stop_run_terminals(&failed_terminals, "Workflow launch failed; agent stopped.");
        for id in unused {
            let _ = self.terminals.cancel_reserved_terminal(id);
        }
        let replaced: Vec<_> = replaced
            .into_iter()
            .filter(|id| {
                !workflow
                    .terminal_history
                    .iter()
                    .any(|entry| entry.terminal_id == *id)
            })
            .collect();
        self.terminals.close_all(&replaced)?;
        saved?;
        // PTY writes can wait for the harness to read. Keep them outside application state locks.
        if workflow.status == WorkflowStatus::Running {
            for (terminal, prompt) in continuations {
                if prompt.is_empty() {
                    continue;
                }
                if let Err(error) = self.notify_workflow_agent(terminal, &prompt) {
                    let mut inner = self.lock_inner()?;
                    let mut workflow = inner.workflows.workflows[index].clone();
                    workflow.run.as_mut().expect("workflow has a run").finish(
                        RunStatus::Failed,
                        "Couldn't send the next assignment to the agent.",
                    );
                    workflow.status = WorkflowStatus::Failed;
                    workflow.ended_at = Some(timestamp());
                    let terminals = workflow.terminal_ids();
                    inner.publish_run_best_effort(index, workflow)?;
                    drop(inner);
                    self.stop_run_terminals(
                        &terminals,
                        "Assignment delivery failed; agent stopped.",
                    );
                    return Err(error);
                }
            }
        }
        Ok(())
    }

    pub(super) fn complete_workflow_role(
        &self,
        workflow_id: WorkflowId,
        agent_id: AgentId,
        generation: u64,
        signal: CompletionSignal,
    ) -> Result<CommandDisposition, ApplicationError> {
        self.poll_harness_steps()?;
        let (advance, running, feedback, generation, mode_revision) = {
            let mut inner = self.lock_inner()?;
            let Some(index) = inner
                .workflows
                .workflows
                .iter()
                .position(|w| w.workflow_id == workflow_id)
            else {
                return Ok(reject(
                    "workflowNotFound",
                    "The workflow is no longer open.",
                ));
            };
            let mut workflow = inner.workflows.workflows[index].clone();
            let Some(run) = &mut workflow.run else {
                return Ok(reject("notWorkflowRun", "This workflow has no stages."));
            };
            let previous_sequence = run.traces.last().map_or(0, |event| event.sequence);
            let anchor = workflow
                .agents
                .iter()
                .find(|agent| agent.agent_id == agent_id)
                .and_then(|agent| match self.terminals.observe(agent.terminal_id) {
                    Ok(observation) => Some(crate::TraceAnchor {
                        terminal_id: agent.terminal_id,
                        byte_offset: observation.byte_offset,
                        boundary_sizes: observation.boundary_sizes,
                    }),
                    Err(error) => {
                        tracing::warn!(%error, "couldn't observe completion terminal boundary");
                        None
                    }
                });
            let advance = match run.complete(agent_id.0, generation, signal) {
                Ok(advance) => advance,
                Err(error) => return Ok(super::rejection("invalidCompletion", &error)),
            };
            let completion_anchors: HashMap<_, _> = run
                .traces
                .iter()
                .filter(|event| event.generation == generation && event.kind == "roleCompleted")
                .filter_map(|event| Some((event.agent_id?, event.anchor.clone()?)))
                .collect();
            for event in run
                .traces
                .iter_mut()
                .filter(|event| event.sequence > previous_sequence)
            {
                // Parallel senders can finish before this completion advances the stage. Their
                // handoffs retain each sender's own completion boundary, even after it exits.
                event.anchor = match event.agent_id {
                    Some(source) if source != agent_id.0 => {
                        completion_anchors.get(&source).cloned()
                    }
                    _ => anchor.clone(),
                };
            }
            let running = run.status == RunStatus::Running;
            let feedback = if advance && !running && run.is_reviewer(agent_id.0) {
                final_review_feedback(&workflow.agents, run)
            } else {
                Vec::new()
            };
            let generation = run.generation;
            let mode_revision = run.mode_revision;
            workflow.status = workflow_status(run.status);
            if !running {
                workflow.ended_at = Some(timestamp());
            }
            if let Err(error) = inner.publish_run(index, workflow) {
                return Ok(super::rejection("completionStoreFailed", &error));
            }
            (advance, running, feedback, generation, mode_revision)
        };
        {
            let mut processes = self
                .run_processes
                .lock()
                .map_err(|_| ApplicationError::Poisoned)?;
            if let Some(processes) = processes.get_mut(&workflow_id) {
                processes.finish_assignment(agent_id, advance);
            }
        }
        if advance && running {
            self.launch_workflow_stage(workflow_id, false)?;
        }
        self.deliver_review_feedback(workflow_id, generation, mode_revision, feedback);
        Ok(CommandDisposition::Accepted)
    }

    fn deliver_review_feedback(
        &self,
        workflow: WorkflowId,
        generation: u64,
        mode_revision: u64,
        feedback: Vec<(TerminalId, String)>,
    ) {
        for (terminal, message) in feedback {
            if self.terminals.is_running(terminal)
                && let Err(error) = self.notify_final_review_feedback(
                    workflow,
                    generation,
                    mode_revision,
                    terminal,
                    &message,
                )
            {
                tracing::warn!(%error, "couldn't deliver the final review feedback");
            }
        }
    }

    fn notify_final_review_feedback(
        &self,
        workflow: WorkflowId,
        generation: u64,
        mode_revision: u64,
        terminal: TerminalId,
        message: &str,
    ) -> Result<(), ApplicationError> {
        let Some(input) = self.workflow_agent_input(terminal)? else {
            return Ok(());
        };
        // A harness can block its writer. Wait without holding application or registry locks,
        // then revalidate the revision while owning the writer used by mode cleanup.
        let mut writer = input.lock().map_err(|_| ApplicationError::Poisoned)?;
        let registry = self
            .run_processes
            .lock()
            .map_err(|_| ApplicationError::Poisoned)?;
        let inner = self.lock_inner()?;
        let current = inner
            .workflows
            .workflows
            .iter()
            .find(|w| w.workflow_id == workflow)
            .and_then(|w| w.run.as_ref());
        if !current.is_some_and(|run| {
            !run.individual_mode
                && run.mode_revision == mode_revision
                && run.generation == generation
                && matches!(run.status, RunStatus::Completed | RunStatus::LimitReached)
        }) {
            return Ok(());
        }
        drop(inner);
        drop(registry);
        writer.notify(&self.terminals, terminal, message)?;
        Ok(())
    }

    fn notify_workflow_agent(
        &self,
        terminal: TerminalId,
        message: &str,
    ) -> Result<(), ApplicationError> {
        if let Some(input) = self.workflow_agent_input(terminal)? {
            let submitted = input
                .lock()
                .map_err(|_| ApplicationError::Poisoned)?
                .notify(&self.terminals, terminal, message)?;
            if submitted {
                self.note_workflow_submission(terminal)?;
            }
        }
        Ok(())
    }

    pub(super) fn note_workflow_submission(
        &self,
        terminal: TerminalId,
    ) -> Result<(), ApplicationError> {
        let owner = {
            let inner = self.lock_inner()?;
            inner.workflows.workflows.iter().find_map(|workflow| {
                let run = workflow.run.as_ref()?;
                if run.status != RunStatus::Running {
                    return None;
                }
                let agent = workflow
                    .agents
                    .iter()
                    .find(|agent| agent.terminal_id == terminal)?;
                Some((workflow.workflow_id, agent.agent_id, run.generation))
            })
        };
        if let Some((workflow, agent, generation)) = owner {
            let mut processes = self
                .run_processes
                .lock()
                .map_err(|_| ApplicationError::Poisoned)?;
            if let Some(processes) = processes.get_mut(&workflow)
                && let Some(routing) = processes.completion_routing.get_mut(&agent)
                && matches!(routing, CompletionRouting::AwaitingSubmission(assigned) if *assigned == generation)
            {
                *routing = CompletionRouting::AwaitingPrompt(generation, Instant::now());
            }
        }
        Ok(())
    }

    pub(super) fn activate_workflow_completion(
        &self,
        workflow: WorkflowId,
        agent: AgentId,
        generation: u64,
        ready: bool,
    ) -> Result<(), ApplicationError> {
        let mut processes = self
            .run_processes
            .lock()
            .map_err(|_| ApplicationError::Poisoned)?;
        if let Some(processes) = processes.get_mut(&workflow)
            && let Some((assigned_generation, inbox)) = processes.inboxes.get(&agent)
            && *assigned_generation == generation
            && let Some(routing) = processes.completion_routing.get_mut(&agent)
            && routing.generation() == Some(generation)
            && let Some(command) = processes.completion_commands.get(&agent)
        {
            if ready {
                if let Err(error) = command.bind(inbox) {
                    tracing::warn!(%error, "couldn't activate the new assignment's completion command");
                } else {
                    *routing = CompletionRouting::Active(generation);
                }
            } else {
                command.deactivate();
                if matches!(routing, CompletionRouting::Active(_)) {
                    *routing = CompletionRouting::AwaitingPrompt(generation, Instant::now());
                }
            }
        }
        Ok(())
    }

    pub(super) fn workflow_agent_input(
        &self,
        terminal: TerminalId,
    ) -> Result<Option<Arc<Mutex<AgentInput>>>, ApplicationError> {
        Ok(self
            .run_processes
            .lock()
            .map_err(|_| ApplicationError::Poisoned)?
            .values()
            .find_map(|processes| processes.inputs.get(&terminal).cloned()))
    }

    pub(super) fn continue_workflow_run(
        &self,
        workflow_id: WorkflowId,
        agent_id: AgentId,
        generation: u64,
        mode_revision: u64,
    ) -> Result<CommandDisposition, ApplicationError> {
        {
            let mut inner = self.lock_inner()?;
            let Some(index) = inner
                .workflows
                .workflows
                .iter()
                .position(|w| w.workflow_id == workflow_id)
            else {
                return Ok(reject(
                    "workflowNotFound",
                    "The workflow is no longer open.",
                ));
            };
            let mut workflow = inner.workflows.workflows[index].clone();
            if !workflow.agents.iter().any(|agent| {
                agent.agent_id == agent_id
                    && inner.terminals.get(&agent.terminal_id) == Some(&TerminalStatus::Running)
            }) {
                return Ok(reject(
                    "agentNotRunning",
                    "This agent's terminal is no longer running.",
                ));
            }
            let Some(run) = workflow.run.as_mut() else {
                return Ok(reject("notWorkflowRun", "This workflow has no stages."));
            };
            match run.continue_with(agent_id.0, generation, mode_revision) {
                Ok(false) => return Ok(CommandDisposition::Accepted),
                Ok(true) => {}
                Err(error) => return Ok(super::rejection("invalidContinuation", &error)),
            }
            workflow.status = WorkflowStatus::Running;
            workflow.ended_at = None;
            inner.publish_run(index, workflow)?;
        }
        self.launch_workflow_stage(workflow_id, true)?;
        Ok(CommandDisposition::Accepted)
    }

    pub(super) fn set_workflow_individual_mode(
        &self,
        workflow_id: WorkflowId,
        generation: u64,
        mode_revision: u64,
        individual_mode: bool,
    ) -> Result<CommandDisposition, ApplicationError> {
        let mut writers = if individual_mode {
            let registry = self
                .run_processes
                .lock()
                .map_err(|_| ApplicationError::Poisoned)?;
            registry
                .get(&workflow_id)
                .map(|processes| {
                    processes
                        .inputs
                        .iter()
                        .map(|(&terminal, input)| (terminal, Arc::clone(input)))
                        .collect::<Vec<_>>()
                })
                .unwrap_or_default()
        } else {
            Vec::new()
        };
        writers.sort_by_key(|(terminal, _)| terminal.value());
        // Wait for slow PTY writes without holding application state. Sorting provides a
        // consistent order for concurrent changes; revalidate only after owning the writers.
        let mut inputs = writers
            .iter()
            .map(|(_, input)| input.lock().map_err(|_| ApplicationError::Poisoned))
            .collect::<Result<Vec<_>, _>>()?;
        // Match stage launch's lock order. Hold the registry through persistence and cleanup so
        // a new continuation cannot install routing that this mode change then deactivates.
        let mut registry = self
            .run_processes
            .lock()
            .map_err(|_| ApplicationError::Poisoned)?;
        let mut inner = self.lock_inner()?;
        let Some(index) = inner
            .workflows
            .workflows
            .iter()
            .position(|w| w.workflow_id == workflow_id)
        else {
            return Ok(reject(
                "workflowNotFound",
                "The workflow is no longer open.",
            ));
        };
        let mut workflow = inner.workflows.workflows[index].clone();
        let Some(run) = workflow.run.as_mut() else {
            return Ok(reject("notWorkflowRun", "This workflow has no stages."));
        };
        match run.set_individual_mode(individual_mode, generation, mode_revision) {
            Ok(false) => return Ok(CommandDisposition::Accepted),
            Ok(true) => {}
            Err(error) => return Ok(super::rejection("invalidIndividualMode", &error)),
        }
        // Synchronize with user writes before publishing the new mode. Clearing review feedback
        // preserves any unfinished user draft and prevents old feedback reaching a private turn.
        inner.publish_run(index, workflow)?;
        for input in &mut inputs {
            input.clear_feedback();
        }
        drop(inputs);
        if let Some(processes) = registry.get_mut(&workflow_id) {
            for command in processes.completion_commands.values() {
                command.deactivate();
            }
            for routing in processes.completion_routing.values_mut() {
                *routing = CompletionRouting::Private;
            }
        }
        Ok(CommandDisposition::Accepted)
    }

    pub(super) fn cancel_workflow_run(
        &self,
        workflow_id: WorkflowId,
    ) -> Result<CommandDisposition, ApplicationError> {
        let terminals = {
            let mut inner = self.lock_inner()?;
            let Some(index) = inner
                .workflows
                .workflows
                .iter()
                .position(|w| w.workflow_id == workflow_id)
            else {
                return Ok(reject(
                    "workflowNotFound",
                    "The workflow is no longer open.",
                ));
            };
            let mut workflow = inner.workflows.workflows[index].clone();
            let Some(run) = &mut workflow.run else {
                return Ok(reject("notWorkflowRun", "This workflow has no stages."));
            };
            if !matches!(
                run.status,
                RunStatus::Running | RunStatus::Completed | RunStatus::LimitReached
            ) {
                return Ok(reject("workflowNotRunning", "The workflow isn't running."));
            }
            run.finish(RunStatus::Cancelled, "Workflow cancelled");
            workflow.status = WorkflowStatus::Cancelled;
            workflow.ended_at = Some(timestamp());
            let terminals = workflow.terminal_ids();
            inner.publish_run_best_effort(index, workflow)?;
            terminals
        };
        self.run_processes
            .lock()
            .map_err(|_| ApplicationError::Poisoned)?
            .remove(&workflow_id);
        self.stop_run_terminals(&terminals, "Workflow cancelled; agent stopped.");
        Ok(CommandDisposition::Accepted)
    }

    fn stop_run_terminals(&self, terminals: &[TerminalId], message: &str) {
        for &terminal in terminals {
            if let Ok(observation) = self.terminals.observe(terminal)
                && let Ok(mut inner) = self.lock_inner()
                && let Err(error) = inner.stop_trace(terminal, observation, message)
            {
                tracing::warn!(%error, "couldn't record a workflow agent ending");
            }
            let _ = self.terminals.terminate(terminal);
        }
    }

    /// The bridge polls events off the UI thread. Polling also services bounded completion
    /// mailboxes, so terminal output (including an idle or exited process) cannot starve signals.
    pub(super) fn poll_workflow_signals(&self) -> Result<(), ApplicationError> {
        self.poll_harness_steps()?;
        // Snapshot/event reads must stay available while a lifetime command waits on transcript
        // storage. The next idle poll will service these mailboxes.
        let _guard = match self.commands.try_lock() {
            Ok(guard) => guard,
            Err(std::sync::TryLockError::WouldBlock) => return Ok(()),
            Err(std::sync::TryLockError::Poisoned(_)) => return Err(ApplicationError::Poisoned),
        };
        self.prune_run_processes()?;
        let submissions: Vec<_> = {
            let processes = self
                .run_processes
                .lock()
                .map_err(|_| ApplicationError::Poisoned)?;
            processes
                .iter()
                .flat_map(|(&id, processes)| {
                    processes
                        .inboxes
                        .iter()
                        .filter_map(move |(&agent, (generation, inbox))| {
                            inbox.take().map(|signal| (id, agent, *generation, signal))
                        })
                })
                .collect()
        };
        for (workflow, agent, generation, submission) in submissions {
            let disposition = match submission {
                Ok(signal) => self.complete_workflow_role(workflow, agent, generation, signal)?,
                Err(message) => reject("invalidCompletion", &message),
            };
            if let CommandDisposition::Rejected { message, .. } = disposition {
                let processes = self
                    .run_processes
                    .lock()
                    .map_err(|_| ApplicationError::Poisoned)?;
                let Some((current_generation, inbox)) =
                    processes.get(&workflow).and_then(|p| p.inboxes.get(&agent))
                else {
                    continue;
                };
                // A review decision can finish a stage while another participant's submission
                // is already in this batch. Never deliver its stale rejection to a new invocation.
                if *current_generation != generation {
                    continue;
                }
                inbox.reject(&message);
                drop(processes);
                let mut inner = self.lock_inner()?;
                if let Some(index) = inner
                    .workflows
                    .workflows
                    .iter()
                    .position(|w| w.workflow_id == workflow)
                {
                    let mut workflow = inner.workflows.workflows[index].clone();
                    if let Some(run) = &mut workflow.run {
                        run.message = Some(message);
                        run.trace(
                            "completionRejected",
                            Some(agent.0),
                            None,
                            "Completion rejected; use Mark done or correct the submission",
                        );
                    }
                    inner.publish_run_best_effort(index, workflow)?;
                }
            }
        }
        self.recover_completion_routes(Instant::now())?;
        Ok(())
    }

    fn recover_completion_routes(&self, now: Instant) -> Result<(), ApplicationError> {
        let candidates: Vec<_> = {
            let registry = self
                .run_processes
                .lock()
                .map_err(|_| ApplicationError::Poisoned)?;
            registry
                .iter()
                .flat_map(|(&workflow, processes)| {
                    processes
                        .completion_routing
                        .iter()
                        .filter_map(move |(&agent, routing)| {
                            if let CompletionRouting::AwaitingPrompt(generation, since) = routing
                                && now.saturating_duration_since(*since) >= PROMPT_HOOK_TIMEOUT
                            {
                                Some((workflow, agent, *generation))
                            } else {
                                None
                            }
                        })
                })
                .collect()
        };
        if candidates.is_empty() {
            return Ok(());
        }
        let assignments: Vec<_> = {
            let inner = self.lock_inner()?;
            candidates
                .into_iter()
                .filter_map(|(workflow, agent, generation)| {
                    let saved = inner
                        .workflows
                        .workflows
                        .iter()
                        .find(|w| w.workflow_id == workflow)?;
                    let run = saved.run.as_ref()?;
                    if run.status != RunStatus::Running || run.generation != generation {
                        return None;
                    }
                    let terminal = saved
                        .agents
                        .iter()
                        .find(|a| a.agent_id == agent)?
                        .terminal_id;
                    Some((
                        workflow,
                        agent,
                        generation,
                        terminal,
                        run.follow_up_instructions(agent.0),
                    ))
                })
                .collect()
        };
        let notifications = {
            let mut registry = self
                .run_processes
                .lock()
                .map_err(|_| ApplicationError::Poisoned)?;
            let mut notifications = Vec::new();
            for (workflow, agent, generation, terminal, instructions) in assignments {
                let Some(processes) = registry.get_mut(&workflow) else {
                    continue;
                };
                let Some(routing) = processes.completion_routing.get_mut(&agent) else {
                    continue;
                };
                if !matches!(routing, CompletionRouting::AwaitingPrompt(assigned, since)
                    if *assigned == generation && now.saturating_duration_since(*since) >= PROMPT_HOOK_TIMEOUT)
                {
                    continue;
                }
                let Some((assigned, inbox)) = processes.inboxes.get(&agent) else {
                    continue;
                };
                if *assigned != generation {
                    continue;
                }
                // Commit sticky private routing before any late hook can reactivate the wrapper.
                *routing = CompletionRouting::Private;
                if let Some(command) = processes.completion_commands.get(&agent) {
                    command.deactivate();
                }
                notifications.push((terminal, format!(
                    "Use this completion command for the current assignment: {}\n{instructions}", inbox.command(),
                )));
            }
            notifications
        };
        for (terminal, message) in notifications {
            if self.terminals.is_running(terminal) {
                self.notify_workflow_agent(terminal, &message)?;
            }
        }
        Ok(())
    }

    pub(super) fn prune_run_processes(&self) -> Result<(), ApplicationError> {
        let inner = self.lock_inner()?;
        let mut processes = self
            .run_processes
            .lock()
            .map_err(|_| ApplicationError::Poisoned)?;
        for processes in processes.values_mut() {
            processes.reap_inboxes();
        }
        processes.retain(|id, _| {
            inner.workflows.workflows.iter().any(|w| {
                w.workflow_id == *id
                    && w.run.as_ref().is_some_and(|run| {
                        matches!(
                            run.status,
                            RunStatus::Running | RunStatus::Completed | RunStatus::LimitReached
                        )
                    })
            })
        });
        Ok(())
    }
}

impl super::Inner {
    fn record_agent_launch(
        &mut self,
        tabs: &mut [Agent],
        run: &mut WorkflowRun,
        agent_id: u64,
        terminal_id: TerminalId,
    ) -> Option<TerminalId> {
        self.terminals.insert(terminal_id, TerminalStatus::Running);
        let tab = tabs
            .iter_mut()
            .find(|tab| tab.agent_id.0 == agent_id)
            .expect("agent tab exists");
        let previous = (tab.terminal_id.value() != 0 && tab.terminal_id != terminal_id)
            .then_some(tab.terminal_id);
        if let Some(previous) = previous {
            self.terminals.remove(&previous);
        }
        tab.terminal_id = terminal_id;
        run.agents
            .iter_mut()
            .find(|agent| agent.agent_id == agent_id)
            .expect("launched agent belongs to run")
            .status = crate::RunAgentStatus::Running;
        previous
    }

    fn publish_launch(
        &mut self,
        index: usize,
        workflow: &mut Workflow,
        sessions: &[(TerminalId, &str)],
    ) -> Result<(), ApplicationError> {
        match self.publish_run_with_sessions(index, workflow.clone(), sessions) {
            Ok(()) => Ok(()),
            Err(error) => {
                tracing::warn!(%error, "failed to record stage launch; stopping its agents");
                workflow.run.as_mut().expect("run exists").finish(
                    RunStatus::Failed,
                    "Couldn't save the stage launch. Agents have been stopped.",
                );
                workflow.status = WorkflowStatus::Failed;
                workflow.ended_at = Some(timestamp());
                self.record_run(index, workflow.clone())
            }
        }
    }

    fn publish_run(&mut self, index: usize, workflow: Workflow) -> Result<(), ApplicationError> {
        self.publish_run_with_sessions(index, workflow, &[])
    }

    fn publish_run_with_sessions(
        &mut self,
        index: usize,
        workflow: Workflow,
        sessions: &[(TerminalId, &str)],
    ) -> Result<(), ApplicationError> {
        let spans = self
            .folders
            .store()
            .save_workflow_run_with_sessions(&workflow, sessions)?;
        self.trace_spans.extend(spans);
        self.publish_trace(workflow.workflow_id)?;
        self.record_run(index, workflow)
    }

    pub(super) fn publish_run_best_effort(
        &mut self,
        index: usize,
        workflow: Workflow,
    ) -> Result<(), ApplicationError> {
        match self.folders.store().save_workflow_run(&workflow) {
            Ok(spans) => {
                self.trace_spans.extend(spans);
                self.publish_trace(workflow.workflow_id)?;
            }
            Err(error) => tracing::warn!(%error, "couldn't persist workflow state"),
        }
        self.record_run(index, workflow)
    }

    fn record_run(&mut self, index: usize, workflow: Workflow) -> Result<(), ApplicationError> {
        self.workflows.workflows[index] = workflow.clone();
        self.events
            .append(EventKind::State(StateEvent::WorkflowChanged(workflow)))?;
        Ok(())
    }
}

pub(super) fn workflow_status(status: RunStatus) -> WorkflowStatus {
    match status {
        RunStatus::Running => WorkflowStatus::Running,
        RunStatus::Completed => WorkflowStatus::Completed,
        RunStatus::Failed | RunStatus::LimitReached => WorkflowStatus::Failed,
        RunStatus::Cancelled => WorkflowStatus::Cancelled,
        RunStatus::Interrupted => WorkflowStatus::Interrupted,
    }
}

#[cfg(test)]
mod tests {
    use std::ffi::OsString;
    use std::os::unix::fs::PermissionsExt;
    use std::path::Path;
    use std::thread;
    use std::time::{Duration, Instant};

    use super::*;
    use crate::config::Config;
    use crate::{BuiltinType, Command, Decision, RequestId};

    const SIZE: TerminalSize = TerminalSize {
        rows: 24,
        columns: 100,
        pixel_width: 800,
        pixel_height: 480,
    };

    fn application(folder: &Path, bin: &Path, script: &str) -> Application {
        let binary = bin.join("pi");
        std::fs::write(&binary, format!("#!/bin/sh\n{script}\n")).unwrap();
        std::fs::set_permissions(binary, std::fs::Permissions::from_mode(0o755)).unwrap();
        let mut app = Application::with_event_capacity(4096).unwrap();
        app.harness_path = Some(OsString::from(format!("{}:/bin:/usr/bin", bin.display())));
        accepted(
            &app,
            Command::OpenFolder {
                path: folder.to_owned(),
            },
        );
        app
    }

    fn accepted(app: &Application, command: Command) {
        assert_eq!(
            app.handle_command(RequestId(1), command)
                .unwrap()
                .disposition,
            CommandDisposition::Accepted
        );
    }

    fn launch(app: &Application, folder: &Path, builtin: BuiltinType) -> WorkflowId {
        launch_with_size(app, folder, builtin, SIZE, "Test the workflow")
    }

    fn launch_with_size(
        app: &Application,
        folder: &Path,
        builtin: BuiltinType,
        run_size: TerminalSize,
        prompt: &str,
    ) -> WorkflowId {
        launch_with_harness(app, folder, builtin, run_size, prompt, HarnessId::Pi)
    }

    fn launch_with_harness(
        app: &Application,
        folder: &Path,
        builtin: BuiltinType,
        run_size: TerminalSize,
        prompt: &str,
        harness: HarnessId,
    ) -> WorkflowId {
        accepted(
            app,
            Command::CreateWorkflow {
                folder: folder.to_owned(),
                session_id: None,
                kind: WorkflowKind::Draft,
                roles: vec![],
                size: SIZE,
            },
        );
        let id = app
            .snapshot()
            .unwrap()
            .workflows
            .workflows
            .last()
            .unwrap()
            .workflow_id;
        let roles = builtin
            .definition()
            .roles
            .iter()
            .flat_map(|r| {
                (0..r.instances.min).map(|_| RoleLaunch {
                    model: None,
                    effort: None,
                    yolo: false,
                    role: r.id.0.clone(),
                    harness,
                })
            })
            .collect();
        accepted(
            app,
            Command::StartWorkflowRun {
                workflow_id: id,
                workflow_type: WorkflowTypeRef::Builtin(builtin),
                prompt: prompt.into(),
                roles,
                size: run_size,
            },
        );
        id
    }

    fn wait_for(app: &Application, id: WorkflowId, check: impl Fn(&Workflow) -> bool) -> Workflow {
        let deadline = Instant::now() + Duration::from_secs(15);
        loop {
            let workflow = app
                .snapshot()
                .unwrap()
                .workflows
                .workflows
                .into_iter()
                .find(|w| w.workflow_id == id)
                .unwrap();
            if check(&workflow) {
                return workflow;
            }
            assert!(
                Instant::now() < deadline,
                "workflow didn't reach expected state: {:?}",
                workflow.run
            );
            thread::sleep(Duration::from_millis(10));
        }
    }

    // A real PTY harness process invokes the same completion helper an installed harness uses.
    const FAKE: &str = r#"
    extension=''
    while [ "$#" -gt 0 ] && [ "$1" != -- ]; do
        if [ "$1" = --extension ]; then shift; extension=$1; fi
        shift
    done
    prompt=$2
    command=$(printf '%s\n' "$prompt" | sed -n "s/^'\(.*\/complete\)' <<.*/\1/p")
    socket=$(sed -n 's/.*const socketPath = "\(.*\)";/\1/p' "$extension")
    round=0
    paste_start=$(printf '\033[200~')
    paste_end=$(printf '\033[201~')
    while :; do
    replacement=$(printf '%s\n' "$prompt" | sed -n "s/^Use this completion command for the current assignment: '\(.*\)'/\1/p")
    if [ -n "$replacement" ]; then command=$replacement; fi
    prompt=$(printf '%s\n' "$prompt" | sed '/^Use this completion command for the current assignment:/d')
    round=$((round + 1))
    turn="turn-$$-$round"
    completion=''
    decision=''
    case "$prompt" in
      'You are Implementer '*|'Continue with the Implement stage.'*) echo implement >> order; decision=done ;;
      'You are Reviewer '*|'Continue with the Review stage.'*) echo review >> order; decision=approve
          if [ -f request-changes ]; then decision=requestChanges; fi ;;
      'You are Coordinator in the Split '*|'Continue with the Split stage.'*)
          echo split >> order
          completion='{"decision":"done","summary":"Result or feedback","assignments":[{"role":"worker","instance":1,"task":"First sub-task","files":["first.txt"]},{"role":"worker","instance":2,"task":"Second sub-task","files":["second.txt"]}]}' ;;
      'You are Worker 1 '*) echo worker1 >> order; printf '%s' "$prompt" > worker1-prompt
          while [ ! -f worker2-prompt ]; do sleep 0.01; done; decision=done ;;
      'You are Worker 2 '*) echo worker2 >> order; printf '%s' "$prompt" > worker2-prompt
          while [ ! -f worker1-prompt ]; do sleep 0.01; done; decision=done ;;
      'You are Coordinator in the Gather '*|'Continue with the Gather stage.'*) echo gather >> order; printf '%s' "$prompt" > gather-prompt; decision=done ;;
      *) printf '%s' "$prompt" > "feedback-$$" ;;
    esac
    if [ -n "$completion" ] || [ -n "$decision" ]; then
    curl --silent --unix-socket "$socket" --data-binary "{\"type\":\"prompt\",\"turn_id\":\"$turn\",\"detail\":\"Assignment\"}" http://localhost/
    case "$command" in *twine-agent-completion-*)
        while [ ! -f "$(dirname "$command")/current" ]; do sleep 0.01; done ;;
    esac
    if [ -z "$completion" ]; then
        completion=$(printf '{"decision":"%s","summary":"Result or feedback"}' "$decision")
    fi
    printf '%s' "$completion" | "$command"
    curl --silent --unix-socket "$socket" --data-binary "{\"type\":\"response\",\"turn_id\":\"$turn\",\"detail\":\"Finished\"}" http://localhost/
    fi
    prompt=''
    while IFS= read -r line; do
        last=false
        case "$line" in *"$paste_end") line=${line%"$paste_end"}; last=true ;; esac
        line=${line#"$paste_start"}
        prompt="$prompt$line
"
        if [ "$last" = true ]; then break; fi
    done
    [ -n "$prompt" ] || exit
    done
    "#;

    #[test]
    fn interrupted_workflow_resumes_its_assignment_and_accepts_fresh_completion() {
        let folder = tempfile::tempdir().unwrap();
        let bin = tempfile::tempdir().unwrap();
        let app = application(
            folder.path(),
            bin.path(),
            "while read line; do echo \"$line\"; done",
        );
        let id = launch(&app, folder.path(), BuiltinType::Adversarial);
        let original = wait_for(&app, id, |w| !w.terminal_ids().is_empty());
        let old_terminal = original.agents[0].terminal_id;
        app.lock_inner()
            .unwrap()
            .folders
            .store()
            .remember_harness_session(old_terminal, "/tmp/implementer.jsonl")
            .unwrap();
        accepted(&app, Command::CloseFolder);
        accepted(
            &app,
            Command::OpenFolder {
                path: folder.path().to_owned(),
            },
        );
        let restored = wait_for(&app, id, |w| w.status == WorkflowStatus::Running);
        let run = restored.run.as_ref().unwrap();
        assert_eq!(run.stage_index, original.run.as_ref().unwrap().stage_index);
        assert!(run.generation > original.run.as_ref().unwrap().generation);
        assert_ne!(restored.agents[0].terminal_id, old_terminal);
        assert!(
            restored
                .terminal_history
                .iter()
                .any(|entry| entry.terminal_id == old_terminal)
        );
        accepted(
            &app,
            Command::CompleteWorkflowRole {
                workflow_id: id,
                agent_id: restored.agents[0].agent_id,
                generation: run.generation,
                signal: CompletionSignal {
                    decision: Decision::Done,
                    summary: "Resumed assignment finished".into(),
                    assignments: vec![],
                    task: String::new(),
                },
            },
        );
        let advanced = wait_for(&app, id, |w| {
            w.run.as_ref().unwrap().stage_index != run.stage_index
        });
        assert_eq!(advanced.status, WorkflowStatus::Running);
        assert_ne!(advanced.agents[1].terminal_id.value(), 0);
    }

    #[test]
    fn fake_harness_completes_adversarial_and_hits_review_limit() {
        for limited in [false, true] {
            let folder = tempfile::tempdir().unwrap();
            let bin = tempfile::tempdir().unwrap();
            if limited {
                std::fs::write(folder.path().join("request-changes"), "").unwrap();
            }
            let app = application(folder.path(), bin.path(), FAKE);
            let id = launch(&app, folder.path(), BuiltinType::Adversarial);
            let result = wait_for(&app, id, |w| w.status != WorkflowStatus::Running);
            assert_eq!(
                result.run.as_ref().unwrap().status,
                if limited {
                    RunStatus::LimitReached
                } else {
                    RunStatus::Completed
                }
            );
            assert_eq!(
                std::fs::read_to_string(folder.path().join("order")).unwrap(),
                "implement\nreview\n".repeat(if limited { 4 } else { 1 })
            );
            assert_run_trace_history(&app, &result, if limited { 8 } else { 2 });
        }
    }

    fn finish_active_stage(app: &Application, workflow: &Workflow, decision: Decision, task: &str) {
        let run = workflow.run.as_ref().unwrap();
        for agent in run.active_agents() {
            accepted(
                app,
                Command::CompleteWorkflowRole {
                    workflow_id: workflow.workflow_id,
                    agent_id: AgentId(agent.agent_id),
                    generation: run.generation,
                    signal: CompletionSignal {
                        decision: if run.is_reviewer(agent.agent_id) {
                            decision
                        } else {
                            Decision::Done
                        },
                        summary: "Result or feedback".into(),
                        task: task.into(),
                        assignments: run
                            .assignment_targets(agent.agent_id)
                            .iter()
                            .map(|target| crate::Assignment {
                                role: target.role.clone(),
                                instance: target.instance,
                                task: format!("Task {}", target.instance),
                                files: vec![format!("{}.txt", target.instance)],
                            })
                            .collect(),
                    },
                },
            );
        }
    }

    fn finish_remaining_stages(app: &Application, id: WorkflowId) {
        loop {
            let workflow = app.snapshot().unwrap().workflows.workflows[0].clone();
            assert_eq!(workflow.workflow_id, id);
            if workflow.status != WorkflowStatus::Running {
                break;
            }
            finish_active_stage(app, &workflow, Decision::Approve, "");
        }
    }

    const RECORD_INPUT: &str = r#"
        extension=''
        while [ "$#" -gt 0 ] && [ "$1" != -- ]; do
            if [ "$1" = --extension ]; then shift; extension=$1; fi
            shift
        done
        prompt=$2
        case "$prompt" in 'You are Implementer '*) role=implement ;; *) role=review ;; esac
        printf '%s' "$prompt" > "$role-launch"
        printf '%s\n' "$prompt" | sed -n "s/^'\(.*\/complete\)' <<.*/\1/p" > "$role-command"
        if [ -n "$extension" ]; then
            sed -n 's/.*const socketPath = "\(.*\)";/\1/p' "$extension" > "$role-socket"
        fi
        stty -echo
        touch "$role-ready"
        while IFS= read -r line; do printf '%s\n' "$line" >> "$role-input"; done
    "#;

    fn send_implementer_hook(app: &Application, folder: &Path, kind: &str, turn: &str) {
        let socket = std::fs::read_to_string(folder.join("implement-socket")).unwrap();
        let payload = serde_json::json!({"type":kind,"turn_id":turn,"detail":"Assignment"});
        assert!(
            std::process::Command::new("/usr/bin/curl")
                .args([
                    "--silent",
                    "--max-time",
                    "1",
                    "--unix-socket",
                    socket.trim(),
                    "--data-binary",
                    &payload.to_string(),
                    "http://localhost/"
                ])
                .output()
                .unwrap()
                .status
                .success()
        );
        app.poll_harness_steps().unwrap();
        if kind == "response" {
            thread::sleep(Duration::from_millis(60));
            app.poll_harness_steps().unwrap();
        }
    }

    #[test]
    fn previous_turn_cannot_complete_a_reused_assignment_after_manual_handoff() {
        use std::io::Write;
        use std::process::{Command as ProcessCommand, Stdio};

        let folder = tempfile::tempdir().unwrap();
        let bin = tempfile::tempdir().unwrap();
        let app = application(folder.path(), bin.path(), RECORD_INPUT);
        let id = launch(&app, folder.path(), BuiltinType::Adversarial);
        let initial = wait_for(&app, id, |_| folder.path().join("implement-ready").exists());
        let terminal = initial.agents[0].terminal_id;
        let command = std::fs::read_to_string(folder.path().join("implement-command")).unwrap();
        send_implementer_hook(&app, folder.path(), "prompt", "old");
        finish_active_stage(&app, &initial, Decision::Done, "");
        let review = app.snapshot().unwrap().workflows.workflows[0].clone();
        finish_active_stage(&app, &review, Decision::RequestChanges, "");
        let reused = app.snapshot().unwrap().workflows.workflows[0].clone();
        assert_eq!(reused.agents[0].terminal_id, terminal);
        for turn in [None, Some("old"), Some("new")] {
            if let Some(turn) = turn {
                send_implementer_hook(&app, folder.path(), "prompt", turn);
            }
            let output = ProcessCommand::new(command.trim()).output().unwrap();
            assert!(
                !output.status.success(),
                "an old turn must not reach the new inbox"
            );
            assert!(
                app.snapshot().unwrap().workflows.workflows[0]
                    .run
                    .as_ref()
                    .unwrap()
                    .completions
                    .is_empty()
            );
        }
        // The missing old Stop must not stall the new assignment: its private path is safe.
        let fresh = app.run_processes.lock().unwrap()[&id].inboxes[&reused.agents[0].agent_id]
            .1
            .command();
        let mut child = ProcessCommand::new("/bin/sh")
            .args(["-c", &fresh])
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(br#"{"decision":"done","summary":"Fresh result"}"#)
            .unwrap();
        let advanced = wait_for(&app, id, |w| {
            w.run.as_ref().unwrap().generation > reused.run.as_ref().unwrap().generation
        });
        assert!(child.wait().unwrap().success());
        assert_eq!(advanced.agents[0].terminal_id, terminal);
        assert!(
            advanced.run.unwrap().incoming[&advanced.agents[1].agent_id.0].contains("Fresh result")
        );
    }

    fn reuse_after_identified_response(
        app: &Application,
        folder: &Path,
        id: WorkflowId,
        draft: bool,
    ) -> Workflow {
        let initial = wait_for(app, id, |_| folder.join("implement-ready").exists());
        send_implementer_hook(app, folder, "prompt", "old");
        send_implementer_hook(app, folder, "response", "old");
        finish_active_stage(app, &initial, Decision::Done, "");
        let review = app.snapshot().unwrap().workflows.workflows[0].clone();
        if draft {
            app.write_terminal_input(initial.agents[0].terminal_id, b"Unfinished user draft")
                .unwrap();
        }
        finish_active_stage(app, &review, Decision::RequestChanges, "");
        app.snapshot().unwrap().workflows.workflows[0].clone()
    }

    fn private_command(app: &Application, workflow: &Workflow) -> String {
        app.run_processes.lock().unwrap()[&workflow.workflow_id].inboxes
            [&workflow.agents[0].agent_id]
            .1
            .command()
    }

    fn submit_private_result(app: &Application, workflow: &Workflow) -> Workflow {
        submit_result(app, workflow, &private_command(app, workflow), "")
    }

    fn submit_result(
        app: &Application,
        workflow: &Workflow,
        command: &str,
        task: &str,
    ) -> Workflow {
        use std::io::Write;
        use std::process::{Command as ProcessCommand, Stdio};
        let mut child = ProcessCommand::new("/bin/sh")
            .args(["-c", command])
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(
                &serde_json::to_vec(&CompletionSignal {
                    decision: Decision::Done,
                    summary: "Fresh result".into(),
                    assignments: vec![],
                    task: task.into(),
                })
                .unwrap(),
            )
            .unwrap();
        let advanced = wait_for(app, workflow.workflow_id, |w| {
            w.run.as_ref().unwrap().generation > workflow.run.as_ref().unwrap().generation
        });
        assert!(child.wait().unwrap().success());
        advanced
    }

    #[test]
    fn slow_user_follow_up_waits_for_submission_and_a_prompt_avoids_fallback() {
        let folder = tempfile::tempdir().unwrap();
        let bin = tempfile::tempdir().unwrap();
        let app = application(folder.path(), bin.path(), RECORD_INPUT);
        let id = launch(&app, folder.path(), BuiltinType::Adversarial);
        let first = wait_for(&app, id, |_| folder.path().join("implement-ready").exists());
        let terminal = first.agents[0].terminal_id;
        let remembered = std::fs::read_to_string(folder.path().join("implement-command")).unwrap();
        send_implementer_hook(&app, folder.path(), "prompt", "old");
        send_implementer_hook(&app, folder.path(), "response", "old");
        finish_active_stage(&app, &first, Decision::Done, "");
        let review = app.snapshot().unwrap().workflows.workflows[0].clone();
        finish_active_stage(&app, &review, Decision::Approve, "");
        let completed = wait_for(&app, id, |_| {
            std::fs::read_to_string(folder.path().join("implement-input")).is_ok_and(|text| {
                text.contains("review is complete") && text.ends_with("\x1b[201~\n")
            })
        });
        let before = std::fs::read_to_string(folder.path().join("implement-input")).unwrap();
        accepted(
            &app,
            Command::ContinueWorkflowRun {
                workflow_id: id,
                agent_id: completed.agents[0].agent_id,
                generation: completed.run.unwrap().generation,
                mode_revision: 0,
            },
        );
        app.write_terminal_input(terminal, b"My next task").unwrap();
        app.recover_completion_routes(Instant::now() + PROMPT_HOOK_TIMEOUT * 10)
            .unwrap();
        assert!(matches!(
            app.run_processes.lock().unwrap()[&id].completion_routing[&first.agents[0].agent_id],
            CompletionRouting::AwaitingSubmission(3)
        ));
        assert_eq!(
            std::fs::read_to_string(folder.path().join("implement-input")).unwrap(),
            before
        );
        app.write_terminal_input(terminal, b"\r").unwrap();
        let continued = app.snapshot().unwrap().workflows.workflows[0].clone();
        send_implementer_hook(&app, folder.path(), "prompt", "new");
        app.recover_completion_routes(Instant::now() + PROMPT_HOOK_TIMEOUT * 10)
            .unwrap();
        assert!(matches!(
            app.run_processes.lock().unwrap()[&id].completion_routing[&first.agents[0].agent_id],
            CompletionRouting::Active(3)
        ));
        let command = format!("'{}'", remembered.trim());
        let review = submit_result(&app, &continued, &command, "My next task");
        assert_eq!(review.run.unwrap().prompt, "My next task");
        assert_eq!(review.agents[0].terminal_id, terminal);
    }

    #[test]
    fn missing_current_prompt_recovers_privately_and_keeps_later_reuse_private() {
        let folder = tempfile::tempdir().unwrap();
        let bin = tempfile::tempdir().unwrap();
        let app = application(folder.path(), bin.path(), RECORD_INPUT);
        let id = launch(&app, folder.path(), BuiltinType::Adversarial);
        let reused = reuse_after_identified_response(&app, folder.path(), id, false);
        let terminal = reused.agents[0].terminal_id;
        let old = std::fs::read_to_string(folder.path().join("implement-command")).unwrap();
        assert!(matches!(
            app.run_processes.lock().unwrap()[&id].completion_routing[&reused.agents[0].agent_id],
            CompletionRouting::AwaitingPrompt(3, _)
        ));
        let command = private_command(&app, &reused);
        app.recover_completion_routes(Instant::now() + PROMPT_HOOK_TIMEOUT)
            .unwrap();
        wait_for(&app, id, |_| {
            std::fs::read_to_string(folder.path().join("implement-input"))
                .is_ok_and(|text| text.contains(&command))
        });
        send_implementer_hook(&app, folder.path(), "prompt", "late");
        assert!(
            !std::process::Command::new(old.trim())
                .output()
                .unwrap()
                .status
                .success()
        );
        let review = submit_private_result(&app, &reused);
        send_implementer_hook(&app, folder.path(), "response", "late");
        assert!(app.harness_turn_finished(terminal).unwrap());
        finish_active_stage(&app, &review, Decision::RequestChanges, "");
        let next = app.snapshot().unwrap().workflows.workflows[0].clone();
        assert_eq!(next.agents[0].terminal_id, terminal);
        assert!(matches!(
            app.run_processes.lock().unwrap()[&id].completion_routing[&next.agents[0].agent_id],
            CompletionRouting::Private
        ));
        let next_command = private_command(&app, &next);
        assert_ne!(next_command, command);
        wait_for(&app, id, |_| {
            std::fs::read_to_string(folder.path().join("implement-input"))
                .is_ok_and(|text| text.contains(&next_command))
        });
        assert!(
            !std::process::Command::new(old.trim())
                .output()
                .unwrap()
                .status
                .success()
        );
        assert_eq!(
            submit_private_result(&app, &next).run.unwrap().generation,
            6
        );
    }

    #[test]
    fn deferred_stage_message_starts_recovery_only_after_the_user_submits() {
        let folder = tempfile::tempdir().unwrap();
        let bin = tempfile::tempdir().unwrap();
        let app = application(folder.path(), bin.path(), RECORD_INPUT);
        let id = launch(&app, folder.path(), BuiltinType::Adversarial);
        let reused = reuse_after_identified_response(&app, folder.path(), id, true);
        let terminal = reused.agents[0].terminal_id;
        let command = private_command(&app, &reused);
        app.recover_completion_routes(Instant::now() + PROMPT_HOOK_TIMEOUT * 10)
            .unwrap();
        assert!(matches!(
            app.run_processes.lock().unwrap()[&id].completion_routing[&reused.agents[0].agent_id],
            CompletionRouting::AwaitingSubmission(3)
        ));
        assert!(
            !std::fs::read_to_string(folder.path().join("implement-input"))
                .unwrap_or_default()
                .contains(&command)
        );
        app.write_terminal_input(terminal, b"\r").unwrap();
        assert!(matches!(
            app.run_processes.lock().unwrap()[&id].completion_routing[&reused.agents[0].agent_id],
            CompletionRouting::AwaitingPrompt(3, _)
        ));
        app.recover_completion_routes(Instant::now() + PROMPT_HOOK_TIMEOUT)
            .unwrap();
        wait_for(&app, id, |_| {
            std::fs::read_to_string(folder.path().join("implement-input"))
                .is_ok_and(|text| text.contains(&command))
        });
        let input = std::fs::read_to_string(folder.path().join("implement-input")).unwrap();
        assert!(input.contains("Unfinished user draft"));
        assert!(input.contains("Result or feedback"));
        assert_eq!(
            submit_private_result(&app, &reused).run.unwrap().generation,
            4
        );
    }

    #[test]
    fn recovery_does_not_send_an_obsolete_command_after_completion_or_cancellation() {
        for cancelled in [false, true] {
            let folder = tempfile::tempdir().unwrap();
            let bin = tempfile::tempdir().unwrap();
            let app = application(folder.path(), bin.path(), RECORD_INPUT);
            let id = launch(&app, folder.path(), BuiltinType::Adversarial);
            let reused = reuse_after_identified_response(&app, folder.path(), id, false);
            let command = private_command(&app, &reused);
            if cancelled {
                accepted(&app, Command::CancelWorkflowRun { workflow_id: id });
            } else {
                finish_active_stage(&app, &reused, Decision::Done, "");
            }
            app.recover_completion_routes(Instant::now() + PROMPT_HOOK_TIMEOUT * 10)
                .unwrap();
            assert!(
                !std::fs::read_to_string(folder.path().join("implement-input"))
                    .unwrap_or_default()
                    .contains(&command)
            );
        }
    }

    #[test]
    fn unhooked_harness_receives_a_new_private_command_without_repeated_setup() {
        let folder = tempfile::tempdir().unwrap();
        let bin = tempfile::tempdir().unwrap();
        let app = application(folder.path(), bin.path(), RECORD_INPUT);
        let wrapper = bin.path().join("opencode");
        std::fs::write(
            &wrapper,
            "#!/bin/sh\nshift\nshift\nprompt=${1#--prompt=}\nexec pi -- \"$prompt\"\n",
        )
        .unwrap();
        std::fs::set_permissions(&wrapper, std::fs::Permissions::from_mode(0o755)).unwrap();
        let id = launch_with_harness(
            &app,
            folder.path(),
            BuiltinType::Adversarial,
            SIZE,
            "Test",
            HarnessId::Opencode,
        );
        let initial = wait_for(&app, id, |_| folder.path().join("implement-ready").exists());
        let old = std::fs::read_to_string(folder.path().join("implement-command")).unwrap();
        finish_active_stage(&app, &initial, Decision::Done, "");
        let review = app.snapshot().unwrap().workflows.workflows[0].clone();
        finish_active_stage(&app, &review, Decision::RequestChanges, "");
        let reused = wait_for(&app, id, |_| {
            std::fs::read_to_string(folder.path().join("implement-input"))
                .is_ok_and(|text| text.contains("Use this completion command"))
        });
        assert_eq!(reused.agents[0].terminal_id, initial.agents[0].terminal_id);
        assert!(std::process::Command::new(old.trim()).output().is_err());
        let text = std::fs::read_to_string(folder.path().join("implement-input")).unwrap();
        assert!(text.contains("Continue with the Implement stage."));
        assert!(!text.contains(old.trim()));
        assert!(!text.contains("You are Implementer"));
        let processes = app.run_processes.lock().unwrap();
        assert!(processes[&id].completion_commands.is_empty());
        assert!(
            text.contains(
                &processes[&id].inboxes[&reused.agents[0].agent_id]
                    .1
                    .command()
            )
        );
    }

    fn change_individual_mode(app: &Application, id: WorkflowId, individual_mode: bool) {
        let workflow = app.snapshot().unwrap().workflows.workflows[0].clone();
        let run = workflow.run.as_ref().unwrap();
        accepted(
            app,
            Command::SetWorkflowIndividualMode {
                workflow_id: id,
                generation: run.generation,
                mode_revision: run.mode_revision,
                individual_mode,
            },
        );
    }

    #[test]
    fn waiting_for_an_agent_writer_does_not_lock_application_state() {
        for changing_mode in [true, false] {
            let folder = tempfile::tempdir().unwrap();
            let bin = tempfile::tempdir().unwrap();
            let app = Arc::new(application(folder.path(), bin.path(), RECORD_INPUT));
            let id = launch(&app, folder.path(), BuiltinType::Adversarial);
            finish_remaining_stages(&app, id);
            let completed = app.snapshot().unwrap().workflows.workflows[0].clone();
            let generation = completed.run.as_ref().unwrap().generation;
            let terminal = completed.agents[0].terminal_id;
            let input = app.workflow_agent_input(terminal).unwrap().unwrap();
            // A blocked PTY write owns this same mutex. No state lock may be held while waiting.
            let writer = input.lock().unwrap();
            let references = Arc::strong_count(&input);
            let worker = Arc::clone(&app);
            let pending = thread::spawn(move || {
                if changing_mode {
                    worker
                        .set_workflow_individual_mode(id, generation, 0, true)
                        .unwrap();
                } else {
                    worker
                        .notify_final_review_feedback(id, generation, 0, terminal, "Final feedback")
                        .unwrap();
                }
            });
            let deadline = Instant::now() + Duration::from_secs(2);
            while Arc::strong_count(&input) == references && Instant::now() < deadline {
                thread::sleep(Duration::from_millis(1));
            }
            let waiting = Arc::strong_count(&input) > references;
            let state_available = app.inner.try_lock().is_ok();
            drop(writer);
            pending.join().unwrap();
            assert!(waiting && state_available);
        }
    }

    fn submit_individual_follow_ups(
        app: &Application,
        folder: &Path,
        id: WorkflowId,
        builtin: BuiltinType,
        completed: &Workflow,
    ) {
        let generation = completed.run.as_ref().unwrap().generation;
        let input = app
            .workflow_agent_input(completed.agents[0].terminal_id)
            .unwrap()
            .unwrap();
        // Final review feedback deferred behind an unfinished draft must not leak into a
        // private turn, including delivery queued just before the mode change.
        app.write_terminal_input(completed.agents[0].terminal_id, b"My draft")
            .unwrap();
        input
            .lock()
            .unwrap()
            .notify(
                &app.terminals,
                completed.agents[0].terminal_id,
                "Initial feedback",
            )
            .unwrap();
        change_individual_mode(app, id, true);
        app.notify_final_review_feedback(
            id,
            generation,
            0,
            completed.agents[0].terminal_id,
            "Obsolete feedback",
        )
        .unwrap();
        for agent in &completed.agents {
            app.write_terminal_input(agent.terminal_id, b"Private question\r")
                .unwrap();
        }
        accepted(
            app,
            Command::ContinueWorkflowRun {
                workflow_id: id,
                agent_id: completed.agents[0].agent_id,
                generation,
                mode_revision: 1,
            },
        );
        if builtin == BuiltinType::Adversarial {
            wait_for(app, id, |_| {
                std::fs::read_to_string(folder.join("implement-input"))
                    .is_ok_and(|text| text.contains("My draftPrivate question"))
            });
            let private = std::fs::read_to_string(folder.join("implement-input")).unwrap();
            assert!(
                !private.contains("Initial feedback") && !private.contains("Obsolete feedback")
            );
        }
    }

    #[test]
    fn individual_mode_keeps_agents_live_and_rejoining_waits_for_fresh_input() {
        for builtin in BuiltinType::ALL {
            let folder = tempfile::tempdir().unwrap();
            let bin = tempfile::tempdir().unwrap();
            let app = application(folder.path(), bin.path(), RECORD_INPUT);
            let id = launch(&app, folder.path(), builtin);
            finish_remaining_stages(&app, id);
            let completed = app.snapshot().unwrap().workflows.workflows[0].clone();
            let generation = completed.run.as_ref().unwrap().generation;
            let spans = app.workflow_trace(id, None, 100).unwrap().spans.len();
            submit_individual_follow_ups(&app, folder.path(), id, builtin, &completed);
            let individual = app.snapshot().unwrap().workflows.workflows[0].clone();
            let stored = app
                .lock_inner()
                .unwrap()
                .folders
                .store()
                .workflows(folder.path())
                .unwrap();
            assert!(
                stored
                    .iter()
                    .find(|w| w.workflow_id == id)
                    .unwrap()
                    .run
                    .as_ref()
                    .unwrap()
                    .individual_mode
            );
            assert_eq!(individual.status, WorkflowStatus::Completed);
            assert!(individual.run.as_ref().unwrap().individual_mode);
            assert_eq!(
                individual.run.as_ref().unwrap().completions,
                completed.run.as_ref().unwrap().completions
            );
            assert_eq!(individual.terminal_ids(), completed.terminal_ids());
            assert_eq!(
                app.workflow_trace(id, None, 100).unwrap().spans.len(),
                spans
            );
            for terminal in individual.terminal_ids() {
                assert!(app.terminals.is_running(terminal));
            }
            change_individual_mode(&app, id, false);
            accepted(
                &app,
                Command::ContinueWorkflowRun {
                    workflow_id: id,
                    agent_id: completed.agents[0].agent_id,
                    generation,
                    mode_revision: 0,
                },
            );
            assert_eq!(
                app.snapshot().unwrap().workflows.workflows[0].status,
                WorkflowStatus::Completed
            );
            accepted(
                &app,
                Command::ContinueWorkflowRun {
                    workflow_id: id,
                    agent_id: completed.agents[0].agent_id,
                    generation,
                    mode_revision: 2,
                },
            );
            let continued = app.snapshot().unwrap().workflows.workflows[0].clone();
            assert_eq!(continued.status, WorkflowStatus::Running);
            assert_eq!(continued.terminal_ids(), completed.terminal_ids());
            assert_eq!(continued.run.as_ref().unwrap().generation, generation + 1);
        }
    }

    #[test]
    fn final_feedback_preserves_a_user_draft_and_continuation_sends_no_setup_prompt() {
        for limited in [false, true] {
            let folder = tempfile::tempdir().unwrap();
            let bin = tempfile::tempdir().unwrap();
            let app = application(folder.path(), bin.path(), RECORD_INPUT);
            let id = launch(&app, folder.path(), BuiltinType::Adversarial);
            let initial = wait_for(&app, id, |_| folder.path().join("implement-ready").exists());
            let terminal = initial.agents[0].terminal_id;
            let mut current = initial;
            loop {
                finish_active_stage(&app, &current, Decision::Done, "");
                let review = app.snapshot().unwrap().workflows.workflows[0].clone();
                let run = review.run.as_ref().unwrap();
                let last = !limited
                    || run.rounds.get("review").copied().unwrap_or(0)
                        >= run.workflow_type.definition.review_loops[0].max_rounds;
                if last {
                    app.write_terminal_input(terminal, b"My unfinished")
                        .unwrap();
                }
                finish_active_stage(
                    &app,
                    &review,
                    if limited {
                        Decision::RequestChanges
                    } else {
                        Decision::Approve
                    },
                    "",
                );
                current = app.snapshot().unwrap().workflows.workflows[0].clone();
                if last {
                    break;
                }
            }
            let before = app.workflow_trace(id, None, 100).unwrap().spans.len();
            assert_eq!(
                current.run.as_ref().unwrap().status,
                if limited {
                    RunStatus::LimitReached
                } else {
                    RunStatus::Completed
                }
            );
            thread::sleep(Duration::from_millis(30));
            let input_path = folder.path().join("implement-input");
            assert!(
                !std::fs::read_to_string(&input_path)
                    .unwrap_or_default()
                    .contains("My unfinished")
            );
            accepted(
                &app,
                Command::ContinueWorkflowRun {
                    workflow_id: id,
                    agent_id: current.agents[0].agent_id,
                    generation: current.run.as_ref().unwrap().generation,
                    mode_revision: 0,
                },
            );
            app.write_terminal_input(terminal, b" message\r").unwrap();
            let continued = wait_for(&app, id, |_| {
                std::fs::read_to_string(&input_path)
                    .is_ok_and(|text| text.contains("Continue with the user's message above."))
            });
            let input = std::fs::read_to_string(&input_path).unwrap();
            assert!(input.contains("My unfinished message"));
            assert!(input.contains("Review feedback received while you were typing:"));
            assert!(input.contains(if limited {
                "review limit was reached"
            } else {
                "review is complete"
            }));
            assert!(
                !input.contains("You are Implementer")
                    && !input.contains("You are part of a Twine")
            );
            assert_eq!(continued.agents[0].terminal_id, terminal);
            assert_eq!(
                app.workflow_trace(id, None, 100).unwrap().spans.len(),
                before + 1
            );
            assert!(continued.run.as_ref().unwrap().needs_task());
            finish_active_stage(&app, &continued, Decision::Done, "My unfinished message");
            let review = app.snapshot().unwrap().workflows.workflows[0].clone();
            assert_eq!(review.run.as_ref().unwrap().prompt, "My unfinished message");
            assert!(
                review
                    .run
                    .as_ref()
                    .unwrap()
                    .follow_up_instructions(review.agents[1].agent_id.0)
                    .contains("My unfinished message")
            );
        }
    }

    #[test]
    fn agents_stay_interactive_and_keep_their_processes_across_handoffs_and_follow_ups() {
        for builtin in BuiltinType::ALL {
            let folder = tempfile::tempdir().unwrap();
            let bin = tempfile::tempdir().unwrap();
            let app = application(
                folder.path(),
                bin.path(),
                r#"
                stty -echo
                echo $$ >> processes
                while IFS= read -r line; do printf '%s\n' "$line" >> "input-$$"; done
            "#,
            );
            let id = launch(&app, folder.path(), builtin);
            let first = wait_for(&app, id, |w| !w.terminal_ids().is_empty());
            let first_agent = first.agents[0].agent_id;
            let first_terminal = first.agents[0].terminal_id;
            finish_active_stage(&app, &first, Decision::Approve, "");
            app.write_terminal_input(first_terminal, b"still interactive after handing off\n")
                .unwrap();
            if builtin == BuiltinType::Adversarial {
                let review = app.snapshot().unwrap().workflows.workflows[0].clone();
                finish_active_stage(&app, &review, Decision::RequestChanges, "");
                let implement = app.snapshot().unwrap().workflows.workflows[0].clone();
                assert_eq!(implement.agents[0].terminal_id, first_terminal);
                finish_active_stage(&app, &implement, Decision::Approve, "");
            }
            finish_remaining_stages(&app, id);
            let completed = app.snapshot().unwrap().workflows.workflows[0].clone();
            assert_eq!(completed.status, WorkflowStatus::Completed);
            let terminals = completed.terminal_ids();
            assert_eq!(completed.agents[0].terminal_id, first_terminal);
            for terminal in &terminals {
                assert_eq!(
                    app.lock_inner().unwrap().terminals[terminal],
                    TerminalStatus::Running
                );
                app.write_terminal_input(*terminal, b"still interactive after completing\n")
                    .unwrap();
            }
            for _ in 0..2 {
                accepted(
                    &app,
                    Command::ContinueWorkflowRun {
                        workflow_id: id,
                        agent_id: first_agent,
                        generation: completed.run.as_ref().unwrap().generation,
                        mode_revision: 0,
                    },
                );
            }
            let continued = app.snapshot().unwrap().workflows.workflows[0].clone();
            assert!(continued.run.as_ref().unwrap().needs_task());
            assert_eq!(continued.terminal_ids(), terminals);
            app.write_terminal_input(first_terminal, b"The follow-up task\n")
                .unwrap();
            finish_active_stage(&app, &continued, Decision::Approve, "The follow-up task");
            finish_remaining_stages(&app, id);
            let finished = app.snapshot().unwrap().workflows.workflows[0].clone();
            assert_eq!(finished.status, WorkflowStatus::Completed);
            assert_eq!(finished.terminal_ids(), terminals);
            assert_eq!(finished.terminal_history, []);
            assert_eq!(finished.run.as_ref().unwrap().prompt, "The follow-up task");
            wait_for(&app, id, |_| {
                std::fs::read_to_string(folder.path().join("processes"))
                    .is_ok_and(|pids| pids.lines().count() == terminals.len())
                    && std::fs::read_dir(folder.path())
                        .unwrap()
                        .filter_map(Result::ok)
                        .filter(|entry| entry.file_name().to_string_lossy().starts_with("input-"))
                        .filter_map(|entry| std::fs::read_to_string(entry.path()).ok())
                        .any(|text| text.contains("The follow-up task"))
            });
            let processes = std::fs::read_to_string(folder.path().join("processes")).unwrap();
            assert_eq!(processes.lines().count(), terminals.len());
            assert_live_assignment_history(
                &app,
                id,
                &terminals,
                if builtin == BuiltinType::Adversarial {
                    6
                } else {
                    8
                },
            );
            accepted(&app, Command::CloseWorkflow { workflow_id: id });
            for terminal in terminals {
                assert!(
                    app.write_terminal_input(terminal, b"after closing\n")
                        .is_err()
                );
            }
        }
    }

    fn assert_live_assignment_history(
        app: &Application,
        id: WorkflowId,
        terminals: &[TerminalId],
        count: usize,
    ) {
        let page = app.workflow_trace(id, None, 200).unwrap();
        let assignments: Vec<_> = page
            .spans
            .iter()
            .filter(|span| span.title != "Shell")
            .collect();
        assert_eq!(assignments.len(), count);
        for span in assignments {
            assert!(terminals.contains(&span.terminal_id.expect("each assignment has a terminal")));
            assert_eq!(span.status, crate::TraceSpanStatus::Completed);
            let events = app.trace_events(span.span_id, None, 200).unwrap().events;
            if let Some(continuation) = events.iter().find(|event| {
                event
                    .message
                    .contains("Assignment continued in the existing harness")
            }) {
                let anchor = continuation
                    .anchor
                    .as_ref()
                    .expect("continuation has a terminal boundary");
                assert_eq!(anchor.terminal_id, span.terminal_id.unwrap());
                assert!(
                    events
                        .iter()
                        .all(|event| event.kind != crate::TraceEventKind::ProcessStarted)
                );
                let completion = events
                    .iter()
                    .find(|event| {
                        event.message.contains("Marked done") || event.message.contains("Approved:")
                    })
                    .unwrap();
                assert!(anchor.byte_offset <= completion.anchor.as_ref().unwrap().byte_offset);
            }
            assert!(
                events
                    .iter()
                    .all(|event| event.kind != crate::TraceEventKind::ProcessStopped)
            );
        }
    }

    #[test]
    fn reaching_the_review_limit_keeps_agents_live_for_a_fresh_cycle_and_explicit_cancel() {
        let folder = tempfile::tempdir().unwrap();
        let bin = tempfile::tempdir().unwrap();
        let app = application(
            folder.path(),
            bin.path(),
            "while read line; do echo \"$line\"; done",
        );
        let id = launch(&app, folder.path(), BuiltinType::Adversarial);
        loop {
            let workflow = app.snapshot().unwrap().workflows.workflows[0].clone();
            if workflow.status != WorkflowStatus::Running {
                break;
            }
            finish_active_stage(&app, &workflow, Decision::RequestChanges, "");
        }
        let limited = app.snapshot().unwrap().workflows.workflows[0].clone();
        assert_eq!(
            limited.run.as_ref().unwrap().status,
            RunStatus::LimitReached
        );
        let terminals = limited.terminal_ids();
        for terminal in &terminals {
            assert!(app.terminals.is_running(*terminal));
        }
        accepted(
            &app,
            Command::ContinueWorkflowRun {
                workflow_id: id,
                agent_id: limited.agents[0].agent_id,
                generation: limited.run.as_ref().unwrap().generation,
                mode_revision: 0,
            },
        );
        let continued = app.snapshot().unwrap().workflows.workflows[0].clone();
        assert_eq!(continued.terminal_ids(), terminals);
        assert!(continued.run.as_ref().unwrap().rounds.is_empty());
        finish_active_stage(
            &app,
            &continued,
            Decision::Approve,
            "A follow-up after the review limit",
        );
        finish_remaining_stages(&app, id);
        assert_eq!(
            app.snapshot().unwrap().workflows.workflows[0].status,
            WorkflowStatus::Completed
        );
        accepted(&app, Command::CancelWorkflowRun { workflow_id: id });
        for terminal in terminals {
            assert!(!app.terminals.is_running(terminal));
        }
        assert!(app.run_processes.lock().unwrap().is_empty());
    }

    fn assert_run_trace_history(app: &Application, workflow: &Workflow, invocations: u64) {
        let page = app.workflow_trace(workflow.workflow_id, None, 200).unwrap();
        assert_eq!(page.summary.span_count, invocations);
        assert!(page.lanes.iter().all(|lane| lane.is_agent));
        assert_eq!(page.summary.agent_count, 2);
        for span in page.spans.iter().filter(|span| span.title != "Shell") {
            let lane = page
                .lanes
                .iter()
                .find(|lane| lane.lane_id == span.lane_id)
                .unwrap();
            assert_eq!(lane.harness.as_deref(), Some("pi"));
            let events = app.trace_events(span.span_id, None, 200).unwrap().events;
            let events: Vec<_> = events
                .iter()
                .filter(|event| event.kind == crate::TraceEventKind::WorkflowEvent)
                .collect();
            assert!(
                events
                    .iter()
                    .any(|event| event.message.contains("Stage started"))
            );
            assert!(
                events
                    .iter()
                    .any(|event| event.message.contains("Stage completed"))
            );
            let completion = events
                .iter()
                .find(|event| {
                    event.message.contains("Marked done:")
                        || event.message.contains("Approved:")
                        || event.message.contains("Requested changes:")
                })
                .unwrap();
            assert!(completion.message.contains("Result or feedback"));
            assert_eq!(span.status, crate::TraceSpanStatus::Completed);
            assert_eq!(
                span.ended_at,
                Some(completion.timestamp.max(span.started_at))
            );
            assert!(completion.anchor.is_some());
            if let Some(handoff) = events
                .iter()
                .find(|event| event.message.contains("Handoff delivered"))
            {
                assert_eq!(span.started_at, handoff.timestamp);
                assert!(handoff.message.contains("Result or feedback"));
                assert!(handoff.anchor.is_some());
            } else {
                let start = events
                    .iter()
                    .find(|event| event.message.contains("Stage started"))
                    .unwrap();
                assert_eq!(span.started_at, start.timestamp);
            }
        }
        for round in 1..=invocations / 2 {
            for stage in ["Implement", "Review"] {
                assert_eq!(
                    page.spans
                        .iter()
                        .filter(|span| span.title == format!("{stage} · Round {round}"))
                        .count(),
                    1
                );
            }
        }
        // Saving the same accepted state again never duplicates events or invocation spans.
        // Hold the store lock so late harness hooks cannot change the revision between reads.
        let mut inner = app.lock_inner().unwrap();
        let store = inner.folders.store();
        let before = store
            .workflow_trace(workflow.workflow_id, None, 200)
            .unwrap()
            .summary
            .revision;
        assert_eq!(store.save_workflow_run(workflow).unwrap(), []);
        assert_eq!(
            store
                .workflow_trace(workflow.workflow_id, None, 200)
                .unwrap()
                .summary
                .revision,
            before
        );
    }

    #[test]
    fn fake_coordinator_sends_worker_tasks_and_files_then_gathers_results() {
        let folder = tempfile::tempdir().unwrap();
        let bin = tempfile::tempdir().unwrap();
        let app = application(folder.path(), bin.path(), FAKE);
        let id = launch(&app, folder.path(), BuiltinType::Coordinator);
        let result = wait_for(&app, id, |w| w.status == WorkflowStatus::Completed);
        let order = std::fs::read_to_string(folder.path().join("order")).unwrap();
        let order: Vec<_> = order.lines().collect();
        assert_eq!(order.first(), Some(&"split"));
        assert_eq!(order.last(), Some(&"gather"));
        assert!(order[1..3].contains(&"worker1") && order[1..3].contains(&"worker2"));
        for (worker, task, file) in [
            (1, "First sub-task", "first.txt"),
            (2, "Second sub-task", "second.txt"),
        ] {
            let prompt =
                std::fs::read_to_string(folder.path().join(format!("worker{worker}-prompt")))
                    .unwrap();
            assert!(prompt.contains(task) && prompt.contains(file));
        }
        let gather = std::fs::read_to_string(folder.path().join("gather-prompt")).unwrap();
        assert!(gather.contains("Worker 1") && gather.contains("Worker 2"));
        let traces = result.run.unwrap().traces;
        assert_eq!(
            traces.iter().filter(|t| t.kind == "stageStarted").count(),
            3
        );
        assert_eq!(traces.iter().filter(|t| t.kind == "handoff").count(), 4);
        let page = app.workflow_trace(id, None, 200).unwrap();
        assert_eq!(page.summary.span_count, 4);
        for (task, label) in [
            ("First sub-task", "Worker 1"),
            ("Second sub-task", "Worker 2"),
        ] {
            let lane = page.lanes.iter().find(|lane| lane.name == label).unwrap();
            let spans: Vec<_> = page
                .spans
                .iter()
                .filter(|span| span.lane_id == lane.lane_id)
                .collect();
            assert_eq!(spans.len(), 1);
            let span = spans[0];
            assert_eq!(span.title, task);
            assert_eq!(span.status, crate::TraceSpanStatus::Completed);
            let events = app.trace_events(span.span_id, None, 200).unwrap().events;
            let handoff = events
                .iter()
                .find(|event| event.message.contains("Handoff delivered"))
                .unwrap();
            assert!(handoff.message.contains(task));
            assert_eq!(span.started_at, handoff.timestamp);
            let completion = events
                .iter()
                .find(|event| event.message.contains("Marked done: Result or feedback"))
                .unwrap();
            assert_eq!(
                span.ended_at,
                Some(completion.timestamp.max(span.started_at))
            );
            assert!(handoff.anchor.is_some() && completion.anchor.is_some());
            assert_eq!(
                completion.anchor.as_ref().unwrap().terminal_id,
                span.terminal_id.unwrap()
            );
            assert!(
                events
                    .iter()
                    .any(|event| event.kind == crate::TraceEventKind::ProcessStarted)
            );
            assert!(app.terminals.is_running(span.terminal_id.unwrap()));
        }
        let handoffs = page
            .spans
            .iter()
            .flat_map(|span| app.trace_events(span.span_id, None, 200).unwrap().events)
            .filter(|event| event.message.contains("Handoff delivered"))
            .count();
        assert_eq!(handoffs, 4);
        assert_gather_anchors(&app, &page);
        accepted(&app, Command::CloseWorkflow { workflow_id: id });
        assert_eq!(
            app.workflow_trace(id, None, 200)
                .unwrap()
                .summary
                .span_count,
            4
        );
    }

    fn assert_gather_anchors(app: &Application, page: &crate::WorkflowTracePage) {
        let gather = page
            .spans
            .iter()
            .find(|span| span.title == "Gather")
            .unwrap();
        let gathered = app.trace_events(gather.span_id, None, 200).unwrap().events;
        for worker in ["Worker 1", "Worker 2"] {
            let lane = page.lanes.iter().find(|lane| lane.name == worker).unwrap();
            let span = page
                .spans
                .iter()
                .find(|span| span.lane_id == lane.lane_id)
                .unwrap();
            let events = app.trace_events(span.span_id, None, 200).unwrap().events;
            let completion = events
                .iter()
                .find(|event| event.message.contains("Marked done:"))
                .unwrap();
            let handoff = gathered
                .iter()
                .find(|event| event.message.contains(&format!("{worker} → Coordinator")))
                .unwrap();
            assert_eq!(handoff.anchor, completion.anchor);
            assert_eq!(
                handoff.anchor.as_ref().unwrap().terminal_id,
                span.terminal_id.unwrap()
            );
        }
    }

    fn launch_coordinator_workers(app: &Application, folder: &Path) -> WorkflowId {
        let id = launch(app, folder, BuiltinType::Coordinator);
        let workflow = app.snapshot().unwrap().workflows.workflows[0].clone();
        accepted(
            app,
            Command::CompleteWorkflowRole {
                workflow_id: id,
                agent_id: workflow.agents[0].agent_id,
                generation: 1,
                signal: CompletionSignal {
                    task: String::new(),
                    decision: Decision::Done,
                    summary: "Split the task".into(),
                    assignments: (1..=2)
                        .map(|instance| crate::Assignment {
                            role: "worker".into(),
                            instance,
                            task: format!("Task {instance}"),
                            files: vec![],
                        })
                        .collect(),
                },
            },
        );
        id
    }

    fn done_signal(summary: &str) -> CompletionSignal {
        CompletionSignal {
            decision: Decision::Done,
            summary: summary.into(),
            assignments: vec![],
            task: String::new(),
        }
    }

    #[test]
    fn coordinator_assignments_finish_independently_and_cancellation_stops_only_unfinished_work() {
        let folder = tempfile::tempdir().unwrap();
        let bin = tempfile::tempdir().unwrap();
        let app = application(folder.path(), bin.path(), "echo ready; sleep 60");
        let id = launch_coordinator_workers(&app, folder.path());
        let page = app.workflow_trace(id, None, 200).unwrap();
        let workers: Vec<_> = page
            .spans
            .iter()
            .filter(|span| span.title.starts_with("Task "))
            .collect();
        assert_eq!(workers.len(), 2);
        assert!(
            workers
                .iter()
                .all(|span| span.is_live && span.ended_at.is_none())
        );
        let workflow = app.snapshot().unwrap().workflows.workflows[0].clone();
        let first = workers.iter().find(|span| span.title == "Task 1").unwrap();
        let terminal = first.terminal_id.unwrap();
        wait_for(&app, id, |_| {
            app.terminals.observe(terminal).unwrap().byte_offset > 0
        });
        let size = TerminalSize {
            columns: 120,
            ..SIZE
        };
        app.terminals.resize(terminal, size).unwrap();
        let boundary = app.terminals.observe(terminal).unwrap();
        accepted(
            &app,
            Command::CompleteWorkflowRole {
                workflow_id: id,
                agent_id: workflow.agents[1].agent_id,
                generation: 2,
                signal: done_signal("Finished Task 1"),
            },
        );
        let page = app.workflow_trace(id, None, 200).unwrap();
        let finished = page
            .spans
            .iter()
            .find(|span| span.title == "Task 1")
            .unwrap();
        assert_eq!(finished.status, crate::TraceSpanStatus::Completed);
        let events = app
            .trace_events(finished.span_id, None, 200)
            .unwrap()
            .events;
        let completion = events
            .iter()
            .find(|event| event.message.contains("Marked done: Finished Task 1"))
            .unwrap();
        let anchor = completion.anchor.as_ref().unwrap();
        // Observation includes all output accepted before completion and the resize boundary.
        assert_eq!(anchor.byte_offset, boundary.byte_offset);
        assert_eq!(anchor.boundary_sizes, Some(vec![size]));
        assert_eq!(anchor.terminal_id, terminal);
        assert!(
            events
                .iter()
                .all(|event| event.kind != crate::TraceEventKind::ProcessStopped)
        );
        assert!(app.terminals.is_running(terminal));
        let unfinished = page
            .spans
            .iter()
            .find(|span| span.title == "Task 2")
            .unwrap();
        assert!(unfinished.is_live && unfinished.ended_at.is_none());
        let finished = finished.clone();
        accepted(&app, Command::CancelWorkflowRun { workflow_id: id });
        assert!(!app.terminals.is_running(terminal));
        let page = app.workflow_trace(id, None, 200).unwrap();
        assert_eq!(
            page.spans
                .iter()
                .find(|span| span.title == "Task 1")
                .unwrap(),
            &finished
        );
        let stopped = page
            .spans
            .iter()
            .find(|span| span.title == "Task 2")
            .unwrap();
        assert_eq!(stopped.status, crate::TraceSpanStatus::Stopped);
        assert!(!stopped.is_live && stopped.ended_at.is_some());
        let events = app.trace_events(stopped.span_id, None, 200).unwrap().events;
        assert!(
            events
                .iter()
                .any(|event| event.kind == crate::TraceEventKind::ProcessStopped
                    && event.anchor.as_ref().unwrap().terminal_id == stopped.terminal_id.unwrap())
        );
        assert!(
            !events
                .iter()
                .any(|event| event.message.contains("Marked done"))
        );
    }

    #[test]
    fn a_process_failure_does_not_end_an_assignment_before_accepted_completion() {
        let folder = tempfile::tempdir().unwrap();
        let bin = tempfile::tempdir().unwrap();
        let app = application(folder.path(), bin.path(), "sleep 60");
        let id = launch(&app, folder.path(), BuiltinType::Adversarial);
        let workflow = app.snapshot().unwrap().workflows.workflows[0].clone();
        let agent = &workflow.agents[0];
        app.lock_inner()
            .unwrap()
            .record_terminal_exit(agent.terminal_id, Err("Injected process failure".into()));
        let span = app.workflow_trace(id, None, 200).unwrap().spans[0].clone();
        assert_eq!(span.status, crate::TraceSpanStatus::Running);
        assert!(span.is_live && span.ended_at.is_none());
        let events = app.trace_events(span.span_id, None, 200).unwrap().events;
        assert!(
            events
                .iter()
                .any(|event| event.kind == crate::TraceEventKind::ProcessFailed
                    && event.anchor.is_some())
        );
        accepted(
            &app,
            Command::CompleteWorkflowRole {
                workflow_id: id,
                agent_id: agent.agent_id,
                generation: 1,
                signal: CompletionSignal {
                    task: String::new(),
                    decision: Decision::Done,
                    summary: "Recovered the result".into(),
                    assignments: vec![],
                },
            },
        );
        let page = app.workflow_trace(id, None, 200).unwrap();
        let completed = page
            .spans
            .iter()
            .find(|candidate| candidate.span_id == span.span_id)
            .unwrap();
        assert_eq!(completed.status, crate::TraceSpanStatus::Completed);
        let events = app.trace_events(span.span_id, None, 200).unwrap().events;
        let completion = events
            .iter()
            .find(|event| event.message.contains("Marked done: Recovered the result"))
            .unwrap();
        assert_eq!(
            completed.ended_at,
            Some(completion.timestamp.max(completed.started_at))
        );
        accepted(&app, Command::CancelWorkflowRun { workflow_id: id });
    }

    #[test]
    fn closing_an_exited_agent_stops_its_unfinished_assignment() {
        let folder = tempfile::tempdir().unwrap();
        let bin = tempfile::tempdir().unwrap();
        let app = application(folder.path(), bin.path(), "exit 0");
        let id = launch(&app, folder.path(), BuiltinType::Adversarial);
        wait_for(&app, id, |_| {
            app.lock_inner()
                .unwrap()
                .terminals
                .values()
                .all(|status| !matches!(status, TerminalStatus::Running))
        });
        let span = app.workflow_trace(id, None, 200).unwrap().spans[0].clone();
        assert_eq!(span.status, crate::TraceSpanStatus::Running);
        assert!(span.is_live && span.ended_at.is_none());
        accepted(&app, Command::CloseWorkflow { workflow_id: id });
        let closed = app.workflow_trace(id, None, 200).unwrap().spans[0].clone();
        assert_eq!(closed.span_id, span.span_id);
        assert_eq!(closed.status, crate::TraceSpanStatus::Stopped);
        let events = app.trace_events(closed.span_id, None, 200).unwrap().events;
        assert!(
            events
                .iter()
                .any(|event| event.kind == crate::TraceEventKind::ProcessExited)
        );
        assert!(
            events
                .iter()
                .any(|event| event.message.contains("Assignment stopped"))
        );
    }

    #[test]
    fn prose_and_process_exit_do_not_advance_but_user_mark_done_does() {
        let folder = tempfile::tempdir().unwrap();
        let bin = tempfile::tempdir().unwrap();
        let app = application(
            folder.path(),
            bin.path(),
            "echo 'done approved requestChanges'; exit 0",
        );
        let id = launch(&app, folder.path(), BuiltinType::Adversarial);
        let first = wait_for(&app, id, |w| {
            app.lock_inner()
                .unwrap()
                .terminals
                .values()
                .all(|s| !matches!(s, TerminalStatus::Running))
                && w.run.is_some()
        });
        let run = first.run.unwrap();
        assert_eq!(run.stage_index, 0);
        assert_eq!(first.status, WorkflowStatus::Running);
        let assignment = app.workflow_trace(id, None, 200).unwrap().spans[0].clone();
        assert_eq!(assignment.status, crate::TraceSpanStatus::Running);
        assert!(assignment.is_live && assignment.ended_at.is_none());
        let events = app
            .trace_events(assignment.span_id, None, 200)
            .unwrap()
            .events;
        assert!(
            events
                .iter()
                .any(|event| event.kind == crate::TraceEventKind::ProcessExited
                    && event.anchor.is_some())
        );
        accepted(
            &app,
            Command::CompleteWorkflowRole {
                workflow_id: id,
                agent_id: first.agents[0].agent_id,
                generation: run.generation,
                signal: CompletionSignal {
                    task: String::new(),
                    decision: Decision::Done,
                    summary: "User result".into(),
                    assignments: vec![],
                },
            },
        );
        let page = app.workflow_trace(id, None, 200).unwrap();
        let completed = page
            .spans
            .iter()
            .find(|span| span.span_id == assignment.span_id)
            .unwrap();
        assert_eq!(completed.status, crate::TraceSpanStatus::Completed);
        let events = app
            .trace_events(completed.span_id, None, 200)
            .unwrap()
            .events;
        let completion = events
            .iter()
            .find(|event| event.message.contains("Marked done: User result"))
            .unwrap();
        assert_eq!(
            completed.ended_at,
            Some(completion.timestamp.max(completed.started_at))
        );
        assert_eq!(
            app.snapshot().unwrap().workflows.workflows[0]
                .run
                .as_ref()
                .unwrap()
                .stage_index,
            1
        );
        accepted(&app, Command::CancelWorkflowRun { workflow_id: id });
        assert_eq!(
            app.snapshot().unwrap().workflows.workflows[0].status,
            WorkflowStatus::Cancelled
        );
        assert!(app.run_processes.lock().unwrap().is_empty());
    }

    #[test]
    fn running_workflows_restore_as_interrupted_without_launching_agents() {
        let folder = tempfile::tempdir().unwrap();
        let bin = tempfile::tempdir().unwrap();
        let data = tempfile::tempdir().unwrap();
        let app = application(folder.path(), bin.path(), "sleep 60");
        // Use its test harness with a persistent database.
        let mut persistent = Application::with_config(data.path(), Config::default()).unwrap();
        persistent.harness_path.clone_from(&app.harness_path);
        accepted(
            &persistent,
            Command::OpenFolder {
                path: folder.path().to_owned(),
            },
        );
        let id = launch(&persistent, folder.path(), BuiltinType::Adversarial);
        let marker = persistent.terminals.reserve_terminal().unwrap();
        persistent
            .terminals
            .cancel_reserved_terminal(marker)
            .unwrap();
        drop(persistent);
        let restored = Application::with_config(data.path(), Config::default()).unwrap();
        let workflow = wait_for(&restored, id, |w| w.restored);
        assert_eq!(workflow.status, WorkflowStatus::Interrupted);
        assert_eq!(workflow.terminal_ids(), []);
        assert_eq!(workflow.run.unwrap().status, RunStatus::Interrupted);
        let next = restored.terminals.reserve_terminal().unwrap();
        restored.terminals.cancel_reserved_terminal(next).unwrap();
        assert_eq!(next.value(), marker.value() + 1);
    }

    #[test]
    fn an_incoming_assignment_is_live_while_its_process_launch_waits_on_storage() {
        let folder = tempfile::tempdir().unwrap();
        let bin = tempfile::tempdir().unwrap();
        let app = Arc::new(application(folder.path(), bin.path(), "sleep 60"));
        let id = launch(&app, folder.path(), BuiltinType::Adversarial);
        let workflow = app.snapshot().unwrap().workflows.workflows[0].clone();
        let stalled = app
            .terminal_output
            .stall_recording_worker(workflow.agents[0].terminal_id);
        let completing = Arc::clone(&app);
        let completion = thread::spawn(move || {
            accepted(
                &completing,
                Command::CompleteWorkflowRole {
                    workflow_id: id,
                    agent_id: workflow.agents[0].agent_id,
                    generation: 1,
                    signal: CompletionSignal {
                        task: String::new(),
                        decision: Decision::Done,
                        summary: "Ready for review".into(),
                        assignments: vec![],
                    },
                },
            );
        });
        let deadline = Instant::now() + Duration::from_secs(3);
        while !app.terminal_output.allocation_is_pending() {
            assert!(
                Instant::now() < deadline,
                "review launch did not reach transcript allocation"
            );
            thread::yield_now();
        }
        let (sent, received) = std::sync::mpsc::sync_channel(1);
        let observing = Arc::clone(&app);
        let observer = thread::spawn(move || {
            sent.send(observing.workflow_trace(id, None, 200).unwrap())
                .unwrap();
        });
        let page = received
            .recv_timeout(Duration::from_secs(1))
            .expect("traces remain readable during launch");
        let span = page
            .spans
            .iter()
            .find(|span| span.title == "Review · Round 1")
            .unwrap();
        assert!(span.is_live && span.terminal_id.is_none() && span.ended_at.is_none());
        let span_id = span.span_id;
        let events = app.trace_events(span_id, None, 200).unwrap().events;
        assert_eq!(span.started_at, events[0].timestamp);
        assert!(events[0].message.contains("Ready for review"));
        drop(stalled);
        observer.join().unwrap();
        completion.join().unwrap();
        let page = app.workflow_trace(id, None, 200).unwrap();
        let span = page
            .spans
            .iter()
            .find(|span| span.span_id == span_id)
            .unwrap();
        assert!(span.is_live && span.terminal_id.is_some());
        accepted(&app, Command::CancelWorkflowRun { workflow_id: id });
    }

    #[test]
    fn stalled_run_launch_keeps_snapshots_available_and_consistent_with_events() {
        let folder = tempfile::tempdir().unwrap();
        let bin = tempfile::tempdir().unwrap();
        let app = Arc::new(application(folder.path(), bin.path(), "sleep 60"));
        accepted(
            &app,
            Command::CreateWorkflow {
                folder: folder.path().into(),
                session_id: None,
                kind: WorkflowKind::Draft,
                roles: vec![],
                size: SIZE,
            },
        );
        let before = app.snapshot().unwrap();
        let draft = &before.workflows.workflows[0];
        let id = draft.workflow_id;
        let stalled = app
            .terminal_output
            .stall_recording_worker(draft.terminal_id);
        let starting = Arc::clone(&app);
        let starter = thread::spawn(move || {
            accepted(
                &starting,
                Command::StartWorkflowRun {
                    workflow_id: id,
                    workflow_type: WorkflowTypeRef::Builtin(BuiltinType::Adversarial),
                    prompt: "Test a stalled launch".into(),
                    roles: ["implementer", "reviewer"]
                        .map(|role| RoleLaunch {
                            model: None,
                            effort: None,
                            yolo: false,
                            role: role.into(),
                            harness: HarnessId::Pi,
                        })
                        .into(),
                    size: SIZE,
                },
            );
        });
        let deadline = Instant::now() + Duration::from_secs(3);
        while !app.terminal_output.allocation_is_pending() {
            assert!(
                Instant::now() < deadline,
                "launch did not reach transcript allocation"
            );
            thread::yield_now();
        }
        let (sent, received) = std::sync::mpsc::sync_channel(1);
        let observing = Arc::clone(&app);
        let observer = thread::spawn(move || {
            let snapshot = observing.snapshot().unwrap();
            let events = observing.events_after(before.sequence, 128).unwrap();
            sent.send((snapshot, events)).unwrap();
        });
        let (snapshot, events) = received
            .recv_timeout(Duration::from_secs(1))
            .expect("state must remain available while launch waits on storage");
        let changed = events
            .iter()
            .rev()
            .find_map(|event| match &event.kind {
                EventKind::State(StateEvent::WorkflowChanged(workflow))
                    if workflow.workflow_id == id =>
                {
                    Some(workflow)
                }
                _ => None,
            })
            .expect("the newly visible run must already have an event");
        assert_eq!(changed, &snapshot.workflows.workflows[0]);
        assert!(changed.run.is_some());
        assert_eq!(events.last().unwrap().sequence, snapshot.sequence);
        drop(stalled);
        observer.join().unwrap();
        starter.join().unwrap();
        accepted(&app, Command::CancelWorkflowRun { workflow_id: id });
    }

    fn fail_run_updates(data: &Path) -> rusqlite::Connection {
        let connection = rusqlite::Connection::open(data.join("twine.db")).unwrap();
        connection
            .execute_batch(
                "CREATE TRIGGER reject_run_update BEFORE UPDATE ON workflow_runs
            BEGIN SELECT RAISE(ABORT, 'injected run write failure'); END",
            )
            .unwrap();
        connection
    }

    #[test]
    fn a_failed_first_invocation_keeps_its_failure_in_visible_trace_history() {
        let folder = tempfile::tempdir().unwrap();
        let bin = tempfile::tempdir().unwrap();
        let app = application(folder.path(), bin.path(), "exit 0");
        // A rejected PTY size fails before the launcher can create a process.
        let id = launch_with_size(
            &app,
            folder.path(),
            BuiltinType::Adversarial,
            TerminalSize { rows: 0, ..SIZE },
            "Test the workflow",
        );
        let workflow = wait_for(&app, id, |w| w.status == WorkflowStatus::Failed);
        assert_eq!(workflow.terminal_ids(), []);
        let page = app.workflow_trace(id, None, 200).unwrap();
        assert_eq!(page.summary.span_count, 1);
        assert_eq!(page.summary.agent_count, 0);
        let events = app
            .trace_events(page.spans[0].span_id, None, 200)
            .unwrap()
            .events;
        assert!(
            events
                .iter()
                .any(|event| event.message.contains("Couldn't start Implementer"))
        );
        assert_eq!(
            events
                .iter()
                .filter(|event| event.kind == crate::TraceEventKind::ProcessStarted)
                .count(),
            0
        );
        accepted(&app, Command::CloseWorkflow { workflow_id: id });
        assert!(
            app.trace_events(page.spans[0].span_id, None, 200)
                .unwrap()
                .events
                .iter()
                .any(|event| event.message.contains("Couldn't start Implementer"))
        );
    }

    #[test]
    fn failed_launch_publication_stops_and_tracks_every_spawned_terminal() {
        let folder = tempfile::tempdir().unwrap();
        let bin = tempfile::tempdir().unwrap();
        let data = tempfile::tempdir().unwrap();
        let fixture = application(folder.path(), bin.path(), "sleep 60");
        let mut app = Application::with_config(data.path(), Config::default()).unwrap();
        app.harness_path.clone_from(&fixture.harness_path);
        accepted(
            &app,
            Command::OpenFolder {
                path: folder.path().to_owned(),
            },
        );
        let _failure = fail_run_updates(data.path());
        let id = launch(&app, folder.path(), BuiltinType::Adversarial);
        let workflow = wait_for(&app, id, |w| {
            w.status == WorkflowStatus::Failed
                && app
                    .lock_inner()
                    .unwrap()
                    .terminals
                    .values()
                    .all(|t| !matches!(t, TerminalStatus::Running))
        });
        assert!(
            !workflow.terminal_ids().is_empty(),
            "stopped terminals remain owned by the failed workflow"
        );
        assert!(app.run_processes.lock().unwrap().is_empty());
        accepted(&app, Command::CloseWorkflow { workflow_id: id });
        for terminal in workflow.terminal_ids() {
            assert!(app.terminals.size(terminal).is_none());
        }
    }

    #[test]
    fn a_run_without_a_prompt_asks_the_first_agent_and_passes_the_reported_task_on() {
        let folder = tempfile::tempdir().unwrap();
        let bin = tempfile::tempdir().unwrap();
        // Each agent records its launch prompt, the last argument, in its own file, written whole.
        let app = application(
            folder.path(),
            bin.path(),
            r#"for last; do :; done; printf '%s' "$last" > "p-$$.tmp"; mv "p-$$.tmp" "prompt-$$.txt"; sleep 60"#,
        );
        let id = launch_with_size(&app, folder.path(), BuiltinType::Adversarial, SIZE, "");
        let prompts = |count: usize| {
            let deadline = Instant::now() + Duration::from_secs(15);
            loop {
                let found: Vec<String> = std::fs::read_dir(folder.path())
                    .unwrap()
                    .filter_map(Result::ok)
                    .filter(|entry| entry.file_name().to_string_lossy().starts_with("prompt-"))
                    .filter_map(|entry| std::fs::read_to_string(entry.path()).ok())
                    .filter(|text| !text.is_empty())
                    .collect();
                if found.len() >= count {
                    return found;
                }
                assert!(Instant::now() < deadline, "agent prompts timed out");
                thread::sleep(Duration::from_millis(10));
            }
        };
        assert!(prompts(1)[0].contains("ask them what they want done"));

        // A completion without the task goes back to the agent to correct.
        submit_helper(&app, id);
        let run = app.snapshot().unwrap().workflows.workflows[0]
            .run
            .clone()
            .unwrap();
        assert_eq!(run.generation, 1);
        let response = app.run_processes.lock().unwrap()[&id]
            .inboxes
            .values()
            .next()
            .unwrap()
            .1
            .response();
        assert!(response.contains("task"), "{response}");

        submit_signal(
            &app,
            id,
            br#"{"decision":"done","summary":"Done","task":"Add a toggle"}"#,
        );
        wait_for(&app, id, |w| {
            w.run.as_ref().is_some_and(|run| run.generation == 2)
        });
        assert!(
            prompts(2)
                .iter()
                .any(|prompt| prompt.contains("Task:\nAdd a toggle"))
        );
    }

    #[test]
    fn each_role_starts_with_its_chosen_model_and_effort() {
        let folder = tempfile::tempdir().unwrap();
        let bin = tempfile::tempdir().unwrap();
        // Each agent records its arguments, written whole, in its own file.
        let app = application(
            folder.path(),
            bin.path(),
            r#"printf '%s ' "$@" > "a-$$.tmp"; mv "a-$$.tmp" "args-$$.txt"; sleep 60"#,
        );
        accepted(
            &app,
            Command::CreateWorkflow {
                folder: folder.path().to_owned(),
                session_id: None,
                kind: WorkflowKind::Draft,
                roles: vec![],
                size: SIZE,
            },
        );
        let id = app.snapshot().unwrap().workflows.workflows[0].workflow_id;
        let role = |role: &str, model: Option<&str>| RoleLaunch {
            role: role.into(),
            harness: HarnessId::Pi,
            model: model.map(str::to_owned),
            effort: model.map(|_| "high".to_owned()),
            yolo: true,
        };
        accepted(
            &app,
            Command::StartWorkflowRun {
                workflow_id: id,
                workflow_type: WorkflowTypeRef::Builtin(BuiltinType::Adversarial),
                prompt: "Task".into(),
                roles: vec![
                    role("implementer", Some("local/m1")),
                    role("reviewer", None),
                ],
                size: SIZE,
            },
        );
        let deadline = Instant::now() + Duration::from_secs(15);
        let arguments = loop {
            let found: Vec<String> = std::fs::read_dir(folder.path())
                .unwrap()
                .filter_map(Result::ok)
                .filter(|entry| entry.file_name().to_string_lossy().starts_with("args-"))
                .filter_map(|entry| std::fs::read_to_string(entry.path()).ok())
                .collect();
            if let Some(found) = found.into_iter().next() {
                break found;
            }
            assert!(Instant::now() < deadline, "the implementer never started");
            thread::sleep(Duration::from_millis(10));
        };
        assert!(
            arguments.contains("--model local/m1 --thinking high "),
            "{arguments}"
        );
    }

    fn submit_helper(app: &Application, id: WorkflowId) {
        submit_signal(app, id, br#"{"decision":"done","summary":"Finished"}"#);
    }

    fn submit_signal(app: &Application, id: WorkflowId, signal: &[u8]) {
        use std::io::Write;
        use std::process::{Command as Process, Stdio};
        let command = app.run_processes.lock().unwrap()[&id]
            .inboxes
            .values()
            .next()
            .unwrap()
            .1
            .command();
        let mut child = Process::new("/bin/sh")
            .args(["-c", &command])
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(signal).unwrap();
        let deadline = Instant::now() + Duration::from_secs(2);
        loop {
            app.poll_workflow_signals().unwrap();
            let remains = app
                .run_processes
                .lock()
                .unwrap()
                .get(&id)
                .is_some_and(|processes| {
                    processes
                        .inboxes
                        .values()
                        .any(|(_, inbox)| inbox.command() == command)
                });
            if let Some(status) = child.try_wait().unwrap() {
                assert_eq!(status.success(), !remains);
                return;
            }
            assert!(Instant::now() < deadline, "completion wasn't processed");
            thread::sleep(Duration::from_millis(5));
        }
    }

    #[test]
    fn a_completion_write_failure_reports_retry_and_cancellation_still_stops_agents() {
        let folder = tempfile::tempdir().unwrap();
        let bin = tempfile::tempdir().unwrap();
        let data = tempfile::tempdir().unwrap();
        let fixture = application(folder.path(), bin.path(), "sleep 60");
        let mut app = Application::with_config(data.path(), Config::default()).unwrap();
        app.harness_path.clone_from(&fixture.harness_path);
        accepted(
            &app,
            Command::OpenFolder {
                path: folder.path().to_owned(),
            },
        );
        let id = launch(&app, folder.path(), BuiltinType::Adversarial);
        let failure = fail_run_updates(data.path());
        let before = app.workflow_trace(id, None, 200).unwrap();
        submit_helper(&app, id);
        let snapshot = app.snapshot().unwrap();
        assert_eq!(app.workflow_trace(id, None, 200).unwrap(), before);
        assert_eq!(
            snapshot.workflows.workflows[0]
                .run
                .as_ref()
                .unwrap()
                .generation,
            1
        );
        assert_ne!(
            app.run_processes.lock().unwrap()[&id]
                .inboxes
                .values()
                .next()
                .unwrap()
                .1
                .response(),
            ""
        );
        failure
            .execute_batch("DROP TRIGGER reject_run_update")
            .unwrap();
        submit_helper(&app, id);
        let snapshot = app.snapshot().unwrap();
        let page = app.workflow_trace(id, None, 200).unwrap();
        assert_eq!(page.summary.span_count, before.summary.span_count + 1);
        let first = page
            .spans
            .iter()
            .find(|span| span.span_id == before.spans[0].span_id)
            .unwrap();
        assert_eq!(first.status, crate::TraceSpanStatus::Completed);
        let events = app.trace_events(first.span_id, None, 200).unwrap().events;
        assert_eq!(
            events
                .iter()
                .filter(|event| event.message.contains("Marked done:"))
                .count(),
            1
        );
        assert_eq!(
            snapshot.workflows.workflows[0]
                .run
                .as_ref()
                .unwrap()
                .generation,
            2
        );
        let _failure = fail_run_updates(data.path());
        accepted(&app, Command::CancelWorkflowRun { workflow_id: id });
        wait_for(&app, id, |w| {
            w.status == WorkflowStatus::Cancelled
                && app
                    .lock_inner()
                    .unwrap()
                    .terminals
                    .values()
                    .all(|t| !matches!(t, TerminalStatus::Running))
        });
    }

    #[test]
    fn a_custom_type_launch_pins_its_version_and_definition() {
        let folder = tempfile::tempdir().unwrap();
        let bin = tempfile::tempdir().unwrap();
        let app = application(folder.path(), bin.path(), FAKE);
        let original = BuiltinType::Adversarial.definition();
        let reference = WorkflowCatalog::new(app.lock_inner().unwrap().folders.store())
            .create(&original)
            .unwrap();
        let WorkflowTypeRef::User { type_id, .. } = reference else {
            panic!("custom reference")
        };
        let mut edited = original.clone();
        edited.name = "Edited type".into();
        WorkflowCatalog::new(app.lock_inner().unwrap().folders.store())
            .edit(type_id, &edited)
            .unwrap();
        accepted(
            &app,
            Command::CreateWorkflow {
                folder: folder.path().to_owned(),
                session_id: None,
                kind: WorkflowKind::Draft,
                roles: vec![],
                size: SIZE,
            },
        );
        let id = app.snapshot().unwrap().workflows.workflows[0].workflow_id;
        accepted(
            &app,
            Command::StartWorkflowRun {
                workflow_id: id,
                workflow_type: reference,
                prompt: "Task".into(),
                roles: original
                    .roles
                    .iter()
                    .map(|role| RoleLaunch {
                        model: None,
                        effort: None,
                        yolo: false,
                        role: role.id.0.clone(),
                        harness: HarnessId::Pi,
                    })
                    .collect(),
                size: SIZE,
            },
        );
        let workflow = wait_for(&app, id, |w| w.status == WorkflowStatus::Completed);
        let run = workflow.run.unwrap();
        assert_eq!(run.reference(), reference);
        assert_eq!(run.workflow_type.definition, original);
    }

    /// Opt-in smoke test: uses an authenticated, installed Codex in a disposable folder. The wrapper
    /// selects its noninteractive mode so unattended verification doesn't need a trust-dialog click.
    #[test]
    #[ignore = "requires a real authenticated Codex; set TWINE_REAL_CODEX to its absolute path"]
    fn real_adversarial_workflow_completes() {
        let codex = std::env::var("TWINE_REAL_CODEX").expect("set TWINE_REAL_CODEX");
        let folder = tempfile::tempdir().unwrap();
        let bin = tempfile::tempdir().unwrap();
        let wrapper = bin.path().join("codex");
        let quoted = codex.replace('\'', "'\\''");
        std::fs::write(&wrapper, format!(
            "#!/bin/sh\nexec '{quoted}' exec --ephemeral --skip-git-repo-check --sandbox workspace-write --ignore-user-config \"$@\"\n"
        )).unwrap();
        std::fs::set_permissions(&wrapper, std::fs::Permissions::from_mode(0o755)).unwrap();
        let app = application(folder.path(), bin.path(), "exit 1");
        accepted(
            &app,
            Command::CreateWorkflow {
                folder: folder.path().to_owned(),
                session_id: None,
                kind: WorkflowKind::Draft,
                roles: vec![],
                size: SIZE,
            },
        );
        let id = app.snapshot().unwrap().workflows.workflows[0].workflow_id;
        accepted(&app, Command::StartWorkflowRun { workflow_id: id,
            workflow_type: WorkflowTypeRef::Builtin(BuiltinType::Adversarial),
            prompt: "This is a small smoke test. Implementer: create proof.txt containing exactly 'Twine workflow works' followed by a newline, then submit completion using the supplied command. Reviewer: read proof.txt, approve if correct, and submit the explicit review decision. Do not use git, install tools, or change anything else. Execute the completion command; do not merely describe it.".into(),
            roles: vec![RoleLaunch { role: "implementer".into(), harness: HarnessId::Codex, model: None, effort: None, yolo: false },
                        RoleLaunch { role: "reviewer".into(), harness: HarnessId::Codex, model: None, effort: None, yolo: false }], size: SIZE });
        let deadline = Instant::now() + Duration::from_secs(240);
        let mut terminal_output = Vec::new();
        loop {
            while let Some(chunk) = app.next_terminal_chunk().unwrap() {
                terminal_output.extend(chunk.bytes);
            }
            let snapshot = app.snapshot().unwrap();
            let workflow = &snapshot.workflows.workflows[0];
            if workflow.status == WorkflowStatus::Completed {
                break;
            }
            if Instant::now() >= deadline || workflow.status != WorkflowStatus::Running {
                let log = std::env::temp_dir().join("twine-real-adversarial-output.txt");
                std::fs::write(&log, terminal_output).unwrap();
                panic!("real run didn't complete; inspect {}", log.display());
            }
            thread::sleep(Duration::from_millis(50));
        }
        assert_eq!(
            std::fs::read_to_string(folder.path().join("proof.txt")).unwrap(),
            "Twine workflow works\n"
        );
    }
}
