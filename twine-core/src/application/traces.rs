use super::{Application, ApplicationError, Inner};
use crate::event::{EventKind, StateEvent};
use crate::store::{NewTraceSpan, TraceEnding};
use crate::terminal::TerminalObservation;
use crate::{
    TerminalId, TerminalStatus, TraceAnchor, TraceEventId, TraceEventKind, TraceEventsPage,
    TraceSpanId, TraceSpanStatus, Workflow, WorkflowId, WorkflowTracePage,
};

#[derive(Clone, Debug)]
pub(super) struct PendingTraceEnding {
    observation: TerminalObservation,
    status: TraceSpanStatus,
    kind: TraceEventKind,
    message: String,
}

impl PendingTraceEnding {
    fn as_store_ending(&self, terminal_id: TerminalId) -> TraceEnding<'_> {
        TraceEnding {
            observed_at: self.observation.observed_at,
            status: self.status,
            kind: self.kind,
            message: &self.message,
            anchor: Some(TraceAnchor {
                terminal_id,
                byte_offset: self.observation.byte_offset,
                boundary_sizes: self.observation.boundary_sizes.clone(),
            }),
        }
    }
}

impl Application {
    pub(super) fn poll_shell_observations(&self) -> Result<(), ApplicationError> {
        let mut inner = self.lock_inner()?;
        inner.record_shell_observations(Vec::new());
        if inner.pending_shell_marks.is_empty() {
            inner.record_shell_observations(self.terminal_output.take_shell_observations()?);
        }
        inner.finish_shell_process_endings(&self.terminal_output);
        Ok(())
    }

    /// Reads a bounded page of the workflow's durable trace, including closed workflow history.
    ///
    /// # Errors
    /// Returns an error if the workflow is missing, the page limit is invalid, or storage fails.
    pub fn workflow_trace(
        &self,
        workflow_id: WorkflowId,
        before: Option<TraceSpanId>,
        limit: usize,
    ) -> Result<WorkflowTracePage, ApplicationError> {
        self.poll_harness_steps()?;
        self.poll_shell_observations()?;
        let inner = self.lock_inner()?;
        let mut page = inner
            .folders
            .read_store()
            .workflow_trace(workflow_id, before, limit)?;
        for span in &mut page.spans {
            let live_assignment = page
                .lanes
                .iter()
                .find(|lane| lane.lane_id == span.lane_id)
                .and_then(|lane| lane.agent_id)
                .is_some_and(|agent_id| {
                    inner.workflows.workflows.iter().any(|workflow| {
                        workflow.workflow_id == workflow_id
                            && workflow.run.as_ref().is_some_and(|run| {
                                run.status == crate::RunStatus::Running
                                    && run
                                        .active_agents()
                                        .iter()
                                        .any(|agent| agent.agent_id == agent_id.0)
                            })
                            && workflow.agents.iter().any(|agent| {
                                agent.agent_id == agent_id
                                    && span.terminal_id.is_none_or(|id| agent.terminal_id == id)
                            })
                    })
                });
            span.is_live = span.status == TraceSpanStatus::Running
                && (live_assignment
                    || span.terminal_id.is_some_and(|id| {
                        inner.trace_spans.get(&id) == Some(&span.span_id)
                            && inner.terminals.get(&id) == Some(&TerminalStatus::Running)
                    }));
        }
        Ok(page)
    }

    /// Reads a bounded page of events for a span, in durable event ID order.
    ///
    /// # Errors
    /// Returns an error if the span is missing, the page limit is invalid, or storage fails.
    pub fn trace_events(
        &self,
        span_id: TraceSpanId,
        after: Option<TraceEventId>,
        limit: usize,
    ) -> Result<TraceEventsPage, ApplicationError> {
        self.poll_harness_steps()?;
        Ok(self
            .lock_inner()?
            .folders
            .read_store()
            .trace_events(span_id, after, limit)?)
    }
}

impl Inner {
    pub(super) fn record_shell_observations(
        &mut self,
        observations: Vec<crate::terminal::ShellObservation>,
    ) {
        for item in &observations {
            if let Some(workflow) = self.workflows.workflows.iter().find(|workflow| {
                workflow.kind == crate::WorkflowKind::Terminal
                    && workflow.terminal_id == item.terminal_id
            }) {
                self.pending_shell_workflows
                    .entry(item.terminal_id)
                    .or_insert_with(|| workflow.clone());
            }
        }
        self.pending_shell_marks.extend(observations);
        while let Some(item) = self.pending_shell_marks.front().cloned() {
            if let Err(error) = self.record_shell_mark(item) {
                tracing::warn!(%error, "couldn't persist shell command boundary");
                break;
            }
            self.pending_shell_marks.pop_front();
        }
        self.pending_shell_workflows.retain(|id, _| {
            self.pending_shell_marks
                .iter()
                .any(|item| item.terminal_id == *id)
        });
    }

    pub(super) fn defer_shell_process_ending(
        &mut self,
        id: TerminalId,
        observation: &TerminalObservation,
        status: TraceSpanStatus,
        kind: TraceEventKind,
        message: &str,
    ) -> bool {
        if !observation.integrated_shell
            && !self.command_shells.contains(&id)
            && !self
                .pending_shell_marks
                .iter()
                .any(|item| item.terminal_id == id)
        {
            return false;
        }
        self.shell_process_endings.insert(
            id,
            PendingTraceEnding {
                observation: observation.clone(),
                status,
                kind,
                message: message.into(),
            },
        );
        true
    }

    pub(super) fn finish_shell_process_endings(
        &mut self,
        output: &crate::terminal::TerminalStream,
    ) {
        let finished = self
            .shell_process_endings
            .iter()
            .filter(|(id, _)| {
                output.reader_finished(**id)
                    && !self
                        .pending_shell_marks
                        .iter()
                        .any(|item| item.terminal_id == **id)
            })
            .map(|(&id, ending)| (id, ending.clone()))
            .collect::<Vec<_>>();
        for (id, mut ending) in finished {
            if self.command_shells.contains(&id) {
                ending.status = TraceSpanStatus::Stopped;
                ending.kind = TraceEventKind::WorkflowEvent;
                ending.message = "Shell ended before the command's ending was recorded.".into();
            }
            if let Err(error) = self.end_trace(
                id,
                ending.observation,
                ending.status,
                ending.kind,
                &ending.message,
            ) {
                tracing::warn!(%error, "couldn't persist shell process ending");
            } else {
                self.shell_process_endings.remove(&id);
                self.command_shells.remove(&id);
            }
        }
    }

    fn record_shell_mark(
        &mut self,
        item: crate::terminal::ShellObservation,
    ) -> Result<(), ApplicationError> {
        use crate::terminal::ShellMark;
        let terminal_id = item.terminal_id;
        let Some(workflow) = self
            .workflows
            .workflows
            .iter()
            .find(|workflow| {
                workflow.kind == crate::WorkflowKind::Terminal
                    && workflow.terminal_id == terminal_id
            })
            .cloned()
            .or_else(|| self.pending_shell_workflows.get(&terminal_id).cloned())
        else {
            return Ok(());
        };
        if !matches!(&item.mark, ShellMark::Stopped(_))
            && !self.command_shells.contains(&terminal_id)
        {
            if let Some(span) = self.trace_spans.get(&terminal_id).copied() {
                self.folders.store().activate_command_trace(span)?;
                self.trace_spans.remove(&terminal_id);
            }
            self.command_shells.insert(terminal_id);
        }
        match item.mark {
            ShellMark::Prompt => {}
            ShellMark::CommandStart(title) => {
                self.end_trace(
                    terminal_id,
                    item.observation.clone(),
                    TraceSpanStatus::Stopped,
                    TraceEventKind::WorkflowEvent,
                    "Command ending was not recorded.",
                )?;
                let mut span = new_span(&workflow);
                span.title = &title;
                span.started_at = item.observation.observed_at;
                span.anchor = Some(TraceAnchor {
                    terminal_id,
                    byte_offset: item.observation.byte_offset,
                    boundary_sizes: item.observation.boundary_sizes,
                });
                let id = self.folders.store().start_command_trace(&span)?;
                self.trace_spans.insert(terminal_id, id);
            }
            ShellMark::CommandEnd(code) => {
                self.end_trace(
                    terminal_id,
                    item.observation,
                    if code == 0 {
                        TraceSpanStatus::Completed
                    } else {
                        TraceSpanStatus::Failed
                    },
                    TraceEventKind::WorkflowEvent,
                    &format!("Command exited with code {code}."),
                )?;
            }
            ShellMark::Lost => {
                self.end_trace(
                    terminal_id,
                    item.observation.clone(),
                    TraceSpanStatus::Stopped,
                    TraceEventKind::WorkflowEvent,
                    "Shell integration boundaries were lost.",
                )?;
                let mut span = new_span(&workflow);
                span.started_at = item.observation.observed_at;
                span.anchor = Some(TraceAnchor {
                    terminal_id,
                    byte_offset: item.observation.byte_offset,
                    boundary_sizes: item.observation.boundary_sizes,
                });
                let id = self.folders.store().start_trace_span(&span)?;
                self.trace_spans.insert(terminal_id, id);
                self.command_shells.remove(&terminal_id);
            }
            ShellMark::Stopped(message) => {
                self.end_trace(
                    terminal_id,
                    item.observation,
                    TraceSpanStatus::Stopped,
                    TraceEventKind::WorkflowEvent,
                    &message,
                )?;
                self.command_shells.remove(&terminal_id);
            }
        }
        // A journal failure must not retry an already committed command boundary.
        if let Err(error) = self.publish_trace(workflow.workflow_id) {
            tracing::warn!(%error, "couldn't publish shell trace revision");
        }
        Ok(())
    }

    pub(super) fn start_trace(&mut self, workflow: &Workflow) -> Result<(), ApplicationError> {
        if workflow.kind == crate::WorkflowKind::Agents {
            let keys = workflow
                .agents
                .iter()
                .map(|agent| format!("agent:{}", agent.agent_id.0))
                .collect::<Vec<_>>();
            let spans = workflow
                .agents
                .iter()
                .zip(&keys)
                .filter(|(agent, _)| agent.terminal_id.value() != 0)
                .map(|(agent, key)| NewTraceSpan {
                    workflow_id: workflow.workflow_id,
                    lane_key: key,
                    lane_name: &agent.role,
                    is_agent: true,
                    role: Some(&agent.role),
                    harness: None,
                    title: "Shell",
                    started_at: workflow.started_at,
                    anchor: Some(TraceAnchor {
                        terminal_id: agent.terminal_id,
                        byte_offset: 0,
                        boundary_sizes: Some(Vec::new()),
                    }),
                })
                .collect::<Vec<_>>();
            let ids = self.folders.store().start_trace_spans(&spans)?;
            for (span, id) in spans.iter().zip(ids) {
                if let Some(anchor) = &span.anchor {
                    self.trace_spans.insert(anchor.terminal_id, id);
                }
            }
            return self.publish_trace(workflow.workflow_id);
        }
        let span_id = self.folders.store().start_trace_span(&new_span(workflow))?;
        self.trace_spans.insert(workflow.terminal_id, span_id);
        self.publish_trace(workflow.workflow_id)
    }

    pub(super) fn start_agent_trace(
        &mut self,
        workflow: &Workflow,
        harness: crate::HarnessId,
        placeholder: TerminalId,
        observation: Option<TerminalObservation>,
    ) -> Result<(), ApplicationError> {
        let ending = self
            .pending_trace_endings
            .get(&placeholder)
            .cloned()
            .or_else(|| {
                observation.map(|observation| PendingTraceEnding {
                    observation,
                    status: TraceSpanStatus::Stopped,
                    kind: TraceEventKind::ProcessStopped,
                    message: "Shell stopped when its agent started.".to_owned(),
                })
            });
        let ending = ending
            .as_ref()
            .map(|ending| ending.as_store_ending(placeholder));
        let placeholder_span = self.trace_spans.get(&placeholder).copied();
        let span_id = self.folders.store().start_agent_trace(
            &new_span(workflow),
            harness,
            placeholder_span.zip(ending.as_ref()),
        )?;
        self.trace_spans.remove(&placeholder);
        self.pending_trace_endings.remove(&placeholder);
        self.trace_spans.insert(workflow.terminal_id, span_id);
        self.publish_trace(workflow.workflow_id)
    }

    pub(super) fn stop_trace(
        &mut self,
        terminal_id: TerminalId,
        observation: TerminalObservation,
        message: &str,
    ) -> Result<(), ApplicationError> {
        self.stop_pending_shell_trace(terminal_id, &observation, message);
        self.end_trace(
            terminal_id,
            observation,
            TraceSpanStatus::Stopped,
            TraceEventKind::ProcessStopped,
            message,
        )
    }

    fn stop_pending_shell_trace(
        &mut self,
        terminal_id: TerminalId,
        observation: &TerminalObservation,
        message: &str,
    ) {
        self.shell_process_endings.remove(&terminal_id);
        if self
            .pending_shell_marks
            .iter()
            .any(|item| item.terminal_id == terminal_id)
        {
            self.pending_shell_marks
                .push_back(crate::terminal::ShellObservation {
                    terminal_id,
                    mark: crate::terminal::ShellMark::Stopped(message.into()),
                    observation: observation.clone(),
                });
        } else {
            self.command_shells.remove(&terminal_id);
        }
    }

    pub(super) fn end_trace(
        &mut self,
        terminal_id: TerminalId,
        observation: TerminalObservation,
        status: TraceSpanStatus,
        kind: TraceEventKind,
        message: &str,
    ) -> Result<(), ApplicationError> {
        let Some(span_id) = self.trace_spans.get(&terminal_id).copied() else {
            if let Some(&workflow_id) = self.step_terminals.get(&terminal_id) {
                let ending = self
                    .pending_trace_endings
                    .entry(terminal_id)
                    .or_insert_with(|| PendingTraceEnding {
                        observation,
                        status,
                        kind,
                        message: message.into(),
                    });
                self.folders.store().record_harness_process_ending(
                    workflow_id,
                    terminal_id,
                    &ending.as_store_ending(terminal_id),
                )?;
                self.pending_trace_endings.remove(&terminal_id);
                self.publish_trace(workflow_id)?;
            }
            return Ok(());
        };
        let ending = self
            .pending_trace_endings
            .entry(terminal_id)
            .or_insert_with(|| PendingTraceEnding {
                observation,
                status,
                kind,
                message: message.to_owned(),
            });
        let workflow_id = self
            .folders
            .store()
            .finish_trace_span(span_id, &ending.as_store_ending(terminal_id))?;
        self.trace_spans.remove(&terminal_id);
        self.pending_trace_endings.remove(&terminal_id);
        if let Some(id) = workflow_id {
            self.publish_trace(id)?;
        }
        Ok(())
    }

    pub(super) fn close_workflow_trace(
        &mut self,
        workflow_id: WorkflowId,
        observations: &[(TerminalId, TerminalObservation)],
    ) -> Result<(), ApplicationError> {
        let idle_endings: Vec<_> = observations
            .iter()
            .filter(|(terminal_id, _)| {
                self.step_terminals.contains_key(terminal_id)
                    && !self.trace_spans.contains_key(terminal_id)
            })
            .map(|(terminal_id, observation)| {
                (
                    *terminal_id,
                    TraceEnding {
                        observed_at: observation.observed_at,
                        status: TraceSpanStatus::Stopped,
                        kind: TraceEventKind::ProcessStopped,
                        message: "Process stopped when its workflow was closed.",
                        anchor: Some(TraceAnchor {
                            terminal_id: *terminal_id,
                            byte_offset: observation.byte_offset,
                            boundary_sizes: observation.boundary_sizes.clone(),
                        }),
                    },
                )
            })
            .collect();
        let pending = observations
            .iter()
            .filter_map(|(terminal_id, observation)| {
                self.trace_spans.get(terminal_id).map(|span_id| {
                    let ending = self
                        .pending_trace_endings
                        .get(terminal_id)
                        .cloned()
                        .unwrap_or_else(|| PendingTraceEnding {
                            observation: observation.clone(),
                            status: TraceSpanStatus::Stopped,
                            kind: TraceEventKind::ProcessStopped,
                            message: "Process stopped when its workflow was closed.".to_owned(),
                        });
                    (*terminal_id, *span_id, ending)
                })
            })
            .collect::<Vec<_>>();
        let endings = pending
            .iter()
            .map(|(terminal_id, span_id, ending)| (*span_id, ending.as_store_ending(*terminal_id)))
            .collect::<Vec<_>>();
        let changed = self.folders.store().close_workflow_and_trace(
            workflow_id,
            crate::workflow::timestamp(),
            &endings,
            &idle_endings,
        )?;
        for (terminal_id, _) in observations {
            self.trace_spans.remove(terminal_id);
            self.pending_trace_endings.remove(terminal_id);
        }
        for (terminal_id, observation) in observations {
            self.stop_pending_shell_trace(
                *terminal_id,
                observation,
                "Command stopped when its workflow was closed.",
            );
        }
        if changed {
            self.publish_trace(workflow_id)?;
        }
        Ok(())
    }

    pub(super) fn retry_trace_endings(&mut self) {
        let pending = self.pending_trace_endings.clone();
        for (id, ending) in pending {
            if let Err(error) = self.end_trace(
                id,
                ending.observation,
                ending.status,
                ending.kind,
                &ending.message,
            ) {
                tracing::warn!(%error, "failed to retry observed trace ending");
            }
        }
    }

    pub(super) fn publish_trace(&mut self, id: WorkflowId) -> Result<(), ApplicationError> {
        let summary = self.folders.store().trace_summary(id)?;
        self.events
            .append(EventKind::State(StateEvent::TraceChanged(summary)))?;
        Ok(())
    }
}

fn new_span(workflow: &Workflow) -> NewTraceSpan<'_> {
    let is_agent = workflow.kind == crate::WorkflowKind::SingleAgent;
    NewTraceSpan {
        workflow_id: workflow.workflow_id,
        lane_key: if is_agent { "agent" } else { "terminal" },
        lane_name: if is_agent { "Agent" } else { "Terminal" },
        is_agent,
        role: is_agent.then_some("agent"),
        harness: workflow.harness.map(|harness| harness.definition().name),
        title: if is_agent { &workflow.name } else { "Shell" },
        started_at: workflow.started_at,
        anchor: Some(TraceAnchor {
            terminal_id: workflow.terminal_id,
            byte_offset: 0,
            boundary_sizes: Some(Vec::new()),
        }),
    }
}

#[cfg(test)]
mod tests {
    use std::thread;
    use std::time::{Duration, Instant};

    use super::*;
    use crate::{
        Command, CommandDisposition, RequestId, TerminalSize, WorkflowKind, WorkflowStatus,
    };

    fn create(application: &Application, folder: &std::path::Path) -> Workflow {
        application
            .handle_command(
                RequestId(1),
                Command::OpenFolder {
                    path: folder.to_owned(),
                },
            )
            .unwrap();
        let receipt = application
            .handle_command(
                RequestId(2),
                Command::CreateWorkflow {
                    folder: folder.to_owned(),
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
        assert_eq!(receipt.disposition, CommandDisposition::Accepted);
        application.snapshot().unwrap().workflows.workflows[0].clone()
    }

    fn reject_trace_writes(application: &Application) {
        application.lock_inner().unwrap().folders.store().execute_test_sql(
            "CREATE TRIGGER reject_trace BEFORE INSERT ON trace_events BEGIN SELECT RAISE(FAIL, 'test recording failure'); END;"
        );
    }

    fn allow_trace_writes(application: &Application) {
        application
            .lock_inner()
            .unwrap()
            .folders
            .store()
            .execute_test_sql("DROP TRIGGER reject_trace");
    }

    fn wait_shell_trace(
        application: &Application,
        workflow: &Workflow,
        ready: impl Fn(&WorkflowTracePage) -> bool,
    ) -> WorkflowTracePage {
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            while let Some(chunk) = application.next_terminal_chunk().unwrap() {
                // Fish probes device attributes before its first prompt. Stand in for the
                // terminal emulator so PTY integration tests exercise actual interactive hooks.
                if chunk.bytes.windows(4).any(|bytes| bytes == b"\x1b[0c") {
                    application
                        .write_terminal_input(workflow.terminal_id, b"\x1b[?62;4c")
                        .unwrap();
                }
            }
            let page = application
                .workflow_trace(workflow.workflow_id, None, 200)
                .unwrap();
            if ready(&page) {
                return page;
            }
            assert!(Instant::now() < deadline, "shell trace timed out: {page:?}");
            thread::sleep(Duration::from_millis(5));
        }
    }

    fn check_command_shell(shell: &str) {
        let folder = tempfile::tempdir().unwrap();
        let home = tempfile::tempdir().unwrap();
        let profile = "printf 'TWINE_STARTUP\\n'\n";
        for file in [".zshenv", ".zprofile", ".zshrc", ".zlogin", ".bash_profile"] {
            std::fs::write(home.path().join(file), profile).unwrap();
        }
        std::fs::create_dir_all(home.path().join(".config/fish")).unwrap();
        std::fs::write(home.path().join(".config/fish/config.fish"), profile).unwrap();
        let mut application = Application::with_event_capacity(4096).unwrap();
        application.terminals.set_test_shell(shell.into());
        application
            .terminals
            .set_test_shell_home(home.path().to_owned());
        let workflow = create(&application, folder.path());
        wait_shell_trace(&application, &workflow, |page| page.spans.is_empty());
        let commands = [
            ("printf 'TWINE_OUTPUT ☃\\n'", TraceSpanStatus::Completed, 0),
            ("false", TraceSpanStatus::Failed, 1),
            (
                "printf 'pipe\\n' | cat; true",
                TraceSpanStatus::Completed,
                0,
            ),
            ("false", TraceSpanStatus::Failed, 1),
        ];
        for (index, (command, status, code)) in commands.iter().enumerate() {
            application
                .write_terminal_input(workflow.terminal_id, format!("{command}\n").as_bytes())
                .unwrap();
            let page = wait_shell_trace(&application, &workflow, |page| {
                page.spans.len() == index + 1 && page.spans[0].ended_at.is_some()
            });
            let span = &page.spans[0];
            assert_eq!(&span.title, command, "{shell}");
            assert_eq!(&span.status, status, "{shell}");
            assert!(!span.is_live);
            let events = application
                .trace_events(span.span_id, None, 10)
                .unwrap()
                .events;
            assert_eq!(events.len(), 2, "{shell}: {events:?}");
            assert_eq!(events[0].message, "Command started.");
            assert_eq!(
                events[1].message,
                format!("Command exited with code {code}.")
            );
            let start = events[0].anchor.as_ref().unwrap();
            let end = events[1].anchor.as_ref().unwrap();
            assert!(end.byte_offset > start.byte_offset);
            assert_eq!(start.terminal_id, workflow.terminal_id);
            let crate::TranscriptRead::Output(page) = application
                .read_terminal_transcript(workflow.terminal_id, 0, crate::MAX_TRANSCRIPT_READ_BYTES)
                .unwrap()
            else {
                panic!("missing transcript");
            };
            assert!(page.replay_available);
            assert!(page.bytes[..usize::try_from(start.byte_offset).unwrap()].ends_with(b"\x07"));
            if index == 0 {
                assert!(
                    String::from_utf8_lossy(
                        &page.bytes[usize::try_from(start.byte_offset).unwrap()
                            ..usize::try_from(end.byte_offset).unwrap()]
                    )
                    .contains("TWINE_OUTPUT ☃")
                );
                application
                    .write_terminal_input(
                        workflow.terminal_id,
                        if shell == "/bin/bash" {
                            b"\n# comment only\n"
                        } else {
                            b"\n"
                        },
                    )
                    .unwrap();
            }
        }
        application
            .write_terminal_input(workflow.terminal_id, b"exit 7\n")
            .unwrap();
        let page = wait_shell_trace(&application, &workflow, |page| {
            page.spans.len() == 5 && page.spans[0].ended_at.is_some()
        });
        assert_eq!(page.spans[0].title, "exit 7");
        assert_eq!(page.spans[0].status, TraceSpanStatus::Failed);
        for file in [".zshenv", ".zprofile", ".zshrc", ".zlogin", ".bash_profile"] {
            assert_eq!(
                std::fs::read_to_string(home.path().join(file)).unwrap(),
                profile
            );
        }
    }

    #[test]
    fn zsh_commands_have_titles_statuses_and_output_anchors() {
        check_command_shell("/bin/zsh");
    }

    #[test]
    fn bash_commands_have_titles_statuses_and_output_anchors() {
        check_command_shell("/bin/bash");
    }

    #[test]
    fn fish_commands_have_titles_statuses_and_output_anchors() {
        let shell = [
            "/opt/homebrew/bin/fish",
            "/usr/local/bin/fish",
            "/usr/bin/fish",
        ]
        .into_iter()
        .find(|path| std::path::Path::new(path).is_file());
        if let Some(shell) = shell {
            check_command_shell(shell);
        } else {
            assert!(
                std::env::var_os("TWINE_REQUIRE_FISH_TESTS").is_none(),
                "install fish to run the shell integration tests"
            );
        }
    }

    #[test]
    fn bash_disabled_history_uses_one_lifetime_span() {
        let folder = tempfile::tempdir().unwrap();
        let home = tempfile::tempdir().unwrap();
        std::fs::write(home.path().join(".bash_profile"), "HISTSIZE=0\n").unwrap();
        let mut application = Application::with_event_capacity(4096).unwrap();
        application.terminals.set_test_shell("/bin/bash".into());
        application
            .terminals
            .set_test_shell_home(home.path().to_owned());
        let workflow = create(&application, folder.path());
        application
            .write_terminal_input(workflow.terminal_id, b"false\nexit 7\n")
            .unwrap();
        let page = wait_shell_trace(&application, &workflow, |page| {
            page.spans[0].ended_at.is_some()
        });
        assert_eq!(page.spans.len(), 1);
        assert_eq!(page.spans[0].title, "Shell");
        assert_eq!(page.spans[0].status, TraceSpanStatus::Exited);
    }

    #[test]
    fn bash_history_disabled_during_a_session_falls_back_once() {
        let folder = tempfile::tempdir().unwrap();
        let home = tempfile::tempdir().unwrap();
        let mut application = Application::with_event_capacity(4096).unwrap();
        application.terminals.set_test_shell("/bin/bash".into());
        application
            .terminals
            .set_test_shell_home(home.path().to_owned());
        let workflow = create(&application, folder.path());
        wait_shell_trace(&application, &workflow, |page| page.spans.is_empty());
        application
            .write_terminal_input(workflow.terminal_id, b"HISTSIZE=0\n")
            .unwrap();
        wait_shell_trace(&application, &workflow, |page| {
            page.spans.len() == 1 && page.spans[0].ended_at.is_some()
        });
        application
            .write_terminal_input(workflow.terminal_id, b"true\nfalse\nexit\n")
            .unwrap();
        let page = wait_shell_trace(&application, &workflow, |page| {
            page.spans.len() == 2 && page.spans[0].ended_at.is_some()
        });
        assert_eq!(page.spans[0].title, "Shell");
        assert_eq!(page.spans[1].title, "HISTSIZE=0");
        assert_eq!(page.spans[1].status, TraceSpanStatus::Completed);
    }

    fn command_observation(
        workflow: &Workflow,
        mark: crate::terminal::ShellMark,
    ) -> crate::terminal::ShellObservation {
        crate::terminal::ShellObservation {
            terminal_id: workflow.terminal_id,
            mark,
            observation: TerminalObservation {
                integrated_shell: true,
                observed_at: workflow.started_at + 1,
                byte_offset: 100,
                boundary_sizes: Some(Vec::new()),
            },
        }
    }

    #[test]
    fn delayed_command_start_is_persisted_and_stopped_after_workflow_close() {
        check_delayed_command_close(false);
    }

    #[test]
    fn delayed_command_start_is_persisted_and_stopped_after_folder_close() {
        check_delayed_command_close(true);
    }

    fn check_delayed_command_close(close_folder: bool) {
        use crate::terminal::ShellMark;
        let folder = tempfile::tempdir().unwrap();
        let mut application = Application::with_event_capacity(4096).unwrap();
        application.terminals.set_test_shell("/bin/sh".into());
        let workflow = create(&application, folder.path());
        application
            .lock_inner()
            .unwrap()
            .record_shell_observations(vec![command_observation(&workflow, ShellMark::Prompt)]);
        reject_trace_writes(&application);
        application
            .lock_inner()
            .unwrap()
            .record_shell_observations(vec![command_observation(
                &workflow,
                ShellMark::CommandStart("delayed".into()),
            )]);
        application
            .handle_command(
                RequestId(3),
                if close_folder {
                    Command::CloseFolder
                } else {
                    Command::CloseWorkflow {
                        workflow_id: workflow.workflow_id,
                    }
                },
            )
            .unwrap();
        assert!(
            application
                .snapshot()
                .unwrap()
                .workflows
                .workflows
                .is_empty()
        );
        allow_trace_writes(&application);
        let page = application
            .workflow_trace(workflow.workflow_id, None, 10)
            .unwrap();
        assert_eq!(page.spans.len(), 1);
        assert_eq!(page.spans[0].title, "delayed");
        assert_eq!(page.spans[0].status, TraceSpanStatus::Stopped);
        assert_eq!(
            application
                .trace_events(page.spans[0].span_id, None, 10)
                .unwrap()
                .events
                .len(),
            2
        );
        assert!(
            application
                .lock_inner()
                .unwrap()
                .pending_shell_workflows
                .is_empty()
        );
    }

    #[test]
    fn failed_command_ending_survives_folder_close_and_storage_recovery() {
        use crate::terminal::ShellMark;
        let folder = tempfile::tempdir().unwrap();
        let mut application = Application::with_event_capacity(4096).unwrap();
        application.terminals.set_test_shell("/bin/sh".into());
        let workflow = create(&application, folder.path());
        application
            .lock_inner()
            .unwrap()
            .record_shell_observations(vec![
                command_observation(&workflow, ShellMark::Prompt),
                command_observation(
                    &workflow,
                    ShellMark::CommandStart("completed before close".into()),
                ),
            ]);
        reject_trace_writes(&application);
        application
            .lock_inner()
            .unwrap()
            .record_shell_observations(vec![command_observation(
                &workflow,
                ShellMark::CommandEnd(0),
            )]);
        application
            .handle_command(RequestId(3), Command::CloseFolder)
            .unwrap();
        allow_trace_writes(&application);
        let page = application
            .workflow_trace(workflow.workflow_id, None, 10)
            .unwrap();
        assert_eq!(page.spans.len(), 1);
        assert_eq!(page.spans[0].title, "completed before close");
        assert_eq!(page.spans[0].status, TraceSpanStatus::Completed);
        assert_eq!(
            application
                .trace_events(page.spans[0].span_id, None, 10)
                .unwrap()
                .events
                .len(),
            2
        );
    }

    #[test]
    fn failed_integration_loss_preserves_its_fallback_when_the_folder_closes() {
        use crate::terminal::ShellMark;
        let folder = tempfile::tempdir().unwrap();
        let mut application = Application::with_event_capacity(4096).unwrap();
        application.terminals.set_test_shell("/bin/sh".into());
        let workflow = create(&application, folder.path());
        application
            .lock_inner()
            .unwrap()
            .record_shell_observations(vec![command_observation(
                &workflow,
                ShellMark::CommandStart("running".into()),
            )]);
        reject_trace_writes(&application);
        application
            .lock_inner()
            .unwrap()
            .record_shell_observations(vec![command_observation(&workflow, ShellMark::Lost)]);
        application
            .handle_command(RequestId(3), Command::CloseFolder)
            .unwrap();
        allow_trace_writes(&application);
        let page = application
            .workflow_trace(workflow.workflow_id, None, 10)
            .unwrap();
        assert_eq!(page.spans.len(), 2);
        assert_eq!(page.spans[0].title, "Shell");
        assert_eq!(page.spans[1].title, "running");
        assert!(
            page.spans
                .iter()
                .all(|span| span.status == TraceSpanStatus::Stopped)
        );
    }

    #[test]
    fn integrated_process_exit_defers_before_its_first_mark_and_preserves_fallback_status() {
        use crate::terminal::{ShellMark, TerminalStream, TranscriptRecorder};
        let folder = tempfile::tempdir().unwrap();
        let mut application = Application::with_event_capacity(4096).unwrap();
        application.terminals.set_test_shell("/bin/sh".into());
        let workflow = create(&application, folder.path());
        let observation = command_observation(&workflow, ShellMark::Prompt).observation;
        let finished = TerminalStream::new(
            4096,
            4,
            std::sync::Arc::new(TranscriptRecorder::temporary().unwrap()),
        )
        .unwrap();
        let mut inner = application.lock_inner().unwrap();
        assert!(inner.defer_shell_process_ending(
            workflow.terminal_id,
            &observation,
            TraceSpanStatus::Failed,
            TraceEventKind::ProcessFailed,
            "exit 7"
        ));
        inner.finish_shell_process_endings(&application.terminal_output);
        assert!(
            inner
                .shell_process_endings
                .contains_key(&workflow.terminal_id)
        );
        inner.record_shell_observations(vec![
            command_observation(&workflow, ShellMark::Prompt),
            command_observation(&workflow, ShellMark::CommandStart("exit 7".into())),
            command_observation(&workflow, ShellMark::CommandEnd(7)),
        ]);
        inner.finish_shell_process_endings(&finished);
        drop(inner);
        let page = application
            .workflow_trace(workflow.workflow_id, None, 10)
            .unwrap();
        assert_eq!(page.spans[0].title, "exit 7");
        assert_eq!(page.spans[0].status, TraceSpanStatus::Failed);

        let second_folder = tempfile::tempdir().unwrap();
        let mut fallback = Application::with_event_capacity(4096).unwrap();
        fallback.terminals.set_test_shell("/bin/sh".into());
        let second = create(&fallback, second_folder.path());
        let mut inner = fallback.lock_inner().unwrap();
        inner.defer_shell_process_ending(
            second.terminal_id,
            &observation,
            TraceSpanStatus::Exited,
            TraceEventKind::ProcessExited,
            "exit 0",
        );
        inner.finish_shell_process_endings(&finished);
        drop(inner);
        let page = fallback
            .workflow_trace(second.workflow_id, None, 10)
            .unwrap();
        assert_eq!(page.spans[0].title, "Shell");
        assert_eq!(page.spans[0].status, TraceSpanStatus::Exited);
    }

    #[test]
    fn command_boundaries_retry_in_order_after_a_store_failure() {
        use crate::terminal::{ShellMark, ShellObservation};
        let folder = tempfile::tempdir().unwrap();
        let application = Application::with_event_capacity(4096).unwrap();
        let workflow = create(&application, folder.path());
        reject_trace_writes(&application);
        let marks = [
            ShellMark::Prompt,
            ShellMark::CommandStart("first command".into()),
            ShellMark::CommandEnd(1),
            ShellMark::CommandStart("second command".into()),
            ShellMark::CommandEnd(0),
        ]
        .into_iter()
        .enumerate()
        .map(|(i, mark)| ShellObservation {
            terminal_id: workflow.terminal_id,
            mark,
            observation: TerminalObservation {
                integrated_shell: false,
                observed_at: workflow.started_at + i as u64,
                byte_offset: i as u64 + 100,
                boundary_sizes: Some(Vec::new()),
            },
        })
        .collect();
        application
            .lock_inner()
            .unwrap()
            .record_shell_observations(marks);
        assert_eq!(
            application.lock_inner().unwrap().pending_shell_marks.len(),
            4
        );
        allow_trace_writes(&application);
        let page = application
            .workflow_trace(workflow.workflow_id, None, 10)
            .unwrap();
        assert_eq!(page.spans.len(), 2);
        assert_eq!(page.spans[0].title, "second command");
        assert_eq!(page.spans[0].status, TraceSpanStatus::Completed);
        assert_eq!(page.spans[1].title, "first command");
        assert_eq!(page.spans[1].status, TraceSpanStatus::Failed);
        for span in page.spans {
            let events = application
                .trace_events(span.span_id, None, 10)
                .unwrap()
                .events;
            assert_eq!(events.len(), 2);
            assert_eq!(events[0].timestamp, span.started_at);
            assert_eq!(events[1].timestamp, span.ended_at.unwrap());
        }
    }

    #[test]
    fn shell_marks_do_not_create_command_spans_in_agent_terminals() {
        let folder = tempfile::tempdir().unwrap();
        let application = Application::with_event_capacity(4096).unwrap();
        let workflow = create_agents(&application, folder.path()).unwrap();
        application
            .lock_inner()
            .unwrap()
            .record_shell_observations(vec![crate::terminal::ShellObservation {
                terminal_id: workflow.agents[0].terminal_id,
                mark: crate::terminal::ShellMark::CommandStart("not a terminal workflow".into()),
                observation: TerminalObservation {
                    integrated_shell: false,
                    observed_at: workflow.started_at,
                    byte_offset: 42,
                    boundary_sizes: Some(Vec::new()),
                },
            }]);
        let page = application
            .workflow_trace(workflow.workflow_id, None, 10)
            .unwrap();
        assert_eq!(page.spans.len(), 2);
        assert!(page.spans.iter().all(|span| span.title == "Shell"));
    }

    fn create_agents(
        application: &Application,
        folder: &std::path::Path,
    ) -> Result<Workflow, ApplicationError> {
        application.handle_command(
            RequestId(1),
            Command::OpenFolder {
                path: folder.to_owned(),
            },
        )?;
        application.handle_command(
            RequestId(2),
            Command::CreateWorkflow {
                folder: folder.to_owned(),
                session_id: None,
                kind: WorkflowKind::Agents,
                roles: vec!["Worker".to_owned(), "Worker".to_owned()],
                size: TerminalSize {
                    rows: 24,
                    columns: 80,
                    pixel_width: 800,
                    pixel_height: 480,
                },
            },
        )?;
        Ok(application.snapshot()?.workflows.workflows[0].clone())
    }

    #[test]
    fn agents_with_the_same_role_have_distinct_lanes_and_exit_independently() {
        let folder = tempfile::tempdir().unwrap();
        let application = Application::with_event_capacity(4096).unwrap();
        let workflow = create_agents(&application, folder.path()).unwrap();
        let page = application
            .workflow_trace(workflow.workflow_id, None, 10)
            .unwrap();
        assert_eq!(page.summary.agent_count, 2);
        assert_eq!(page.lanes.len(), 2);
        assert!(
            page.lanes
                .iter()
                .all(|lane| lane.is_agent && lane.role.as_deref() == Some("Worker"))
        );
        assert_ne!(page.spans[0].lane_id, page.spans[1].lane_id);
        assert!(
            page.spans
                .iter()
                .all(|span| span.is_live && span.started_at == workflow.started_at)
        );
        let first = workflow.agents[0].terminal_id;
        let second = workflow.agents[1].terminal_id;
        application.lock_inner().unwrap().record_terminal_exit_at(
            first,
            Ok(crate::TerminalExit {
                exit_code: 3,
                signal: None,
            }),
            TerminalObservation {
                integrated_shell: false,
                observed_at: workflow.started_at + 10,
                byte_offset: 42,
                boundary_sizes: Some(Vec::new()),
            },
        );
        let workflows = application.snapshot().unwrap().workflows.workflows;
        assert_eq!(workflows[0].status, WorkflowStatus::Running);
        let page = application
            .workflow_trace(workflow.workflow_id, None, 10)
            .unwrap();
        assert_eq!(page.spans.iter().filter(|span| span.is_live).count(), 1);
        let span = page
            .spans
            .iter()
            .find(|span| span.terminal_id == Some(first))
            .unwrap();
        assert_eq!(span.status, TraceSpanStatus::Exited);
        let events = application
            .trace_events(span.span_id, None, 10)
            .unwrap()
            .events;
        assert_eq!(events[1].anchor.as_ref().unwrap().byte_offset, 42);
        application.lock_inner().unwrap().record_terminal_exit_at(
            second,
            Ok(crate::TerminalExit {
                exit_code: 0,
                signal: None,
            }),
            TerminalObservation {
                integrated_shell: false,
                observed_at: workflow.started_at + 20,
                byte_offset: 70,
                boundary_sizes: Some(Vec::new()),
            },
        );
        let snapshot = application.snapshot().unwrap();
        assert_eq!(
            snapshot.workflows.workflows[0].status,
            WorkflowStatus::Exited
        );
        assert_eq!(
            snapshot.workflows.workflows[0].ended_at,
            Some(workflow.started_at + 20)
        );
        application
            .handle_command(
                RequestId(3),
                Command::CloseWorkflow {
                    workflow_id: workflow.workflow_id,
                },
            )
            .unwrap();
        let page = application
            .workflow_trace(workflow.workflow_id, None, 10)
            .unwrap();
        assert_eq!(page.spans.len(), 2);
        assert!(
            page.spans
                .iter()
                .all(|span| !span.is_live && span.status == TraceSpanStatus::Exited)
        );
        for span in page.spans {
            assert_eq!(
                application
                    .trace_events(span.span_id, None, 10)
                    .unwrap()
                    .events
                    .len(),
                2
            );
        }
    }

    #[test]
    fn failed_multi_agent_close_rolls_back_every_ending_and_then_closes_all_processes() {
        let folder = tempfile::tempdir().unwrap();
        let application = Application::with_event_capacity(4096).unwrap();
        let workflow = create_agents(&application, folder.path()).unwrap();
        application.lock_inner().unwrap().folders.store().execute_test_sql(
            "CREATE TRIGGER reject_trace BEFORE INSERT ON trace_events WHEN NEW.kind = 'processStopped' AND NEW.span_id = 2 BEGIN SELECT RAISE(FAIL, 'test second ending failure'); END;"
        );
        assert!(
            application
                .handle_command(
                    RequestId(3),
                    Command::CloseWorkflow {
                        workflow_id: workflow.workflow_id
                    }
                )
                .is_err()
        );
        let page = application
            .workflow_trace(workflow.workflow_id, None, 10)
            .unwrap();
        assert!(
            page.spans
                .iter()
                .all(|span| span.is_live && span.status == TraceSpanStatus::Running)
        );
        for span in &page.spans {
            assert_eq!(
                application
                    .trace_events(span.span_id, None, 10)
                    .unwrap()
                    .events
                    .len(),
                1
            );
        }
        assert_eq!(
            application
                .lock_inner()
                .unwrap()
                .folders
                .read_store()
                .workflows(folder.path())
                .unwrap()
                .len(),
            1
        );
        allow_trace_writes(&application);
        application
            .handle_command(
                RequestId(4),
                Command::CloseWorkflow {
                    workflow_id: workflow.workflow_id,
                },
            )
            .unwrap();
        let page = application
            .workflow_trace(workflow.workflow_id, None, 10)
            .unwrap();
        assert!(
            page.spans
                .iter()
                .all(|span| !span.is_live && span.status == TraceSpanStatus::Stopped)
        );
        for span in &page.spans {
            assert_eq!(
                application
                    .trace_events(span.span_id, None, 10)
                    .unwrap()
                    .events
                    .len(),
                2
            );
        }
        assert!(application.snapshot().unwrap().terminals.is_empty());
        for agent in workflow.agents {
            assert!(
                application
                    .write_terminal_input(agent.terminal_id, b"echo alive\n")
                    .is_err()
            );
        }
    }

    #[test]
    fn failed_multi_agent_start_rolls_back_all_spans_and_stops_every_process() {
        let folder = tempfile::tempdir().unwrap();
        let application = Application::with_event_capacity(4096).unwrap();
        application.lock_inner().unwrap().folders.store().execute_test_sql(
            "CREATE TRIGGER reject_trace BEFORE INSERT ON trace_events WHEN NEW.kind = 'processStarted' AND NEW.span_id = 2 BEGIN SELECT RAISE(FAIL, 'test second start failure'); END;"
        );
        assert!(create_agents(&application, folder.path()).is_err());
        let snapshot = application.snapshot().unwrap();
        assert!(snapshot.terminals.is_empty());
        assert!(snapshot.workflows.workflows.is_empty());
        let page = application.workflow_trace(WorkflowId(1), None, 10).unwrap();
        assert!(page.spans.is_empty());
        assert!(page.lanes.is_empty());
        for id in [1, 2] {
            assert!(
                application
                    .terminals
                    .size(TerminalId::from_value(id))
                    .is_none()
            );
        }
    }

    #[test]
    fn restoring_agents_reuses_lane_identity_and_cleans_up_all_failed_trace_starts() {
        let folder = tempfile::tempdir().unwrap();
        let application = Application::with_event_capacity(4096).unwrap();
        let workflow = create_agents(&application, folder.path()).unwrap();
        let initial = application
            .workflow_trace(workflow.workflow_id, None, 10)
            .unwrap();
        application
            .handle_command(RequestId(3), Command::CloseFolder)
            .unwrap();
        application.lock_inner().unwrap().folders.store().execute_test_sql(
            "CREATE TRIGGER reject_trace BEFORE INSERT ON trace_events WHEN NEW.kind = 'processStarted' AND NEW.span_id = 4 BEGIN SELECT RAISE(FAIL, 'test second restored start failure'); END;"
        );
        application
            .handle_command(
                RequestId(4),
                Command::OpenFolder {
                    path: folder.path().to_owned(),
                },
            )
            .unwrap();
        let snapshot = application.snapshot().unwrap();
        assert!(snapshot.terminals.is_empty());
        let failed = &snapshot.workflows.workflows[0];
        assert_eq!(failed.status, WorkflowStatus::Failed);
        assert!(
            failed
                .agents
                .iter()
                .all(|agent| agent.terminal_id.value() == 0)
        );
        let page = application
            .workflow_trace(workflow.workflow_id, None, 10)
            .unwrap();
        assert_eq!(page.spans.len(), 2);
        assert_eq!(page.lanes, initial.lanes);
        allow_trace_writes(&application);
        application
            .handle_command(RequestId(5), Command::CloseFolder)
            .unwrap();
        application
            .handle_command(
                RequestId(6),
                Command::OpenFolder {
                    path: folder.path().to_owned(),
                },
            )
            .unwrap();
        let page = application
            .workflow_trace(workflow.workflow_id, None, 10)
            .unwrap();
        assert_eq!(page.lanes, initial.lanes);
        assert_eq!(page.spans.len(), 4);
        assert_eq!(page.spans.iter().filter(|span| span.is_live).count(), 2);
    }

    #[test]
    fn trace_write_failure_never_prevents_folder_process_cleanup() {
        let folder = tempfile::tempdir().unwrap();
        let application = Application::with_event_capacity(4096).unwrap();
        let workflow = create(&application, folder.path());
        reject_trace_writes(&application);
        application
            .handle_command(RequestId(3), Command::CloseFolder)
            .unwrap();
        let snapshot = application.snapshot().unwrap();
        assert!(snapshot.folders.open_folder.is_none());
        assert!(snapshot.workflows.workflows.is_empty());
        assert!(snapshot.terminals.is_empty());
        assert!(
            application
                .write_terminal_input(workflow.terminal_id, b"echo alive\n")
                .is_err()
        );
        allow_trace_writes(&application);
        application
            .handle_command(RequestId(4), Command::Ping)
            .unwrap();
        let page = application
            .workflow_trace(workflow.workflow_id, None, 10)
            .unwrap();
        assert_eq!(page.spans[0].status, TraceSpanStatus::Stopped);
        assert_eq!(
            application
                .trace_events(page.spans[0].span_id, None, 10)
                .unwrap()
                .events
                .len(),
            2
        );
    }

    #[test]
    fn shutdown_retries_endings_even_after_folder_cleanup_removes_the_process() {
        let data = tempfile::tempdir().unwrap();
        let folder = tempfile::tempdir().unwrap();
        let mut application =
            Application::with_config(data.path(), crate::config::Config::default()).unwrap();
        application.terminals.set_test_shell("/bin/sh".into());
        let workflow = create(&application, folder.path());
        reject_trace_writes(&application);
        application
            .handle_command(RequestId(3), Command::CloseFolder)
            .unwrap();
        assert_eq!(
            application
                .lock_inner()
                .unwrap()
                .pending_trace_endings
                .len(),
            1
        );
        allow_trace_writes(&application);
        drop(application);
        let application =
            Application::with_config(data.path(), crate::config::Config::default()).unwrap();
        let page = application
            .workflow_trace(workflow.workflow_id, None, 10)
            .unwrap();
        assert_eq!(page.spans[0].status, TraceSpanStatus::Stopped);
        let events = application
            .trace_events(page.spans[0].span_id, None, 10)
            .unwrap()
            .events;
        assert_eq!(events.len(), 2);
        assert!(events[1].message.contains("folder was closed"));
    }

    #[test]
    fn failed_restoration_stops_the_process_and_publishes_a_visible_failed_tab() {
        let folder = tempfile::tempdir().unwrap();
        let application = Application::with_event_capacity(4096).unwrap();
        let workflow = create(&application, folder.path());
        application
            .handle_command(RequestId(3), Command::CloseFolder)
            .unwrap();
        reject_trace_writes(&application);
        application
            .handle_command(
                RequestId(4),
                Command::OpenFolder {
                    path: folder.path().to_owned(),
                },
            )
            .unwrap();
        let snapshot = application.snapshot().unwrap();
        assert_eq!(snapshot.workflows.workflows.len(), 1);
        assert_eq!(
            snapshot.workflows.workflows[0].status,
            WorkflowStatus::Failed
        );
        assert_eq!(snapshot.workflows.workflows[0].terminal_id.value(), 0);
        assert!(snapshot.terminals.is_empty());
        allow_trace_writes(&application);
        application
            .handle_command(RequestId(5), Command::CloseFolder)
            .unwrap();
        application
            .handle_command(
                RequestId(6),
                Command::OpenFolder {
                    path: folder.path().to_owned(),
                },
            )
            .unwrap();
        let snapshot = application.snapshot().unwrap();
        assert_eq!(snapshot.terminals.len(), 1);
        assert_eq!(
            snapshot.workflows.workflows[0].workflow_id,
            workflow.workflow_id
        );
        assert_eq!(
            snapshot.workflows.workflows[0].status,
            WorkflowStatus::Running
        );
        assert_eq!(snapshot.traces[0].span_count, 2);
    }

    #[test]
    fn a_failed_exit_write_is_retried_with_its_original_observation() {
        let folder = tempfile::tempdir().unwrap();
        let application = Application::with_event_capacity(4096).unwrap();
        let workflow = create(&application, folder.path());
        reject_trace_writes(&application);
        let at = workflow.started_at + 25;
        application.lock_inner().unwrap().record_terminal_exit_at(
            workflow.terminal_id,
            Ok(crate::TerminalExit {
                exit_code: 7,
                signal: None,
            }),
            TerminalObservation {
                integrated_shell: false,
                observed_at: at,
                byte_offset: 42,
                boundary_sizes: Some(Vec::new()),
            },
        );
        assert_eq!(
            application
                .lock_inner()
                .unwrap()
                .pending_trace_endings
                .len(),
            1
        );
        allow_trace_writes(&application);
        application
            .handle_command(
                RequestId(3),
                Command::CloseWorkflow {
                    workflow_id: workflow.workflow_id,
                },
            )
            .unwrap();
        let page = application
            .workflow_trace(workflow.workflow_id, None, 10)
            .unwrap();
        let events = application
            .trace_events(page.spans[0].span_id, None, 10)
            .unwrap()
            .events;
        assert_eq!(events.len(), 2);
        assert_eq!(events[1].kind, TraceEventKind::ProcessExited);
        assert!(events[1].message.contains("code 7"));
        assert_eq!(events[1].timestamp, at);
        assert_eq!(events[1].anchor.as_ref().unwrap().byte_offset, 42);
    }

    #[test]
    fn failed_workflow_close_rolls_back_its_trace_ending() {
        let folder = tempfile::tempdir().unwrap();
        let application = Application::with_event_capacity(4096).unwrap();
        let workflow = create(&application, folder.path());
        application.lock_inner().unwrap().folders.store().execute_test_sql(
            "CREATE TRIGGER reject_close BEFORE UPDATE OF closed_at ON workflows BEGIN SELECT RAISE(FAIL, 'test close failure'); END;"
        );
        assert!(
            application
                .handle_command(
                    RequestId(3),
                    Command::CloseWorkflow {
                        workflow_id: workflow.workflow_id
                    }
                )
                .is_err()
        );
        let page = application
            .workflow_trace(workflow.workflow_id, None, 10)
            .unwrap();
        assert!(page.spans[0].is_live);
        assert_eq!(page.spans[0].status, TraceSpanStatus::Running);
        assert_eq!(
            application
                .trace_events(page.spans[0].span_id, None, 10)
                .unwrap()
                .events
                .len(),
            1
        );
        application
            .write_terminal_input(workflow.terminal_id, b"echo alive\n")
            .unwrap();
        application
            .lock_inner()
            .unwrap()
            .folders
            .store()
            .execute_test_sql("DROP TRIGGER reject_close");
        application
            .handle_command(
                RequestId(4),
                Command::CloseWorkflow {
                    workflow_id: workflow.workflow_id,
                },
            )
            .unwrap();
        assert_eq!(
            application
                .workflow_trace(workflow.workflow_id, None, 10)
                .unwrap()
                .spans[0]
                .status,
            TraceSpanStatus::Stopped
        );
    }

    #[test]
    fn failed_trace_ending_rolls_back_the_workflow_closed_marker() {
        let folder = tempfile::tempdir().unwrap();
        let application = Application::with_event_capacity(4096).unwrap();
        let workflow = create(&application, folder.path());
        reject_trace_writes(&application);
        assert!(
            application
                .handle_command(
                    RequestId(3),
                    Command::CloseWorkflow {
                        workflow_id: workflow.workflow_id,
                    }
                )
                .is_err()
        );
        let stored = application
            .lock_inner()
            .unwrap()
            .folders
            .read_store()
            .workflows(folder.path())
            .unwrap();
        assert_eq!(stored.len(), 1);
        assert_eq!(stored[0].workflow_id, workflow.workflow_id);
        let page = application
            .workflow_trace(workflow.workflow_id, None, 10)
            .unwrap();
        assert!(page.spans[0].is_live);
        assert_eq!(page.spans[0].status, TraceSpanStatus::Running);
        assert_eq!(
            application
                .trace_events(page.spans[0].span_id, None, 10)
                .unwrap()
                .events
                .len(),
            1
        );
        assert_eq!(application.snapshot().unwrap().workflows.workflows.len(), 1);
        allow_trace_writes(&application);
        application
            .handle_command(
                RequestId(4),
                Command::CloseWorkflow {
                    workflow_id: workflow.workflow_id,
                },
            )
            .unwrap();
        assert!(
            application
                .lock_inner()
                .unwrap()
                .folders
                .read_store()
                .workflows(folder.path())
                .unwrap()
                .is_empty()
        );
        assert_eq!(
            application
                .workflow_trace(workflow.workflow_id, None, 10)
                .unwrap()
                .spans[0]
                .status,
            TraceSpanStatus::Stopped
        );
    }

    #[test]
    fn durable_trace_anchors_read_the_original_binary_transcript_after_relaunch() {
        let data = tempfile::tempdir().unwrap();
        let folder = tempfile::tempdir().unwrap();
        let (workflow_id, span_id, anchor, expected, events) = {
            let mut application =
                Application::with_config(data.path(), crate::config::Config::default()).unwrap();
            application.terminals.set_test_shell("/bin/sh".into());
            let workflow = create(&application, folder.path());
            application
                .write_terminal_input(
                    workflow.terminal_id,
                    b"printf '\\377\\000\\033[Htrace bytes\\n'\n",
                )
                .unwrap();
            let deadline = Instant::now() + Duration::from_secs(3);
            loop {
                while application.next_terminal_chunk().unwrap().is_some() {}
                let crate::TranscriptRead::Output(page) = application
                    .read_terminal_transcript(
                        workflow.terminal_id,
                        0,
                        crate::MAX_TRANSCRIPT_READ_BYTES,
                    )
                    .unwrap()
                else {
                    panic!("new transcript must be retained");
                };
                if page
                    .bytes
                    .windows(5)
                    .any(|bytes| bytes == [0xff, 0, 0x1b, b'[', b'H'])
                {
                    break;
                }
                assert!(
                    Instant::now() < deadline,
                    "shell did not produce binary output"
                );
                thread::sleep(Duration::from_millis(5));
            }
            application
                .handle_command(
                    RequestId(3),
                    Command::CloseWorkflow {
                        workflow_id: workflow.workflow_id,
                    },
                )
                .unwrap();
            let trace = application
                .workflow_trace(workflow.workflow_id, None, 10)
                .unwrap();
            let span_id = trace.spans[0].span_id;
            let events = application.trace_events(span_id, None, 10).unwrap().events;
            assert_eq!(events.len(), 2);
            let anchor = events[1].anchor.as_ref().unwrap().clone();
            assert_eq!(anchor.terminal_id, workflow.terminal_id);
            assert!(anchor.byte_offset > 0);
            let expected = application
                .read_terminal_transcript(anchor.terminal_id, 0, crate::MAX_TRANSCRIPT_READ_BYTES)
                .unwrap();
            let crate::TranscriptRead::Output(page) = &expected else {
                panic!("closed transcript must be retained");
            };
            assert!(anchor.byte_offset <= page.end_offset);
            assert!(
                page.bytes
                    .windows(5)
                    .any(|bytes| bytes == [0xff, 0, 0x1b, b'[', b'H'])
            );
            (workflow.workflow_id, span_id, anchor, expected, events)
        };
        let mut application =
            Application::with_config(data.path(), crate::config::Config::default()).unwrap();
        application.terminals.set_test_shell("/bin/sh".into());
        let fresh = create(&application, folder.path());
        assert!(fresh.terminal_id.value() > anchor.terminal_id.value());
        assert_eq!(
            application
                .read_terminal_transcript(anchor.terminal_id, 0, crate::MAX_TRANSCRIPT_READ_BYTES)
                .unwrap(),
            expected
        );
        let crate::TranscriptRead::Output(page) = application
            .read_terminal_transcript(anchor.terminal_id, anchor.byte_offset, 1)
            .unwrap()
        else {
            panic!("trace anchor must remain readable");
        };
        assert_eq!(page.offset, anchor.byte_offset);
        assert_eq!(
            application.trace_events(span_id, None, 10).unwrap().events,
            events
        );
        let historical = application.workflow_trace(workflow_id, None, 10).unwrap();
        assert_eq!(historical.spans[0].terminal_id, Some(anchor.terminal_id));
        assert!(!historical.spans[0].is_live);
    }

    #[test]
    fn observed_output_anchors_survive_queue_drain_and_text_creates_no_events() {
        let folder = tempfile::tempdir().unwrap();
        let application = Application::with_event_capacity(4096).unwrap();
        let workflow = create(&application, folder.path());
        application
            .write_terminal_input(
                workflow.terminal_id,
                b"printf 'processExited processStarted\\n'\n",
            )
            .unwrap();
        let deadline = Instant::now() + Duration::from_secs(3);
        let mut output = Vec::new();
        while Instant::now() < deadline {
            while let Some(chunk) = application.next_terminal_chunk().unwrap() {
                output.extend(chunk.bytes);
            }
            if String::from_utf8_lossy(&output).contains("processExited processStarted") {
                break;
            }
            thread::sleep(Duration::from_millis(5));
        }
        assert!(String::from_utf8_lossy(&output).contains("processExited processStarted"));
        let page = application
            .workflow_trace(workflow.workflow_id, None, 10)
            .unwrap();
        let span_id = page.spans[0].span_id;
        assert!(page.spans[0].is_live);
        assert_eq!(
            application
                .trace_events(span_id, None, 10)
                .unwrap()
                .events
                .len(),
            1
        );
        let observation = application.terminals.observe(workflow.terminal_id).unwrap();
        application
            .handle_command(
                RequestId(3),
                Command::CloseWorkflow {
                    workflow_id: workflow.workflow_id,
                },
            )
            .unwrap();
        let page = application
            .workflow_trace(workflow.workflow_id, None, 10)
            .unwrap();
        assert_eq!(page.spans[0].status, TraceSpanStatus::Stopped);
        assert!(!page.spans[0].is_live);
        let events = application.trace_events(span_id, None, 10).unwrap().events;
        assert_eq!(events.len(), 2);
        assert!(events[1].anchor.as_ref().unwrap().byte_offset >= observation.byte_offset);
        assert!(events[1].anchor.as_ref().unwrap().byte_offset > 0);
    }

    #[test]
    fn natural_exit_records_an_exit_without_completing_work_and_close_is_idempotent() {
        let folder = tempfile::tempdir().unwrap();
        let application = Application::with_event_capacity(4096).unwrap();
        let workflow = create(&application, folder.path());
        application
            .write_terminal_input(workflow.terminal_id, b"exit 7\n")
            .unwrap();
        let deadline = Instant::now() + Duration::from_secs(3);
        while application.snapshot().unwrap().workflows.workflows[0].status
            == WorkflowStatus::Running
        {
            assert!(Instant::now() < deadline, "process exit should be observed");
            while application.next_terminal_chunk().unwrap().is_some() {}
            thread::sleep(Duration::from_millis(5));
        }
        let page = application
            .workflow_trace(workflow.workflow_id, None, 10)
            .unwrap();
        let span_id = page.spans[0].span_id;
        assert_eq!(page.spans[0].status, TraceSpanStatus::Exited);
        application
            .handle_command(
                RequestId(3),
                Command::CloseWorkflow {
                    workflow_id: workflow.workflow_id,
                },
            )
            .unwrap();
        let events = application.trace_events(span_id, None, 10).unwrap().events;
        assert_eq!(events.len(), 2);
        assert_eq!(events[1].kind, TraceEventKind::ProcessExited);
        assert!(events[1].message.contains("code 7"));
    }

    #[test]
    fn folder_reopen_keeps_history_and_opens_a_distinct_span() {
        let folder = tempfile::tempdir().unwrap();
        let application = Application::with_event_capacity(4096).unwrap();
        let workflow = create(&application, folder.path());
        let original = application
            .workflow_trace(workflow.workflow_id, None, 10)
            .unwrap()
            .spans[0]
            .span_id;
        application
            .handle_command(RequestId(3), Command::CloseFolder)
            .unwrap();
        application
            .handle_command(
                RequestId(4),
                Command::OpenFolder {
                    path: folder.path().to_owned(),
                },
            )
            .unwrap();
        let page = application
            .workflow_trace(workflow.workflow_id, None, 10)
            .unwrap();
        assert_eq!(page.summary.span_count, 2);
        assert_eq!(page.lanes.len(), 1);
        assert_ne!(page.spans[0].span_id, original);
        assert!(page.spans[0].is_live);
        assert_eq!(page.spans[1].span_id, original);
        assert_eq!(page.spans[1].status, TraceSpanStatus::Stopped);
        assert!(!page.spans[1].is_live);
        assert_eq!(application.snapshot().unwrap().traces[0], page.summary);
    }
}
