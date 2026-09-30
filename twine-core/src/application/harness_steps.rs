use std::collections::{HashMap, VecDeque};
use std::ffi::OsString;
use std::time::{Duration, Instant};

use super::{Application, ApplicationError};
use crate::harness::steps::{ObservedStep, StepInbox, StepKind};
use crate::{HarnessId, TerminalId, TraceAnchor, WorkflowId};

pub(super) struct HarnessRecording {
    workflow_id: WorkflowId,
    single_agent: bool,
    inbox: StepInbox,
    pending: VecDeque<ObservedStep>,
    open_tools: HashMap<String, Option<String>>,
    ended_since: Option<Instant>,
}

const HOOK_GRACE: Duration = Duration::from_millis(1500);

impl HarnessRecording {
    fn acknowledge(&mut self, index: usize) {
        let item = self.pending.remove(index).expect("pending step exists");
        if item.step.kind == StepKind::Responded {
            self.open_tools.retain(|_, turn| turn != &item.step.turn_id);
        }
        if let Some(id) = item.step.tool_call_id {
            if item.step.kind == StepKind::ToolStarted && self.open_tools.len() < 256 {
                self.open_tools.insert(id, item.step.turn_id);
            } else if item.step.kind == StepKind::ToolFinished {
                self.open_tools.remove(&id);
            }
        }
    }

    fn next_ready(
        &self,
        store: &crate::store::Store,
        terminal_id: TerminalId,
    ) -> Result<Option<usize>, crate::StoreError> {
        for (index, item) in self.pending.iter().enumerate() {
            let step = &item.step;
            if step.kind == StepKind::Prompt {
                return Ok(Some(index));
            }
            if self.single_agent && !store.has_harness_turn(terminal_id, step.turn_id.as_deref())? {
                if let Some(prompt) = self.pending.iter().position(|other| {
                    other.step.kind == StepKind::Prompt && other.step.turn_id == step.turn_id
                }) {
                    return Ok(Some(prompt));
                }
                if item.received_at.elapsed() >= HOOK_GRACE {
                    return Ok(Some(index));
                }
                continue;
            }
            if step.kind == StepKind::ToolFinished
                && step
                    .tool_call_id
                    .as_ref()
                    .is_some_and(|id| !self.open_tools.contains_key(id))
                && item.received_at.elapsed() < HOOK_GRACE
            {
                if let Some(start) = self.pending.iter().position(|other| {
                    other.step.kind == StepKind::ToolStarted
                        && other.step.tool_call_id == step.tool_call_id
                }) {
                    return Ok(Some(start));
                }
                continue;
            }
            if step.kind == StepKind::Responded && item.received_at.elapsed() < HOOK_GRACE {
                if let Some(tool) = self.pending.iter().position(|other| {
                    other.step.turn_id == step.turn_id
                        && (other.step.kind == StepKind::ToolStarted
                            || (other.step.kind == StepKind::ToolFinished
                                && other
                                    .step
                                    .tool_call_id
                                    .as_ref()
                                    .is_none_or(|id| self.open_tools.contains_key(id))))
                }) {
                    return Ok(Some(tool));
                }
                let awaiting_tools = self.open_tools.values().any(|turn| turn == &step.turn_id)
                    || self.pending.iter().any(|other| {
                        other.step.turn_id == step.turn_id
                            && other.step.kind == StepKind::ToolFinished
                    });
                if awaiting_tools || item.received_at.elapsed() < Duration::from_millis(50) {
                    return Ok(None);
                }
            }
            return Ok(Some(index));
        }
        Ok(None)
    }
}

impl Application {
    pub(super) fn register_stage_steps(
        &self,
        workflow_id: WorkflowId,
        hooks: Vec<(TerminalId, StepInbox)>,
    ) {
        for (terminal_id, inbox) in hooks {
            if let Err(error) = self.register_harness_steps(terminal_id, workflow_id, false, inbox)
            {
                tracing::warn!(%error, "couldn't register harness step hooks");
            }
        }
    }
    /// Missing hook infrastructure degrades to the normal interactive launch.
    pub(super) fn harness_arguments(
        &self,
        harness: HarnessId,
        terminal_id: TerminalId,
        prompt: &str,
    ) -> (Vec<OsString>, Option<StepInbox>) {
        let mut arguments = Vec::new();
        let hooks = if harness == HarnessId::ClaudeCode {
            self.terminal_output
                .replay_position(terminal_id)
                .ok()
                .and_then(|position| match crate::harness::claude::prepare(position) {
                    Ok((inbox, flags)) => {
                        arguments = flags;
                        Some(inbox)
                    }
                    Err(error) => {
                        tracing::warn!(%error, "couldn't prepare harness step hooks");
                        None
                    }
                })
        } else {
            None
        };
        arguments.extend(harness.definition().arguments(prompt));
        (arguments, hooks)
    }

    pub(super) fn register_harness_steps(
        &self,
        terminal_id: TerminalId,
        workflow_id: WorkflowId,
        single_agent: bool,
        inbox: StepInbox,
    ) -> Result<(), ApplicationError> {
        let mut recordings = self
            .harness_steps
            .lock()
            .map_err(|_| ApplicationError::Poisoned)?;
        let mut inner = self.lock_inner()?;
        if single_agent {
            inner.folders.store().activate_harness_trace(terminal_id)?;
            inner.trace_spans.remove(&terminal_id);
            inner.step_terminals.insert(terminal_id, workflow_id);
            inner.publish_trace(workflow_id)?;
        }
        recordings.insert(
            terminal_id,
            HarnessRecording {
                workflow_id,
                single_agent,
                inbox,
                pending: VecDeque::new(),
                open_tools: HashMap::new(),
                ended_since: None,
            },
        );
        Ok(())
    }

    pub(super) fn poll_harness_steps(&self) -> Result<(), ApplicationError> {
        let mut recordings = self
            .harness_steps
            .lock()
            .map_err(|_| ApplicationError::Poisoned)?;
        let mut inner = self.lock_inner()?;
        for (&terminal_id, recording) in recordings.iter_mut() {
            if !inner
                .folders
                .store()
                .has_harness_workflow(recording.workflow_id)?
            {
                // Session deletion cascades the trace. Pending hooks must not recreate it.
                inner.pending_trace_endings.remove(&terminal_id);
                inner.trace_spans.remove(&terminal_id);
                recording.pending.clear();
                recording.ended_since = Instant::now().checked_sub(HOOK_GRACE);
                continue;
            }
            recording.pending.extend(
                recording
                    .inbox
                    .take(256_usize.saturating_sub(recording.pending.len())),
            );
            while let Some(index) = recording.next_ready(inner.folders.store(), terminal_id)? {
                let item = &recording.pending[index];
                let anchor = TraceAnchor {
                    terminal_id,
                    byte_offset: item.observation.byte_offset,
                    boundary_sizes: item.observation.boundary_sizes.clone(),
                };
                match inner.folders.store().record_harness_step(
                    recording.workflow_id,
                    recording.single_agent,
                    &item.step,
                    item.observation.observed_at,
                    &anchor,
                ) {
                    Ok(span) => {
                        if recording.single_agent {
                            inner.track_harness_step(terminal_id, &item.step, span)?;
                        }
                        recording.acknowledge(index);
                        if let Err(error) = inner.publish_trace(recording.workflow_id) {
                            tracing::warn!(%error, "couldn't publish harness step revision");
                        }
                    }
                    Err(error) => {
                        tracing::warn!(%error, "couldn't persist harness step");
                        break;
                    }
                }
            }
            // A full deferred batch can leave already-received steps in the inbox. Drain them
            // before retirement; the next poll persists this bounded batch.
            if recording.pending.is_empty() {
                recording.pending.extend(recording.inbox.take(256));
            }
            if inner.terminals.get(&terminal_id) != Some(&crate::TerminalStatus::Running)
                || !inner.workflows.workflows.iter().any(|w| {
                    w.workflow_id == recording.workflow_id
                        && w.status == crate::WorkflowStatus::Running
                })
            {
                recording.ended_since.get_or_insert_with(Instant::now);
            }
        }
        let closed: Vec<_> = recordings
            .iter()
            .filter(|(id, recording)| {
                recording.pending.is_empty()
                    && !inner.pending_trace_endings.contains_key(*id)
                    && recording
                        .ended_since
                        .is_some_and(|since| since.elapsed() >= HOOK_GRACE)
            })
            .map(|(&id, _)| id)
            .collect();
        let removed: Vec<_> = closed
            .iter()
            .filter_map(|id| recordings.remove(id))
            .collect();
        for id in closed {
            inner.step_terminals.remove(&id);
        }
        drop(inner);
        drop(recordings);
        drop(removed);
        Ok(())
    }
}

impl super::Inner {
    fn track_harness_step(
        &mut self,
        terminal_id: TerminalId,
        step: &crate::harness::steps::HarnessStep,
        span: Option<crate::TraceSpanId>,
    ) -> Result<(), crate::StoreError> {
        let Some(span) = span else {
            return Ok(());
        };
        if matches!(step.kind, StepKind::Prompt | StepKind::ToolStarted)
            && self.folders.store().harness_span_is_running(span)?
            && self
                .trace_spans
                .get(&terminal_id)
                .is_none_or(|current| current.0 <= span.0)
        {
            self.trace_spans.insert(terminal_id, span);
        } else if step.kind == StepKind::Responded
            && self.trace_spans.get(&terminal_id) == Some(&span)
        {
            self.trace_spans.remove(&terminal_id);
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use std::io::Write;
    use std::os::unix::fs::PermissionsExt;
    use std::path::Path;
    use std::process::{Command as ProcessCommand, Stdio};
    use std::thread;
    use std::time::{Duration, Instant};

    use serde_json::{Value, json};

    use super::*;
    use crate::config::Config;
    use crate::{
        BuiltinType, Command, CommandDisposition, CompletionSignal, Decision, RequestId,
        RoleLaunch, TerminalSize, TraceSpanStatus, Workflow, WorkflowKind, WorkflowTypeRef,
    };

    const SIZE: TerminalSize = TerminalSize {
        rows: 24,
        columns: 80,
        pixel_width: 800,
        pixel_height: 480,
    };

    fn accepted(app: &Application, command: Command) {
        assert_eq!(
            app.handle_command(RequestId(1), command)
                .unwrap()
                .disposition,
            CommandDisposition::Accepted
        );
    }

    fn setup(app: &mut Application, folder: &Path, bin: &Path) -> WorkflowId {
        let args_file = bin
            .join("arguments")
            .to_string_lossy()
            .replace('\'', "'\\''");
        let binary = bin.join("claude");
        std::fs::write(&binary, format!("#!/bin/sh\nprintf '%s\\n' \"$@\" > '{args_file}'\nprintf 'READY\\n'\nwhile read line; do printf 'OUTPUT:%s\\n' \"$line\"; done\n")).unwrap();
        std::fs::set_permissions(binary, std::fs::Permissions::from_mode(0o700)).unwrap();
        app.harness_path = Some(OsString::from(format!("{}:/usr/bin:/bin", bin.display())));
        accepted(
            app,
            Command::OpenFolder {
                path: folder.to_owned(),
            },
        );
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
        app.snapshot()
            .unwrap()
            .workflows
            .workflows
            .last()
            .unwrap()
            .workflow_id
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

    fn start_adversarial(app: &Application, id: WorkflowId) {
        let builtin = BuiltinType::Adversarial;
        let roles = builtin
            .definition()
            .roles
            .iter()
            .flat_map(|role| {
                (0..role.instances.min).map(|_| RoleLaunch {
                    role: role.id.0.clone(),
                    harness: HarnessId::ClaudeCode,
                })
            })
            .collect();
        accepted(
            app,
            Command::StartWorkflowRun {
                workflow_id: id,
                workflow_type: WorkflowTypeRef::Builtin(builtin),
                prompt: "Implement then review".into(),
                roles,
                size: SIZE,
            },
        );
    }

    fn dispatch_hook(app: &Application, terminal_id: TerminalId, payload: &Value) {
        let command = {
            let recordings = app.harness_steps.lock().unwrap();
            let recording = &recordings[&terminal_id];
            let settings: Value = serde_json::from_slice(
                &std::fs::read(recording.inbox.directory.path().join("settings.json")).unwrap(),
            )
            .unwrap();
            settings["hooks"][payload["hook_event_name"].as_str().unwrap()][0]["hooks"][0]["command"].as_str().unwrap().to_owned()
        };
        let mut child = ProcessCommand::new("/bin/sh")
            .args(["-c", &command])
            .stdin(Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(&serde_json::to_vec(payload).unwrap())
            .unwrap();
        assert!(child.wait().unwrap().success());
    }

    fn send_hook(app: &Application, terminal_id: TerminalId, payload: &Value) {
        dispatch_hook(app, terminal_id, payload);
        app.poll_harness_steps().unwrap();
        if payload["hook_event_name"] == "Stop" {
            thread::sleep(Duration::from_millis(60));
            app.poll_harness_steps().unwrap();
        }
    }

    fn start_single(app: &Application, id: WorkflowId) -> TerminalId {
        accepted(
            app,
            Command::StartAgent {
                workflow_id: id,
                harness: HarnessId::ClaudeCode,
                prompt: "Initial prompt".into(),
                size: SIZE,
            },
        );
        let terminal = workflow(app, id).terminal_id;
        wait_for_output(app, terminal, b"READY");
        terminal
    }

    #[test]
    fn async_turn_and_tool_identities_preserve_causal_order() {
        let folder = tempfile::tempdir().unwrap();
        let bin = tempfile::tempdir().unwrap();
        let mut app = Application::with_event_capacity(4096).unwrap();
        let id = setup(&mut app, folder.path(), bin.path());
        let terminal = start_single(&app, id);
        // A result precedes its prompt and start. Both are buffered until the cause is available.
        dispatch_hook(
            &app,
            terminal,
            &json!({"hook_event_name":"PostToolUse","prompt_id":"a","tool_use_id":"tool-a","tool_name":"Bash","tool_input":{"command":"make test"},"tool_response":"passed"}),
        );
        app.poll_harness_steps().unwrap();
        assert_eq!(
            app.harness_steps.lock().unwrap()[&terminal].pending.len(),
            1
        );
        dispatch_hook(
            &app,
            terminal,
            &json!({"hook_event_name":"UserPromptSubmit","prompt_id":"a","prompt":"First turn"}),
        );
        dispatch_hook(
            &app,
            terminal,
            &json!({"hook_event_name":"PreToolUse","prompt_id":"a","tool_use_id":"tool-a","tool_name":"Bash","tool_input":{"command":"make test"}}),
        );
        dispatch_hook(
            &app,
            terminal,
            &json!({"hook_event_name":"Stop","prompt_id":"a"}),
        );
        dispatch_hook(
            &app,
            terminal,
            &json!({"hook_event_name":"UserPromptSubmit","prompt_id":"b","prompt":"Second turn"}),
        );
        dispatch_hook(
            &app,
            terminal,
            &json!({"hook_event_name":"Stop","prompt_id":"b"}),
        );
        thread::sleep(Duration::from_millis(60));
        let page = app.workflow_trace(id, None, 20).unwrap();
        let first = page
            .spans
            .iter()
            .find(|span| span.title == "First turn")
            .unwrap();
        let second = page
            .spans
            .iter()
            .find(|span| span.title == "Second turn")
            .unwrap();
        assert_eq!(first.status, TraceSpanStatus::Completed);
        assert_eq!(second.status, TraceSpanStatus::Completed);
        let events = app.trace_events(first.span_id, None, 20).unwrap().events;
        assert!(events[2].message.starts_with("Run make test"));
        assert!(events[3].message.starts_with("Finished: Run make test"));
        assert!(events[4].message.starts_with("Finished responding"));
        // A's late repeated response cannot close C, the currently active turn.
        send_hook(
            &app,
            terminal,
            &json!({"hook_event_name":"UserPromptSubmit","prompt_id":"c","prompt":"Third turn"}),
        );
        send_hook(
            &app,
            terminal,
            &json!({"hook_event_name":"Stop","prompt_id":"a"}),
        );
        let page = app.workflow_trace(id, None, 20).unwrap();
        assert_eq!(page.spans[0].title, "Third turn");
        assert_eq!(page.spans[0].status, TraceSpanStatus::Running);
        assert!(page.spans[0].is_live);
    }

    #[test]
    fn a_prompt_delayed_past_cancellation_stays_stopped_after_reopening() {
        let folder = tempfile::tempdir().unwrap();
        let bin = tempfile::tempdir().unwrap();
        let data = tempfile::tempdir().unwrap();
        let mut app = Application::with_config(data.path(), Config::default()).unwrap();
        let id = setup(&mut app, folder.path(), bin.path());
        let terminal = start_single(&app, id);
        accepted(&app, Command::CancelAgent { workflow_id: id });
        send_hook(
            &app,
            terminal,
            &json!({"hook_event_name":"UserPromptSubmit","prompt_id":"late","prompt":"Delayed prompt"}),
        );
        let page = app.workflow_trace(id, None, 20).unwrap();
        assert_eq!(page.spans[0].status, TraceSpanStatus::Stopped);
        assert!(page.spans[0].ended_at.is_some());
        assert!(!page.spans[0].is_live);
        // Once the bounded grace elapses, a stopped process no longer owns an inbox or worker.
        app.harness_steps
            .lock()
            .unwrap()
            .get_mut(&terminal)
            .unwrap()
            .ended_since = Some(Instant::now().checked_sub(HOOK_GRACE).unwrap());
        app.poll_harness_steps().unwrap();
        assert!(!app.harness_steps.lock().unwrap().contains_key(&terminal));
        drop(app);
        let reopened = Application::with_config(data.path(), Config::default()).unwrap();
        assert_eq!(
            reopened.workflow_trace(id, None, 20).unwrap().spans[0].status,
            TraceSpanStatus::Stopped
        );
    }

    #[test]
    fn late_prompts_cannot_reopen_closed_or_deleted_workflows() {
        for action in ["workflow", "folder", "session"] {
            let folder = tempfile::tempdir().unwrap();
            let bin = tempfile::tempdir().unwrap();
            let mut app = Application::with_event_capacity(4096).unwrap();
            let id = setup(&mut app, folder.path(), bin.path());
            let terminal = start_single(&app, id);
            let session_id = workflow(&app, id).session_id;
            accepted(
                &app,
                match action {
                    "workflow" => Command::CloseWorkflow { workflow_id: id },
                    "folder" => Command::CloseFolder,
                    _ => Command::DeleteSession { session_id },
                },
            );
            dispatch_hook(
                &app,
                terminal,
                &json!({"hook_event_name":"UserPromptSubmit","prompt_id":"late","prompt":"Late prompt"}),
            );
            app.poll_harness_steps().unwrap();
            if action == "session" {
                assert!(!app.harness_steps.lock().unwrap().contains_key(&terminal));
                assert!(app.workflow_trace(id, None, 20).is_err());
            } else {
                let page = app.workflow_trace(id, None, 20).unwrap();
                assert_eq!(page.spans[0].title, "Late prompt");
                assert_eq!(page.spans[0].status, TraceSpanStatus::Stopped);
                assert!(!page.spans[0].is_live);
            }
        }
    }

    #[test]
    fn recording_recovers_after_missing_hooks_and_transient_store_failure() {
        let folder = tempfile::tempdir().unwrap();
        let bin = tempfile::tempdir().unwrap();
        let mut app = Application::with_event_capacity(4096).unwrap();
        let id = setup(&mut app, folder.path(), bin.path());
        let terminal = start_single(&app, id);
        let observation = app.terminals.observe(terminal).unwrap();
        {
            let mut recordings = app.harness_steps.lock().unwrap();
            let recording = recordings.get_mut(&terminal).unwrap();
            for _ in 0..256 {
                recording.pending.push_back(ObservedStep {
                    observation: observation.clone(),
                    received_at: Instant::now().checked_sub(HOOK_GRACE).unwrap(),
                    step: crate::harness::steps::HarnessStep {
                        kind: StepKind::ToolStarted,
                        turn_id: Some("missing".into()),
                        tool_call_id: None,
                        title: "Unmatched step".into(),
                        detail: String::new(),
                    },
                });
            }
        }
        dispatch_hook(
            &app,
            terminal,
            &json!({"hook_event_name":"UserPromptSubmit","prompt_id":"recovered","prompt":"Recovered prompt"}),
        );
        app.poll_harness_steps().unwrap();
        app.poll_harness_steps().unwrap();
        assert_eq!(
            app.workflow_trace(id, None, 20).unwrap().spans[0].title,
            "Recovered prompt"
        );
        send_hook(
            &app,
            terminal,
            &json!({"hook_event_name":"Stop","prompt_id":"recovered"}),
        );
        app.lock_inner().unwrap().folders.store().execute_test_sql(
            "CREATE TRIGGER reject_hooks BEFORE INSERT ON trace_events BEGIN SELECT RAISE(FAIL, 'temporary hook recording failure'); END;");
        accepted(&app, Command::CancelAgent { workflow_id: id });
        assert!(
            app.lock_inner()
                .unwrap()
                .pending_trace_endings
                .contains_key(&terminal)
        );
        app.lock_inner()
            .unwrap()
            .folders
            .store()
            .execute_test_sql("DROP TRIGGER reject_hooks");
        accepted(&app, Command::Ping);
        assert!(
            !app.lock_inner()
                .unwrap()
                .pending_trace_endings
                .contains_key(&terminal)
        );
        send_hook(
            &app,
            terminal,
            &json!({"hook_event_name":"UserPromptSubmit","prompt_id":"cancelled","prompt":"Cancelled prompt"}),
        );
        assert_eq!(
            app.workflow_trace(id, None, 20).unwrap().spans[0].status,
            TraceSpanStatus::Stopped
        );
    }

    #[test]
    fn tools_after_a_stop_hook_resume_the_same_prompt() {
        let folder = tempfile::tempdir().unwrap();
        let bin = tempfile::tempdir().unwrap();
        let mut app = Application::with_event_capacity(4096).unwrap();
        let id = setup(&mut app, folder.path(), bin.path());
        let terminal = start_single(&app, id);
        send_hook(
            &app,
            terminal,
            &json!({"hook_event_name":"UserPromptSubmit","prompt_id":"continued","prompt":"Continued prompt"}),
        );
        send_hook(
            &app,
            terminal,
            &json!({"hook_event_name":"Stop","prompt_id":"continued"}),
        );
        let span_id = app.workflow_trace(id, None, 20).unwrap().spans[0].span_id;
        send_hook(
            &app,
            terminal,
            &json!({"hook_event_name":"PreToolUse","prompt_id":"continued","tool_use_id":"followup","tool_name":"Read","tool_input":{"file_path":"src/main.rs"}}),
        );
        let page = app.workflow_trace(id, None, 20).unwrap();
        assert_eq!(page.spans[0].span_id, span_id);
        assert_eq!(page.spans[0].status, TraceSpanStatus::Running);
        assert!(page.spans[0].is_live);
        send_hook(
            &app,
            terminal,
            &json!({"hook_event_name":"PostToolUse","prompt_id":"continued","tool_use_id":"followup","tool_name":"Read","tool_input":{"file_path":"src/main.rs"},"tool_response":"contents"}),
        );
        send_hook(
            &app,
            terminal,
            &json!({"hook_event_name":"Stop","prompt_id":"continued"}),
        );
        assert_eq!(
            app.workflow_trace(id, None, 20).unwrap().spans[0].status,
            TraceSpanStatus::Completed
        );
    }

    #[test]
    fn a_rejected_close_does_not_record_a_process_stop() {
        let folder = tempfile::tempdir().unwrap();
        let bin = tempfile::tempdir().unwrap();
        let mut app = Application::with_event_capacity(4096).unwrap();
        let id = setup(&mut app, folder.path(), bin.path());
        let terminal = start_single(&app, id);
        send_hook(
            &app,
            terminal,
            &json!({"hook_event_name":"UserPromptSubmit","prompt_id":"first","prompt":"First turn"}),
        );
        send_hook(
            &app,
            terminal,
            &json!({"hook_event_name":"Stop","prompt_id":"first"}),
        );
        app.lock_inner().unwrap().folders.store().execute_test_sql("CREATE TRIGGER reject_close BEFORE UPDATE OF closed_at ON workflows BEGIN SELECT RAISE(FAIL, 'temporary close failure'); END;");
        assert!(
            app.handle_command(RequestId(2), Command::CloseWorkflow { workflow_id: id })
                .is_err()
        );
        send_hook(
            &app,
            terminal,
            &json!({"hook_event_name":"UserPromptSubmit","prompt_id":"second","prompt":"Second turn"}),
        );
        let page = app.workflow_trace(id, None, 20).unwrap();
        assert_eq!(page.spans[0].title, "Second turn");
        assert_eq!(page.spans[0].status, TraceSpanStatus::Running);
        assert!(page.spans[0].is_live);
        assert!(
            !app.trace_events(page.spans[0].span_id, None, 20)
                .unwrap()
                .events
                .iter()
                .any(|e| e.kind == crate::TraceEventKind::ProcessStopped)
        );
        app.lock_inner()
            .unwrap()
            .folders
            .store()
            .execute_test_sql("DROP TRIGGER reject_close");
    }

    fn wait_for_output(app: &Application, terminal_id: TerminalId, needle: &[u8]) {
        let deadline = Instant::now() + Duration::from_secs(5);
        let mut output = Vec::new();
        loop {
            while let Some(chunk) = app.next_terminal_chunk().unwrap() {
                if chunk.terminal_id == terminal_id {
                    output.extend(chunk.bytes);
                }
            }
            if output.windows(needle.len()).any(|part| part == needle) {
                break;
            }
            assert!(Instant::now() < deadline, "stub output timed out");
            thread::sleep(Duration::from_millis(5));
        }
    }

    #[test]
    fn claude_turns_have_ordered_steps_anchors_and_durable_history() {
        let folder = tempfile::tempdir().unwrap();
        let bin = tempfile::tempdir().unwrap();
        let data = tempfile::tempdir().unwrap();
        let user_settings = folder.path().join(".claude/settings.json");
        std::fs::create_dir(user_settings.parent().unwrap()).unwrap();
        std::fs::write(&user_settings, br#"{"hooks":{"Stop":[]},"model":"custom"}"#).unwrap();
        let before = std::fs::read(&user_settings).unwrap();
        let mut app = Application::with_config(data.path(), Config::default()).unwrap();
        let id = setup(&mut app, folder.path(), bin.path());
        accepted(
            &app,
            Command::StartAgent {
                workflow_id: id,
                harness: HarnessId::ClaudeCode,
                prompt: "-initial prompt".into(),
                size: SIZE,
            },
        );
        let terminal = workflow(&app, id).terminal_id;
        wait_for_output(&app, terminal, b"READY");
        let args = std::fs::read_to_string(bin.path().join("arguments")).unwrap();
        assert!(args.starts_with("--settings\n"));
        assert!(args.ends_with("\n--\n-initial prompt\n"));
        send_hook(
            &app,
            terminal,
            &json!({"hook_event_name":"UserPromptSubmit","prompt":"Fix src/main.rs"}),
        );
        send_hook(
            &app,
            terminal,
            &json!({"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"src/main.rs","new_string":"☃".repeat(20_000)}}),
        );
        app.write_terminal_input(terminal, b"edited file\n")
            .unwrap();
        wait_for_output(&app, terminal, b"OUTPUT:edited file");
        send_hook(
            &app,
            terminal,
            &json!({"hook_event_name":"PostToolUse","tool_name":"Edit","tool_input":{"file_path":"src/main.rs"},"tool_response":"updated"}),
        );
        send_hook(
            &app,
            terminal,
            &json!({"hook_event_name":"Stop","last_assistant_message":"Updated the file."}),
        );
        let page = app.workflow_trace(id, None, 20).unwrap();
        let span = page
            .spans
            .iter()
            .find(|s| s.title == "Fix src/main.rs")
            .unwrap();
        assert_eq!(span.status, TraceSpanStatus::Completed);
        assert!(!span.is_live);
        let span_id = span.span_id;
        let events = app.trace_events(span_id, None, 20).unwrap().events;
        assert_eq!(events.len(), 5); // Process start, prompt, edit start, edit result, response.
        assert!(events[2].message.starts_with("Edit src/main.rs\nInput:"));
        assert!(events[2].message.contains("[truncated]"));
        assert!(events[3].message.starts_with("Finished: Edit src/main.rs"));
        assert!(events[4].message.starts_with("Finished responding"));
        assert!(
            events
                .iter()
                .all(|event| event.anchor.as_ref().unwrap().terminal_id == terminal)
        );
        assert!(
            events[3].anchor.as_ref().unwrap().byte_offset
                > events[2].anchor.as_ref().unwrap().byte_offset
        );
        send_hook(
            &app,
            terminal,
            &json!({"hook_event_name":"UserPromptSubmit","prompt":"Run tests"}),
        );
        send_hook(
            &app,
            terminal,
            &json!({"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"make test"}}),
        );
        accepted(&app, Command::CancelAgent { workflow_id: id });
        let page = app.workflow_trace(id, None, 20).unwrap();
        assert_eq!(page.spans[0].title, "Run tests");
        assert_eq!(page.spans[0].status, TraceSpanStatus::Stopped);
        assert_eq!(std::fs::read(&user_settings).unwrap(), before);
        drop(app);
        let reopened = Application::with_config(data.path(), Config::default()).unwrap();
        assert_eq!(
            reopened.trace_events(span_id, None, 20).unwrap().events,
            events
        );
        assert_eq!(
            reopened.workflow_trace(id, None, 20).unwrap().spans[0].status,
            TraceSpanStatus::Stopped
        );
    }

    #[test]
    fn multi_agent_hooks_stay_in_their_assignment_across_stage_changes() {
        let folder = tempfile::tempdir().unwrap();
        let bin = tempfile::tempdir().unwrap();
        let mut app = Application::with_event_capacity(4096).unwrap();
        let id = setup(&mut app, folder.path(), bin.path());
        start_adversarial(&app, id);
        let current = workflow(&app, id);
        let agent = current
            .agents
            .iter()
            .find(|agent| agent.terminal_id.value() != 0)
            .unwrap();
        let terminal = agent.terminal_id;
        wait_for_output(&app, terminal, b"READY");
        let span = app
            .workflow_trace(id, None, 20)
            .unwrap()
            .spans
            .into_iter()
            .find(|span| span.terminal_id == Some(terminal))
            .unwrap();
        send_hook(
            &app,
            terminal,
            &json!({"hook_event_name":"UserPromptSubmit","prompt":"Implement the assignment"}),
        );
        send_hook(
            &app,
            terminal,
            &json!({"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"src/main.rs"}}),
        );
        send_hook(&app, terminal, &json!({"hook_event_name":"Stop"}));
        assert_eq!(
            app.workflow_trace(id, None, 20)
                .unwrap()
                .spans
                .iter()
                .find(|s| s.span_id == span.span_id)
                .unwrap()
                .status,
            TraceSpanStatus::Running
        );
        accepted(
            &app,
            Command::CompleteWorkflowRole {
                workflow_id: id,
                agent_id: agent.agent_id,
                generation: current.run.unwrap().generation,
                signal: CompletionSignal {
                    decision: Decision::Done,
                    summary: "Implementation ready".into(),
                    assignments: vec![],
                },
            },
        );
        // An async result from the prior process belongs to its prior assignment.
        send_hook(
            &app,
            terminal,
            &json!({"hook_event_name":"PostToolUseFailure","tool_name":"Bash",
            "tool_input":{"command":"make test"},"error":"command failed"}),
        );
        let events = app.trace_events(span.span_id, None, 30).unwrap().events;
        assert!(
            events
                .iter()
                .any(|e| e.message.starts_with("Read src/main.rs"))
        );
        assert!(
            events
                .iter()
                .any(|e| e.message.starts_with("Failed: Run make test"))
        );
        let new_terminal = workflow(&app, id)
            .agents
            .iter()
            .find(|a| a.terminal_id.value() != 0 && a.terminal_id != terminal)
            .unwrap()
            .terminal_id;
        let new_span = app
            .workflow_trace(id, None, 20)
            .unwrap()
            .spans
            .into_iter()
            .find(|s| s.terminal_id == Some(new_terminal))
            .unwrap();
        assert!(
            !app.trace_events(new_span.span_id, None, 30)
                .unwrap()
                .events
                .iter()
                .any(|e| e.message.contains("make test"))
        );
    }
}
