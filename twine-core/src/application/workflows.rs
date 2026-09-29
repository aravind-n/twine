use std::path::Path;

use super::{Application, ApplicationError, CommandDisposition, RequestId};
use crate::event::{CommandResult, EventKind, StateEvent};
use crate::folder::Folders;
use crate::terminal::{TerminalSize, TerminalStatus};
use crate::workflow::{
    Session, SessionId, SessionStatus, Workflow, WorkflowId, WorkflowKind, WorkflowStatus,
    timestamp,
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
        let Some(workflow) = inner
            .workflows
            .workflows
            .iter_mut()
            .find(|workflow| workflow.workflow_id == workflow_id)
        else {
            return Ok(reject(
                "workflowNotFound",
                "The workflow is no longer open.",
            ));
        };
        if workflow.kind != WorkflowKind::Draft {
            return Ok(reject(
                "workflowNotDraft",
                "The workflow is already configured.",
            ));
        }
        if workflow.name != name {
            name.clone_into(&mut workflow.name);
            let workflow = workflow.clone();
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
        kind: WorkflowKind,
        size: TerminalSize,
    ) -> Result<CommandDisposition, ApplicationError> {
        let mut inner = self.lock_inner()?;
        // A view whose folder has closed while awaiting startup must not create a shell elsewhere.
        if inner.folders.state().open_folder.as_deref() != Some(folder) {
            return Ok(reject(
                "folderChanged",
                "The workflow's folder is no longer open.",
            ));
        }
        let workflow_id = WorkflowId(inner.next_workflow_id);
        let next_workflow_id = inner
            .next_workflow_id
            .checked_add(1)
            .ok_or(ApplicationError::IdExhausted)?;
        let next_session_id = inner
            .next_session_id
            .checked_add(1)
            .ok_or(ApplicationError::IdExhausted)?;
        let terminal_id = match self.start_terminal(folder, size) {
            Ok(id) => id,
            Err(error) => return Ok(super::rejection("terminalStartFailed", &error)),
        };
        let started_at = timestamp();
        inner.next_workflow_id = next_workflow_id;
        inner.terminals.insert(terminal_id, TerminalStatus::Running);
        if inner.workflows.session.is_none() {
            let session = Session {
                session_id: SessionId(inner.next_session_id),
                name: "Session".to_owned(),
                folder: folder.to_owned(),
                status: SessionStatus::Active,
                started_at,
                ended_at: None,
            };
            inner.next_session_id = next_session_id;
            inner.workflows.session = Some(session.clone());
            inner
                .events
                .append(EventKind::State(StateEvent::SessionChanged(session)))?;
        }
        let workflow = Workflow {
            workflow_id,
            session_id: inner
                .workflows
                .session
                .as_ref()
                .expect("session was just created")
                .session_id,
            name: match kind {
                WorkflowKind::Draft => "New workflow".to_owned(),
                WorkflowKind::Terminal => "Terminal".to_owned(),
            },
            kind,
            terminal_id,
            status: WorkflowStatus::Running,
            started_at,
            ended_at: None,
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
        let Some(workflow) = inner
            .workflows
            .workflows
            .iter_mut()
            .find(|workflow| workflow.workflow_id == workflow_id)
        else {
            return Ok(reject(
                "workflowNotFound",
                "The workflow is no longer open.",
            ));
        };
        // Activation changes the workflow type, never terminal ownership, timing, or process state.
        workflow.kind = WorkflowKind::Terminal;
        "Terminal".clone_into(&mut workflow.name);
        let workflow = workflow.clone();
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
        // Joining a supervisor while holding Inner would deadlock its exit callback.
        self.terminals.close(terminal_id)?;
        self.lock_inner()?
            .events
            .append(EventKind::CommandCompleted {
                request_id,
                result: CommandResult::WorkflowClosed { workflow_id },
            })?;
        Ok(CommandDisposition::Accepted)
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
            // Forget ownership before cleanup, so a late exit cannot resurrect a closed terminal.
            let terminal_ids = inner.terminals.keys().copied().collect::<Vec<_>>();
            inner.terminals.clear();
            for terminal_id in &terminal_ids {
                inner
                    .events
                    .append(EventKind::State(StateEvent::TerminalClosed {
                        terminal_id: *terminal_id,
                    }))?;
            }
            for mut workflow in std::mem::take(&mut inner.workflows.workflows) {
                workflow.status = WorkflowStatus::Closed;
                workflow
                    .ended_at
                    .get_or_insert(timestamp().max(workflow.started_at));
                inner
                    .events
                    .append(EventKind::State(StateEvent::WorkflowChanged(workflow)))?;
            }
            if let Some(mut session) = inner.workflows.session.take() {
                session.status = SessionStatus::Closed;
                session.ended_at = Some(timestamp().max(session.started_at));
                inner
                    .events
                    .append(EventKind::State(StateEvent::SessionChanged(session)))?;
            }
            (disposition, terminal_ids)
        };
        for terminal_id in terminal_ids {
            self.terminals.close(terminal_id)?;
        }
        Ok(disposition)
    }
}

fn reject(code: &str, message: &str) -> CommandDisposition {
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
        assert!(events.iter().any(|event| matches!(&event.kind, EventKind::State(StateEvent::SessionChanged(session)) if session.status == SessionStatus::Closed && session.ended_at.is_some())));
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
                EventKind::State(StateEvent::SessionChanged(session)) => {
                    state.session =
                        (session.status == SessionStatus::Active).then(|| session.clone());
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
