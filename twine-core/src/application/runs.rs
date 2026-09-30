use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;

use super::workflows::reject;
use super::{Application, ApplicationError, CommandDisposition};
use crate::event::{EventKind, StateEvent};
use crate::harness::{HarnessId, LocatedHarness};
use crate::terminal::{TerminalId, TerminalSize, TerminalStatus};
use crate::workflow::{
    Agent, AgentId, Workflow, WorkflowId, WorkflowKind, WorkflowStatus, timestamp,
};
use crate::workflow_run::completion::CompletionInbox;
use crate::workflow_run::{CompletionSignal, RoleLaunch, RunStatus, WorkflowRun};
use crate::workflow_type::{WorkflowCatalog, WorkflowType, WorkflowTypeRef};

pub(super) struct RunProcesses {
    folder: PathBuf,
    size: TerminalSize,
    harnesses: HashMap<HarnessId, LocatedHarness>,
    inboxes: HashMap<AgentId, (u64, CompletionInbox)>,
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
                },
            );
        self.launch_workflow_stage(workflow_id)?;
        Ok(CommandDisposition::Accepted)
    }

    fn prepare_workflow_stage(
        &self,
        run: &mut WorkflowRun,
    ) -> Vec<(crate::RunAgent, CompletionInbox, TerminalId)> {
        let active: Vec<_> = run.active_agents().into_iter().cloned().collect();
        // Reserve every transcript outside application state locks; storage can wait on disk.
        let mut prepared = Vec::new();
        for agent in active {
            let Ok(inbox) = CompletionInbox::new() else {
                run.finish(RunStatus::Failed, "Couldn't create the completion command.");
                break;
            };
            match self.terminals.reserve_terminal() {
                Ok(id) => prepared.push((agent, inbox, id)),
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

    fn launch_workflow_stage(&self, workflow_id: WorkflowId) -> Result<(), ApplicationError> {
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
        drop(inner);
        let run = workflow.run.as_mut().expect("execution has a run");
        run.trace("stageStarted", None, None, "Stage started");
        let prepared = self.prepare_workflow_stage(run);
        let mut inner = self.lock_inner()?;
        let mut replaced = Vec::new();
        let mut unused = Vec::new();
        for (agent, inbox, reserved) in prepared {
            if run.status != RunStatus::Running {
                unused.push(reserved);
                continue;
            }
            let prompt = run.instructions(agent.agent_id, &inbox.command());
            let located = &processes.harnesses[&agent.harness];
            match self.terminals.start_program(
                reserved,
                &processes.folder,
                &located.program,
                &agent.harness.definition().arguments(&prompt),
                &located.path,
                processes.size,
                Arc::new(self.exit_callback()),
            ) {
                Ok(terminal_id) => {
                    inner.terminals.insert(terminal_id, TerminalStatus::Running);
                    let tab = workflow
                        .agents
                        .iter_mut()
                        .find(|a| a.agent_id.0 == agent.agent_id)
                        .expect("agent tab exists");
                    if tab.terminal_id.value() != 0 {
                        replaced.push(tab.terminal_id);
                        inner.terminals.remove(&tab.terminal_id);
                    }
                    tab.terminal_id = terminal_id;
                    processes
                        .inboxes
                        .insert(AgentId(agent.agent_id), (run.generation, inbox));
                    run.trace(
                        "agentStarted",
                        Some(agent.agent_id),
                        None,
                        "Harness started",
                    );
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
        let saved = inner.publish_launch(index, &mut workflow);
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
        self.stop_run_terminals(&failed_terminals, "Workflow launch failed; agent stopped.");
        for id in unused {
            let _ = self.terminals.cancel_reserved_terminal(id);
        }
        self.terminals.close_all(&replaced)?;
        saved
    }

    pub(super) fn complete_workflow_role(
        &self,
        workflow_id: WorkflowId,
        agent_id: AgentId,
        generation: u64,
        signal: CompletionSignal,
    ) -> Result<CommandDisposition, ApplicationError> {
        let (advance, running, terminal_ids) = {
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
            let advance = match run.complete(agent_id.0, generation, signal) {
                Ok(advance) => advance,
                Err(error) => return Ok(super::rejection("invalidCompletion", &error)),
            };
            let running = run.status == RunStatus::Running;
            workflow.status = workflow_status(run.status);
            if !running {
                workflow.ended_at = Some(timestamp());
            }
            let terminals = if advance {
                workflow.terminal_ids()
            } else {
                workflow
                    .agents
                    .iter()
                    .filter(|a| a.agent_id == agent_id)
                    .map(|a| a.terminal_id)
                    .collect()
            };
            if let Err(error) = inner.publish_run(index, workflow) {
                return Ok(super::rejection("completionStoreFailed", &error));
            }
            (advance, running, terminals)
        };
        {
            let mut processes = self
                .run_processes
                .lock()
                .map_err(|_| ApplicationError::Poisoned)?;
            if let Some(processes) = processes.get_mut(&workflow_id) {
                if advance {
                    processes.inboxes.clear();
                } else {
                    processes.inboxes.remove(&agent_id);
                }
            }
        }
        self.stop_run_terminals(
            &terminal_ids,
            "Explicit workflow completion stopped the agent.",
        );
        if advance && running {
            self.launch_workflow_stage(workflow_id)?;
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
            if run.status != RunStatus::Running {
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
        Ok(())
    }

    pub(super) fn prune_run_processes(&self) -> Result<(), ApplicationError> {
        let inner = self.lock_inner()?;
        self.run_processes
            .lock()
            .map_err(|_| ApplicationError::Poisoned)?
            .retain(|id, _| {
                inner
                    .workflows
                    .workflows
                    .iter()
                    .any(|w| w.workflow_id == *id && w.status == WorkflowStatus::Running)
            });
        Ok(())
    }
}

impl super::Inner {
    fn publish_launch(
        &mut self,
        index: usize,
        workflow: &mut Workflow,
    ) -> Result<(), ApplicationError> {
        match self.publish_run(index, workflow.clone()) {
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
        let spans = self.folders.store().save_workflow_run(&workflow)?;
        self.trace_spans.extend(spans);
        self.publish_trace(workflow.workflow_id)?;
        self.record_run(index, workflow)
    }

    fn publish_run_best_effort(
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
        launch_with_size(app, folder, builtin, SIZE)
    }

    fn launch_with_size(
        app: &Application,
        folder: &Path,
        builtin: BuiltinType,
        run_size: TerminalSize,
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
                    role: r.id.0.clone(),
                    harness: HarnessId::Pi,
                })
            })
            .collect();
        accepted(
            app,
            Command::StartWorkflowRun {
                workflow_id: id,
                workflow_type: WorkflowTypeRef::Builtin(builtin),
                prompt: "Test the workflow".into(),
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
    prompt=$2
    command=$(printf '%s\n' "$prompt" | sed -n "s/^'\(.*\/complete\)' <<.*/\1/p")
    case "$prompt" in
      'You are Implementer '*) echo implement >> order; decision=done ;;
      'You are Reviewer '*) echo review >> order; decision=approve
          if [ -f request-changes ]; then decision=requestChanges; fi ;;
      'You are Coordinator in the Split '*)
          echo split >> order
          printf '%s' '{"decision":"done","assignments":[{"role":"worker","instance":1,"task":"First sub-task","files":["first.txt"]},{"role":"worker","instance":2,"task":"Second sub-task","files":["second.txt"]}]}' | "$command"
          exit ;;
      'You are Worker 1 '*) echo worker1 >> order; printf '%s' "$prompt" > worker1-prompt
          while [ ! -f worker2-prompt ]; do sleep 0.01; done; decision=done ;;
      'You are Worker 2 '*) echo worker2 >> order; printf '%s' "$prompt" > worker2-prompt
          while [ ! -f worker1-prompt ]; do sleep 0.01; done; decision=done ;;
      'You are Coordinator in the Gather '*) echo gather >> order; printf '%s' "$prompt" > gather-prompt; decision=done ;;
    esac
    printf '{"decision":"%s","summary":"Result or feedback"}' "$decision" | "$command"
    "#;

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

    fn assert_run_trace_history(app: &Application, workflow: &Workflow, invocations: u64) {
        let page = app.workflow_trace(workflow.workflow_id, None, 200).unwrap();
        assert_eq!(page.summary.span_count, invocations + 1); // plus the draft shell
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
            assert!(
                events
                    .iter()
                    .all(|event| event.message.starts_with(&span.title))
            );
        }
        let before = page.summary.revision;
        // Saving the same accepted state again never duplicates events or invocation spans.
        assert!(
            app.lock_inner()
                .unwrap()
                .folders
                .store()
                .save_workflow_run(workflow)
                .unwrap()
                .is_empty()
        );
        assert_eq!(
            app.workflow_trace(workflow.workflow_id, None, 200)
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
        assert_eq!(page.summary.span_count, 5);
        let handoffs = page
            .spans
            .iter()
            .flat_map(|span| app.trace_events(span.span_id, None, 200).unwrap().events)
            .filter(|event| event.message.contains("Handoff delivered"))
            .count();
        assert_eq!(handoffs, 4);
        accepted(&app, Command::CloseWorkflow { workflow_id: id });
        assert_eq!(
            app.workflow_trace(id, None, 200)
                .unwrap()
                .summary
                .span_count,
            5
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
        accepted(
            &app,
            Command::CompleteWorkflowRole {
                workflow_id: id,
                agent_id: first.agents[0].agent_id,
                generation: run.generation,
                signal: CompletionSignal {
                    decision: Decision::Done,
                    summary: "User result".into(),
                    assignments: vec![],
                },
            },
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
        assert!(workflow.terminal_ids().is_empty());
        assert_eq!(workflow.run.unwrap().status, RunStatus::Interrupted);
        let next = restored.terminals.reserve_terminal().unwrap();
        restored.terminals.cancel_reserved_terminal(next).unwrap();
        assert_eq!(next.value(), marker.value() + 1);
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
        );
        let workflow = wait_for(&app, id, |w| w.status == WorkflowStatus::Failed);
        assert!(workflow.terminal_ids().is_empty());
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
            1
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

    fn submit_helper(app: &Application, id: WorkflowId) {
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
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(br#"{"decision":"done","summary":"Finished"}"#)
            .unwrap();
        assert!(child.wait().unwrap().success());
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
        submit_helper(&app, id);
        let snapshot = app.snapshot().unwrap();
        assert_eq!(
            snapshot.workflows.workflows[0]
                .run
                .as_ref()
                .unwrap()
                .generation,
            1
        );
        assert!(
            !app.run_processes.lock().unwrap()[&id]
                .inboxes
                .values()
                .next()
                .unwrap()
                .1
                .response()
                .is_empty()
        );
        failure
            .execute_batch("DROP TRIGGER reject_run_update")
            .unwrap();
        submit_helper(&app, id);
        assert_eq!(
            app.snapshot().unwrap().workflows.workflows[0]
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
            "#!/bin/sh\nexec '{quoted}' exec --ephemeral --skip-git-repo-check --sandbox workspace-write --ignore-user-config -- \"$2\"\n"
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
            roles: vec![RoleLaunch { role: "implementer".into(), harness: HarnessId::Codex },
                        RoleLaunch { role: "reviewer".into(), harness: HarnessId::Codex }], size: SIZE });
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
