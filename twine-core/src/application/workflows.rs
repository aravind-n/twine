use std::path::Path;

use super::{Application, ApplicationError, CommandDisposition, RequestId};
use crate::event::{CommandResult, EventKind, StateEvent};
use crate::folder::Folders;
use crate::terminal::{TerminalId, TerminalSize, TerminalStatus};
use crate::workflow::{
    SessionId, Workflow, WorkflowId, WorkflowKind, WorkflowState, WorkflowStatus, timestamp,
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

    pub(super) fn create_workflow(
        &self,
        request_id: RequestId,
        folder: &Path,
        session_id: Option<SessionId>,
        kind: WorkflowKind,
        size: TerminalSize,
    ) -> Result<CommandDisposition, ApplicationError> {
        if kind == WorkflowKind::SingleAgent {
            return Ok(reject(
                "invalidWorkflowKind",
                "Start an agent from a new workflow tab.",
            ));
        }
        let mut inner = self.lock_inner()?;
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
        let terminal_id = match self.start_terminal(folder, size) {
            Ok(id) => id,
            Err(error) => return Ok(super::rejection("terminalStartFailed", &error)),
        };
        let name = match kind {
            WorkflowKind::Draft => "New workflow",
            WorkflowKind::Terminal | WorkflowKind::SingleAgent => "Terminal",
        };
        let persisted = (|| -> Result<_, ApplicationError> {
            let session_id = match selected {
                Some(id) => id,
                None => inner.add_session(folder, "Session")?,
            };
            let workflow_id = inner
                .folders
                .store()
                .create_workflow(session_id, name, kind)?;
            Ok((session_id, workflow_id))
        })();
        let (session_id, workflow_id) = match persisted {
            Ok(ids) => ids,
            Err(error) => {
                drop(inner);
                let _ = self.terminals.close(terminal_id);
                return Err(error);
            }
        };
        inner.terminals.insert(terminal_id, TerminalStatus::Running);
        let workflow = Workflow {
            workflow_id,
            session_id,
            name: name.to_owned(),
            kind,
            harness: None,
            terminal_id,
            status: WorkflowStatus::Running,
            started_at: timestamp(),
            ended_at: None,
            restored: false,
        };
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
        if workflow.kind != WorkflowKind::Draft && workflow.kind != WorkflowKind::Terminal {
            return Ok(reject(
                "workflowNotDraft",
                "The workflow is already configured.",
            ));
        }
        inner.folders.store().update_workflow(
            workflow_id,
            "Terminal",
            WorkflowKind::Terminal,
            None,
        )?;
        workflow.kind = WorkflowKind::Terminal;
        "Terminal".clone_into(&mut workflow.name);
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
        let terminal_id = {
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
            inner.folders.store().delete_workflow(workflow_id)?;
            let mut workflow = inner.workflows.workflows.remove(index);
            workflow.status = WorkflowStatus::Closed;
            workflow
                .ended_at
                .get_or_insert(timestamp().max(workflow.started_at));
            inner.terminals.remove(&workflow.terminal_id);
            let terminal_id = workflow.terminal_id;
            inner
                .events
                .append(EventKind::State(StateEvent::WorkflowChanged(workflow)))?;
            terminal_id
        };
        if terminal_id.value() != 0 {
            self.terminals.close(terminal_id)?;
        }
        self.lock_inner()?
            .events
            .append(EventKind::CommandCompleted {
                request_id,
                result: CommandResult::WorkflowClosed { workflow_id },
            })?;
        Ok(CommandDisposition::Accepted)
    }

    /// Loads tabs from SQLite and gives each one a new shell. No terminal bytes or process IDs
    /// are persisted. Failed shell starts keep their tab so the user can see and close it.
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
        inner.workflows = WorkflowState {
            sessions_initialized,
            session,
            sessions,
            workflows: Vec::new(),
        };
        for stored in stored {
            if stored.kind == WorkflowKind::SingleAgent {
                // The agent's process and terminal are gone. Its work didn't finish.
                inner.workflows.workflows.push(Workflow {
                    workflow_id: stored.workflow_id,
                    session_id: stored.session_id,
                    name: stored.name,
                    kind: stored.kind,
                    harness: stored.harness,
                    terminal_id: TerminalId::from_value(0),
                    // Only an agent that was still running when Twine stopped was interrupted.
                    status: match stored.agent_status {
                        Some(status) if status != WorkflowStatus::Running => status,
                        _ => WorkflowStatus::Interrupted,
                    },
                    started_at: timestamp(),
                    ended_at: Some(timestamp()),
                    restored: true,
                });
                continue;
            }
            let (terminal_id, status) = match self.start_terminal(
                &folder,
                TerminalSize {
                    rows: 24,
                    columns: 80,
                    pixel_width: 800,
                    pixel_height: 480,
                },
            ) {
                Ok(id) => {
                    inner.terminals.insert(id, TerminalStatus::Running);
                    (id, WorkflowStatus::Running)
                }
                Err(error) => {
                    tracing::warn!(%error, "failed to restart a restored workflow shell");
                    (TerminalId::from_value(0), WorkflowStatus::Failed)
                }
            };
            inner.workflows.workflows.push(Workflow {
                workflow_id: stored.workflow_id,
                session_id: stored.session_id,
                name: stored.name,
                kind: stored.kind,
                harness: None,
                terminal_id,
                status,
                started_at: timestamp(),
                ended_at: (status == WorkflowStatus::Failed).then(timestamp),
                restored: true,
            });
        }
        inner.publish_workflows()?;
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

    fn create(application: &Application, folder: &Path, kind: WorkflowKind) -> Workflow {
        assert_eq!(
            application
                .handle_command(
                    RequestId(2),
                    Command::CreateWorkflow {
                        folder: folder.to_owned(),
                        session_id: None,
                        kind,
                        size: TerminalSize {
                            rows: 24,
                            columns: 80,
                            pixel_width: 800,
                            pixel_height: 480
                        },
                    }
                )
                .unwrap()
                .disposition,
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
}
