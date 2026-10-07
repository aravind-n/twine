use std::collections::{HashMap, HashSet, VecDeque};
use std::ffi::OsString;
use std::time::{Duration, Instant};

use super::{Application, ApplicationError};
use crate::harness::steps::{ObservedStep, StepInbox, StepKind};
use crate::{HarnessId, TerminalId, TraceAnchor, WorkflowId};

pub(super) struct HarnessRecording {
    workflow_id: WorkflowId,
    single_agent: bool,
    active: bool,
    inbox: StepInbox,
    pending: VecDeque<ObservedStep>,
    open_tools: HashMap<String, Option<String>>,
    ended_since: Option<Instant>,
    session_observed_at: Option<Instant>,
    has_session_start: bool,
    turns: AssignmentTurns,
}

#[derive(Default)]
struct AssignmentTurns {
    /// Live processes retain earlier assignment turns so delayed hooks stay in their round.
    spans: HashMap<String, crate::TraceSpanId>,
    order: VecDeque<String>,
    active: HashMap<String, crate::TraceSpanId>,
    completed: HashSet<String>,
    unidentified: bool,
}

const HOOK_GRACE: Duration = Duration::from_millis(1500);

impl HarnessRecording {
    /// Session identity follows receipt order, independent of causal reordering of trace steps.
    /// Once a session-start is known, late tool hooks from an earlier conversation cannot replace it.
    fn capture_session(
        &mut self,
        store: &crate::store::Store,
        terminal: TerminalId,
    ) -> Result<(), crate::StoreError> {
        let has_start = self.has_session_start
            || self.pending.iter().any(|item| {
                item.step.kind == StepKind::SessionStarted && item.step.session_id.is_some()
            });
        let candidate = self
            .pending
            .iter()
            .filter(|item| {
                item.step.kind != StepKind::Activity
                    && item.step.session_id.is_some()
                    && (!has_start || item.step.kind == StepKind::SessionStarted)
            })
            .max_by_key(|item| item.received_at);
        if let Some(item) = candidate
            && self
                .session_observed_at
                .is_none_or(|time| item.received_at > time)
        {
            store.remember_harness_session(
                terminal,
                item.step.session_id.as_deref().expect("has session"),
            )?;
            self.session_observed_at = Some(item.received_at);
            self.has_session_start = has_start;
        }
        Ok(())
    }

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
            if matches!(step.kind, StepKind::Prompt | StepKind::SessionStarted) {
                return Ok(Some(index));
            }
            if (self.single_agent
                && (!self.active
                    || !store.has_harness_turn(terminal_id, step.turn_id.as_deref())?))
                || (!self.single_agent
                    && step
                        .turn_id
                        .as_ref()
                        .is_some_and(|turn| !self.turns.spans.contains_key(turn)))
            {
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
    pub(super) fn harness_turn_finished(
        &self,
        terminal: TerminalId,
    ) -> Result<bool, ApplicationError> {
        let recordings = self
            .harness_steps
            .lock()
            .map_err(|_| ApplicationError::Poisoned)?;
        Ok(recordings.get(&terminal).is_some_and(|r| {
            !r.turns.unidentified
                && !r.turns.spans.is_empty()
                && r.turns.active.is_empty()
                && r.pending.is_empty()
        }))
    }

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
        options: crate::harness::launch::LaunchOptions<'_>,
        prompt: &str,
    ) -> (Vec<OsString>, Option<StepInbox>) {
        let mut arguments: Vec<OsString> = harness
            .definition()
            .subcommand
            .map(OsString::from)
            .into_iter()
            .collect();
        let hooks = {
            self.terminal_output
                .replay_position(terminal_id)
                .ok()
                .and_then(|position| {
                    match match harness {
                        HarnessId::ClaudeCode => crate::harness::claude::prepare(position),
                        HarnessId::Codex => crate::harness::codex::prepare(position),
                        HarnessId::Pi | HarnessId::Omp => {
                            crate::harness::pi::prepare(position, harness)
                        }
                        HarnessId::Antigravity => crate::harness::antigravity::prepare(position),
                        // This CLI has no launch-only plugin flag; preserve user/folder config.
                        HarnessId::Opencode => return None,
                    } {
                        Ok((inbox, flags)) => {
                            arguments.extend(flags);
                            Some(inbox)
                        }
                        Err(error) => {
                            tracing::warn!(%error, "couldn't prepare harness step hooks");
                            None
                        }
                    }
                })
        };
        arguments.extend(crate::harness::launch::launch_arguments(harness, options));
        // Without a prompt the harness opens interactively and waits for the user.
        if !prompt.is_empty() {
            arguments.extend(harness.definition().arguments(prompt));
        }
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
        recordings.insert(
            terminal_id,
            HarnessRecording {
                workflow_id,
                single_agent,
                active: !single_agent,
                inbox,
                pending: VecDeque::new(),
                open_tools: HashMap::new(),
                ended_since: None,
                session_observed_at: None,
                has_session_start: false,
                turns: AssignmentTurns::default(),
            },
        );
        Ok(())
    }

    #[expect(
        clippy::too_many_lines,
        reason = "session capture and step lifecycle commit in the same ordered polling loop"
    )]
    pub(super) fn poll_harness_steps(&self) -> Result<(), ApplicationError> {
        let mut recordings = self
            .harness_steps
            .lock()
            .map_err(|_| ApplicationError::Poisoned)?;
        let mut inner = self.lock_inner()?;
        let mut activations = Vec::new();
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
            recording.capture_session(inner.folders.store(), terminal_id)?;
            while let Some(index) = recording.next_ready(inner.folders.store(), terminal_id)? {
                let item = &recording.pending[index];
                if item.step.kind == StepKind::SessionStarted {
                    recording.acknowledge(index);
                    continue;
                }
                // Keep the fallback until a prompt is durably recorded. Unavailable hooks
                // and failed first-prompt writes must leave the ordinary agent trace intact.
                if !recording.active && item.step.kind != StepKind::Prompt {
                    recording.acknowledge(index);
                    continue;
                }
                let anchor = TraceAnchor {
                    terminal_id,
                    byte_offset: item.observation.byte_offset,
                    boundary_sizes: item.observation.boundary_sizes.clone(),
                };
                match inner.folders.store().record_harness_step(
                    crate::store::HarnessStepContext {
                        workflow_id: recording.workflow_id,
                        single_agent: recording.single_agent,
                        activate: recording.single_agent && !recording.active,
                        span: item
                            .step
                            .turn_id
                            .as_ref()
                            .and_then(|turn| recording.turns.spans.get(turn))
                            .copied(),
                    },
                    &item.step,
                    item.observation.observed_at,
                    &anchor,
                ) {
                    Ok(span) => {
                        if !recording.single_agent {
                            if item.step.kind == StepKind::Prompt && item.step.turn_id.is_none() {
                                recording.turns.unidentified = true;
                            }
                            if item.step.kind == StepKind::Prompt
                                && let (Some(turn), Some(span)) = (&item.step.turn_id, span)
                                && !recording.turns.completed.contains(turn)
                                && recording.turns.active.len() < 256
                            {
                                recording.turns.active.insert(turn.clone(), span);
                            } else if item.step.kind == StepKind::Responded
                                && let Some(turn) = &item.step.turn_id
                            {
                                recording.turns.active.remove(turn);
                                if recording.turns.spans.contains_key(turn) {
                                    recording.turns.completed.insert(turn.clone());
                                }
                            }
                        }
                        if !recording.single_agent
                            && item.step.kind == StepKind::Prompt
                            && let (Some(turn), Some(span)) = (&item.step.turn_id, span)
                            && !recording.turns.spans.contains_key(turn)
                        {
                            if recording.turns.order.len() == 256
                                && let Some(oldest) = recording.turns.order.pop_front()
                            {
                                recording.turns.spans.remove(&oldest);
                                recording.turns.completed.remove(&oldest);
                            }
                            recording.turns.order.push_back(turn.clone());
                            recording.turns.spans.insert(turn.clone(), span);
                        }
                        if !recording.active && span.is_some() {
                            if recording.single_agent {
                                inner.trace_spans.remove(&terminal_id);
                            }
                            inner
                                .step_terminals
                                .insert(terminal_id, recording.workflow_id);
                            recording.active = true;
                        }
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
            if let Some(workflow) = inner
                .workflows
                .workflows
                .iter()
                .find(|w| w.workflow_id == recording.workflow_id)
                && let Some(run) = &workflow.run
                && run.status == crate::RunStatus::Running
                && let Some(agent) = workflow
                    .agents
                    .iter()
                    .find(|a| a.terminal_id == terminal_id)
                && run
                    .active_agents()
                    .iter()
                    .any(|active| active.agent_id == agent.agent_id.0)
            {
                let ready = !recording.turns.unidentified
                    && !recording.turns.active.is_empty()
                    && inner.trace_spans.get(&terminal_id).is_some_and(|current| {
                        recording.turns.active.values().all(|span| span == current)
                    });
                activations.push((workflow.workflow_id, agent.agent_id, run.generation, ready));
            }
            // A full deferred batch can leave already-received steps in the inbox. Drain them
            // before retirement; the next poll persists this bounded batch.
            if recording.pending.is_empty() {
                recording.pending.extend(recording.inbox.take(256));
            }
            if inner.terminals.get(&terminal_id) != Some(&crate::TerminalStatus::Running)
                || !inner
                    .workflows
                    .workflows
                    .iter()
                    .any(|w| w.workflow_id == recording.workflow_id)
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
        for (workflow, agent, generation, ready) in activations {
            self.activate_workflow_completion(workflow, agent, generation, ready)?;
        }
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
        std::fs::write(&binary, format!("#!/bin/sh\nprintf '%s\\n' \"$@\" > '{args_file}'\nprintf '%s\\n' \"$CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN\" > '{args_file}.renderer'\nprintf 'READY\\n'\nwhile read line; do printf 'OUTPUT:%s\\n' \"$line\"; done\n")).unwrap();
        std::fs::set_permissions(&binary, std::fs::Permissions::from_mode(0o700)).unwrap();
        std::fs::copy(&binary, bin.join("codex")).unwrap();
        std::fs::copy(&binary, bin.join("pi")).unwrap();
        std::fs::copy(&binary, bin.join("agy")).unwrap();
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
        start_adversarial_with_harness(app, id, HarnessId::ClaudeCode);
    }

    fn start_adversarial_with_harness(app: &Application, id: WorkflowId, harness: HarnessId) {
        let builtin = BuiltinType::Adversarial;
        let roles = builtin
            .definition()
            .roles
            .iter()
            .flat_map(|role| {
                (0..role.instances.min).map(|_| RoleLaunch {
                    model: None,
                    effort: None,
                    yolo: false,
                    role: role.id.0.clone(),
                    harness,
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
            recording.inbox.hook_command()
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
        if payload["hook_event_name"] == "Stop" || payload["type"] == "response" {
            thread::sleep(Duration::from_millis(60));
            app.poll_harness_steps().unwrap();
        }
    }

    fn start_single(app: &Application, id: WorkflowId) -> TerminalId {
        accepted(
            app,
            Command::StartAgent {
                model: None,
                effort: None,
                yolo: false,
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

    fn start_pi(app: &Application, id: WorkflowId) -> TerminalId {
        accepted(
            app,
            Command::StartAgent {
                model: None,
                effort: None,
                yolo: false,
                workflow_id: id,
                harness: HarnessId::Pi,
                prompt: "Initial prompt".into(),
                size: SIZE,
            },
        );
        let terminal = workflow(app, id).terminal_id;
        wait_for_output(app, terminal, b"READY");
        terminal
    }

    fn start_antigravity(app: &Application, id: WorkflowId) -> TerminalId {
        accepted(
            app,
            Command::StartAgent {
                model: None,
                effort: None,
                yolo: false,
                workflow_id: id,
                harness: HarnessId::Antigravity,
                prompt: "Initial prompt".into(),
                size: SIZE,
            },
        );
        let terminal = workflow(app, id).terminal_id;
        wait_for_output(app, terminal, b"READY");
        terminal
    }

    fn assert_pi_arguments(bin: &Path, folder: &Path) -> std::path::PathBuf {
        let arguments = std::fs::read_to_string(bin.join("arguments")).unwrap();
        let arguments: Vec<_> = arguments.lines().collect();
        assert_eq!(arguments[0], "--extension");
        let extension = Path::new(arguments[1]);
        assert!(extension.is_file());
        assert!(!extension.starts_with(folder));
        assert_eq!(
            &arguments[2..],
            ["--tui-mode", "regular", "--", "Initial prompt"]
        );
        assert!(
            !std::fs::read_to_string(extension)
                .unwrap()
                .contains("__TWINE_SOCKET__")
        );
        extension.to_owned()
    }

    fn assert_pi_trace_events(app: &Application, span: crate::TraceSpanId, terminal: TerminalId) {
        let events = app.trace_events(span, None, 30).unwrap().events;
        let titles: Vec<_> = events
            .iter()
            .skip(1)
            .map(|event| event.message.lines().next().unwrap())
            .collect();
        assert_eq!(
            titles,
            [
                "Read the file",
                "Read src/main.rs",
                "Finished: Read src/main.rs",
                "Run make test",
                "Failed: Run make test",
                "Finished responding"
            ]
        );
        assert!(
            events
                .iter()
                .all(|event| event.anchor.as_ref().unwrap().terminal_id == terminal)
        );
        assert!(
            events[4].anchor.as_ref().unwrap().byte_offset
                > events[1].anchor.as_ref().unwrap().byte_offset
        );
    }

    #[test]
    fn old_session_tools_cannot_replace_a_new_session_start() {
        let folder = tempfile::tempdir().unwrap();
        let bin = tempfile::tempdir().unwrap();
        let mut app = Application::with_event_capacity(4096).unwrap();
        let id = setup(&mut app, folder.path(), bin.path());
        let terminal = start_single(&app, id);
        let observation = app.terminals.observe(terminal).unwrap();
        let mut recordings = app.harness_steps.lock().unwrap();
        let recording = recordings.get_mut(&terminal).unwrap();
        let mut inner = app.lock_inner().unwrap();
        let mut old =
            crate::harness::steps::HarnessStep::session_started(&json!("old-session")).unwrap();
        old.kind = StepKind::ToolFinished;
        let now = Instant::now();
        recording.pending.push_back(ObservedStep {
            step: old.clone(),
            observation: observation.clone(),
            received_at: now.checked_sub(HOOK_GRACE).unwrap(),
        });
        recording.pending.push_back(ObservedStep {
            step: crate::harness::steps::HarnessStep::session_started(&json!("new-session"))
                .unwrap(),
            observation: observation.clone(),
            received_at: now,
        });
        recording
            .capture_session(inner.folders.store(), terminal)
            .unwrap();
        recording.pending.pop_back();
        recording.pending.push_back(ObservedStep {
            step: old,
            observation,
            received_at: now + Duration::from_millis(1),
        });
        recording
            .capture_session(inner.folders.store(), terminal)
            .unwrap();
        assert_eq!(
            inner
                .folders
                .store()
                .harness_session(terminal)
                .unwrap()
                .as_deref(),
            Some("new-session")
        );
    }

    #[test]
    fn pi_turns_have_ordered_steps_anchors_and_durable_history() {
        let folder = tempfile::tempdir().unwrap();
        let bin = tempfile::tempdir().unwrap();
        let data = tempfile::tempdir().unwrap();
        let settings = folder.path().join(".pi/settings.json");
        std::fs::create_dir(settings.parent().unwrap()).unwrap();
        std::fs::write(&settings, r#"{"extensions":["./existing.js"]}"#).unwrap();
        let mut app = Application::with_config(data.path(), Config::default()).unwrap();
        let id = setup(&mut app, folder.path(), bin.path());
        let terminal = start_pi(&app, id);
        let extension = assert_pi_arguments(bin.path(), folder.path());
        // Results arriving before their prompt/start use the same recorder as other harnesses.
        dispatch_hook(
            &app,
            terminal,
            &json!({"type":"tool_end", "turn_id":"first",
            "tool_call_id":"read", "tool_name":"read", "target":"src/main.rs", "detail":"file contents"}),
        );
        send_hook(
            &app,
            terminal,
            &json!({"type":"prompt", "turn_id":"first", "detail":"Read the file"}),
        );
        app.write_terminal_input(terminal, b"reading file\n")
            .unwrap();
        wait_for_output(&app, terminal, b"OUTPUT:reading file");
        send_hook(
            &app,
            terminal,
            &json!({"type":"tool_start", "turn_id":"first",
            "tool_call_id":"read", "tool_name":"read", "target":"src/main.rs"}),
        );
        send_hook(
            &app,
            terminal,
            &json!({"type":"tool_start", "turn_id":"first",
            "tool_call_id":"bash", "tool_name":"bash", "target":"make test"}),
        );
        send_hook(
            &app,
            terminal,
            &json!({"type":"tool_end", "turn_id":"first",
            "tool_call_id":"bash", "tool_name":"bash", "target":"make test", "is_error":true, "detail":"tests failed"}),
        );
        send_hook(
            &app,
            terminal,
            &json!({"type":"response", "turn_id":"first", "detail":"Tests need a fix"}),
        );
        let page = trace_for_terminal(&app, id, terminal);
        assert_eq!(page.spans[0].status, TraceSpanStatus::Completed);
        let span = page.spans[0].span_id;
        assert_pi_trace_events(&app, span, terminal);
        send_hook(
            &app,
            terminal,
            &json!({"type":"prompt", "turn_id":"second", "detail":"Fix the tests"}),
        );
        send_hook(
            &app,
            terminal,
            &json!({"type":"response", "turn_id":"first", "detail":"delayed response"}),
        );
        let page = trace_for_terminal(&app, id, terminal);
        assert_eq!(page.spans.len(), 2);
        assert_eq!(page.spans[0].title, "Fix the tests");
        assert_eq!(page.spans[0].status, TraceSpanStatus::Running);
        accepted(&app, Command::CancelAgent { workflow_id: id });
        assert_eq!(
            std::fs::read_to_string(settings).unwrap(),
            r#"{"extensions":["./existing.js"]}"#
        );
        let events = app.trace_events(span, None, 30).unwrap().events;
        drop(app);
        assert!(!extension.exists());
        let reopened = Application::with_config(data.path(), Config::default()).unwrap();
        assert_eq!(
            reopened.trace_events(span, None, 30).unwrap().events,
            events
        );
    }

    #[test]
    fn pi_without_activity_retains_its_fallback_and_interactive_terminal() {
        let folder = tempfile::tempdir().unwrap();
        let bin = tempfile::tempdir().unwrap();
        let mut app = Application::with_event_capacity(4096).unwrap();
        let id = setup(&mut app, folder.path(), bin.path());
        let terminal = start_pi(&app, id);
        let original = trace_for_terminal(&app, id, terminal).spans[0].span_id;
        send_hook(
            &app,
            terminal,
            &json!({"type":"prompt", "detail":"missing id"}),
        );
        send_hook(
            &app,
            terminal,
            &json!({"type":"response", "turn_id":"missing-prompt"}),
        );
        app.write_terminal_input(terminal, b"still interactive\n")
            .unwrap();
        wait_for_output(&app, terminal, b"OUTPUT:still interactive");
        accepted(&app, Command::CancelAgent { workflow_id: id });
        let page = trace_for_terminal(&app, id, terminal);
        assert_eq!(page.spans.len(), 1);
        assert_eq!(page.spans[0].span_id, original);
        assert_eq!(page.spans[0].status, TraceSpanStatus::Stopped);
    }

    #[test]
    fn antigravity_launches_with_add_dir_hooks_and_records_steps() {
        let folder = tempfile::tempdir().unwrap();
        let bin = tempfile::tempdir().unwrap();
        let data = tempfile::tempdir().unwrap();
        let mut app = Application::with_config(data.path(), Config::default()).unwrap();
        let id = setup(&mut app, folder.path(), bin.path());
        let terminal = start_antigravity(&app, id);

        let arguments = std::fs::read_to_string(bin.path().join("arguments")).unwrap();
        let arguments: Vec<_> = arguments.lines().collect();
        assert_eq!(arguments[0], "--add-dir");
        let added_dir = Path::new(arguments[1]);
        assert!(added_dir.is_dir());
        assert!(!added_dir.starts_with(folder.path()));
        assert!(added_dir.join(".agents/hooks.json").is_file());
        assert!(added_dir.join("hook.sh").is_file());
        assert_eq!(arguments[2], "--prompt-interactive=Initial prompt");

        let hook_script = added_dir.join("hook.sh");
        let run_hook = |event: &str, payload: &Value| {
            let mut child = ProcessCommand::new(&hook_script)
                .arg(event)
                .stdin(Stdio::piped())
                .stdout(Stdio::piped())
                .spawn()
                .unwrap();
            child
                .stdin
                .take()
                .unwrap()
                .write_all(&serde_json::to_vec(payload).unwrap())
                .unwrap();
            let output = child.wait_with_output().unwrap();
            assert!(output.status.success());
            output.stdout
        };

        run_hook("SessionStart", &json!({"conversationId": "conv-1"}));
        app.poll_harness_steps().unwrap();

        run_hook(
            "PreInvocation",
            &json!({"conversationId": "conv-1", "invocationNum": 0, "prompt": "Initial prompt"}),
        );
        app.poll_harness_steps().unwrap();

        let stdout = run_hook(
            "PreToolUse",
            &json!({
                "conversationId": "conv-1",
                "stepIdx": 1,
                "toolCall": {
                    "name": "run_command",
                    "args": {"CommandLine": "ls -la", "toolAction": "List files"}
                }
            }),
        );
        assert_eq!(String::from_utf8_lossy(&stdout), r#"{"decision":"allow"}"#);
        app.poll_harness_steps().unwrap();

        let stdout = run_hook(
            "PostToolUse",
            &json!({
                "conversationId": "conv-1",
                "stepIdx": 1,
                "error": "",
                "toolCall": {
                    "name": "run_command",
                    "args": {"CommandLine": "ls -la", "toolAction": "List files"}
                }
            }),
        );
        assert_eq!(String::from_utf8_lossy(&stdout), "{}");
        app.poll_harness_steps().unwrap();

        run_hook(
            "Stop",
            &json!({"conversationId": "conv-1", "terminationReason": "NO_TOOL_CALL"}),
        );
        thread::sleep(Duration::from_millis(60));
        app.poll_harness_steps().unwrap();

        let page = trace_for_terminal(&app, id, terminal);
        assert_eq!(page.spans.len(), 1);
        let span = page.spans[0].span_id;
        let activities = app.trace_activities(span, None, 10).unwrap().activities;
        assert_eq!(activities.len(), 1);
        assert_eq!(activities[0].title, "List files");
        assert_eq!(activities[0].status, crate::TraceActivityStatus::Completed);
    }

    #[test]
    fn pi_steps_remain_under_the_current_assignment_after_handoff() {
        let folder = tempfile::tempdir().unwrap();
        let bin = tempfile::tempdir().unwrap();
        let mut app = Application::with_event_capacity(4096).unwrap();
        let id = setup(&mut app, folder.path(), bin.path());
        start_adversarial_with_harness(&app, id, HarnessId::Pi);
        let current = workflow(&app, id);
        let agent = current
            .agents
            .iter()
            .find(|agent| agent.terminal_id.value() != 0)
            .unwrap();
        let terminal = agent.terminal_id;
        wait_for_output(&app, terminal, b"READY");
        let span = trace_for_terminal(&app, id, terminal).spans[0].span_id;
        send_hook(
            &app,
            terminal,
            &json!({"type":"prompt", "turn_id":"first", "detail":"Implement"}),
        );
        send_hook(
            &app,
            terminal,
            &json!({"type":"tool_start", "turn_id":"first",
            "tool_call_id":"edit", "tool_name":"edit", "target":"src/main.rs"}),
        );
        send_hook(
            &app,
            terminal,
            &json!({"type":"response", "turn_id":"first", "detail":"Ready"}),
        );
        assert_eq!(
            trace_for_terminal(&app, id, terminal).spans[0].status,
            TraceSpanStatus::Running
        );
        accepted(
            &app,
            Command::CompleteWorkflowRole {
                workflow_id: id,
                agent_id: agent.agent_id,
                generation: current.run.unwrap().generation,
                signal: CompletionSignal {
                    task: String::new(),
                    decision: Decision::Done,
                    summary: "Ready".into(),
                    assignments: vec![],
                },
            },
        );
        send_hook(
            &app,
            terminal,
            &json!({"type":"tool_end", "turn_id":"first",
            "tool_call_id":"edit", "tool_name":"edit", "target":"src/main.rs", "detail":"late result"}),
        );
        let events = app.trace_events(span, None, 30).unwrap().events;
        assert!(
            events
                .iter()
                .any(|event| event.message.starts_with("Edit src/main.rs"))
        );
        assert!(
            events
                .iter()
                .any(|event| event.message.contains("late result"))
        );
        let other = app
            .workflow_trace(id, None, 30)
            .unwrap()
            .spans
            .into_iter()
            .find(|span| span.terminal_id != Some(terminal))
            .unwrap();
        assert!(
            !app.trace_events(other.span_id, None, 30)
                .unwrap()
                .events
                .iter()
                .any(|event| event.message.contains("late result"))
        );
    }

    #[test]
    fn anonymous_claude_hooks_use_a_private_command_when_the_conversation_is_reused() {
        let folder = tempfile::tempdir().unwrap();
        let bin = tempfile::tempdir().unwrap();
        let mut app = Application::with_event_capacity(4096).unwrap();
        let id = setup(&mut app, folder.path(), bin.path());
        start_adversarial_with_harness(&app, id, HarnessId::ClaudeCode);
        let initial = workflow(&app, id);
        let terminal = initial.agents[0].terminal_id;
        wait_for_output(&app, terminal, b"READY");
        let arguments = std::fs::read_to_string(bin.path().join("arguments")).unwrap();
        let old = arguments
            .lines()
            .find(|line| line.starts_with('\'') && line.contains("/complete"))
            .unwrap()
            .split('\'')
            .nth(1)
            .unwrap()
            .to_owned();
        send_hook(
            &app,
            terminal,
            &json!({"hook_event_name":"UserPromptSubmit","prompt":"Implement"}),
        );
        send_hook(&app, terminal, &json!({"hook_event_name":"Stop"}));
        assert!(!app.harness_turn_finished(terminal).unwrap());
        let complete = |agent_id, generation, decision| {
            accepted(
                &app,
                Command::CompleteWorkflowRole {
                    workflow_id: id,
                    agent_id,
                    generation,
                    signal: CompletionSignal {
                        task: String::new(),
                        decision,
                        summary: "Specific feedback".into(),
                        assignments: vec![],
                    },
                },
            );
        };
        complete(
            initial.agents[0].agent_id,
            initial.run.unwrap().generation,
            Decision::Done,
        );
        let review = workflow(&app, id);
        complete(
            review.agents[1].agent_id,
            review.run.unwrap().generation,
            Decision::RequestChanges,
        );
        wait_for_output(
            &app,
            terminal,
            b"Use this completion command for the current assignment:",
        );
        let crate::terminal::TranscriptRead::Output(page) =
            app.read_terminal_transcript(terminal, 0, 65536).unwrap()
        else {
            panic!("transcript missing");
        };
        let text = String::from_utf8_lossy(&page.bytes);
        let fresh = text
            .split("Use this completion command for the current assignment:")
            .nth(1)
            .unwrap()
            .split('\'')
            .nth(1)
            .unwrap();
        assert_ne!(fresh, old);
        assert!(!ProcessCommand::new(&old).output().unwrap().status.success());
        send_hook(
            &app,
            terminal,
            &json!({"hook_event_name":"UserPromptSubmit","prompt":"Fix feedback"}),
        );
        let mut child = ProcessCommand::new(fresh)
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(br#"{"decision":"done","summary":"Fixed"}"#)
            .unwrap();
        let deadline = Instant::now() + Duration::from_secs(5);
        while workflow(&app, id).run.unwrap().generation == 3 {
            assert!(Instant::now() < deadline);
            thread::sleep(Duration::from_millis(5));
        }
        assert!(child.wait().unwrap().success());
        assert_eq!(workflow(&app, id).agents[0].terminal_id, terminal);
    }

    #[test]
    #[ignore = "requires authenticated Pi with DeepSeek; set TWINE_REAL_PI to its absolute path"]
    fn real_pi_deepseek_models_record_tool_steps() {
        let pi = std::env::var("TWINE_REAL_PI").expect("set TWINE_REAL_PI");
        for model in ["deepseek-flash", "deepseek-v4-pro"] {
            let folder = tempfile::tempdir().unwrap();
            let bin = tempfile::tempdir().unwrap();
            let mut app = Application::with_event_capacity(4096).unwrap();
            let id = setup(&mut app, folder.path(), bin.path());
            let quoted = pi.replace('\'', "'\\''");
            let node_path = Path::new(&pi)
                .parent()
                .unwrap()
                .to_string_lossy()
                .replace('\'', "'\\''");
            std::fs::write(bin.path().join("pi"), format!(
                "#!/bin/sh\nPATH='{node_path}':\"$PATH\" exec '{quoted}' --no-session --no-extensions --no-skills --no-prompt-templates --no-themes --provider deepseek --model {model} --tools bash \"$@\"\n"
            )).unwrap();
            accepted(&app, Command::StartAgent {
                model: None,
                effort: None,
                yolo: false,
                workflow_id: id, harness: HarnessId::Pi,
                prompt: "Trace smoke test: use bash to run `printf TWINE45_TRACE_SMOKE` exactly once, then reply Done. Do not read or write files or run other commands.".into(), size: SIZE,
            });
            let terminal = workflow(&app, id).terminal_id;
            let deadline = Instant::now() + Duration::from_secs(120);
            loop {
                while let Some(chunk) = app.next_terminal_chunk().unwrap() {
                    if chunk.terminal_id == terminal
                        && chunk.bytes.windows(4).any(|part| part == b"\x1b[6n")
                    {
                        app.write_terminal_input(terminal, b"\x1b[1;1R").unwrap();
                    }
                }
                let page = trace_for_terminal(&app, id, terminal);
                if let Some(span) = page
                    .spans
                    .iter()
                    .find(|span| span.status == TraceSpanStatus::Completed)
                {
                    let events = app.trace_events(span.span_id, None, 30).unwrap().events;
                    assert!(
                        events.iter().any(|event| event
                            .message
                            .starts_with("Run printf TWINE45_TRACE_SMOKE")),
                        "missing {model} tool start: {events:?}"
                    );
                    assert!(
                        events.iter().any(|event| event
                            .message
                            .starts_with("Finished: Run printf TWINE45_TRACE_SMOKE")),
                        "missing {model} tool result: {events:?}"
                    );
                    assert!(events.iter().all(|event| {
                        event
                            .anchor
                            .as_ref()
                            .is_some_and(|anchor| anchor.terminal_id == terminal)
                    }));
                    break;
                }
                assert!(
                    Instant::now() < deadline,
                    "no completed {model} prompt span; status: {:?}",
                    workflow(&app, id).status
                );
                thread::sleep(Duration::from_millis(20));
            }
        }
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
                        activity: None,
                        session_id: None,
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

    fn assert_codex_arguments(app: &Application, terminal: TerminalId, bin: &Path) {
        let arguments = std::fs::read_to_string(bin.join("arguments")).unwrap();
        assert!(arguments.starts_with("-c\nhooks="));
        assert!(arguments.ends_with("\n--\n-initial prompt\n"));
        let config: toml::Value = toml::from_str(arguments.lines().nth(1).unwrap()).unwrap();
        let command = config["hooks"]["UserPromptSubmit"][0]["hooks"][0]["command"]
            .as_str()
            .unwrap();
        assert_eq!(
            command,
            app.harness_steps.lock().unwrap()[&terminal]
                .inbox
                .hook_command()
        );
    }

    fn start_codex(app: &Application, id: WorkflowId) -> TerminalId {
        accepted(
            app,
            Command::StartAgent {
                model: None,
                effort: None,
                yolo: false,
                workflow_id: id,
                harness: HarnessId::Codex,
                prompt: "-initial prompt".into(),
                size: SIZE,
            },
        );
        let terminal = workflow(app, id).terminal_id;
        wait_for_output(app, terminal, b"READY");
        terminal
    }

    fn trace_for_terminal(
        app: &Application,
        id: WorkflowId,
        terminal: TerminalId,
    ) -> crate::WorkflowTracePage {
        let mut page = app.workflow_trace(id, None, 20).unwrap();
        page.spans.retain(|span| span.terminal_id == Some(terminal));
        page
    }

    #[test]
    fn codex_turns_have_ordered_steps_anchors_and_durable_history() {
        let folder = tempfile::tempdir().unwrap();
        let bin = tempfile::tempdir().unwrap();
        let data = tempfile::tempdir().unwrap();
        let user_config = folder.path().join(".codex/config.toml");
        std::fs::create_dir(user_config.parent().unwrap()).unwrap();
        std::fs::write(&user_config, "model = 'custom'\n[hooks]\nStop = []\n").unwrap();
        let before = std::fs::read(&user_config).unwrap();
        let mut app = Application::with_config(data.path(), Config::default()).unwrap();
        let id = setup(&mut app, folder.path(), bin.path());
        let terminal = start_codex(&app, id);
        assert_codex_arguments(&app, terminal, bin.path());
        // No activity yet: retain the ordinary agent span.
        assert_eq!(trace_for_terminal(&app, id, terminal).spans.len(), 1);
        // Async hooks can arrive out of order, including before their prompt.
        send_hook(
            &app,
            terminal,
            &json!({"hook_event_name":"PreToolUse","turn_id":"first","tool_use_id":"edit","tool_name":"apply_patch","tool_input":{"command":"*** Begin Patch\n*** Update File: src/main.rs\n"}}),
        );
        send_hook(
            &app,
            terminal,
            &json!({"hook_event_name":"UserPromptSubmit","turn_id":"first","prompt":"Fix src/main.rs"}),
        );
        app.write_terminal_input(terminal, b"edited file\n")
            .unwrap();
        wait_for_output(&app, terminal, b"OUTPUT:edited file");
        send_hook(
            &app,
            terminal,
            &json!({"hook_event_name":"PostToolUse","turn_id":"first","tool_use_id":"edit","tool_name":"apply_patch","tool_input":{"command":"*** Update File: src/main.rs"},"tool_response":"updated"}),
        );
        send_hook(
            &app,
            terminal,
            &json!({"hook_event_name":"PreToolUse","turn_id":"first","tool_use_id":"test","tool_name":"Bash","tool_input":{"command":"make test"}}),
        );
        send_hook(
            &app,
            terminal,
            &json!({"hook_event_name":"PostToolUse","turn_id":"first","tool_use_id":"test","tool_name":"Bash","tool_input":{"command":"make test"},"tool_response":"☃".repeat(20_000)}),
        );
        send_hook(
            &app,
            terminal,
            &json!({"hook_event_name":"Stop","turn_id":"first","last_assistant_message":"Fixed and tested."}),
        );
        let page = trace_for_terminal(&app, id, terminal);
        assert_eq!(page.spans.len(), 1);
        let span = &page.spans[0];
        assert_eq!(span.title, "Fix src/main.rs");
        assert_eq!(span.status, TraceSpanStatus::Completed);
        let span_id = span.span_id;
        let events = app.trace_events(span_id, None, 20).unwrap().events;
        assert_eq!(events.len(), 7);
        assert!(events[1].message.starts_with("Fix src/main.rs"));
        assert!(events[2].message.starts_with("Edit src/main.rs"));
        assert!(events[3].message.starts_with("Finished: Edit src/main.rs"));
        assert!(events[4].message.starts_with("Run make test"));
        assert!(events[5].message.contains("[truncated]"));
        assert!(events[6].message.starts_with("Finished responding"));
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
            &json!({"hook_event_name":"UserPromptSubmit","turn_id":"second","prompt":"Follow up"}),
        );
        // A delayed stop belongs to the first turn, never the current turn.
        send_hook(
            &app,
            terminal,
            &json!({"hook_event_name":"Stop","turn_id":"first"}),
        );
        let page = trace_for_terminal(&app, id, terminal);
        assert_eq!(page.spans.len(), 2);
        assert_eq!(page.spans[0].title, "Follow up");
        assert_eq!(page.spans[0].status, TraceSpanStatus::Running);
        accepted(&app, Command::CancelAgent { workflow_id: id });
        let events = app.trace_events(span_id, None, 20).unwrap().events;
        assert_eq!(std::fs::read(user_config).unwrap(), before);
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
    fn codex_child_hooks_do_not_replace_or_interrupt_the_root_prompt() {
        let folder = tempfile::tempdir().unwrap();
        let bin = tempfile::tempdir().unwrap();
        let mut app = Application::with_event_capacity(4096).unwrap();
        let id = setup(&mut app, folder.path(), bin.path());
        let terminal = start_codex(&app, id);
        send_hook(
            &app,
            terminal,
            &json!({"hook_event_name":"UserPromptSubmit", "turn_id":"root", "prompt":"Root task"}),
        );
        send_hook(
            &app,
            terminal,
            &json!({"hook_event_name":"SubagentStart", "agent_id":"child", "agent_type":"Reviewer", "turn_id":"child-turn"}),
        );
        send_hook(
            &app,
            terminal,
            &json!({"hook_event_name":"UserPromptSubmit", "agent_id":"child", "turn_id":"child-turn", "prompt":"Child task"}),
        );
        send_hook(
            &app,
            terminal,
            &json!({"hook_event_name":"PreToolUse", "agent_id":"child", "turn_id":"child-turn", "tool_use_id":"child-tool", "tool_name":"Bash", "tool_input":{"command":"child command"}}),
        );
        send_hook(
            &app,
            terminal,
            &json!({"hook_event_name":"PostToolUse", "agent_id":"child", "turn_id":"child-turn", "tool_use_id":"child-tool", "tool_name":"Bash", "tool_input":{"command":"child command"}, "tool_response":"done"}),
        );
        send_hook(
            &app,
            terminal,
            &json!({"hook_event_name":"SubagentStop", "agent_id":"child", "agent_type":"Reviewer", "turn_id":"child-turn"}),
        );
        let page = trace_for_terminal(&app, id, terminal);
        assert_eq!(page.spans.len(), 1);
        assert_eq!(page.spans[0].title, "Root task");
        assert_eq!(page.spans[0].status, TraceSpanStatus::Running);
        send_hook(
            &app,
            terminal,
            &json!({"hook_event_name":"Stop", "turn_id":"root"}),
        );
        let page = trace_for_terminal(&app, id, terminal);
        assert_eq!(page.spans.len(), 1);
        assert_eq!(page.spans[0].status, TraceSpanStatus::Completed);
        let events = app
            .trace_events(page.spans[0].span_id, None, 20)
            .unwrap()
            .events;
        assert_eq!(events.len(), 7); // Process, root prompt/response, child and tool endpoints.
        let activity = app
            .trace_activities(page.spans[0].span_id, None, 20)
            .unwrap()
            .activities;
        assert_eq!(activity.len(), 2);
        assert_eq!(
            activity[1].parent_activity_id,
            Some(activity[0].activity_id)
        );
        assert_eq!(activity[1].status, crate::TraceActivityStatus::Completed);
        assert!(activity[1].title.contains("child command"));
        assert_eq!(activity[1].anchor.as_ref().unwrap().terminal_id, terminal);
    }

    #[test]
    fn codex_without_activity_keeps_the_agent_span_and_terminal() {
        let folder = tempfile::tempdir().unwrap();
        let bin = tempfile::tempdir().unwrap();
        let mut app = Application::with_event_capacity(4096).unwrap();
        let id = setup(&mut app, folder.path(), bin.path());
        accepted(
            &app,
            Command::StartAgent {
                model: None,
                effort: None,
                yolo: false,
                workflow_id: id,
                harness: HarnessId::Codex,
                prompt: "Work without hooks".into(),
                size: SIZE,
            },
        );
        let terminal = workflow(&app, id).terminal_id;
        wait_for_output(&app, terminal, b"READY");
        let original = trace_for_terminal(&app, id, terminal).spans[0].span_id;
        // Malformed activity and a missing prompt do not activate prompt tracing.
        send_hook(&app, terminal, &json!({"hook_event_name":"Stop"}));
        send_hook(
            &app,
            terminal,
            &json!({"hook_event_name":"Stop","turn_id":"unknown"}),
        );
        app.write_terminal_input(terminal, b"still interactive\n")
            .unwrap();
        wait_for_output(&app, terminal, b"OUTPUT:still interactive");
        accepted(&app, Command::CancelAgent { workflow_id: id });
        let page = trace_for_terminal(&app, id, terminal);
        assert_eq!(page.spans.len(), 1);
        assert_eq!(page.spans[0].span_id, original);
        assert_eq!(page.spans[0].status, TraceSpanStatus::Stopped);
    }

    #[test]
    fn failed_first_prompt_preserves_fallback_until_atomic_conversion_succeeds() {
        let folder = tempfile::tempdir().unwrap();
        let bin = tempfile::tempdir().unwrap();
        let mut app = Application::with_event_capacity(4096).unwrap();
        let id = setup(&mut app, folder.path(), bin.path());
        let terminal = start_codex(&app, id);
        let original = trace_for_terminal(&app, id, terminal).spans[0].clone();
        let events = app.trace_events(original.span_id, None, 20).unwrap().events;
        app.lock_inner().unwrap().folders.store().execute_test_sql(
            "CREATE TRIGGER reject_prompt BEFORE INSERT ON trace_events WHEN NEW.kind = 'workflowEvent' BEGIN SELECT RAISE(FAIL, 'temporary write failure'); END;"
        );
        send_hook(
            &app,
            terminal,
            &json!({"hook_event_name":"UserPromptSubmit","turn_id":"first","prompt":"Recover me"}),
        );
        assert_eq!(
            trace_for_terminal(&app, id, terminal).spans,
            vec![original.clone()]
        );
        assert_eq!(
            app.trace_events(original.span_id, None, 20).unwrap().events,
            events
        );
        assert!(!app.harness_steps.lock().unwrap()[&terminal].active);
        app.lock_inner()
            .unwrap()
            .folders
            .store()
            .execute_test_sql("DROP TRIGGER reject_prompt;");
        let page = trace_for_terminal(&app, id, terminal);
        assert_eq!(page.spans.len(), 1);
        assert_eq!(page.spans[0].title, "Recover me");
        assert!(app.harness_steps.lock().unwrap()[&terminal].active);
        let events = app
            .trace_events(page.spans[0].span_id, None, 20)
            .unwrap()
            .events;
        assert_eq!(
            events
                .iter()
                .filter(|event| event.message.starts_with("Recover me"))
                .count(),
            1
        );
        assert!(
            events
                .iter()
                .any(|event| event.kind == crate::TraceEventKind::ProcessStarted)
        );
    }

    #[test]
    #[ignore = "requires authenticated Codex; set TWINE_REAL_CODEX to its absolute path"]
    fn real_codex_records_tool_steps() {
        let codex = std::env::var("TWINE_REAL_CODEX").expect("set TWINE_REAL_CODEX");
        let folder = tempfile::tempdir().unwrap();
        let bin = tempfile::tempdir().unwrap();
        let mut app = Application::with_event_capacity(4096).unwrap();
        let id = setup(&mut app, folder.path(), bin.path());
        let quoted = codex.replace('\'', "'\\''");
        let folder_path = folder.path().canonicalize().unwrap();
        let trust = format!(
            "projects={{{}={{trust_level=\"trusted\"}}}}",
            serde_json::to_string(&folder_path).unwrap()
        )
        .replace('\'', "'\\''");
        std::fs::write(bin.path().join("codex"), format!(
            "#!/bin/sh\nexec '{quoted}' --no-alt-screen --sandbox read-only --ask-for-approval never -c '{trust}' \"$@\"\n"
        )).unwrap();
        accepted(&app, Command::StartAgent {
            model: None,
            effort: None,
            yolo: false,
            workflow_id: id, harness: HarnessId::Codex,
            prompt: "Trace smoke test: run the shell command `printf TWINE44_TRACE_SMOKE` exactly once, then reply Done. Do not read or write files or run other tools.".into(), size: SIZE,
        });
        let terminal = workflow(&app, id).terminal_id;
        let deadline = Instant::now() + Duration::from_secs(120);
        loop {
            while let Some(chunk) = app.next_terminal_chunk().unwrap() {
                if chunk.terminal_id == terminal
                    && chunk.bytes.windows(4).any(|part| part == b"\x1b[6n")
                {
                    app.write_terminal_input(terminal, b"\x1b[1;1R").unwrap();
                }
            }
            let page = trace_for_terminal(&app, id, terminal);
            if let Some(span) = page
                .spans
                .iter()
                .find(|span| span.status == TraceSpanStatus::Completed)
            {
                let events = app.trace_events(span.span_id, None, 30).unwrap().events;
                assert!(
                    events
                        .iter()
                        .any(|event| event.message.starts_with("Run printf TWINE44_TRACE_SMOKE")),
                    "missing tool start: {events:?}"
                );
                assert!(
                    events.iter().any(|event| event
                        .message
                        .starts_with("Finished: Run printf TWINE44_TRACE_SMOKE")),
                    "missing tool result: {events:?}"
                );
                assert!(
                    events
                        .iter()
                        .any(|event| event.message.starts_with("Finished responding"))
                );
                assert!(events.iter().all(|event| {
                    event
                        .anchor
                        .as_ref()
                        .is_some_and(|anchor| anchor.terminal_id == terminal)
                }));
                break;
            }
            assert!(
                Instant::now() < deadline,
                "no completed prompt span; workflow status: {:?}",
                workflow(&app, id).status
            );
            thread::sleep(Duration::from_millis(20));
        }
    }

    #[test]
    fn codex_steps_stay_under_their_assignment_after_a_handoff() {
        let folder = tempfile::tempdir().unwrap();
        let bin = tempfile::tempdir().unwrap();
        let mut app = Application::with_event_capacity(4096).unwrap();
        let id = setup(&mut app, folder.path(), bin.path());
        start_adversarial_with_harness(&app, id, HarnessId::Codex);
        let current = workflow(&app, id);
        let agent = current
            .agents
            .iter()
            .find(|a| a.terminal_id.value() != 0)
            .unwrap();
        let terminal = agent.terminal_id;
        wait_for_output(&app, terminal, b"READY");
        let span = app
            .workflow_trace(id, None, 20)
            .unwrap()
            .spans
            .into_iter()
            .find(|s| s.terminal_id == Some(terminal))
            .unwrap();
        send_hook(
            &app,
            terminal,
            &json!({"hook_event_name":"UserPromptSubmit","turn_id":"first","prompt":"Implement"}),
        );
        send_hook(
            &app,
            terminal,
            &json!({"hook_event_name":"PreToolUse","turn_id":"first","tool_use_id":"test","tool_name":"Bash","tool_input":{"command":"make test"}}),
        );
        send_hook(
            &app,
            terminal,
            &json!({"hook_event_name":"PostToolUse","turn_id":"first","tool_use_id":"test","tool_name":"Bash","tool_input":{"command":"make test"},"tool_response":"passed"}),
        );
        send_hook(
            &app,
            terminal,
            &json!({"hook_event_name":"Stop","turn_id":"first"}),
        );
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
                    task: String::new(),
                    decision: Decision::Done,
                    summary: "Ready".into(),
                    assignments: vec![],
                },
            },
        );
        send_hook(
            &app,
            terminal,
            &json!({"hook_event_name":"PostToolUse","turn_id":"first","tool_name":"Bash","tool_input":{"command":"late result"},"tool_response":"done"}),
        );
        let events = app.trace_events(span.span_id, None, 30).unwrap().events;
        assert!(
            events
                .iter()
                .any(|e| e.message.starts_with("Run make test"))
        );
        assert!(
            events
                .iter()
                .any(|e| e.message.starts_with("Finished: Run late result"))
        );
        assert!(
            events
                .iter()
                .filter_map(|e| e.anchor.as_ref())
                .all(|a| a.terminal_id == terminal)
        );
        let other = app
            .workflow_trace(id, None, 20)
            .unwrap()
            .spans
            .into_iter()
            .find(|s| s.terminal_id != Some(terminal))
            .unwrap();
        assert!(
            !app.trace_events(other.span_id, None, 30)
                .unwrap()
                .events
                .iter()
                .any(|e| e.message.contains("late result"))
        );
    }

    fn assert_claude_launch(bin: &Path) {
        let args = std::fs::read_to_string(bin.join("arguments")).unwrap();
        assert!(args.starts_with("--settings\n"));
        assert!(args.ends_with("\n--\n-initial prompt\n"));
        assert_eq!(
            std::fs::read_to_string(bin.join("arguments.renderer")).unwrap(),
            "1\n"
        );
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
                model: None,
                effort: None,
                yolo: false,
                workflow_id: id,
                harness: HarnessId::ClaudeCode,
                prompt: "-initial prompt".into(),
                size: SIZE,
            },
        );
        let terminal = workflow(&app, id).terminal_id;
        wait_for_output(&app, terminal, b"READY");
        assert_claude_launch(bin.path());
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
    fn reused_assignments_keep_delayed_hooks_in_their_original_turn() {
        let folder = tempfile::tempdir().unwrap();
        let bin = tempfile::tempdir().unwrap();
        let mut app = Application::with_event_capacity(4096).unwrap();
        let id = setup(&mut app, folder.path(), bin.path());
        start_adversarial(&app, id);
        let original = workflow(&app, id);
        let implementer = &original.agents[0];
        let terminal = implementer.terminal_id;
        wait_for_output(&app, terminal, b"READY");
        let old_span = app.workflow_trace(id, None, 20).unwrap().spans[0].span_id;
        send_hook(
            &app,
            terminal,
            &json!({"hook_event_name":"UserPromptSubmit", "prompt_id":"old", "prompt":"First assignment"}),
        );
        send_hook(
            &app,
            terminal,
            &json!({"hook_event_name":"PreToolUse", "prompt_id":"old", "tool_use_id":"old-tool", "tool_name":"Bash", "tool_input":{"command":"make old-test"}}),
        );
        let complete = |agent_id, generation, decision| {
            accepted(
                &app,
                Command::CompleteWorkflowRole {
                    workflow_id: id,
                    agent_id,
                    generation,
                    signal: CompletionSignal {
                        task: String::new(),
                        decision,
                        summary: "Result or feedback".into(),
                        assignments: vec![],
                    },
                },
            );
        };
        complete(implementer.agent_id, 1, Decision::Done);
        let review = workflow(&app, id);
        complete(review.agents[1].agent_id, 2, Decision::RequestChanges);
        assert_eq!(workflow(&app, id).agents[0].terminal_id, terminal);
        let new_span = app
            .workflow_trace(id, None, 20)
            .unwrap()
            .spans
            .iter()
            .filter(|span| span.terminal_id == Some(terminal))
            .max_by_key(|span| span.span_id.0)
            .unwrap()
            .span_id;
        assert_ne!(old_span, new_span);
        send_hook(
            &app,
            terminal,
            &json!({"hook_event_name":"UserPromptSubmit", "prompt_id":"new", "prompt":"Fix the feedback"}),
        );
        send_hook(
            &app,
            terminal,
            &json!({"hook_event_name":"PostToolUseFailure", "prompt_id":"old", "tool_use_id":"old-tool", "tool_name":"Bash", "tool_input":{"command":"make old-test"}, "error":"old failure"}),
        );
        send_hook(
            &app,
            terminal,
            &json!({"hook_event_name":"Stop", "prompt_id":"old"}),
        );
        let old_events = app.trace_events(old_span, None, 100).unwrap().events;
        assert!(
            old_events
                .iter()
                .any(|event| event.message.starts_with("Failed: Run make old-test"))
        );
        assert!(
            old_events
                .iter()
                .any(|event| event.message == "Finished responding")
        );
        let new_events = app.trace_events(new_span, None, 100).unwrap().events;
        assert!(
            new_events
                .iter()
                .any(|event| event.message.contains("Fix the feedback"))
        );
        assert!(
            new_events
                .iter()
                .all(|event| !event.message.contains("old-test")
                    && event.message != "Finished responding")
        );
        send_hook(
            &app,
            terminal,
            &json!({"hook_event_name":"Stop", "prompt_id":"new"}),
        );
        assert!(
            app.trace_events(new_span, None, 100)
                .unwrap()
                .events
                .iter()
                .any(|event| event.message == "Finished responding")
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
                    task: String::new(),
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
