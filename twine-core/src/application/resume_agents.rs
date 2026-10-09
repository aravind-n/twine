//! Restored conversations get fresh PTYs; recorded output and interrupted traces stay immutable.

use std::path::Path;
use std::sync::Arc;

use super::{Application, ApplicationError};
use crate::event::{CommandResult, EventKind, StateEvent};
use crate::harness::{launch::LaunchOptions, resume};
use crate::{TerminalId, TerminalSize, TerminalStatus, Workflow, WorkflowKind, WorkflowStatus};

pub(super) const RESTORED_SIZE: TerminalSize = TerminalSize {
    rows: 24,
    columns: 80,
    pixel_width: 800,
    pixel_height: 480,
};

impl Application {
    pub(super) fn resume_agent(
        &self,
        request_id: super::RequestId,
        workflow_id: crate::WorkflowId,
        session: &str,
    ) -> Result<super::CommandDisposition, ApplicationError> {
        let session = session.trim();
        let (saved, folder) = {
            let inner = self.lock_inner()?;
            let Some(workflow) = inner
                .workflows
                .workflows
                .iter()
                .find(|w| w.workflow_id == workflow_id)
            else {
                return Ok(super::workflows::reject(
                    "workflowNotFound",
                    "The workflow is no longer open.",
                ));
            };
            if workflow.kind != WorkflowKind::SingleAgent
                || workflow.status == WorkflowStatus::Running
            {
                return Ok(super::workflows::reject(
                    "agentNotStopped",
                    "Only a stopped agent can be resumed.",
                ));
            }
            if workflow
                .harness
                .and_then(|h| resume::arguments(h, session))
                .is_none()
            {
                return Ok(super::workflows::reject(
                    "invalidSession",
                    "Enter a valid harness session ID or absolute session file path.",
                ));
            }
            let Some(folder) = inner
                .workflows
                .sessions
                .iter()
                .find(|s| s.session_id == workflow.session_id)
            else {
                return Ok(super::workflows::reject(
                    "workflowNotFound",
                    "The session is no longer open.",
                ));
            };
            (workflow.clone(), folder.folder.clone())
        };
        if let Err(error) = self.resume_single_agent(&saved, &folder, Some(session)) {
            return Ok(super::rejection("agentResumeFailed", &error));
        }
        self.lock_inner()?
            .events
            .append(EventKind::CommandCompleted {
                request_id,
                result: CommandResult::AgentStarted { workflow_id },
            })?;
        Ok(super::CommandDisposition::Accepted)
    }

    pub(super) fn resume_restored_agents(&self, folder: &Path) -> Result<(), ApplicationError> {
        let workflows = self.lock_inner()?.workflows.workflows.clone();
        for workflow in workflows {
            if workflow.run.is_some() {
                if let Err(error) = self.resume_workflow_run(&workflow, folder) {
                    tracing::warn!(%error, "couldn't resume workflow agent sessions");
                }
                continue;
            }
            if workflow.kind != WorkflowKind::SingleAgent
                || !matches!(
                    workflow.status,
                    WorkflowStatus::Interrupted | WorkflowStatus::Exited
                )
            {
                continue;
            }
            if let Err(error) = self.resume_single_agent(&workflow, folder, None) {
                tracing::warn!(%error, workflow_id = workflow.workflow_id.0, "couldn't resume agent session");
            }
        }
        Ok(())
    }

    fn resume_single_agent(
        &self,
        saved: &Workflow,
        folder: &Path,
        requested: Option<&str>,
    ) -> Result<(), ApplicationError> {
        let Some(harness) = saved.harness else {
            return Ok(());
        };
        let session = requested.map(str::to_owned).or(self
            .lock_inner()?
            .folders
            .store()
            .harness_session(saved.terminal_id)?);
        let Some(session) = session else {
            return Ok(());
        };
        let Some(resume_args) = resume::arguments(harness, &session) else {
            return Ok(());
        };
        let located = self.locate_harness(harness.definition())?;
        let history = self
            .lock_inner()?
            .folders
            .store()
            .terminal_history(saved.workflow_id)?;
        let reserved = self.terminals.reserve_terminal()?;
        let (mut arguments, hooks) =
            self.harness_arguments(harness, reserved, LaunchOptions::default(), "");
        arguments.extend(resume_args);
        let mut inner = self.lock_inner()?;
        let id = self.terminals.start_program(
            reserved,
            folder,
            &located.program,
            &arguments,
            &located.path,
            &crate::harness::launch::observed_environment(harness, hooks.as_ref()),
            RESTORED_SIZE,
            Arc::new(self.exit_callback()),
        )?;
        let mut workflow = saved.clone();
        workflow.restored = true;
        workflow.terminal_history = history;
        workflow.terminal_id = id;
        workflow.status = WorkflowStatus::Running;
        workflow.started_at = crate::workflow::timestamp();
        workflow.ended_at = None;
        let recorded = inner.start_agent_trace(
            &workflow,
            harness,
            TerminalId::from_value(0),
            None,
            Some(&session),
        );
        if let Err(error) = recorded {
            drop(inner);
            let _ = self.terminals.close(id);
            return Err(error);
        }
        let retire_previous = inner.terminals.remove(&saved.terminal_id).is_some();
        inner.terminals.insert(id, TerminalStatus::Running);
        if let Some(current) = inner
            .workflows
            .workflows
            .iter_mut()
            .find(|w| w.workflow_id == workflow.workflow_id)
        {
            *current = workflow.clone();
        }
        inner
            .events
            .append(EventKind::State(StateEvent::WorkflowChanged(workflow)))?;
        drop(inner);
        if retire_previous {
            let _ = self.terminals.close_in_background(saved.terminal_id);
        }
        if let Some(hooks) = hooks
            && let Err(error) = self.register_harness_steps(id, saved.workflow_id, true, hooks)
        {
            tracing::warn!(%error, "couldn't register resumed harness hooks");
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use std::os::unix::fs::PermissionsExt;
    use std::time::{Duration, Instant};

    use super::*;
    use crate::{Command, CommandDisposition, HarnessId, RequestId, WorkflowId};

    fn accepted(app: &Application, command: Command) {
        assert_eq!(
            app.handle_command(RequestId(1), command)
                .unwrap()
                .disposition,
            CommandDisposition::Accepted
        );
    }

    fn fixture(folder: &Path, bin: &Path) -> Application {
        for harness in [
            HarnessId::Codex,
            HarnessId::ClaudeCode,
            HarnessId::Pi,
            HarnessId::Antigravity,
            HarnessId::Omp,
            HarnessId::Opencode,
        ] {
            let path = bin.join(harness.definition().binary);
            std::fs::write(&path, "#!/bin/sh\nprintf 'ARG:%s\\n' \"$@\"\nprintf 'READY\\n'\nwhile IFS= read -r line; do printf 'INPUT:%s\\n' \"$line\"; done\n").unwrap();
            std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).unwrap();
        }
        let mut app = Application::with_event_capacity(4096).unwrap();
        app.harness_path = Some(bin.as_os_str().to_owned());
        accepted(
            &app,
            Command::OpenFolder {
                path: folder.to_owned(),
            },
        );
        app
    }

    fn workflow(app: &Application, id: WorkflowId) -> Workflow {
        app.snapshot()
            .unwrap()
            .workflows
            .workflows
            .into_iter()
            .find(|w| w.workflow_id == id)
            .unwrap()
    }

    fn start(app: &Application, folder: &Path, harness: HarnessId) -> Workflow {
        accepted(
            app,
            Command::CreateWorkflow {
                folder: folder.to_owned(),
                session_id: None,
                kind: WorkflowKind::Draft,
                roles: vec![],
                size: RESTORED_SIZE,
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
        accepted(
            app,
            Command::StartAgent {
                workflow_id: id,
                harness,
                model: None,
                effort: None,
                yolo: false,
                prompt: "Original task".into(),
                size: RESTORED_SIZE,
            },
        );
        workflow(app, id)
    }

    fn output(app: &Application, terminal: TerminalId, needle: &str) -> String {
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            let crate::TranscriptRead::Output(page) =
                app.read_terminal_transcript(terminal, 0, 65536).unwrap()
            else {
                panic!("transcript should remain readable")
            };
            let text = String::from_utf8_lossy(&page.bytes).into_owned();
            if text.contains(needle) {
                return text;
            }
            assert!(Instant::now() < deadline, "missing {needle:?} in {text:?}");
            std::thread::sleep(Duration::from_millis(10));
        }
    }

    #[test]
    fn failed_resume_keeps_the_old_handle_and_success_retires_the_previous_terminal() {
        let folder = tempfile::tempdir().unwrap();
        let bin = tempfile::tempdir().unwrap();
        let app = fixture(folder.path(), bin.path());
        let original = start(&app, folder.path(), HarnessId::Codex);
        accepted(
            &app,
            Command::CancelAgent {
                workflow_id: original.workflow_id,
            },
        );
        let old_history = app
            .lock_inner()
            .unwrap()
            .folders
            .store()
            .terminal_history(original.workflow_id)
            .unwrap();
        app.lock_inner().unwrap().folders.store().execute_test_sql(
            "CREATE TRIGGER fail_resume BEFORE INSERT ON workflow_terminals WHEN NEW.harness_session IS NOT NULL BEGIN SELECT RAISE(FAIL, 'session save failed'); END");
        let rejected = app
            .handle_command(
                RequestId(3),
                Command::ResumeAgent {
                    workflow_id: original.workflow_id,
                    session: "exact-session".into(),
                },
            )
            .unwrap();
        assert!(matches!(
            rejected.disposition,
            CommandDisposition::Rejected { .. }
        ));
        assert_eq!(
            workflow(&app, original.workflow_id).status,
            WorkflowStatus::Cancelled
        );
        assert_eq!(
            app.lock_inner()
                .unwrap()
                .folders
                .store()
                .terminal_history(original.workflow_id)
                .unwrap(),
            old_history
        );
        app.lock_inner()
            .unwrap()
            .folders
            .store()
            .execute_test_sql("DROP TRIGGER fail_resume");
        accepted(
            &app,
            Command::ResumeAgent {
                workflow_id: original.workflow_id,
                session: "exact-session".into(),
            },
        );
        let resumed = workflow(&app, original.workflow_id);
        assert_ne!(resumed.terminal_id, original.terminal_id);
        let deadline = Instant::now() + Duration::from_secs(5);
        while app.terminals.size(original.terminal_id).is_some() {
            assert!(Instant::now() < deadline);
            std::thread::sleep(Duration::from_millis(10));
        }
        assert!(
            !app.lock_inner()
                .unwrap()
                .terminals
                .contains_key(&original.terminal_id)
        );
    }

    #[test]
    fn restored_harnesses_resume_exact_conversations_and_keep_terminal_history() {
        for harness in [
            HarnessId::Codex,
            HarnessId::ClaudeCode,
            HarnessId::Pi,
            HarnessId::Antigravity,
            HarnessId::Omp,
            HarnessId::Opencode,
        ] {
            let folder = tempfile::tempdir().unwrap();
            let bin = tempfile::tempdir().unwrap();
            let app = fixture(folder.path(), bin.path());
            let original = start(&app, folder.path(), harness);
            output(&app, original.terminal_id, "READY");
            let session = if matches!(harness, HarnessId::Pi | HarnessId::Omp) {
                "/tmp/agent session.jsonl"
            } else {
                "exact-session-1"
            };
            app.lock_inner()
                .unwrap()
                .folders
                .store()
                .remember_harness_session(original.terminal_id, session)
                .unwrap();
            accepted(&app, Command::CloseFolder);
            accepted(
                &app,
                Command::OpenFolder {
                    path: folder.path().to_owned(),
                },
            );
            let resumed = workflow(&app, original.workflow_id);
            assert_eq!(resumed.status, WorkflowStatus::Running);
            assert!(resumed.restored);
            assert_ne!(resumed.terminal_id, original.terminal_id);
            assert_eq!(resumed.terminal_ids(), [resumed.terminal_id]);
            assert!(
                resumed
                    .terminal_history
                    .iter()
                    .any(|entry| entry.terminal_id == original.terminal_id)
            );
            let text = output(&app, resumed.terminal_id, "READY");
            assert!(text.contains(&format!("ARG:{session}")), "{text}");
            assert!(!text.contains("Original task"));
            app.write_terminal_input(resumed.terminal_id, b"follow-up\n")
                .unwrap();
            output(&app, resumed.terminal_id, "INPUT:follow-up");
            accepted(
                &app,
                Command::CloseWorkflow {
                    workflow_id: resumed.workflow_id,
                },
            );
            assert_eq!(app.snapshot().unwrap().workflows.workflows, []);
            assert!(app.terminals.size(resumed.terminal_id).is_none());
        }
    }

    #[test]
    fn missing_handles_remain_archived_until_an_exact_session_is_supplied() {
        let folder = tempfile::tempdir().unwrap();
        let bin = tempfile::tempdir().unwrap();
        let app = fixture(folder.path(), bin.path());
        let original = start(&app, folder.path(), HarnessId::Antigravity);
        accepted(&app, Command::CloseFolder);
        accepted(
            &app,
            Command::OpenFolder {
                path: folder.path().to_owned(),
            },
        );
        assert_eq!(workflow(&app, original.workflow_id).terminal_ids(), []);
        let invalid = app
            .handle_command(
                RequestId(2),
                Command::ResumeAgent {
                    workflow_id: original.workflow_id,
                    session: "--continue".into(),
                },
            )
            .unwrap();
        assert!(matches!(
            invalid.disposition,
            CommandDisposition::Rejected { .. }
        ));
        accepted(
            &app,
            Command::ResumeAgent {
                workflow_id: original.workflow_id,
                session: "chosen-session".into(),
            },
        );
        let resumed = workflow(&app, original.workflow_id);
        let text = output(&app, resumed.terminal_id, "READY");
        assert!(
            text.contains("ARG:--conversation\r\nARG:chosen-session"),
            "{text}"
        );
        assert_ne!(resumed.terminal_id, original.terminal_id);
        let again = app
            .handle_command(
                RequestId(3),
                Command::ResumeAgent {
                    workflow_id: original.workflow_id,
                    session: "another-session".into(),
                },
            )
            .unwrap();
        assert!(matches!(
            again.disposition,
            CommandDisposition::Rejected { .. }
        ));
    }
}
