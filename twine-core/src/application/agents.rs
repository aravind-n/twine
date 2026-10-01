use std::path::PathBuf;
use std::sync::Arc;

use tracing::{info, warn};

use super::workflows::reject;
use super::{Application, ApplicationError, CommandDisposition, RequestId, rejection};
use crate::event::{CommandResult, EventKind, StateEvent};
use crate::harness::launch::validate_options;
use crate::harness::{
    HarnessDefinition, HarnessError, HarnessId, LocatedHarness, LoginPath, locate_in,
};
use crate::terminal::{TerminalSize, TerminalStatus};
use crate::workflow::{WorkflowId, WorkflowKind, WorkflowStatus, timestamp};

/// Finds a harness binary on `test_path` alone when tests give one, otherwise on the login
/// shell's `PATH` and then the app's.
fn locate(
    definition: &HarnessDefinition,
    test_path: Option<&std::ffi::OsStr>,
    login_path: &LoginPath,
) -> Result<LocatedHarness, HarnessError> {
    if let Some(path) = test_path {
        return locate_in(definition, Some(path), None);
    }
    // UI tests point this at a stub harness, like `TWINE_DATA_DIRECTORY` points at test data.
    if let Some(path) = std::env::var_os("TWINE_HARNESS_PATH") {
        return locate_in(definition, Some(&path), None);
    }
    locate_in(
        definition,
        login_path.get().as_deref(),
        std::env::var_os("PATH").as_deref(),
    )
}

impl Application {
    /// Finds a harness binary. The login shell's `PATH` is looked up once in the background, so
    /// this only waits on that at the first start after launch.
    pub(super) fn locate_harness(
        &self,
        definition: &HarnessDefinition,
    ) -> Result<LocatedHarness, HarnessError> {
        #[cfg(test)]
        let test_path = self.harness_path.as_deref();
        #[cfg(not(test))]
        let test_path = None;
        locate(definition, test_path, &self.login_path)
    }

    /// Starts listing the models `harness` offers, read from its own CLI on another thread, so a
    /// slow harness never holds up commands or terminals. Poll the request for the result.
    pub fn request_harness_models(
        &self,
        harness: HarnessId,
        folder: Option<PathBuf>,
    ) -> crate::ModelListRequest {
        #[cfg(test)]
        let test_path = self.harness_path.clone();
        #[cfg(not(test))]
        let test_path: Option<std::ffi::OsString> = None;
        let login_path = Arc::clone(&self.login_path);
        crate::ModelListRequest::spawn(harness, folder, move || {
            locate(harness.definition(), test_path.as_deref(), &login_path)
        })
    }

    /// The folder of a draft workflow's session, or the rejection to send if it isn't a draft.
    pub(super) fn draft_folder(
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

    /// Turns a draft workflow into a single agent: starts the harness in its own PTY, with
    /// `prompt` if there is one, then replaces the draft's placeholder shell with it.
    #[expect(
        clippy::too_many_lines,
        reason = "agent replacement keeps process, history, and trace cleanup together"
    )]
    pub(super) fn start_agent(
        &self,
        request_id: RequestId,
        workflow_id: WorkflowId,
        harness: HarnessId,
        (model, effort, yolo): (Option<&str>, Option<&str>, bool),
        prompt: &str,
        size: TerminalSize,
    ) -> Result<CommandDisposition, ApplicationError> {
        let prompt = prompt.trim();
        let Some(options) = validate_options(harness, model, effort, yolo) else {
            return Ok(reject(
                "invalidModel",
                "Choose a model and effort from the lists, or type one model name.",
            ));
        };
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
        let (arguments, hooks) = self.harness_arguments(harness, reserved, options, prompt);
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
            &arguments,
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
        workflow.kind = WorkflowKind::SingleAgent;
        workflow.restored = false;
        workflow.terminal_history.clear();
        workflow.harness = Some(harness);
        name.clone_into(&mut workflow.name);
        workflow.terminal_id = terminal_id;
        workflow.status = WorkflowStatus::Running;
        workflow.started_at = timestamp();
        workflow.ended_at = None;
        if let Err(error) = inner.start_agent_trace(
            &workflow,
            harness,
            placeholder,
            self.terminals.observe(placeholder).ok(),
            None,
        ) {
            drop(inner);
            let _ = self.terminals.close(terminal_id);
            return Err(error);
        }
        inner.terminals.remove(&placeholder);
        inner.terminals.insert(terminal_id, TerminalStatus::Running);
        inner.workflows.workflows[index] = workflow.clone();
        inner
            .events
            .append(EventKind::State(StateEvent::WorkflowChanged(workflow)))?;
        inner.events.append(EventKind::CommandCompleted {
            request_id,
            result: CommandResult::AgentStarted { workflow_id },
        })?;
        drop(inner);
        if let Some(hooks) = hooks
            && let Err(error) = self.register_harness_steps(terminal_id, workflow_id, true, hooks)
        {
            warn!(%error, "couldn't register harness step hooks");
        }
        info!(
            workflow_id = workflow_id.0,
            terminal_id = terminal_id.value(),
            harness = name,
            "agent started"
        );
        if placeholder.value() != 0 {
            // Return promptly so the UI can answer the agent's startup terminal queries before
            // they time out. Reaping the old shell includes a hang-up grace period.
            let _ = self.terminals.close_in_background(placeholder);
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
            if let Ok(observation) = self.terminals.observe(workflow.terminal_id)
                && let Err(error) = inner.stop_trace(
                    workflow.terminal_id,
                    observation,
                    "Process stopped when its agent was cancelled.",
                )
            {
                warn!(%error, "failed to record the cancelled agent's trace");
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
                    model: None,
                    effort: None,
                    yolo: false,
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
            Some(
                "while [ \"$#\" -gt 0 ] && [ \"$1\" != -- ]; do shift; done; printf 'ARGS:%s|%s\\n' \"$1\" \"$2\"; read line; echo \"GOT:$line\"; exit 3",
            ),
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
        let trace = application
            .workflow_trace(draft.workflow_id, None, 10)
            .unwrap();
        assert_eq!(trace.spans.len(), 1);
        let agent_span = trace
            .spans
            .iter()
            .find(|span| span.terminal_id == Some(agent.terminal_id))
            .unwrap();
        assert_eq!(agent_span.status, crate::TraceSpanStatus::Exited);
        assert!(!agent_span.is_live);
        let lane = trace
            .lanes
            .iter()
            .find(|lane| lane.lane_id == agent_span.lane_id)
            .unwrap();
        assert!(lane.is_agent);
        assert_eq!(lane.role.as_deref(), Some("agent"));
        assert_eq!(lane.harness.as_deref(), Some("pi"));
        let events = application
            .trace_events(agent_span.span_id, None, 10)
            .unwrap()
            .events;
        assert_eq!(events.len(), 2);
        assert_eq!(events[0].kind, crate::TraceEventKind::ProcessStarted);
        assert_eq!(events[1].kind, crate::TraceEventKind::ProcessExited);
        assert!(events[1].message.contains("code 3"));
        assert!(events[1].anchor.as_ref().unwrap().byte_offset > 0);
        assert!(
            events
                .iter()
                .all(|event| !event.message.contains("fix it") && !event.message.contains("GOT:"))
        );
        assert!(
            trace
                .spans
                .iter()
                .all(|span| span.terminal_id != Some(draft.terminal_id))
        );
        assert!(trace.lanes.iter().all(|lane| lane.is_agent));
    }

    #[test]
    fn an_agent_started_from_a_restored_draft_keeps_live_terminal_ownership() {
        let (folder, bin) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
        let app = application(folder.path(), bin.path(), Some("read line"));
        let original = draft(&app, folder.path());
        app.handle_command(RequestId(20), Command::CloseFolder)
            .unwrap();
        app.handle_command(
            RequestId(21),
            Command::OpenFolder {
                path: folder.path().to_owned(),
            },
        )
        .unwrap();
        assert!(workflow(&app).restored);
        assert_eq!(
            start(&app, original.workflow_id, ""),
            CommandDisposition::Accepted
        );
        let live = workflow(&app);
        assert!(!live.restored);
        assert_eq!(live.terminal_history, []);
        assert_eq!(live.terminal_ids(), vec![live.terminal_id]);
        app.write_terminal_input(live.terminal_id, b"exit\n")
            .unwrap();
        wait_until(|| workflow(&app).status == WorkflowStatus::Exited);
        app.handle_command(
            RequestId(22),
            Command::CloseWorkflow {
                workflow_id: live.workflow_id,
            },
        )
        .unwrap();
        assert!(
            app.write_terminal_input(live.terminal_id, b"late\n")
                .is_err()
        );
    }

    #[test]
    fn antigravity_starts_interactively_with_options_and_accepts_follow_up_input() {
        for prompt in ["", "-fix it\nKeep the terminal open"] {
            let (folder, bin) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
            let application = application(
                folder.path(),
                bin.path(),
                Some(
                    "printf 'ARG:%s\\n' \"$@\"; echo READY; IFS= read -r line; printf 'GOT:%s\\n' \"$line\"",
                ),
            );
            std::fs::rename(bin.path().join("pi"), bin.path().join("agy")).unwrap();
            let draft = draft(&application, folder.path());
            assert_eq!(
                application
                    .handle_command(
                        RequestId(3),
                        Command::StartAgent {
                            workflow_id: draft.workflow_id,
                            harness: HarnessId::Antigravity,
                            model: Some("gemini-3.8-flash-high".into()),
                            effort: Some("high".into()),
                            yolo: true,
                            prompt: prompt.into(),
                            size: SIZE,
                        },
                    )
                    .unwrap()
                    .disposition,
                CommandDisposition::Accepted
            );
            let agent = workflow(&application);
            assert_eq!(agent.harness, Some(HarnessId::Antigravity));
            assert_eq!(agent.name, "Antigravity");
            let mut output = Vec::new();
            wait_until(|| output_contains(&application, &mut output, "READY"));
            let arguments = String::from_utf8_lossy(&output);
            for argument in [
                "--dangerously-skip-permissions",
                "--model",
                "gemini-3.8-flash-high",
                "--effort",
                "high",
            ] {
                assert!(arguments.contains(&format!("ARG:{argument}\r\n")));
            }
            if prompt.is_empty() {
                assert!(!arguments.contains("--prompt-interactive"));
            } else {
                assert!(
                    arguments
                        .contains("ARG:--prompt-interactive=-fix it\r\nKeep the terminal open")
                );
            }
            assert!(!arguments.contains("ARG:--print"));
            application
                .write_terminal_input(agent.terminal_id, b"follow up\n")
                .unwrap();
            wait_until(|| output_contains(&application, &mut output, "GOT:follow up"));
            wait_until(|| workflow(&application).status == WorkflowStatus::Exited);
            let trace = application
                .workflow_trace(draft.workflow_id, None, 10)
                .unwrap();
            let lane = trace.lanes.iter().find(|lane| lane.is_agent).unwrap();
            assert_eq!(lane.harness.as_deref(), Some("Antigravity"));
            let span = trace
                .spans
                .iter()
                .find(|span| span.lane_id == lane.lane_id)
                .unwrap();
            assert_eq!(span.status, crate::TraceSpanStatus::Exited);
            assert_eq!(
                trace.spans.len(),
                1,
                "The lifecycle span remains without prompt hooks"
            );
        }
    }

    #[test]
    fn omp_launch_keeps_prompts_literal_and_accepts_follow_up_input() {
        for prompt in ["", "models", "@README.md", "-fix it"] {
            let (folder, bin) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
            let application = application(
                folder.path(),
                bin.path(),
                Some(
                    "printf 'ARG:%s\\n' \"$@\"; echo READY; IFS= read -r line; printf 'GOT:%s\\n' \"$line\"",
                ),
            );
            std::fs::rename(bin.path().join("pi"), bin.path().join("omp")).unwrap();
            let draft = draft(&application, folder.path());
            assert_eq!(
                application
                    .handle_command(
                        RequestId(3),
                        Command::StartAgent {
                            workflow_id: draft.workflow_id,
                            harness: HarnessId::Omp,
                            model: Some("local/model".into()),
                            effort: Some("high".into()),
                            yolo: true,
                            prompt: prompt.into(),
                            size: SIZE,
                        }
                    )
                    .unwrap()
                    .disposition,
                CommandDisposition::Accepted
            );
            let agent = workflow(&application);
            assert_eq!(agent.harness, Some(HarnessId::Omp));
            let mut output = Vec::new();
            wait_until(|| output_contains(&application, &mut output, "READY"));
            let arguments = String::from_utf8_lossy(&output);
            assert!(arguments.starts_with("ARG:launch\r\nARG:--extension\r\n"));
            for argument in [
                "--auto-approve",
                "--model",
                "local/model",
                "--thinking",
                "high",
            ] {
                assert!(arguments.contains(&format!("ARG:{argument}\r\n")));
            }
            if prompt.is_empty() {
                assert!(!arguments.contains("ARG:--\r\n"));
            } else {
                assert!(arguments.contains(&format!("ARG:--\r\nARG:{prompt}\r\n")));
            }
            assert!(!arguments.contains("ARG:--print"));
            application
                .write_terminal_input(agent.terminal_id, b"follow up\n")
                .unwrap();
            wait_until(|| output_contains(&application, &mut output, "GOT:follow up"));
            wait_until(|| workflow(&application).status == WorkflowStatus::Exited);
        }
    }

    #[test]
    fn opencode_launch_is_interactive_with_literal_prompts_model_variants_and_lifecycle_traces() {
        for prompt in [
            "",
            "models",
            "@README.md",
            "-fix it\nKeep the terminal open",
        ] {
            let (folder, bin) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
            let application = application(
                folder.path(),
                bin.path(),
                Some(
                    "printf 'ARG:%s\\n' \"$@\"; echo READY; IFS= read -r line; printf 'GOT:%s\\n' \"$line\"",
                ),
            );
            std::fs::rename(bin.path().join("pi"), bin.path().join("opencode")).unwrap();
            let draft = draft(&application, folder.path());
            assert_eq!(
                application
                    .handle_command(
                        RequestId(3),
                        Command::StartAgent {
                            workflow_id: draft.workflow_id,
                            harness: HarnessId::Opencode,
                            model: Some("local/model".into()),
                            effort: Some("high".into()),
                            yolo: false,
                            prompt: prompt.into(),
                            size: SIZE,
                        }
                    )
                    .unwrap()
                    .disposition,
                CommandDisposition::Accepted
            );
            let agent = workflow(&application);
            assert_eq!(agent.harness, Some(HarnessId::Opencode));
            assert_eq!(agent.name, "OpenCode");
            let mut output = Vec::new();
            wait_until(|| output_contains(&application, &mut output, "READY"));
            let expected = if prompt.is_empty() {
                "ARG:mini\r\nARG:--standalone\r\nARG:--model\r\nARG:local/model#high\r\nREADY\r\n"
                    .to_owned()
            } else {
                format!(
                    "ARG:mini\r\nARG:--standalone\r\nARG:--model\r\nARG:local/model#high\r\nARG:--prompt={}\r\nREADY\r\n",
                    prompt.replace('\n', "\r\n")
                )
            };
            assert_eq!(String::from_utf8_lossy(&output), expected);
            application
                .write_terminal_input(agent.terminal_id, b"follow up\n")
                .unwrap();
            wait_until(|| output_contains(&application, &mut output, "GOT:follow up"));
            wait_until(|| workflow(&application).status == WorkflowStatus::Exited);
            let trace = application
                .workflow_trace(draft.workflow_id, None, 10)
                .unwrap();
            assert_eq!(trace.spans.len(), 1);
            let lane = trace.lanes.iter().find(|lane| lane.is_agent).unwrap();
            assert_eq!(lane.harness.as_deref(), Some("OpenCode"));
            let span = trace
                .spans
                .iter()
                .find(|span| span.lane_id == lane.lane_id)
                .unwrap();
            assert_eq!(span.status, crate::TraceSpanStatus::Exited);
        }
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
    fn an_agent_without_a_prompt_starts_interactively_and_only_from_a_draft() {
        let (folder, bin) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
        let application = application(
            folder.path(),
            bin.path(),
            Some(
                "for a in \"$@\"; do [ \"$a\" = -- ] && echo SEPARATOR; done; echo ARGS-DONE; sleep 30",
            ),
        );
        let draft = draft(&application, folder.path());

        assert_eq!(
            start(&application, draft.workflow_id, "   "),
            CommandDisposition::Accepted
        );
        // Hook flags may still be passed, but no prompt separator or prompt follows them.
        let mut output = Vec::new();
        wait_until(|| output_contains(&application, &mut output, "ARGS-DONE"));
        assert!(!String::from_utf8_lossy(&output).contains("SEPARATOR"));
        assert!(matches!(
            start(&application, draft.workflow_id, "again"),
            CommandDisposition::Rejected { code, .. } if code == "workflowNotDraft"
        ));
    }

    #[test]
    fn the_agent_starts_with_its_chosen_model_and_effort_and_rejects_a_flag_as_a_model() {
        let (folder, bin) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
        let application = application(
            folder.path(),
            bin.path(),
            Some("printf 'ARGS:%s\\n' \"$*\"; sleep 30"),
        );
        let draft = draft(&application, folder.path());
        let start_with = |model: &str, effort: &str| {
            application
                .handle_command(
                    RequestId(3),
                    Command::StartAgent {
                        workflow_id: draft.workflow_id,
                        harness: HarnessId::Pi,
                        model: Some(model.to_owned()),
                        effort: Some(effort.to_owned()),
                        // pi has no permission prompts, so this adds no flag.
                        yolo: true,
                        prompt: String::new(),
                        size: SIZE,
                    },
                )
                .unwrap()
                .disposition
        };

        assert!(matches!(
            start_with("--help", "high"),
            CommandDisposition::Rejected { code, .. } if code == "invalidModel"
        ));
        assert!(matches!(
            start_with("local/m1", "High"),
            CommandDisposition::Rejected { code, .. } if code == "invalidModel"
        ));
        assert_eq!(
            start_with(" local/m1 ", "high"),
            CommandDisposition::Accepted
        );
        let mut output = Vec::new();
        wait_until(|| {
            output_contains(
                &application,
                &mut output,
                "--model local/m1 --thinking high",
            )
        });
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
        let trace = application
            .workflow_trace(draft.workflow_id, None, 10)
            .unwrap();
        let span = trace
            .spans
            .iter()
            .find(|span| span.terminal_id == Some(terminal_id))
            .unwrap();
        assert_eq!(span.status, crate::TraceSpanStatus::Stopped);
        let events = application
            .trace_events(span.span_id, None, 10)
            .unwrap()
            .events;
        assert_eq!(
            events.len(),
            2,
            "the exit callback must not add a second ending"
        );
        assert_eq!(events[1].kind, crate::TraceEventKind::ProcessStopped);
        assert!(events[1].message.contains("cancelled"));
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
                "#!/bin/sh\nwhile [ \"$#\" -gt 0 ] && [ \"$1\" != -- ]; do shift; done\ncase \"$2\" in exit) exit 0;; *) trap '' HUP; sleep 30;; esac\n",
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
            let trace = second.workflow_trace(id, None, 10).unwrap();
            assert_eq!(trace.spans.len(), 1);
            let lane = trace.lanes.iter().find(|lane| lane.is_agent).unwrap();
            assert_eq!(lane.harness.as_deref(), Some("pi"));
            let span = trace
                .spans
                .iter()
                .find(|span| span.lane_id == lane.lane_id)
                .unwrap();
            assert_eq!(
                span.status,
                if expected == WorkflowStatus::Exited {
                    crate::TraceSpanStatus::Exited
                } else {
                    crate::TraceSpanStatus::Stopped
                }
            );
            assert!(!span.is_live);
            assert_eq!(
                second
                    .trace_events(span.span_id, None, 10)
                    .unwrap()
                    .events
                    .len(),
                2
            );
            assert_eq!(Some(restored.terminal_id), span.terminal_id);
            assert!(
                restored.terminal_ids().is_empty(),
                "agents are never relaunched"
            );
            assert_eq!(
                restored.terminal_history.last().unwrap().terminal_id,
                restored.terminal_id
            );
        }
    }

    #[test]
    fn a_failed_agent_start_trace_keeps_the_draft_and_rolls_back_its_shell_ending() {
        let (folder, bin) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
        let application = application(folder.path(), bin.path(), Some("sleep 30"));
        let draft = draft(&application, folder.path());
        application.lock_inner().unwrap().folders.store().execute_test_sql(
            "CREATE TRIGGER reject_start BEFORE INSERT ON trace_events WHEN NEW.kind = 'processStarted' BEGIN SELECT RAISE(FAIL, 'test start failure'); END;"
        );
        assert!(
            application
                .handle_command(
                    RequestId(3),
                    Command::StartAgent {
                        model: None,
                        effort: None,
                        yolo: false,
                        workflow_id: draft.workflow_id,
                        harness: HarnessId::Pi,
                        prompt: "go".to_owned(),
                        size: SIZE,
                    }
                )
                .is_err()
        );
        assert_eq!(workflow(&application), draft);
        let stored = application
            .lock_inner()
            .unwrap()
            .folders
            .read_store()
            .workflows(folder.path())
            .unwrap();
        assert_eq!(stored[0].kind, WorkflowKind::Draft);
        assert_eq!(stored[0].harness, None);
        let trace = application
            .workflow_trace(draft.workflow_id, None, 10)
            .unwrap();
        assert_eq!(trace.spans, []);
        assert_eq!(trace.lanes, []);
        let history = application
            .lock_inner()
            .unwrap()
            .folders
            .store()
            .terminal_history(draft.workflow_id)
            .unwrap();
        assert_eq!(history.len(), 1);
        assert_eq!(history[0].terminal_id, draft.terminal_id);
        assert_eq!(application.snapshot().unwrap().terminals.len(), 1);
        assert!(
            application
                .terminals
                .size(crate::TerminalId::from_value(draft.terminal_id.value() + 1))
                .is_none()
        );
        application
            .write_terminal_input(draft.terminal_id, b"echo alive\n")
            .unwrap();
    }

    #[test]
    fn a_failed_cancel_trace_still_stops_the_agent_and_retries_the_cancellation() {
        let (folder, bin) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
        let application = application(
            folder.path(),
            bin.path(),
            Some("trap '' HUP; echo ready; while :; do sleep 1; done"),
        );
        let draft = draft(&application, folder.path());
        start(&application, draft.workflow_id, "go");
        let agent = workflow(&application);
        let mut output = Vec::new();
        wait_until(|| output_contains(&application, &mut output, "ready"));
        application.lock_inner().unwrap().folders.store().execute_test_sql(
            "CREATE TRIGGER reject_trace BEFORE INSERT ON trace_events BEGIN SELECT RAISE(FAIL, 'test recording failure'); END;"
        );
        application
            .handle_command(
                RequestId(4),
                Command::CancelAgent {
                    workflow_id: draft.workflow_id,
                },
            )
            .unwrap();
        wait_until(|| {
            application
                .snapshot()
                .unwrap()
                .terminals
                .iter()
                .any(|terminal| {
                    terminal.terminal_id == agent.terminal_id
                        && matches!(terminal.status, TerminalStatus::Exited(_))
                })
        });
        assert_eq!(workflow(&application).status, WorkflowStatus::Cancelled);
        assert_eq!(
            application
                .lock_inner()
                .unwrap()
                .pending_trace_endings
                .len(),
            1
        );
        application
            .lock_inner()
            .unwrap()
            .folders
            .store()
            .execute_test_sql("DROP TRIGGER reject_trace");
        application
            .handle_command(RequestId(5), Command::Ping)
            .unwrap();
        let trace = application
            .workflow_trace(draft.workflow_id, None, 10)
            .unwrap();
        let span = trace
            .spans
            .iter()
            .find(|span| span.terminal_id == Some(agent.terminal_id))
            .unwrap();
        assert_eq!(span.status, crate::TraceSpanStatus::Stopped);
        let events = application
            .trace_events(span.span_id, None, 10)
            .unwrap()
            .events;
        assert_eq!(events.len(), 2);
        assert_eq!(events[1].kind, crate::TraceEventKind::ProcessStopped);
        assert!(events[1].message.contains("cancelled"));
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
