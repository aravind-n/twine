use std::path::Path;

use super::{Application, ApplicationError, CommandDisposition, Inner, RequestId};
use crate::event::{CommandResult, EventKind, StateEvent};
use crate::workflow::{Session, SessionId, SessionStatus, Workflow, timestamp, valid_name};

impl Application {
    pub(super) fn create_session(
        &self,
        request: RequestId,
        folder: &Path,
        name: &str,
    ) -> Result<CommandDisposition, ApplicationError> {
        let name = name.trim();
        if !valid_name(name) {
            return Ok(invalid_name());
        }
        let mut inner = self.lock_inner()?;
        if inner.folders.state().open_folder.as_deref() != Some(folder) {
            return Ok(super::workflows::reject(
                "folderChanged",
                "The session's folder is no longer open.",
            ));
        }
        let session_id = inner.add_session(folder, name)?;
        inner.complete_session(request, CommandResult::SessionCreated { session_id })?;
        Ok(CommandDisposition::Accepted)
    }

    pub(super) fn rename_session(
        &self,
        request: RequestId,
        session_id: SessionId,
        name: &str,
    ) -> Result<CommandDisposition, ApplicationError> {
        let name = name.trim();
        if !valid_name(name) {
            return Ok(invalid_name());
        }
        let mut inner = self.lock_inner()?;
        let Some(index) = inner
            .workflows
            .sessions
            .iter()
            .position(|session| session.session_id == session_id)
        else {
            return Ok(not_found());
        };
        inner.folders.store().rename_session(session_id, name)?;
        name.clone_into(&mut inner.workflows.sessions[index].name);
        if let Some(selected) = inner
            .workflows
            .session
            .as_mut()
            .filter(|session| session.session_id == session_id)
        {
            name.clone_into(&mut selected.name);
        }
        inner.complete_session(request, CommandResult::SessionRenamed { session_id })?;
        Ok(CommandDisposition::Accepted)
    }

    pub(super) fn select_session(
        &self,
        request: RequestId,
        session_id: SessionId,
    ) -> Result<CommandDisposition, ApplicationError> {
        let mut inner = self.lock_inner()?;
        let Some(session) = inner
            .workflows
            .sessions
            .iter()
            .find(|session| session.session_id == session_id)
            .cloned()
        else {
            return Ok(not_found());
        };
        inner
            .folders
            .store()
            .select_session(&session.folder, Some(session_id))?;
        inner.workflows.session = Some(session);
        inner.complete_session(request, CommandResult::SessionSelected { session_id })?;
        Ok(CommandDisposition::Accepted)
    }

    pub(super) fn delete_session(
        &self,
        request: RequestId,
        session_id: SessionId,
    ) -> Result<CommandDisposition, ApplicationError> {
        let terminal_ids = {
            let mut inner = self.lock_inner()?;
            let Some(index) = inner
                .workflows
                .sessions
                .iter()
                .position(|session| session.session_id == session_id)
            else {
                return Ok(not_found());
            };
            let mut sessions = inner.workflows.sessions.clone();
            let removed = sessions.remove(index);
            let selected = if inner
                .workflows
                .session
                .as_ref()
                .is_some_and(|session| session.session_id == session_id)
            {
                sessions
                    .get(index.min(sessions.len().saturating_sub(1)))
                    .cloned()
            } else {
                inner.workflows.session.clone()
            };
            inner.folders.store().delete_session(
                &removed.folder,
                session_id,
                selected.as_ref().map(|session| session.session_id),
            )?;
            let terminal_ids: Vec<_> = inner
                .workflows
                .workflows
                .iter()
                .filter(|workflow| workflow.session_id == session_id)
                .flat_map(Workflow::terminal_ids)
                .collect();
            for terminal_id in &terminal_ids {
                inner.terminals.remove(terminal_id);
                inner.trace_spans.remove(terminal_id);
                inner.pending_trace_endings.remove(terminal_id);
                inner
                    .events
                    .append(EventKind::State(StateEvent::TerminalClosed {
                        terminal_id: *terminal_id,
                    }))?;
            }
            inner
                .workflows
                .workflows
                .retain(|workflow| workflow.session_id != session_id);
            inner.workflows.sessions = sessions;
            inner.workflows.session = selected;
            inner.publish_workflows()?;
            terminal_ids
        };
        self.terminals.close_all(&terminal_ids)?;
        self.lock_inner()?
            .events
            .append(EventKind::CommandCompleted {
                request_id: request,
                result: CommandResult::SessionDeleted { session_id },
            })?;
        Ok(CommandDisposition::Accepted)
    }
}

impl Inner {
    pub(super) fn add_session(
        &mut self,
        folder: &Path,
        name: &str,
    ) -> Result<SessionId, ApplicationError> {
        let started_at = timestamp();
        let session_id = self
            .folders
            .store()
            .create_session(folder, name, started_at)?;
        let session = Session {
            session_id,
            name: name.to_owned(),
            folder: folder.to_owned(),
            status: SessionStatus::Active,
            started_at,
            ended_at: None,
        };
        self.workflows.sessions.push(session.clone());
        self.workflows.sessions_initialized = true;
        self.workflows.session = Some(session);
        self.publish_workflows()?;
        Ok(session_id)
    }

    pub(super) fn publish_workflows(&mut self) -> Result<(), ApplicationError> {
        self.events
            .append(EventKind::State(StateEvent::WorkflowsChanged(
                self.workflows.clone(),
            )))?;
        Ok(())
    }

    fn complete_session(
        &mut self,
        request_id: RequestId,
        result: CommandResult,
    ) -> Result<(), ApplicationError> {
        self.publish_workflows()?;
        self.events
            .append(EventKind::CommandCompleted { request_id, result })?;
        Ok(())
    }
}

fn invalid_name() -> CommandDisposition {
    super::workflows::reject(
        "invalidSessionName",
        "Use a session name of 1–200 characters on one line.",
    )
}
fn not_found() -> CommandDisposition {
    super::workflows::reject(
        "sessionNotFound",
        "The session is no longer in the open folder.",
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::Config;
    use crate::{Command, TerminalSize, Workflow, WorkflowKind};
    use std::time::{Duration, Instant};

    fn accepted(app: &Application, command: Command) {
        assert_eq!(
            app.handle_command(RequestId(1), command)
                .unwrap()
                .disposition,
            CommandDisposition::Accepted
        );
    }

    fn open(app: &Application, folder: &Path) {
        accepted(
            app,
            Command::OpenFolder {
                path: folder.to_owned(),
            },
        );
    }

    fn create_session(app: &Application, folder: &Path, name: &str) -> SessionId {
        accepted(
            app,
            Command::CreateSession {
                folder: folder.to_owned(),
                name: name.to_owned(),
            },
        );
        app.snapshot()
            .unwrap()
            .workflows
            .session
            .unwrap()
            .session_id
    }

    fn create_workflow(
        app: &Application,
        folder: &Path,
        session_id: SessionId,
        kind: WorkflowKind,
    ) -> Workflow {
        accepted(
            app,
            Command::CreateWorkflow {
                folder: folder.to_owned(),
                session_id: Some(session_id),
                kind,
                roles: Vec::new(),
                size: TerminalSize {
                    rows: 24,
                    columns: 80,
                    pixel_width: 800,
                    pixel_height: 480,
                },
            },
        );
        app.snapshot()
            .unwrap()
            .workflows
            .workflows
            .last()
            .unwrap()
            .clone()
    }

    fn wait_for_file(path: &Path) -> String {
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            if let Ok(contents) = std::fs::read_to_string(path)
                && !contents.is_empty()
            {
                return contents;
            }
            assert!(Instant::now() < deadline, "shell didn't write its marker");
            std::thread::sleep(Duration::from_millis(10));
        }
    }

    #[test]
    fn relaunch_restores_names_selection_tabs_and_fresh_shells() {
        let data = tempfile::tempdir().unwrap();
        let folder = tempfile::tempdir().unwrap();
        let mut app = Application::with_config(data.path(), Config::default()).unwrap();
        app.terminals.set_test_shell("/bin/sh".into());
        open(&app, folder.path());
        let first = create_session(&app, folder.path(), "First");
        let workflow = create_workflow(&app, folder.path(), first, WorkflowKind::Draft);
        accepted(
            &app,
            Command::NameDraftWorkflow {
                workflow_id: workflow.workflow_id,
                name: "Single agent".to_owned(),
            },
        );
        app.write_terminal_input(
            workflow.terminal_id,
            b"TWINE_SESSION_VALUE=old; echo $$ > before.pid\n",
        )
        .unwrap();
        let before = wait_for_file(&folder.path().join("before.pid"));
        let second = create_session(&app, folder.path(), "Second");
        let other = create_workflow(&app, folder.path(), second, WorkflowKind::Terminal);
        // Deletion must survive relaunch; identifiers must not be reused.
        let closed = create_workflow(&app, folder.path(), second, WorkflowKind::Terminal);
        accepted(
            &app,
            Command::CloseWorkflow {
                workflow_id: closed.workflow_id,
            },
        );
        accepted(
            &app,
            Command::RenameSession {
                session_id: first,
                name: "Renamed".to_owned(),
            },
        );
        accepted(&app, Command::SelectSession { session_id: first });
        drop(app);

        let app = Application::with_config(data.path(), Config::default()).unwrap();
        let state = app.snapshot().unwrap().workflows;
        assert_eq!(
            state
                .sessions
                .iter()
                .map(|session| session.name.as_str())
                .collect::<Vec<_>>(),
            ["Renamed", "Second"]
        );
        assert_eq!(state.session.unwrap().session_id, first);
        assert_eq!(
            state
                .workflows
                .iter()
                .map(|workflow| workflow.workflow_id)
                .collect::<Vec<_>>(),
            [workflow.workflow_id, other.workflow_id]
        );
        assert!(state.workflows.iter().all(|workflow| workflow.restored));
        assert_eq!(state.workflows[0].name, "Single agent");
        assert_eq!(state.workflows[0].kind, WorkflowKind::Draft);
        app.write_terminal_input(
            state.workflows[0].terminal_id,
            b"printf '%s:%s\\n' $$ \"${TWINE_SESSION_VALUE-fresh}\" > after.txt\n",
        )
        .unwrap();
        let after = wait_for_file(&folder.path().join("after.txt"));
        assert!(after.trim().ends_with(":fresh"));
        assert_ne!(after.split(':').next().unwrap(), before.trim());
        let created = create_workflow(&app, folder.path(), first, WorkflowKind::Terminal);
        assert!(created.workflow_id.0 > closed.workflow_id.0);
    }

    #[test]
    fn deleting_a_session_stops_only_its_shells_and_persists_the_neighbor() {
        let data = tempfile::tempdir().unwrap();
        let folder = tempfile::tempdir().unwrap();
        let app = Application::with_config(data.path(), Config::default()).unwrap();
        open(&app, folder.path());
        let first = create_session(&app, folder.path(), "First");
        let removed = create_workflow(&app, folder.path(), first, WorkflowKind::Terminal);
        let second = create_session(&app, folder.path(), "Second");
        let survivor = create_workflow(&app, folder.path(), second, WorkflowKind::Terminal);
        accepted(&app, Command::SelectSession { session_id: first });
        accepted(&app, Command::DeleteSession { session_id: first });
        let state = app.snapshot().unwrap();
        assert_eq!(state.workflows.session.unwrap().session_id, second);
        assert_eq!(
            state.workflows.workflows.as_slice(),
            std::slice::from_ref(&survivor)
        );
        assert_eq!(state.terminals.len(), 1);
        assert!(
            app.write_terminal_input(removed.terminal_id, b"touch stale\n")
                .is_err()
        );
        app.write_terminal_input(survivor.terminal_id, b"echo alive > survivor.txt\n")
            .unwrap();
        assert_eq!(
            wait_for_file(&folder.path().join("survivor.txt")).trim(),
            "alive"
        );
        drop(app);
        let app = Application::with_config(data.path(), Config::default()).unwrap();
        assert_eq!(app.snapshot().unwrap().workflows.sessions.len(), 1);
        accepted(&app, Command::DeleteSession { session_id: second });
        drop(app);
        let app = Application::with_config(data.path(), Config::default()).unwrap();
        assert_eq!(
            app.snapshot().unwrap().workflows,
            crate::WorkflowState {
                sessions_initialized: true,
                ..crate::WorkflowState::default()
            }
        );
        assert!(app.snapshot().unwrap().terminals.is_empty());
    }

    #[test]
    fn selection_keeps_shells_and_stale_commands_cannot_target_another_session_or_folder() {
        let folder = tempfile::tempdir().unwrap();
        let other_folder = tempfile::tempdir().unwrap();
        let app = Application::with_event_capacity(4096).unwrap();
        open(&app, folder.path());
        let first = create_session(&app, folder.path(), "First");
        let first_workflow = create_workflow(&app, folder.path(), first, WorkflowKind::Terminal);
        let second = create_session(&app, folder.path(), "Second");
        let receipt = app
            .handle_command(
                RequestId(2),
                Command::CreateWorkflow {
                    folder: folder.path().to_owned(),
                    session_id: Some(first),
                    kind: WorkflowKind::Terminal,
                    roles: Vec::new(),
                    size: TerminalSize {
                        rows: 24,
                        columns: 80,
                        pixel_width: 0,
                        pixel_height: 0,
                    },
                },
            )
            .unwrap();
        assert!(
            matches!(receipt.disposition, CommandDisposition::Rejected { code, .. } if code == "sessionChanged")
        );
        accepted(&app, Command::SelectSession { session_id: first });
        assert_eq!(
            app.snapshot().unwrap().workflows.workflows,
            [first_workflow]
        );
        for name in ["", "\n", "two\nlines", &"a".repeat(201)] {
            assert!(matches!(
                app.handle_command(
                    RequestId(3),
                    Command::RenameSession {
                        session_id: first,
                        name: name.to_owned()
                    }
                )
                .unwrap()
                .disposition,
                CommandDisposition::Rejected { .. }
            ));
        }
        open(&app, other_folder.path());
        assert!(matches!(
            app.handle_command(RequestId(4), Command::DeleteSession { session_id: second })
                .unwrap()
                .disposition,
            CommandDisposition::Rejected { .. }
        ));
        open(&app, folder.path());
        assert_eq!(app.snapshot().unwrap().workflows.sessions.len(), 2);
        assert_eq!(
            app.snapshot()
                .unwrap()
                .workflows
                .session
                .unwrap()
                .session_id,
            first
        );
        assert!(app.snapshot().unwrap().workflows.workflows[0].restored);
    }

    #[test]
    fn session_and_folder_events_reconstruct_the_final_snapshot() {
        let folder = tempfile::tempdir().unwrap();
        let app = Application::with_event_capacity(4096).unwrap();
        open(&app, folder.path());
        let initial = app.snapshot().unwrap();
        let first = create_session(&app, folder.path(), "First");
        create_workflow(&app, folder.path(), first, WorkflowKind::Terminal);
        let second = create_session(&app, folder.path(), "Second");
        create_workflow(&app, folder.path(), second, WorkflowKind::Draft);
        accepted(
            &app,
            Command::RenameSession {
                session_id: first,
                name: "Renamed".to_owned(),
            },
        );
        accepted(&app, Command::SelectSession { session_id: first });
        accepted(&app, Command::DeleteSession { session_id: second });
        accepted(&app, Command::CloseFolder);
        open(&app, folder.path());
        let final_snapshot = app.snapshot().unwrap();
        let mut state = initial.workflows;
        for (index, event) in app
            .events_after(initial.sequence, 4096)
            .unwrap()
            .iter()
            .filter(|event| event.sequence <= final_snapshot.sequence)
            .enumerate()
        {
            assert_eq!(
                event.sequence,
                initial.sequence + u64::try_from(index).unwrap() + 1
            );
            match &event.kind {
                EventKind::State(StateEvent::WorkflowsChanged(changed)) => state = changed.clone(),
                EventKind::State(StateEvent::WorkflowChanged(workflow)) => {
                    if workflow.status == crate::WorkflowStatus::Closed {
                        state
                            .workflows
                            .retain(|current| current.workflow_id != workflow.workflow_id);
                    } else if let Some(current) = state
                        .workflows
                        .iter_mut()
                        .find(|current| current.workflow_id == workflow.workflow_id)
                    {
                        *current = workflow.clone();
                    } else {
                        state.workflows.push(workflow.clone());
                    }
                }
                _ => {}
            }
        }
        assert_eq!(state, final_snapshot.workflows);
    }

    #[test]
    fn relaunch_restores_agents_with_fresh_shells_and_deleting_the_session_stops_them() {
        let data = tempfile::tempdir().unwrap();
        let folder = tempfile::tempdir().unwrap();
        let mut app = Application::with_config(data.path(), Config::default()).unwrap();
        app.terminals.set_test_shell("/bin/sh".into());
        open(&app, folder.path());
        let session = create_session(&app, folder.path(), "Agents");
        accepted(
            &app,
            Command::CreateWorkflow {
                folder: folder.path().to_owned(),
                session_id: Some(session),
                kind: WorkflowKind::Agents,
                roles: vec!["Implementer".to_owned(), "Reviewer".to_owned()],
                size: TerminalSize {
                    rows: 24,
                    columns: 80,
                    pixel_width: 800,
                    pixel_height: 480,
                },
            },
        );
        let original = app.snapshot().unwrap().workflows.workflows[0].clone();
        app.write_terminal_input(original.agents[1].terminal_id, b"echo $$ > before.pid\n")
            .unwrap();
        let before = wait_for_file(&folder.path().join("before.pid"));
        drop(app);

        let mut app = Application::with_config(data.path(), Config::default()).unwrap();
        app.terminals.set_test_shell("/bin/sh".into());
        let snapshot = app.snapshot().unwrap();
        let [restored] = snapshot.workflows.workflows.as_slice() else {
            panic!("expected the agents workflow, got {:?}", snapshot.workflows);
        };
        assert!(restored.restored);
        assert_eq!(restored.kind, WorkflowKind::Agents);
        assert_eq!(restored.status, crate::WorkflowStatus::Running);
        assert_eq!(restored.terminal_id.value(), 0);
        assert_eq!(
            restored
                .agents
                .iter()
                .map(|agent| (agent.agent_id, agent.role.as_str()))
                .collect::<Vec<_>>(),
            original
                .agents
                .iter()
                .map(|agent| (agent.agent_id, agent.role.as_str()))
                .collect::<Vec<_>>()
        );
        let terminal_ids = restored.terminal_ids();
        assert_eq!(terminal_ids.len(), 2);
        assert_eq!(snapshot.terminals.len(), 2);
        app.write_terminal_input(terminal_ids[1], b"echo $$ > after.pid\n")
            .unwrap();
        assert_ne!(wait_for_file(&folder.path().join("after.pid")), before);

        accepted(
            &app,
            Command::DeleteSession {
                session_id: session,
            },
        );
        let snapshot = app.snapshot().unwrap();
        assert!(snapshot.workflows.workflows.is_empty());
        assert!(snapshot.terminals.is_empty());
        for terminal_id in terminal_ids {
            assert!(app.write_terminal_input(terminal_id, b"\n").is_err());
        }
    }

    #[test]
    fn empty_sessions_and_sessions_outside_the_recent_list_survive_reopen() {
        let data = tempfile::tempdir().unwrap();
        let folders = tempfile::tempdir().unwrap();
        let app = Application::with_config(data.path(), Config::default()).unwrap();
        let first_folder = folders.path().join("first");
        std::fs::create_dir(&first_folder).unwrap();
        open(&app, &first_folder);
        let first = create_session(&app, &first_folder, "Empty");
        for index in 0..11 {
            let folder = folders.path().join(index.to_string());
            std::fs::create_dir(&folder).unwrap();
            open(&app, &folder);
        }
        drop(app);
        let app = Application::with_config(data.path(), Config::default()).unwrap();
        open(&app, &first_folder);
        let state = app.snapshot().unwrap();
        assert_eq!(state.workflows.session.unwrap().session_id, first);
        assert_eq!(state.workflows.sessions[0].name, "Empty");
        assert!(state.workflows.workflows.is_empty());
    }
}
