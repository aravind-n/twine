use std::path::PathBuf;
use std::sync::Arc;

use tracing::{info, warn};

use super::workflows::reject;
use super::{Application, ApplicationError, CommandDisposition, RequestId, rejection};
use crate::event::{CommandResult, EventKind, StateEvent};
use crate::harness::{HarnessDefinition, HarnessError, HarnessId, LocatedHarness, locate_in};
use crate::terminal::{TerminalSize, TerminalStatus};
use crate::workflow::{WorkflowId, WorkflowKind, WorkflowStatus, timestamp};

impl Application {
    /// Finds a harness binary. The login shell's `PATH` is looked up once in the background, so
    /// this only waits on that at the first start after launch.
    fn locate_harness(
        &self,
        definition: &HarnessDefinition,
    ) -> Result<LocatedHarness, HarnessError> {
        #[cfg(test)]
        if let Some(path) = &self.harness_path {
            return locate_in(definition, Some(path), None);
        }
        // UI tests point this at a stub harness, like `TWINE_DATA_DIRECTORY` points at test data.
        if let Some(path) = std::env::var_os("TWINE_HARNESS_PATH") {
            return locate_in(definition, Some(&path), None);
        }
        locate_in(
            definition,
            self.login_path.get().as_deref(),
            std::env::var_os("PATH").as_deref(),
        )
    }

    /// The folder of a draft workflow's session, or the rejection to send if it isn't a draft.
    fn draft_folder(
        &self,
        workflow_id: WorkflowId,
    ) -> Result<Result<PathBuf, CommandDisposition>, ApplicationError> {
        let inner = self.lock_inner()?;
        let Some(workflow) = inner
            .workflows
            .workflows
            .iter()
            .find(|workflow| workflow.workflow_id == workflow_id)
        else {
            return Ok(Err(reject(
                "workflowNotFound",
                "The workflow is no longer open.",
            )));
        };
        if workflow.kind != WorkflowKind::Draft {
            return Ok(Err(reject(
                "workflowNotDraft",
                "The workflow is already configured.",
            )));
        }
        let session = inner
            .workflows
            .sessions
            .iter()
            .find(|session| session.session_id == workflow.session_id);
        Ok(session
            .map(|session| session.folder.clone())
            .ok_or_else(|| reject("workflowNotFound", "The workflow is no longer open.")))
    }

    /// Turns a draft workflow into a single agent: starts the harness with `prompt` in its own
    /// PTY, then replaces the draft's placeholder shell with it.
    pub(super) fn start_agent(
        &self,
        request_id: RequestId,
        workflow_id: WorkflowId,
        harness: HarnessId,
        prompt: &str,
        size: TerminalSize,
    ) -> Result<CommandDisposition, ApplicationError> {
        let prompt = prompt.trim();
        if prompt.is_empty() {
            return Ok(reject("emptyPrompt", "Type a prompt for the agent."));
        }
        let folder = match self.draft_folder(workflow_id)? {
            Ok(folder) => folder,
            Err(rejected) => return Ok(rejected),
        };

        let definition = harness.definition();
        let located = match self.locate_harness(definition) {
            Ok(located) => located,
            Err(error) => return Ok(rejection("harnessNotFound", &error)),
        };

        // Transcript allocation may wait on disk; lifetime commands keep this draft valid while
        // application state remains available. Hold state again for startup and exit-event order.
        let reserved = match self.terminals.reserve_terminal() {
            Ok(id) => id,
            Err(error) => return Ok(rejection("agentStartFailed", &error)),
        };
        let mut inner = self.lock_inner()?;
        // Start the agent at the size its draft terminal has now, as the view has already fitted it.
        let placeholder_size = inner
            .workflows
            .workflows
            .iter()
            .find(|workflow| workflow.workflow_id == workflow_id)
            .and_then(|workflow| self.terminals.size(workflow.terminal_id))
            .unwrap_or(size);
        let terminal_id = match self.terminals.start_program(
            reserved,
            &folder,
            &located.program,
            &definition.arguments(prompt),
            &located.path,
            placeholder_size,
            Arc::new(self.exit_callback()),
        ) {
            Ok(terminal_id) => terminal_id,
            Err(error) => return Ok(rejection("agentStartFailed", &error)),
        };
        let Some(index) = inner
            .workflows
            .workflows
            .iter()
            .position(|workflow| workflow.workflow_id == workflow_id)
        else {
            drop(inner);
            let _ = self.terminals.close(terminal_id);
            return Ok(reject(
                "workflowNotFound",
                "The workflow is no longer open.",
            ));
        };
        let mut workflow = inner.workflows.workflows[index].clone();
        let placeholder = workflow.terminal_id;
        let name = definition.name;
        if let Err(error) = inner.folders.store().update_workflow(
            workflow_id,
            name,
            WorkflowKind::SingleAgent,
            Some(harness),
        ) {
            drop(inner);
            let _ = self.terminals.close(terminal_id);
            return Err(error.into());
        }
        if let Err(error) = inner
            .folders
            .store()
            .update_agent_status(workflow_id, WorkflowStatus::Running)
        {
            warn!(%error, "failed to record that the agent is running");
        }
        inner.terminals.remove(&placeholder);
        inner.terminals.insert(terminal_id, TerminalStatus::Running);
        workflow.kind = WorkflowKind::SingleAgent;
        workflow.harness = Some(harness);
        name.clone_into(&mut workflow.name);
        workflow.terminal_id = terminal_id;
        workflow.status = WorkflowStatus::Running;
        workflow.started_at = timestamp();
        workflow.ended_at = None;
        inner.workflows.workflows[index] = workflow.clone();
        inner
            .events
            .append(EventKind::State(StateEvent::WorkflowChanged(workflow)))?;
        inner.events.append(EventKind::CommandCompleted {
            request_id,
            result: CommandResult::AgentStarted { workflow_id },
        })?;
        drop(inner);
        // Recording the trace start event belongs here once traces exist (TWINE-23).
        info!(
            workflow_id = workflow_id.0,
            terminal_id = terminal_id.value(),
            harness = name,
            "agent started"
        );
        if placeholder.value() != 0 {
            let _ = self.terminals.close(placeholder);
        }
        Ok(CommandDisposition::Accepted)
    }

    /// Stops a running agent's process. The workflow stays open as cancelled, with its output.
    pub(super) fn cancel_agent(
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
            let mut workflow = inner.workflows.workflows[index].clone();
            if workflow.kind != WorkflowKind::SingleAgent
                || workflow.status != WorkflowStatus::Running
            {
                return Ok(reject("agentNotRunning", "The agent isn't running."));
            }
            workflow.status = WorkflowStatus::Cancelled;
            workflow.ended_at = Some(timestamp().max(workflow.started_at));
            if let Err(error) = inner
                .folders
                .store()
                .update_agent_status(workflow_id, WorkflowStatus::Cancelled)
            {
                warn!(%error, "failed to record the cancelled agent");
            }
            let terminal_id = workflow.terminal_id;
            inner.workflows.workflows[index] = workflow.clone();
            inner
                .events
                .append(EventKind::State(StateEvent::WorkflowChanged(workflow)))?;
            terminal_id
        };
        // The exit callback keeps the cancelled status, so the process ending isn't reported as
        // a crash or as finished work.
        if let Err(error) = self.terminals.terminate(terminal_id) {
            warn!(workflow_id = workflow_id.0, %error, "failed to stop cancelled agent");
        }
        info!(workflow_id = workflow_id.0, "agent cancelled");
        self.lock_inner()?
            .events
            .append(EventKind::CommandCompleted {
                request_id,
                result: CommandResult::AgentCancelled { workflow_id },
            })?;
        Ok(CommandDisposition::Accepted)
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
    use crate::Command;

    const SIZE: TerminalSize = TerminalSize {
        rows: 24,
        columns: 80,
        pixel_width: 800,
        pixel_height: 480,
    };

    /// An application whose `pi` harness is `script`, or is missing when `script` is `None`.
    fn application(folder: &Path, bin: &Path, script: Option<&str>) -> Application {
        if let Some(script) = script {
            let binary = bin.join("pi");
            std::fs::write(&binary, format!("#!/bin/sh\n{script}\n")).unwrap();
            std::fs::set_permissions(&binary, std::fs::Permissions::from_mode(0o755)).unwrap();
        }
        let mut application = Application::with_event_capacity(4096).unwrap();
        application.harness_path = Some(OsString::from(format!("{}:/bin:/usr/bin", bin.display())));
        application
            .handle_command(
                RequestId(1),
                Command::OpenFolder {
                    path: folder.to_owned(),
                },
            )
            .unwrap();
        application
    }

    fn draft(application: &Application, folder: &Path) -> crate::Workflow {
        application
            .handle_command(
                RequestId(2),
                Command::CreateWorkflow {
                    folder: folder.to_owned(),
                    session_id: None,
                    kind: WorkflowKind::Draft,
                    roles: Vec::new(),
                    size: SIZE,
                },
            )
            .unwrap();
        application.snapshot().unwrap().workflows.workflows[0].clone()
    }

    fn draft_at(application: &Application, folder: &Path) -> crate::Workflow {
        application
            .handle_command(
                RequestId(2),
                Command::CreateWorkflow {
                    folder: folder.to_owned(),
                    session_id: None,
                    kind: WorkflowKind::Draft,
                    roles: Vec::new(),
                    size: SIZE,
                },
            )
            .unwrap();
        application
            .snapshot()
            .unwrap()
            .workflows
            .workflows
            .last()
            .unwrap()
            .clone()
    }

    fn status_of(application: &Application, id: WorkflowId) -> WorkflowStatus {
        application
            .snapshot()
            .unwrap()
            .workflows
            .workflows
            .iter()
            .find(|workflow| workflow.workflow_id == id)
            .unwrap()
            .status
    }

    fn start(
        application: &Application,
        workflow_id: WorkflowId,
        prompt: &str,
    ) -> CommandDisposition {
        application
            .handle_command(
                RequestId(3),
                Command::StartAgent {
                    workflow_id,
                    harness: HarnessId::Pi,
                    prompt: prompt.to_owned(),
                    size: SIZE,
                },
            )
            .unwrap()
            .disposition
    }

    fn workflow(application: &Application) -> crate::Workflow {
        application.snapshot().unwrap().workflows.workflows[0].clone()
    }

    fn wait_until(mut condition: impl FnMut() -> bool) {
        let deadline = Instant::now() + Duration::from_secs(10);
        while !condition() {
            assert!(Instant::now() < deadline, "agent condition timed out");
            thread::sleep(Duration::from_millis(10));
        }
    }

    fn output_contains(application: &Application, output: &mut Vec<u8>, needle: &str) -> bool {
        while let Some(chunk) = application.next_terminal_chunk().unwrap() {
            output.extend_from_slice(&chunk.bytes);
        }
        String::from_utf8_lossy(output).contains(needle)
    }

    #[test]
    fn the_agent_gets_the_prompt_and_an_interactive_terminal() {
        let (folder, bin) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
        let application = application(
            folder.path(),
            bin.path(),
            Some("printf 'ARGS:%s|%s\\n' \"$1\" \"$2\"; read line; echo \"GOT:$line\"; exit 3"),
        );
        let draft = draft(&application, folder.path());

        assert_eq!(
            start(&application, draft.workflow_id, "  -fix it  "),
            CommandDisposition::Accepted
        );

        let agent = workflow(&application);
        assert_eq!(agent.kind, WorkflowKind::SingleAgent);
        assert_eq!(agent.harness, Some(HarnessId::Pi));
        assert_ne!(agent.terminal_id, draft.terminal_id);
        let mut output = Vec::new();
        wait_until(|| output_contains(&application, &mut output, "ARGS:--|-fix it"));
        application
            .write_terminal_input(agent.terminal_id, b"hello\n")
            .unwrap();
        wait_until(|| output_contains(&application, &mut output, "GOT:hello"));
        // A nonzero exit is a finished process, never a successful or cancelled workflow.
        wait_until(|| workflow(&application).status == WorkflowStatus::Exited);
    }

    #[test]
    fn agent_allocation_waits_without_holding_application_state() {
        let (folder, bin) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
        let application = Arc::new(application(folder.path(), bin.path(), Some("read line")));
        let draft = draft(&application, folder.path());
        let stalled = application
            .terminal_output
            .stall_recording_worker(draft.terminal_id);
        let starting = Arc::clone(&application);
        let starter = thread::spawn(move || start(&starting, draft.workflow_id, "wait for input"));
        wait_until(|| application.terminal_output.allocation_is_pending());
        let (sent, received) = std::sync::mpsc::sync_channel(1);
        let observing = Arc::clone(&application);
        let observer = thread::spawn(move || {
            let snapshot = observing.snapshot().unwrap();
            observing.events_after(snapshot.sequence, 8).unwrap();
            sent.send(()).unwrap();
        });
        received
            .recv_timeout(Duration::from_secs(1))
            .expect("state must remain available while agent allocation is stalled");
        observer.join().unwrap();
        assert!(!starter.is_finished());
        drop(stalled);
        assert_eq!(starter.join().unwrap(), CommandDisposition::Accepted);
    }

    #[test]
    fn a_missing_harness_binary_is_rejected_and_keeps_the_draft() {
        let (folder, bin) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
        let application = application(folder.path(), bin.path(), None);
        let draft = draft(&application, folder.path());

        let CommandDisposition::Rejected { code, message } =
            start(&application, draft.workflow_id, "hi")
        else {
            panic!("a missing binary should be rejected");
        };

        assert_eq!(code, "harnessNotFound");
        assert!(message.contains("`pi`"), "{message}");
        assert_eq!(workflow(&application), draft);
    }

    #[test]
    fn an_empty_prompt_and_a_configured_workflow_are_rejected() {
        let (folder, bin) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
        let application = application(folder.path(), bin.path(), Some("sleep 30"));
        let draft = draft(&application, folder.path());

        assert!(matches!(
            start(&application, draft.workflow_id, "   "),
            CommandDisposition::Rejected { code, .. } if code == "emptyPrompt"
        ));
        assert_eq!(
            start(&application, draft.workflow_id, "go"),
            CommandDisposition::Accepted
        );
        assert!(matches!(
            start(&application, draft.workflow_id, "again"),
            CommandDisposition::Rejected { code, .. } if code == "workflowNotDraft"
        ));
    }

    #[test]
    fn cancelling_stops_the_process_and_stays_cancelled() {
        let (folder, bin) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
        let application = application(
            folder.path(),
            bin.path(),
            Some("trap '' HUP; echo ready; while :; do sleep 1; done"),
        );
        let draft = draft(&application, folder.path());
        start(&application, draft.workflow_id, "go");
        let mut output = Vec::new();
        wait_until(|| output_contains(&application, &mut output, "ready"));

        let receipt = application
            .handle_command(
                RequestId(4),
                Command::CancelAgent {
                    workflow_id: draft.workflow_id,
                },
            )
            .unwrap();

        assert_eq!(receipt.disposition, CommandDisposition::Accepted);
        let agent = workflow(&application);
        assert_eq!(agent.status, WorkflowStatus::Cancelled);
        let terminal_id = agent.terminal_id;
        wait_until(|| {
            application
                .snapshot()
                .unwrap()
                .terminals
                .iter()
                .any(|terminal| {
                    terminal.terminal_id == terminal_id
                        && matches!(terminal.status, TerminalStatus::Exited(_))
                })
        });
        assert_eq!(workflow(&application).status, WorkflowStatus::Cancelled);
        assert!(matches!(
            application
                .handle_command(
                    RequestId(5),
                    Command::CancelAgent {
                        workflow_id: draft.workflow_id
                    }
                )
                .unwrap()
                .disposition,
            CommandDisposition::Rejected { code, .. } if code == "agentNotRunning"
        ));
    }

    #[test]
    fn restored_agents_keep_how_they_ended_and_only_running_ones_are_interrupted() {
        let (folder, bin) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
        let data = tempfile::tempdir().unwrap();
        let ids = {
            let mut first =
                Application::with_config(data.path(), crate::config::Config::default()).unwrap();
            first.harness_path = Some(OsString::from(format!(
                "{}:/bin:/usr/bin",
                bin.path().display()
            )));
            let binary = bin.path().join("pi");
            std::fs::write(
                &binary,
                "#!/bin/sh\ncase \"$2\" in exit) exit 0;; *) trap '' HUP; sleep 30;; esac\n",
            )
            .unwrap();
            std::fs::set_permissions(&binary, std::fs::Permissions::from_mode(0o755)).unwrap();
            first
                .handle_command(
                    RequestId(1),
                    Command::OpenFolder {
                        path: folder.path().to_owned(),
                    },
                )
                .unwrap();
            let mut ids = Vec::new();
            for prompt in ["exit", "cancel", "run"] {
                let draft = draft_at(&first, folder.path());
                assert_eq!(
                    start(&first, draft.workflow_id, prompt),
                    CommandDisposition::Accepted
                );
                ids.push(draft.workflow_id);
            }
            first
                .handle_command(
                    RequestId(9),
                    Command::CancelAgent {
                        workflow_id: ids[1],
                    },
                )
                .unwrap();
            wait_until(|| status_of(&first, ids[0]) == WorkflowStatus::Exited);
            ids
        };

        let second =
            Application::with_config(data.path(), crate::config::Config::default()).unwrap();

        for (id, expected) in ids.into_iter().zip([
            WorkflowStatus::Exited,
            WorkflowStatus::Cancelled,
            WorkflowStatus::Interrupted,
        ]) {
            let restored = second
                .snapshot()
                .unwrap()
                .workflows
                .workflows
                .into_iter()
                .find(|workflow| workflow.workflow_id == id)
                .unwrap();
            assert_eq!(restored.kind, WorkflowKind::SingleAgent);
            assert_eq!(restored.harness, Some(HarnessId::Pi));
            assert_eq!(restored.status, expected);
            assert!(restored.restored);
            assert_eq!(
                restored.terminal_id.value(),
                0,
                "agents are never relaunched"
            );
        }
    }

    #[test]
    fn starting_replaces_the_placeholder_shell_and_keeps_its_size() {
        let (folder, bin) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
        let application = application(folder.path(), bin.path(), Some("stty size; sleep 30"));
        let draft = draft(&application, folder.path());
        application
            .resize_terminal(
                draft.terminal_id,
                TerminalSize {
                    rows: 37,
                    columns: 101,
                    pixel_width: 1_010,
                    pixel_height: 740,
                },
            )
            .unwrap();

        start(&application, draft.workflow_id, "go");

        assert!(
            application
                .write_terminal_input(draft.terminal_id, b"x")
                .is_err(),
            "the draft's placeholder shell should be closed"
        );
        let mut output = Vec::new();
        wait_until(|| output_contains(&application, &mut output, "37 101"));
    }

    #[test]
    fn a_configured_agent_cannot_be_activated_as_a_terminal_and_can_still_be_cancelled() {
        let (folder, bin) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
        let application = application(folder.path(), bin.path(), Some("trap '' HUP; sleep 30"));
        let draft = draft(&application, folder.path());
        start(&application, draft.workflow_id, "go");

        let activation = application
            .handle_command(
                RequestId(4),
                Command::ActivateWorkflow {
                    workflow_id: draft.workflow_id,
                },
            )
            .unwrap();

        assert!(matches!(
            activation.disposition,
            CommandDisposition::Rejected { code, .. } if code == "workflowNotDraft"
        ));
        let agent = workflow(&application);
        assert_eq!(agent.kind, WorkflowKind::SingleAgent);
        assert_eq!(agent.harness, Some(HarnessId::Pi));
        assert_eq!(agent.status, WorkflowStatus::Running);
        let cancel = application
            .handle_command(
                RequestId(5),
                Command::CancelAgent {
                    workflow_id: draft.workflow_id,
                },
            )
            .unwrap();
        assert_eq!(cancel.disposition, CommandDisposition::Accepted);
    }

    #[test]
    fn cancelling_an_agent_that_already_exited_is_rejected_and_stays_exited() {
        let (folder, bin) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
        let application = application(folder.path(), bin.path(), Some("exit 0"));
        let draft = draft(&application, folder.path());
        start(&application, draft.workflow_id, "go");
        wait_until(|| workflow(&application).status == WorkflowStatus::Exited);

        let receipt = application
            .handle_command(
                RequestId(4),
                Command::CancelAgent {
                    workflow_id: draft.workflow_id,
                },
            )
            .unwrap();

        assert!(matches!(
            receipt.disposition,
            CommandDisposition::Rejected { code, .. } if code == "agentNotRunning"
        ));
        assert_eq!(workflow(&application).status, WorkflowStatus::Exited);
    }

    #[test]
    fn a_failed_agent_start_leaves_the_draft_and_its_shell_untouched() {
        let (folder, bin) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
        let application = application(folder.path(), bin.path(), Some("sleep 30"));
        let draft = draft(&application, folder.path());
        // The harness is found, but the folder is gone by the time the agent would start in it.
        std::fs::remove_dir_all(folder.path()).unwrap();

        let disposition = start(&application, draft.workflow_id, "go");

        assert!(matches!(
            disposition,
            CommandDisposition::Rejected { code, .. } if code == "agentStartFailed"
        ));
        assert_eq!(workflow(&application), draft);
        application
            .write_terminal_input(draft.terminal_id, b"x")
            .expect("the draft's shell should still be running");
        let stored = application
            .lock_inner()
            .unwrap()
            .folders
            .store()
            .workflows(folder.path())
            .unwrap();
        assert_eq!(stored.len(), 1);
        assert_eq!(stored[0].kind, WorkflowKind::Draft);
        assert_eq!(stored[0].harness, None);
    }
}
