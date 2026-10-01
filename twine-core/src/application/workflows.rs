use std::path::Path;

use super::{Application, ApplicationError, CommandDisposition, RequestId};
use crate::event::{CommandResult, EventKind, StateEvent};
use crate::folder::Folders;
use crate::terminal::{TerminalId, TerminalSize, TerminalStatus};
use crate::workflow::{
    Agent, AgentId, MAX_AGENTS, SessionId, Workflow, WorkflowId, WorkflowKind, WorkflowState,
    WorkflowStatus, timestamp, valid_name,
};

impl Application {
    pub(super) fn name_draft_workflow(
        &self,
        workflow_id: WorkflowId,
        name: &str,
    ) -> Result<CommandDisposition, ApplicationError> {
        let name = name.trim();
        if name.is_empty() || name.chars().any(char::is_control) {
            return Ok(reject(
                "invalidWorkflowName",
                "A workflow needs a single-line name.",
            ));
        }
        let mut inner = self.lock_inner()?;
        let Some(index) = inner
            .workflows
            .workflows
            .iter()
            .position(|workflow| workflow.workflow_id == workflow_id)
        else {
            return Ok(reject(
                "workflowNotFound",
                "The workflow is no longer open.",
            ));
        };
        let mut workflow = inner.workflows.workflows[index].clone();
        if workflow.kind != WorkflowKind::Draft {
            return Ok(reject(
                "workflowNotDraft",
                "The workflow is already configured.",
            ));
        }
        if workflow.name != name {
            inner
                .folders
                .store()
                .update_workflow(workflow_id, name, workflow.kind, None)?;
            name.clone_into(&mut workflow.name);
            inner.workflows.workflows[index] = workflow.clone();
            inner
                .events
                .append(EventKind::State(StateEvent::WorkflowChanged(workflow)))?;
        }
        Ok(CommandDisposition::Accepted)
    }

    #[expect(
        clippy::too_many_lines,
        reason = "one lifetime command coordinates all role shells, persistence, and failure cleanup"
    )]
    pub(super) fn create_workflow(
        &self,
        request_id: RequestId,
        folder: &Path,
        session_id: Option<SessionId>,
        kind: WorkflowKind,
        roles: &[String],
        size: TerminalSize,
    ) -> Result<CommandDisposition, ApplicationError> {
        let roles = match agent_roles(kind, roles) {
            Ok(roles) => roles,
            Err(rejection) => return Ok(rejection),
        };
        let inner = self.lock_inner()?;
        if inner.folders.state().open_folder.as_deref() != Some(folder) {
            return Ok(reject(
                "folderChanged",
                "The workflow's folder is no longer open.",
            ));
        }
        let selected = inner
            .workflows
            .session
            .as_ref()
            .map(|session| session.session_id);
        if session_id.is_some() && session_id != selected {
            return Ok(reject(
                "sessionChanged",
                "Select the session again before opening a workflow.",
            ));
        }
        // Lifetime commands keep folder/selection validation valid while transcript allocation
        // waits without application state. Reserve every agent's stream before starting shells.
        drop(inner);
        let mut reserved = Vec::with_capacity(roles.len().max(1));
        for _ in 0..roles.len().max(1) {
            match self.terminals.reserve_terminal() {
                Ok(terminal_id) => reserved.push(terminal_id),
                Err(error) => {
                    for terminal_id in reserved {
                        let _ = self.terminals.cancel_reserved_terminal(terminal_id);
                    }
                    return Ok(super::rejection("terminalStartFailed", &error));
                }
            }
        }
        // Hold state throughout startup so creation is published before any shell's exit.
        let mut inner = self.lock_inner()?;
        let mut terminal_ids = Vec::with_capacity(reserved.len());
        for (index, &terminal_id) in reserved.iter().enumerate() {
            match self.start_terminal(
                terminal_id,
                folder,
                size,
                matches!(kind, WorkflowKind::Draft | WorkflowKind::Terminal),
            ) {
                Ok(terminal_id) => terminal_ids.push(terminal_id),
                Err(error) => {
                    drop(inner);
                    for &terminal_id in &reserved[index + 1..] {
                        let _ = self.terminals.cancel_reserved_terminal(terminal_id);
                    }
                    let _ = self.terminals.close_all(&terminal_ids);
                    return Ok(super::rejection("terminalStartFailed", &error));
                }
            }
        }
        let name = match kind {
            WorkflowKind::Draft => "New workflow",
            WorkflowKind::Terminal | WorkflowKind::SingleAgent => "Terminal",
            WorkflowKind::Agents => "Agents",
        };
        let persisted = (|| -> Result<_, ApplicationError> {
            let session_id = match selected {
                Some(id) => id,
                None => inner.add_session(folder, "Session")?,
            };
            let (workflow_id, agent_ids) = inner
                .folders
                .store()
                .create_workflow(session_id, name, kind, &roles)?;
            Ok((session_id, workflow_id, agent_ids))
        })();
        let (session_id, workflow_id, agent_ids) = match persisted {
            Ok(ids) => ids,
            Err(error) => {
                drop(inner);
                let _ = self.terminals.close_all(&terminal_ids);
                return Err(error);
            }
        };
        for &terminal_id in &terminal_ids {
            inner.terminals.insert(terminal_id, TerminalStatus::Running);
        }
        let (terminal_id, agents) = match kind {
            WorkflowKind::Draft | WorkflowKind::Terminal | WorkflowKind::SingleAgent => {
                (terminal_ids[0], Vec::new())
            }
            WorkflowKind::Agents => (
                TerminalId::from_value(0),
                agents(agent_ids, &roles, terminal_ids),
            ),
        };
        let workflow = Workflow {
            workflow_id,
            session_id,
            name: name.to_owned(),
            kind,
            harness: None,
            terminal_id,
            agents,
            status: WorkflowStatus::Running,
            started_at: timestamp(),
            ended_at: None,
            restored: false,
            terminal_history: Vec::new(),
            run: None,
        };
        if let Err(error) = inner.start_trace(&workflow) {
            let terminal_ids = inner.remove_workflow_terminals(&workflow);
            let store = inner.folders.store();
            let _ = store.close_workflow(workflow_id, timestamp());
            drop(inner);
            let _ = self.terminals.close_all(&terminal_ids);
            return Err(error);
        }
        inner.workflows.workflows.push(workflow.clone());
        inner
            .events
            .append(EventKind::State(StateEvent::WorkflowChanged(workflow)))?;
        inner.events.append(EventKind::CommandCompleted {
            request_id,
            result: CommandResult::WorkflowCreated { workflow_id },
        })?;
        Ok(CommandDisposition::Accepted)
    }

    pub(super) fn activate_workflow(
        &self,
        request_id: RequestId,
        workflow_id: WorkflowId,
    ) -> Result<CommandDisposition, ApplicationError> {
        let mut inner = self.lock_inner()?;
        let Some(index) = inner
            .workflows
            .workflows
            .iter()
            .position(|workflow| workflow.workflow_id == workflow_id)
        else {
            return Ok(reject(
                "workflowNotFound",
                "The workflow is no longer open.",
            ));
        };
        let mut workflow = inner.workflows.workflows[index].clone();
        match workflow.kind {
            WorkflowKind::Draft | WorkflowKind::Terminal => {}
            WorkflowKind::SingleAgent | WorkflowKind::Agents => {
                return Ok(reject(
                    "workflowNotDraft",
                    "The workflow is already configured.",
                ));
            }
        }
        inner.folders.store().update_workflow(
            workflow_id,
            "Terminal",
            WorkflowKind::Terminal,
            None,
        )?;
        let was_draft = workflow.kind == WorkflowKind::Draft;
        workflow.kind = WorkflowKind::Terminal;
        "Terminal".clone_into(&mut workflow.name);
        if was_draft
            && inner.terminals.get(&workflow.terminal_id) == Some(&TerminalStatus::Running)
            && let Err(error) = inner.start_trace(&workflow)
        {
            tracing::warn!(%error, "could not record the activated terminal's process trace");
        }
        inner.workflows.workflows[index] = workflow.clone();
        inner
            .events
            .append(EventKind::State(StateEvent::WorkflowChanged(workflow)))?;
        inner.events.append(EventKind::CommandCompleted {
            request_id,
            result: CommandResult::WorkflowActivated { workflow_id },
        })?;
        Ok(CommandDisposition::Accepted)
    }

    pub(super) fn close_workflow(
        &self,
        request_id: RequestId,
        workflow_id: WorkflowId,
    ) -> Result<CommandDisposition, ApplicationError> {
        let terminal_ids = {
            let mut inner = self.lock_inner()?;
            let Some(index) = inner
                .workflows
                .workflows
                .iter()
                .position(|workflow| workflow.workflow_id == workflow_id)
            else {
                return Ok(reject(
                    "workflowNotFound",
                    "The workflow is no longer open.",
                ));
            };
            let observations = inner.workflows.workflows[index]
                .terminal_ids()
                .into_iter()
                .map(|id| {
                    self.terminals
                        .observe(id)
                        .map(|observation| (id, observation))
                })
                .collect::<Result<Vec<_>, _>>()?;
            inner.close_workflow_trace(workflow_id, &observations)?;
            let mut workflow = inner.workflows.workflows.remove(index);
            workflow.status = WorkflowStatus::Closed;
            workflow
                .ended_at
                .get_or_insert(timestamp().max(workflow.started_at));
            let terminal_ids = workflow.terminal_ids();
            for terminal_id in &terminal_ids {
                inner.terminals.remove(terminal_id);
            }
            inner
                .events
                .append(EventKind::State(StateEvent::WorkflowChanged(workflow)))?;
            terminal_ids
        };
        self.terminals.close_all(&terminal_ids)?;
        self.lock_inner()?
            .events
            .append(EventKind::CommandCompleted {
                request_id,
                result: CommandResult::WorkflowClosed { workflow_id },
            })?;
        Ok(CommandDisposition::Accepted)
    }

    /// Loads tabs from SQLite and gives each one a new shell and terminal ID. Earlier transcripts
    /// remain independently readable until pruned. Failed starts keep their tab for inspection.
    #[expect(
        clippy::too_many_lines,
        reason = "restoration keeps workflow and agent metadata paired with their fresh terminals"
    )]
    pub(super) fn restore_workflows(&self) -> Result<(), ApplicationError> {
        let mut inner = self.lock_inner()?;
        let Some(folder) = inner.folders.state().open_folder.clone() else {
            return Ok(());
        };
        let sessions = inner.folders.store().sessions(&folder)?;
        let sessions_initialized = inner.folders.store().sessions_initialized(&folder)?;
        if !sessions_initialized {
            return Ok(());
        }
        let selected = inner.folders.store().selected_session(&folder)?;
        let session = sessions
            .iter()
            .find(|session| Some(session.session_id) == selected)
            .or_else(|| sessions.first())
            .cloned();
        let stored = inner.folders.store().workflows(&folder)?;
        drop(inner);
        let reserved: Vec<_> = stored
            .iter()
            .map(|workflow| {
                let shells = match workflow.kind {
                    WorkflowKind::Draft | WorkflowKind::Terminal => 1,
                    // Harness runs never restart; legacy multi-agent workflows restore shells.
                    WorkflowKind::SingleAgent => 0,
                    WorkflowKind::Agents if workflow.run.is_some() => 0,
                    WorkflowKind::Agents => workflow.agents.len(),
                };
                (0..shells)
                    .map(|_| {
                        self.terminals
                            .reserve_terminal()
                            .map_err(ApplicationError::from)
                    })
                    .collect::<Vec<_>>()
            })
            .collect();
        let mut inner = self.lock_inner()?;
        inner.workflows = WorkflowState {
            sessions_initialized,
            session,
            sessions,
            workflows: Vec::new(),
        };
        let mut failed_terminals = Vec::new();
        for (stored, reserved) in stored.into_iter().zip(reserved) {
            let terminal_history = inner.folders.store().terminal_history(stored.workflow_id)?;
            let mut reserved = reserved.into_iter();
            let mut restart = || match reserved
                .next()
                .expect("each restored shell has a transcript reservation")
                .and_then(|id| {
                    self.start_terminal(
                        id,
                        &folder,
                        TerminalSize {
                            rows: 24,
                            columns: 80,
                            pixel_width: 800,
                            pixel_height: 480,
                        },
                        matches!(stored.kind, WorkflowKind::Draft | WorkflowKind::Terminal),
                    )
                }) {
                Ok(id) => {
                    inner.terminals.insert(id, TerminalStatus::Running);
                    id
                }
                Err(error) => {
                    tracing::warn!(%error, "failed to restart a restored workflow shell");
                    TerminalId::from_value(0)
                }
            };
            // An agents workflow has no shell of its own; each of its agents gets a fresh one.
            let (terminal_id, agents) = match stored.kind {
                WorkflowKind::Draft | WorkflowKind::Terminal => (restart(), Vec::new()),
                // Keep the recorded terminal available without restarting the harness.
                WorkflowKind::SingleAgent => (
                    terminal_history
                        .last()
                        .map_or(TerminalId::from_value(0), |entry| entry.terminal_id),
                    Vec::new(),
                ),
                WorkflowKind::Agents => {
                    let agents: Vec<_> = stored
                        .agents
                        .into_iter()
                        .map(|agent| Agent {
                            agent_id: agent.agent_id,
                            role: agent.role,
                            terminal_id: if stored.run.is_some() {
                                terminal_history
                                    .iter()
                                    .rev()
                                    .find(|entry| entry.agent_id == Some(agent.agent_id))
                                    .map_or(TerminalId::from_value(0), |entry| entry.terminal_id)
                            } else {
                                restart()
                            },
                        })
                        .collect();
                    (TerminalId::from_value(0), agents)
                }
            };
            let mut workflow = Workflow {
                workflow_id: stored.workflow_id,
                session_id: stored.session_id,
                name: stored.name,
                kind: stored.kind,
                harness: stored.harness,
                terminal_id,
                agents,
                status: WorkflowStatus::Running,
                started_at: timestamp(),
                ended_at: None,
                restored: true,
                terminal_history,
                run: stored.run,
            };
            if workflow.run.is_some() {
                restore_run(&mut workflow, inner.folders.store())?;
            } else if workflow.kind == WorkflowKind::SingleAgent {
                // Only an agent that was still running when Twine stopped was interrupted.
                workflow.status = match stored.agent_status {
                    Some(status) if status != WorkflowStatus::Running => status,
                    _ => WorkflowStatus::Interrupted,
                };
                workflow.ended_at = Some(workflow.started_at);
            } else if workflow.terminal_ids().is_empty() {
                workflow.status = WorkflowStatus::Failed;
                workflow.ended_at = Some(workflow.started_at);
            }
            if workflow.run.is_none() && workflow.kind != WorkflowKind::SingleAgent {
                failed_terminals.extend(inner.record_restored_trace(&mut workflow));
            }
            inner.workflows.workflows.push(workflow);
        }
        let published = inner.publish_workflows();
        drop(inner);
        self.terminals.close_all(&failed_terminals)?;
        published?;
        Ok(())
    }

    pub(super) fn change_folder(
        &self,
        path: Option<&Path>,
    ) -> Result<CommandDisposition, ApplicationError> {
        let (disposition, terminal_ids) = {
            let mut inner = self.lock_inner()?;
            let previous = inner.folders.state().open_folder.clone();
            let disposition = inner.update_folders(|folders| match path {
                Some(path) => folders.open(path),
                None => Folders::close(folders),
            })?;
            if inner.folders.state().open_folder == previous {
                return Ok(disposition);
            }
            let terminal_ids = inner.terminals.keys().copied().collect::<Vec<_>>();
            for terminal_id in &terminal_ids {
                match self.terminals.observe(*terminal_id) {
                    Ok(observation) => {
                        if let Err(error) = inner.stop_trace(
                            *terminal_id,
                            observation,
                            "Process stopped when its folder was closed.",
                        ) {
                            tracing::warn!(%error, "failed to persist trace while closing folder; cleanup continues");
                        }
                    }
                    Err(error) => {
                        tracing::warn!(%error, "failed to observe terminal during folder cleanup");
                    }
                }
            }
            inner.terminals.clear();
            for terminal_id in &terminal_ids {
                inner
                    .events
                    .append(EventKind::State(StateEvent::TerminalClosed {
                        terminal_id: *terminal_id,
                    }))?;
            }
            // Closing a folder ends its processes, while sessions and tabs stay in SQLite.
            if inner.workflows != WorkflowState::default() {
                inner.workflows = WorkflowState::default();
                inner.publish_workflows()?;
            }
            (disposition, terminal_ids)
        };
        self.terminals.close_all(&terminal_ids)?;
        self.files.clear();
        self.restore_workflows()?;
        Ok(disposition)
    }
}

impl super::Inner {
    fn remove_workflow_terminals(&mut self, workflow: &Workflow) -> Vec<TerminalId> {
        let ids = workflow.terminal_ids();
        for id in &ids {
            self.terminals.remove(id);
        }
        ids
    }

    fn record_restored_trace(&mut self, workflow: &mut Workflow) -> Vec<TerminalId> {
        if workflow.terminal_ids().is_empty() {
            return Vec::new();
        }
        if let Err(error) = self.start_trace(workflow) {
            tracing::warn!(%error, "failed to record restored workflow starts; stopping its shells");
            let ids = self.remove_workflow_terminals(workflow);
            workflow.terminal_id = TerminalId::from_value(0);
            for agent in &mut workflow.agents {
                agent.terminal_id = TerminalId::from_value(0);
            }
            workflow.status = WorkflowStatus::Failed;
            workflow.ended_at = Some(timestamp().max(workflow.started_at));
            return ids;
        }
        Vec::new()
    }
}

fn restore_run(
    workflow: &mut Workflow,
    store: &mut crate::store::Store,
) -> Result<(), ApplicationError> {
    let mut interrupted = false;
    if let Some(run) = &mut workflow.run {
        // Startup has already recovered all folders. A folder closed and reopened within this
        // instance can still contain a stopped run that needs the same interruption outcome.
        if run.status == crate::RunStatus::Running {
            run.finish(
                crate::RunStatus::Interrupted,
                "Twine stopped while the workflow was running.",
            );
            interrupted = true;
        }
        workflow.status = super::runs::workflow_status(run.status);
        workflow.ended_at = Some(workflow.started_at);
    }
    if interrupted {
        store.save_workflow_run(workflow)?;
    }
    Ok(())
}

/// The trimmed roles, if a workflow of this kind can be created with them. Single agents start from
/// drafts instead, agents workflows need 1–[`MAX_AGENTS`] valid roles, and other kinds take none.
fn agent_roles(kind: WorkflowKind, roles: &[String]) -> Result<Vec<&str>, CommandDisposition> {
    if kind == WorkflowKind::SingleAgent {
        return Err(reject(
            "invalidWorkflowKind",
            "Start an agent from a new workflow tab.",
        ));
    }
    let roles: Vec<&str> = roles.iter().map(|role| role.trim()).collect();
    let valid = if kind == WorkflowKind::Agents {
        (1..=MAX_AGENTS).contains(&roles.len()) && roles.iter().all(|role| valid_name(role))
    } else {
        roles.is_empty()
    };
    if !valid {
        return Err(reject(
            "invalidAgents",
            &format!(
                "An agents workflow needs 1–{MAX_AGENTS} roles of 1–200 characters on one line, \
                 and other workflows take none."
            ),
        ));
    }
    Ok(roles)
}

fn agents(agent_ids: Vec<AgentId>, roles: &[&str], terminal_ids: Vec<TerminalId>) -> Vec<Agent> {
    agent_ids
        .into_iter()
        .zip(roles)
        .zip(terminal_ids)
        .map(|((agent_id, role), terminal_id)| Agent {
            agent_id,
            role: (*role).to_owned(),
            terminal_id,
        })
        .collect()
}

pub(super) fn reject(code: &str, message: &str) -> CommandDisposition {
    CommandDisposition::Rejected {
        code: code.to_owned(),
        message: message.to_owned(),
    }
}

#[cfg(test)]
mod tests {
    use std::sync::{Arc, Barrier};
    use std::thread;
    use std::time::{Duration, Instant};

    use super::*;
    use crate::{Command, TerminalExit, TerminalId, WorkflowState};

    fn application(folder: &Path) -> Application {
        let application = Application::with_event_capacity(4096).unwrap();
        assert_eq!(
            application
                .handle_command(
                    RequestId(1),
                    Command::OpenFolder {
                        path: folder.to_owned()
                    }
                )
                .unwrap()
                .disposition,
            CommandDisposition::Accepted
        );
        application
    }

    fn request(
        application: &Application,
        folder: &Path,
        kind: WorkflowKind,
        roles: &[&str],
    ) -> CommandDisposition {
        application
            .handle_command(
                RequestId(2),
                Command::CreateWorkflow {
                    folder: folder.to_owned(),
                    session_id: None,
                    kind,
                    roles: roles.iter().map(|role| (*role).to_owned()).collect(),
                    size: TerminalSize {
                        rows: 24,
                        columns: 80,
                        pixel_width: 800,
                        pixel_height: 480,
                    },
                },
            )
            .unwrap()
            .disposition
    }

    fn create(application: &Application, folder: &Path, kind: WorkflowKind) -> Workflow {
        create_with_roles(application, folder, kind, &[])
    }

    #[test]
    fn a_draft_has_no_activity_and_activating_an_exited_shell_cannot_start_a_span() {
        let folder = tempfile::tempdir().unwrap();
        let mut app = application(folder.path());
        app.terminals.set_test_shell("/bin/sh".into());
        let draft = create(&app, folder.path(), WorkflowKind::Draft);
        let trace = app.workflow_trace(draft.workflow_id, None, 10).unwrap();
        assert!(trace.spans.is_empty() && trace.lanes.is_empty());
        app.write_terminal_input(draft.terminal_id, b"exit\n")
            .unwrap();
        wait_until(|| {
            app.snapshot().unwrap().workflows.workflows[0].status == WorkflowStatus::Exited
        });
        assert_eq!(
            app.handle_command(
                RequestId(4),
                Command::ActivateWorkflow {
                    workflow_id: draft.workflow_id
                }
            )
            .unwrap()
            .disposition,
            CommandDisposition::Accepted
        );
        let trace = app.workflow_trace(draft.workflow_id, None, 10).unwrap();
        assert!(trace.spans.is_empty() && trace.lanes.is_empty());
    }

    fn create_with_roles(
        application: &Application,
        folder: &Path,
        kind: WorkflowKind,
        roles: &[&str],
    ) -> Workflow {
        assert_eq!(
            request(application, folder, kind, roles),
            CommandDisposition::Accepted
        );
        application
            .snapshot()
            .unwrap()
            .workflows
            .workflows
            .last()
            .unwrap()
            .clone()
    }

    fn roles(workflow: &Workflow) -> Vec<&str> {
        workflow
            .agents
            .iter()
            .map(|agent| agent.role.as_str())
            .collect()
    }

    fn read_when_written(path: &Path) -> String {
        let mut contents = String::new();
        wait_until(|| {
            contents = std::fs::read_to_string(path).unwrap_or_default();
            contents.ends_with('\n')
        });
        contents
    }

    fn process_exists(pid: &str) -> bool {
        std::process::Command::new("kill")
            .args(["-0", pid])
            .stderr(std::process::Stdio::null())
            .status()
            .unwrap()
            .success()
    }

    fn wait_until(mut condition: impl FnMut() -> bool) {
        let deadline = Instant::now() + Duration::from_secs(5);
        while !condition() {
            assert!(Instant::now() < deadline, "workflow condition timed out");
            thread::sleep(Duration::from_millis(10));
        }
    }

    fn write(application: &Application, terminal_id: TerminalId, input: &str) {
        application
            .write_terminal_input(terminal_id, input.as_bytes())
            .unwrap();
    }

    #[test]
    fn draft_activation_preserves_shell_identity_state_and_timing() {
        let folder = tempfile::tempdir().unwrap();
        let application = application(folder.path());
        let draft = create(&application, folder.path(), WorkflowKind::Draft);
        write(&application, draft.terminal_id, "exec /bin/sh\n");
        write(
            &application,
            draft.terminal_id,
            "TWINE_MARKER=preserved; echo $$ > before.pid\n",
        );
        wait_until(|| folder.path().join("before.pid").exists());
        assert_eq!(
            application
                .handle_command(
                    RequestId(3),
                    Command::ActivateWorkflow {
                        workflow_id: draft.workflow_id
                    }
                )
                .unwrap()
                .disposition,
            CommandDisposition::Accepted
        );
        let activated = application.snapshot().unwrap().workflows.workflows[0].clone();
        assert_eq!(activated.terminal_id, draft.terminal_id);
        assert_eq!(activated.workflow_id, draft.workflow_id);
        assert_eq!(activated.session_id, draft.session_id);
        assert_eq!(activated.started_at, draft.started_at);
        assert_eq!(activated.kind, WorkflowKind::Terminal);
        assert_eq!(activated.name, "Terminal");
        write(
            &application,
            activated.terminal_id,
            "{ echo $$; echo $TWINE_MARKER; } > after.txt\n",
        );
        wait_until(|| {
            std::fs::read_to_string(folder.path().join("after.txt"))
                .is_ok_and(|text| text.contains("preserved"))
        });
        let before = std::fs::read_to_string(folder.path().join("before.pid")).unwrap();
        let after = std::fs::read_to_string(folder.path().join("after.txt")).unwrap();
        assert_eq!(after.lines().next(), Some(before.trim()));
    }

    #[test]
    fn naming_an_unavailable_choice_keeps_the_draft_shell_and_activation_wins() {
        let folder = tempfile::tempdir().unwrap();
        let application = application(folder.path());
        let draft = create(&application, folder.path(), WorkflowKind::Draft);
        let receipt = application
            .handle_command(
                RequestId(3),
                Command::NameDraftWorkflow {
                    workflow_id: draft.workflow_id,
                    name: "Single agent".to_owned(),
                },
            )
            .unwrap();
        assert_eq!(receipt.disposition, CommandDisposition::Accepted);
        let named = application.snapshot().unwrap().workflows.workflows[0].clone();
        assert_eq!(named.name, "Single agent");
        assert_eq!(named.kind, WorkflowKind::Draft);
        assert_eq!(named.terminal_id, draft.terminal_id);
        assert_eq!(named.started_at, draft.started_at);
        application
            .handle_command(
                RequestId(4),
                Command::ActivateWorkflow {
                    workflow_id: draft.workflow_id,
                },
            )
            .unwrap();
        let receipt = application
            .handle_command(
                RequestId(5),
                Command::NameDraftWorkflow {
                    workflow_id: draft.workflow_id,
                    name: "Coordinator".to_owned(),
                },
            )
            .unwrap();
        assert!(
            matches!(receipt.disposition, CommandDisposition::Rejected { ref code, .. } if code == "workflowNotDraft")
        );
        let activated = application.snapshot().unwrap().workflows.workflows[0].clone();
        assert_eq!(activated.name, "Terminal");
        assert_eq!(activated.terminal_id, draft.terminal_id);
    }

    #[test]
    fn closing_one_workflow_keeps_the_other_shell_and_publishes_its_end() {
        let folder = tempfile::tempdir().unwrap();
        let application = application(folder.path());
        let first = create(&application, folder.path(), WorkflowKind::Terminal);
        let second = create(&application, folder.path(), WorkflowKind::Terminal);
        assert_ne!(first.workflow_id, second.workflow_id);
        assert_ne!(first.terminal_id, second.terminal_id);
        assert_eq!(first.session_id, second.session_id);
        let sequence = application.snapshot().unwrap().sequence;
        assert_eq!(
            application
                .handle_command(
                    RequestId(3),
                    Command::CloseWorkflow {
                        workflow_id: first.workflow_id
                    }
                )
                .unwrap()
                .disposition,
            CommandDisposition::Accepted
        );
        let snapshot = application.snapshot().unwrap();
        assert_eq!(snapshot.workflows.workflows, vec![second.clone()]);
        assert_eq!(snapshot.terminals.len(), 1);
        assert!(
            application
                .write_terminal_input(first.terminal_id, b"echo closed\n")
                .is_err()
        );
        write(&application, second.terminal_id, "touch still-live\n");
        wait_until(|| folder.path().join("still-live").exists());
        let events = application.events_after(sequence, 32).unwrap();
        let closed = events
            .iter()
            .find_map(|event| match &event.kind {
                EventKind::State(StateEvent::WorkflowChanged(workflow))
                    if workflow.status == WorkflowStatus::Closed =>
                {
                    Some(workflow)
                }
                _ => None,
            })
            .unwrap();
        assert!(closed.ended_at.unwrap() >= closed.started_at);
        // A supervisor already queued at close must not resurrect its state or append an event.
        let mut inner = application.lock_inner().unwrap();
        let sequence = inner.events.latest_sequence();
        inner.record_terminal_exit(
            first.terminal_id,
            Ok(TerminalExit {
                exit_code: 0,
                signal: None,
            }),
        );
        assert_eq!(inner.events.latest_sequence(), sequence);
        assert!(!inner.terminals.contains_key(&first.terminal_id));
    }

    #[test]
    fn shell_exit_is_exited_and_never_workflow_success() {
        let folder = tempfile::tempdir().unwrap();
        let application = application(folder.path());
        let workflow = create(&application, folder.path(), WorkflowKind::Draft);
        write(&application, workflow.terminal_id, "exit 7\n");
        wait_until(|| {
            application.snapshot().unwrap().workflows.workflows[0].status == WorkflowStatus::Exited
        });
        let ended = application.snapshot().unwrap().workflows.workflows[0].clone();
        assert!(ended.ended_at.unwrap() >= ended.started_at);
        application
            .handle_command(
                RequestId(3),
                Command::ActivateWorkflow {
                    workflow_id: ended.workflow_id,
                },
            )
            .unwrap();
        let activated = application.snapshot().unwrap().workflows.workflows[0].clone();
        assert_eq!(activated.status, WorkflowStatus::Exited);
        assert_eq!(activated.ended_at, ended.ended_at);
        assert_eq!(activated.terminal_id, ended.terminal_id);
    }

    #[test]
    fn folder_replacement_and_close_clean_up_all_terminals_and_end_the_session() {
        let first_folder = tempfile::tempdir().unwrap();
        let second_folder = tempfile::tempdir().unwrap();
        let application = application(first_folder.path());
        let first = create(&application, first_folder.path(), WorkflowKind::Terminal);
        let second = create(&application, first_folder.path(), WorkflowKind::Terminal);
        let sequence = application.snapshot().unwrap().sequence;
        application
            .handle_command(
                RequestId(3),
                Command::OpenFolder {
                    path: second_folder.path().to_owned(),
                },
            )
            .unwrap();
        let snapshot = application.snapshot().unwrap();
        assert_eq!(snapshot.workflows, WorkflowState::default());
        assert!(snapshot.terminals.is_empty());
        for id in [first.terminal_id, second.terminal_id] {
            assert!(
                application
                    .write_terminal_input(id, b"touch stale\n")
                    .is_err()
            );
        }
        let events = application.events_after(sequence, 32).unwrap();
        assert!(events.iter().any(|event| matches!(&event.kind, EventKind::State(StateEvent::WorkflowsChanged(state)) if state == &WorkflowState::default())));
        let third = create(&application, second_folder.path(), WorkflowKind::Terminal);
        assert!(third.workflow_id.0 > second.workflow_id.0);
        assert_ne!(third.session_id, second.session_id);
        application
            .handle_command(RequestId(4), Command::CloseFolder)
            .unwrap();
        assert_eq!(
            application.snapshot().unwrap().workflows,
            WorkflowState::default()
        );
        assert!(
            application
                .write_terminal_input(third.terminal_id, b"touch stale\n")
                .is_err()
        );
    }

    #[test]
    fn racing_start_with_folder_close_cannot_leave_a_shell_owned_by_a_closed_folder() {
        let folder = tempfile::tempdir().unwrap();
        for _ in 0..6 {
            let application = Arc::new(application(folder.path()));
            let barrier = Barrier::new(2);
            thread::scope(|scope| {
                scope.spawn(|| {
                    barrier.wait();
                    application
                        .handle_command(
                            RequestId(2),
                            Command::CreateWorkflow {
                                folder: folder.path().to_owned(),
                                session_id: None,
                                kind: WorkflowKind::Terminal,
                                roles: Vec::new(),
                                size: TerminalSize {
                                    rows: 24,
                                    columns: 80,
                                    pixel_width: 800,
                                    pixel_height: 480,
                                },
                            },
                        )
                        .unwrap();
                });
                barrier.wait();
                application
                    .handle_command(RequestId(3), Command::CloseFolder)
                    .unwrap();
            });
            let snapshot = application.snapshot().unwrap();
            assert_eq!(snapshot.workflows, WorkflowState::default());
            assert!(snapshot.terminals.is_empty());
            assert!(snapshot.folders.open_folder.is_none());
        }
    }

    #[test]
    fn snapshot_and_following_workflow_events_reconstruct_identical_state() {
        let folder = tempfile::tempdir().unwrap();
        let application = application(folder.path());
        let snapshot = application.snapshot().unwrap();
        let first = create(&application, folder.path(), WorkflowKind::Draft);
        create(&application, folder.path(), WorkflowKind::Terminal);
        application
            .handle_command(
                RequestId(3),
                Command::ActivateWorkflow {
                    workflow_id: first.workflow_id,
                },
            )
            .unwrap();
        application
            .handle_command(
                RequestId(4),
                Command::CloseWorkflow {
                    workflow_id: first.workflow_id,
                },
            )
            .unwrap();
        let agents = create_with_roles(
            &application,
            folder.path(),
            WorkflowKind::Agents,
            &["Implementer", "Reviewer"],
        );
        for terminal_id in agents.terminal_ids() {
            write(&application, terminal_id, "exit\n");
        }
        wait_until(|| {
            application.snapshot().unwrap().workflows.workflows[1].status == WorkflowStatus::Exited
        });
        let mut state = snapshot.workflows;
        let events = application.events_after(snapshot.sequence, 128).unwrap();
        for (index, event) in events.iter().enumerate() {
            assert_eq!(
                event.sequence,
                snapshot.sequence + u64::try_from(index).unwrap() + 1
            );
            match &event.kind {
                EventKind::State(StateEvent::WorkflowsChanged(changed)) => {
                    state = changed.clone();
                }
                EventKind::State(StateEvent::WorkflowChanged(workflow)) => {
                    state
                        .workflows
                        .retain(|existing| existing.workflow_id != workflow.workflow_id);
                    if workflow.status != WorkflowStatus::Closed {
                        state.workflows.push(workflow.clone());
                    }
                }
                _ => {}
            }
        }
        assert_eq!(state, application.snapshot().unwrap().workflows);
    }

    #[test]
    fn an_owned_terminal_cannot_be_closed_outside_its_workflow() {
        let folder = tempfile::tempdir().unwrap();
        let application = application(folder.path());
        let workflow = create(&application, folder.path(), WorkflowKind::Terminal);
        let receipt = application
            .handle_command(
                RequestId(3),
                Command::CloseTerminal {
                    terminal_id: workflow.terminal_id,
                },
            )
            .unwrap();
        assert!(
            matches!(receipt.disposition, CommandDisposition::Rejected { ref code, .. } if code == "terminalOwnedByWorkflow")
        );
        assert_eq!(
            application.snapshot().unwrap().workflows.workflows,
            vec![workflow]
        );
    }

    #[test]
    fn an_old_window_close_does_not_close_the_replacement_folder() {
        let old_folder = tempfile::tempdir().unwrap();
        let new_folder = tempfile::tempdir().unwrap();
        let application = application(old_folder.path());
        create(&application, old_folder.path(), WorkflowKind::Terminal);
        application
            .handle_command(
                RequestId(3),
                Command::OpenFolder {
                    path: new_folder.path().to_owned(),
                },
            )
            .unwrap();
        let replacement = create(&application, new_folder.path(), WorkflowKind::Terminal);
        application
            .handle_command(
                RequestId(4),
                Command::CloseFolderIfOpen {
                    path: old_folder.path().to_owned(),
                },
            )
            .unwrap();
        assert_eq!(
            application.snapshot().unwrap().workflows.workflows,
            vec![replacement]
        );
        application
            .handle_command(
                RequestId(5),
                Command::CloseFolderIfOpen {
                    path: new_folder.path().to_owned(),
                },
            )
            .unwrap();
        assert!(application.snapshot().unwrap().terminals.is_empty());
    }

    #[test]
    fn folder_cleanup_also_publishes_standalone_terminal_closure() {
        let folder = tempfile::tempdir().unwrap();
        let application = application(folder.path());
        application
            .handle_command(
                RequestId(2),
                Command::StartTerminal {
                    working_directory: folder.path().to_owned(),
                    size: TerminalSize {
                        rows: 24,
                        columns: 80,
                        pixel_width: 800,
                        pixel_height: 480,
                    },
                },
            )
            .unwrap();
        let snapshot = application.snapshot().unwrap();
        let id = snapshot.terminals[0].terminal_id;
        application
            .handle_command(RequestId(3), Command::CloseFolder)
            .unwrap();
        assert!(application.snapshot().unwrap().terminals.is_empty());
        assert!(
            application
                .events_after(snapshot.sequence, 32)
                .unwrap()
                .iter()
                .any(|event| event.kind
                    == EventKind::State(StateEvent::TerminalClosed { terminal_id: id }))
        );
    }

    #[cfg(unix)]
    #[test]
    fn immediately_exiting_workflow_publishes_creation_before_exit() {
        use std::os::unix::fs::PermissionsExt;

        let folder = tempfile::tempdir().unwrap();
        let shell = folder.path().join("exit-immediately");
        std::fs::write(&shell, "#!/bin/sh\nexit 7\n").unwrap();
        std::fs::set_permissions(&shell, std::fs::Permissions::from_mode(0o700)).unwrap();
        let mut application = application(folder.path());
        application.terminals.set_test_shell(shell);
        let sequence = application.snapshot().unwrap().sequence;
        let workflow = create(&application, folder.path(), WorkflowKind::Terminal);
        wait_until(|| {
            application.snapshot().unwrap().workflows.workflows[0].status == WorkflowStatus::Exited
        });
        let events = application.events_after(sequence, 32).unwrap();
        let created = events
            .iter()
            .position(|event| {
                matches!(
                    event.kind,
                    EventKind::CommandCompleted {
                        result: CommandResult::WorkflowCreated { .. },
                        ..
                    }
                )
            })
            .unwrap();
        let exited = events.iter().position(|event| matches!(event.kind, EventKind::State(StateEvent::TerminalExited { terminal_id, .. }) if terminal_id == workflow.terminal_id)).unwrap();
        assert!(created < exited);
        application
            .handle_command(
                RequestId(3),
                Command::CloseWorkflow {
                    workflow_id: workflow.workflow_id,
                },
            )
            .unwrap();
        assert!(application.snapshot().unwrap().terminals.is_empty());
    }

    #[test]
    fn agents_run_their_own_shells_and_closing_the_workflow_stops_every_one() {
        let folder = tempfile::tempdir().unwrap();
        let application = application(folder.path());
        let workflow = create_with_roles(
            &application,
            folder.path(),
            WorkflowKind::Agents,
            &["Implementer", " Reviewer ", "Coordinator"],
        );
        assert_eq!(workflow.name, "Agents");
        assert_eq!(roles(&workflow), ["Implementer", "Reviewer", "Coordinator"]);
        assert_eq!(workflow.terminal_id, TerminalId::from_value(0));
        let terminal_ids = workflow.terminal_ids();
        assert_eq!(terminal_ids.len(), 3);
        let snapshot = application.snapshot().unwrap();
        assert_eq!(
            snapshot
                .terminals
                .iter()
                .map(|terminal| (terminal.terminal_id, terminal.status.clone()))
                .collect::<Vec<_>>(),
            terminal_ids
                .iter()
                .map(|terminal_id| (*terminal_id, TerminalStatus::Running))
                .collect::<Vec<_>>()
        );
        for (index, terminal_id) in terminal_ids.iter().enumerate() {
            write(
                &application,
                *terminal_id,
                &format!("echo $$ > {index}.pid\n"),
            );
        }
        let pids: Vec<_> = (0..terminal_ids.len())
            .map(|index| read_when_written(&folder.path().join(format!("{index}.pid"))))
            .collect();
        assert_ne!(pids[0], pids[1]);
        assert_ne!(pids[1], pids[2]);
        assert_ne!(pids[0], pids[2]);

        let sequence = application.snapshot().unwrap().sequence;
        assert_eq!(
            application
                .handle_command(
                    RequestId(3),
                    Command::CloseWorkflow {
                        workflow_id: workflow.workflow_id,
                    },
                )
                .unwrap()
                .disposition,
            CommandDisposition::Accepted
        );
        let snapshot = application.snapshot().unwrap();
        assert!(snapshot.workflows.workflows.is_empty());
        assert!(snapshot.terminals.is_empty());
        for terminal_id in terminal_ids {
            assert!(
                application
                    .write_terminal_input(terminal_id, b"\n")
                    .is_err()
            );
        }
        for pid in &pids {
            wait_until(|| !process_exists(pid.trim()));
        }
        let closed = application
            .events_after(sequence, 32)
            .unwrap()
            .into_iter()
            .find_map(|event| match event.kind {
                EventKind::State(StateEvent::WorkflowChanged(workflow)) => Some(workflow),
                _ => None,
            })
            .unwrap();
        assert_eq!(closed.status, WorkflowStatus::Closed);
        assert_eq!(closed.agents, workflow.agents);
    }

    #[test]
    fn invalid_roles_are_rejected_before_any_shell_starts() {
        let folder = tempfile::tempdir().unwrap();
        let application = application(folder.path());
        let before = application.snapshot().unwrap();
        let long = "a".repeat(201);
        let nine = ["Worker"; MAX_AGENTS + 1];
        let cases: [(WorkflowKind, &[&str]); 7] = [
            (WorkflowKind::Agents, &[]),
            (WorkflowKind::Agents, &nine),
            (WorkflowKind::Agents, &["Implementer", "  "]),
            (WorkflowKind::Agents, &["two\nlines"]),
            (WorkflowKind::Agents, &[long.as_str()]),
            (WorkflowKind::Terminal, &["Implementer"]),
            (WorkflowKind::Draft, &["Implementer"]),
        ];
        for (kind, roles) in cases {
            assert!(
                matches!(
                    request(&application, folder.path(), kind, roles),
                    CommandDisposition::Rejected { ref code, .. } if code == "invalidAgents"
                ),
                "{kind:?} with {roles:?} should be rejected"
            );
        }
        assert_eq!(application.snapshot().unwrap(), before);

        let most = create_with_roles(
            &application,
            folder.path(),
            WorkflowKind::Agents,
            &["Worker"; MAX_AGENTS],
        );
        assert_eq!(most.terminal_ids().len(), MAX_AGENTS);
        let one = create_with_roles(
            &application,
            folder.path(),
            WorkflowKind::Agents,
            &[&"a".repeat(200)],
        );
        assert_eq!(one.agents.len(), 1);
    }

    #[test]
    fn an_agents_workflow_ends_when_its_last_agent_exits_and_not_before() {
        let folder = tempfile::tempdir().unwrap();
        let application = application(folder.path());
        let workflow = create_with_roles(
            &application,
            folder.path(),
            WorkflowKind::Agents,
            &["Implementer", "Reviewer"],
        );
        let [first, second] = [
            workflow.agents[0].terminal_id,
            workflow.agents[1].terminal_id,
        ];
        let sequence = application.snapshot().unwrap().sequence;
        write(&application, first, "exit 3\n");
        wait_until(|| {
            application
                .snapshot()
                .unwrap()
                .terminals
                .iter()
                .any(|terminal| {
                    terminal.terminal_id == first
                        && matches!(terminal.status, TerminalStatus::Exited(_))
                })
        });
        let running = application.snapshot().unwrap().workflows.workflows[0].clone();
        assert_eq!(running.status, WorkflowStatus::Running);
        assert_eq!(running.ended_at, None);

        write(&application, second, "exit 4\n");
        wait_until(|| {
            application.snapshot().unwrap().workflows.workflows[0].status == WorkflowStatus::Exited
        });
        let ended = application.snapshot().unwrap().workflows.workflows[0].clone();
        assert!(ended.ended_at.unwrap() >= ended.started_at);
        let events = application.events_after(sequence, 32).unwrap();
        let exits = |terminal_id| {
            events.iter().position(|event| {
                matches!(event.kind, EventKind::State(StateEvent::TerminalExited { terminal_id: id, .. }) if id == terminal_id)
            })
        };
        let workflow_changes: Vec<_> = events
            .iter()
            .enumerate()
            .filter(|(_, event)| {
                matches!(event.kind, EventKind::State(StateEvent::WorkflowChanged(_)))
            })
            .map(|(index, _)| index)
            .collect();
        assert_eq!(workflow_changes.len(), 1, "{events:?}");
        assert!(exits(first).unwrap() < workflow_changes[0]);
        assert!(workflow_changes[0] < exits(second).unwrap());
    }

    #[test]
    fn an_agents_workflow_is_not_a_draft_and_owns_its_agents_terminals() {
        let folder = tempfile::tempdir().unwrap();
        let application = application(folder.path());
        let workflow = create_with_roles(
            &application,
            folder.path(),
            WorkflowKind::Agents,
            &["Implementer", "Reviewer"],
        );
        for command in [
            Command::ActivateWorkflow {
                workflow_id: workflow.workflow_id,
            },
            Command::NameDraftWorkflow {
                workflow_id: workflow.workflow_id,
                name: "Terminal".to_owned(),
            },
        ] {
            assert!(matches!(
                application.handle_command(RequestId(3), command).unwrap().disposition,
                CommandDisposition::Rejected { ref code, .. } if code == "workflowNotDraft"
            ));
        }
        let receipt = application
            .handle_command(
                RequestId(4),
                Command::CloseTerminal {
                    terminal_id: workflow.agents[1].terminal_id,
                },
            )
            .unwrap();
        assert!(
            matches!(receipt.disposition, CommandDisposition::Rejected { ref code, .. } if code == "terminalOwnedByWorkflow")
        );
        assert_eq!(
            application.snapshot().unwrap().workflows.workflows,
            vec![workflow.clone()]
        );
        write(
            &application,
            workflow.agents[1].terminal_id,
            "touch alive\n",
        );
        wait_until(|| folder.path().join("alive").exists());
    }

    #[test]
    fn a_shell_that_fails_to_start_stops_the_agents_started_before_it() {
        let folder = tempfile::tempdir().unwrap();
        let application = application(folder.path());
        let before = application.snapshot().unwrap();
        application.terminals.fail_starts_after(2);
        assert!(matches!(
            request(
                &application,
                folder.path(),
                WorkflowKind::Agents,
                &["Implementer", "Reviewer", "Coordinator", "Observer"],
            ),
            CommandDisposition::Rejected { ref code, .. } if code == "terminalStartFailed"
        ));
        assert_eq!(application.snapshot().unwrap(), before);
        assert!(
            application.terminal_output.tracks_no_terminals(),
            "started shells and unused reservations must all be released"
        );
        // The two shells that started were stopped rather than left running without a workflow.
        for terminal_id in 1..=2 {
            assert!(
                application
                    .write_terminal_input(TerminalId::from_value(terminal_id), b"\n")
                    .is_err()
            );
        }
        application.terminals.fail_starts_after(usize::MAX);
        let workflow = create(&application, folder.path(), WorkflowKind::Terminal);
        assert_eq!(workflow.workflow_id, WorkflowId(1), "nothing was stored");
    }
}
