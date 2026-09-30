use std::collections::HashMap;
use std::path::Path;
use std::sync::Arc;

use tracing::{debug, warn};

use super::{Application, ApplicationError, CommandDisposition, Inner, RequestId, rejection};
use crate::event::{CommandResult, EventKind, StateEvent};
use crate::terminal::{
    TerminalChunk, TerminalExit, TerminalId, TerminalObservation, TerminalSize, TerminalStatus,
    TranscriptRead,
};
use crate::workflow::{Workflow, WorkflowKind, WorkflowStatus};

impl Application {
    /// Starts a shell and records it as running, or rejects the command if the shell can't start.
    pub(super) fn start_terminal_command(
        &self,
        request_id: RequestId,
        working_directory: &Path,
        size: TerminalSize,
    ) -> Result<CommandDisposition, ApplicationError> {
        let reserved = match self.terminals.reserve_terminal() {
            Ok(id) => id,
            Err(error) => return Ok(rejection("terminalStartFailed", &error)),
        };
        // Hold state while the process starts so an immediately exiting shell cannot publish its
        // exit before the command-completion event.
        let mut inner = self.lock_inner()?;
        let terminal_id = match self.start_terminal(reserved, working_directory, size) {
            Ok(terminal_id) => terminal_id,
            Err(error) => return Ok(rejection("terminalStartFailed", &error)),
        };
        inner.terminals.insert(terminal_id, TerminalStatus::Running);
        if let Err(error) = inner.events.append(EventKind::CommandCompleted {
            request_id,
            result: CommandResult::TerminalStarted { terminal_id },
        }) {
            inner.terminals.remove(&terminal_id);
            drop(inner);
            let _ = self.terminals.close(terminal_id);
            return Err(error.into());
        }
        debug!(
            request_id = request_id.0,
            terminal_id = terminal_id.value(),
            "terminal started"
        );
        Ok(CommandDisposition::Accepted)
    }

    /// Stops a shell and forgets it, or rejects the command if it isn't running.
    pub(super) fn close_terminal_command(
        &self,
        request_id: RequestId,
        terminal_id: TerminalId,
    ) -> Result<CommandDisposition, ApplicationError> {
        {
            let mut inner = self.lock_inner()?;
            if inner
                .workflows
                .workflows
                .iter()
                .any(|workflow| workflow.terminal_ids().contains(&terminal_id))
            {
                return Ok(CommandDisposition::Rejected {
                    code: "terminalOwnedByWorkflow".to_owned(),
                    message: "Close the workflow to close its terminal.".to_owned(),
                });
            }
            inner.terminals.remove(&terminal_id);
        }
        if let Err(error) = self.terminals.close(terminal_id) {
            return Ok(rejection("terminalCloseFailed", &error));
        }
        let mut inner = self.lock_inner()?;
        inner.events.append(EventKind::CommandCompleted {
            request_id,
            result: CommandResult::TerminalClosed { terminal_id },
        })?;
        debug!(
            request_id = request_id.0,
            terminal_id = terminal_id.value(),
            "terminal closed"
        );
        Ok(CommandDisposition::Accepted)
    }

    /// Removes the next terminal chunk from the binary output queue.
    ///
    /// # Errors
    ///
    /// Returns an error if the queue cannot be accessed.
    pub fn next_terminal_chunk(&self) -> Result<Option<TerminalChunk>, ApplicationError> {
        Ok(self.terminal_output.next_chunk()?)
    }

    /// Reads at most `limit` raw bytes beginning exactly at `offset`, after committing output
    /// already accepted for recording. `limit` must be between 1 and 64 KiB. An offset at the
    /// recorded end returns an empty page; pruned history returns an explicit expired result.
    ///
    /// This performs storage work on the recording worker and waits for its reply. Call it off
    /// the UI thread. It acquires no application-state or terminal-input locks.
    ///
    /// # Errors
    ///
    /// Returns an error for an invalid limit, an unknown terminal, an offset beyond the recorded
    /// end, or unavailable/corrupt storage. Terminal IDs remain readable after terminal closure.
    pub fn read_terminal_transcript(
        &self,
        terminal_id: TerminalId,
        offset: u64,
        limit: usize,
    ) -> Result<TranscriptRead, ApplicationError> {
        Ok(self
            .terminal_output
            .read_transcript(terminal_id, offset, limit)?)
    }

    /// Writes binary user input to a live terminal.
    ///
    /// # Errors
    ///
    /// Returns an error if the terminal is not running or the PTY writer fails.
    pub fn write_terminal_input(
        &self,
        terminal_id: TerminalId,
        bytes: &[u8],
    ) -> Result<(), ApplicationError> {
        Ok(self.terminals.write_input(terminal_id, bytes)?)
    }

    /// Changes the kernel PTY size for a live terminal.
    ///
    /// # Errors
    ///
    /// Returns an error if the size is invalid, the terminal is not running, or resizing fails.
    pub fn resize_terminal(
        &self,
        terminal_id: TerminalId,
        size: TerminalSize,
    ) -> Result<(), ApplicationError> {
        Ok(self.terminals.resize(terminal_id, size)?)
    }

    pub(super) fn start_terminal(
        &self,
        terminal_id: TerminalId,
        working_directory: &Path,
        size: TerminalSize,
    ) -> Result<TerminalId, ApplicationError> {
        Ok(self.terminals.start_default_shell(
            terminal_id,
            working_directory,
            size,
            Arc::new(self.exit_callback()),
        )?)
    }

    /// Records a terminal's process exit in application state.
    pub(super) fn exit_callback(
        &self,
    ) -> impl Fn(TerminalId, Result<TerminalExit, String>, TerminalObservation) + Send + Sync + 'static
    {
        let inner = Arc::downgrade(&self.inner);
        move |terminal_id, result, observation| {
            let Some(inner) = inner.upgrade() else { return };
            let Ok(mut inner) = inner.lock() else {
                warn!(
                    terminal_id = terminal_id.value(),
                    "application state lock poisoned after terminal exit"
                );
                return;
            };
            inner.record_terminal_exit_at(terminal_id, result, observation);
        }
    }
}

impl Inner {
    /// Records how a shell ended, in the terminal's status and as an event, and ends the workflow
    /// that owns it once all of that workflow's shells have ended.
    #[cfg(test)]
    pub(super) fn record_terminal_exit(
        &mut self,
        terminal_id: TerminalId,
        result: Result<TerminalExit, String>,
    ) {
        self.record_terminal_exit_at(
            terminal_id,
            result,
            TerminalObservation {
                observed_at: crate::workflow::timestamp(),
                byte_offset: 0,
            },
        );
    }

    pub(super) fn record_terminal_exit_at(
        &mut self,
        terminal_id: TerminalId,
        result: Result<TerminalExit, String>,
        observation: TerminalObservation,
    ) {
        if self.terminals.get(&terminal_id) != Some(&TerminalStatus::Running) {
            return;
        }
        let (status, event) = match result {
            Ok(exit) => (
                TerminalStatus::Exited(exit.clone()),
                StateEvent::TerminalExited { terminal_id, exit },
            ),
            Err(message) => (
                TerminalStatus::Failed {
                    message: message.clone(),
                },
                StateEvent::TerminalFailed {
                    terminal_id,
                    message,
                },
            ),
        };
        let (trace_status, trace_kind, trace_message) = match &status {
            TerminalStatus::Exited(exit) => (
                crate::TraceSpanStatus::Exited,
                crate::TraceEventKind::ProcessExited,
                match &exit.signal {
                    Some(signal) => format!("Process exited with signal {signal}."),
                    None => format!("Process exited with code {}.", exit.exit_code),
                },
            ),
            TerminalStatus::Failed { message } => (
                crate::TraceSpanStatus::Failed,
                crate::TraceEventKind::ProcessFailed,
                format!("Process failed: {message}"),
            ),
            TerminalStatus::Running => return,
        };
        if let Err(error) = self.end_trace(
            terminal_id,
            observation,
            trace_status,
            trace_kind,
            &trace_message,
        ) {
            warn!(%error, "failed to persist process trace");
        }
        self.terminals.insert(terminal_id, status);
        if let Some(workflow) = self.workflows.workflows.iter_mut().find(|workflow| {
            workflow.status == WorkflowStatus::Running
                && workflow.terminal_ids().contains(&terminal_id)
        }) && let Some(status) = ended_status(workflow, &self.terminals)
        {
            // Only a running workflow ends here, so a cancelled agent keeps its cancelled status. An
            // exit only means the processes ended, never that the work succeeded.
            workflow.status = status;
            workflow.ended_at = Some(observation.observed_at.max(workflow.started_at));
            if workflow.kind == WorkflowKind::SingleAgent {
                if let Err(error) = self
                    .folders
                    .store()
                    .update_agent_status(workflow.workflow_id, workflow.status)
                {
                    warn!(%error, "failed to record the agent's exit");
                }
                tracing::info!(
                    workflow_id = workflow.workflow_id.0,
                    status = ?workflow.status,
                    "agent exited"
                );
            }
            let workflow = workflow.clone();
            if let Err(error) = self
                .events
                .append(EventKind::State(StateEvent::WorkflowChanged(workflow)))
            {
                warn!(%error, "failed to record workflow exit");
            }
        }
        if let Err(error) = self.events.append(EventKind::State(event)) {
            warn!(terminal_id = terminal_id.value(), %error, "failed to record terminal exit");
        }
    }
}

/// A workflow runs while any shell it owns runs. Once all have ended it has failed if any failed or
/// couldn't restart, and otherwise exited. A shell exiting never means the work succeeded.
fn ended_status(
    workflow: &Workflow,
    terminals: &HashMap<TerminalId, TerminalStatus>,
) -> Option<WorkflowStatus> {
    if workflow.run.is_some() {
        return None;
    }
    let mut failed = false;
    for terminal_id in workflow.shells() {
        match terminals.get(&terminal_id) {
            Some(TerminalStatus::Running) => return None,
            Some(TerminalStatus::Exited(_)) => {}
            Some(TerminalStatus::Failed { .. }) | None => failed = true,
        }
    }
    Some(if failed {
        WorkflowStatus::Failed
    } else {
        WorkflowStatus::Exited
    })
}

#[cfg(test)]
mod tests {
    use std::sync::mpsc;
    use std::thread;
    use std::time::{Duration, Instant};

    use super::*;
    use crate::Command;
    use crate::config::Config;
    use crate::workflow::{Agent, AgentId, SessionId, WorkflowId, WorkflowKind};

    fn workflow(terminal_id: u64, agent_terminal_ids: &[u64]) -> Workflow {
        Workflow {
            workflow_id: WorkflowId(1),
            session_id: SessionId(1),
            name: "Agents".to_owned(),
            kind: if agent_terminal_ids.is_empty() {
                WorkflowKind::Terminal
            } else {
                WorkflowKind::Agents
            },
            harness: None,
            terminal_id: TerminalId::from_value(terminal_id),
            agents: agent_terminal_ids
                .iter()
                .zip(1..)
                .map(|(terminal_id, agent_id)| Agent {
                    agent_id: AgentId(agent_id),
                    role: "Worker".to_owned(),
                    terminal_id: TerminalId::from_value(*terminal_id),
                })
                .collect(),
            status: WorkflowStatus::Running,
            started_at: 0,
            ended_at: None,
            restored: false,
            run: None,
        }
    }

    #[test]
    fn a_workflow_ends_after_all_of_its_shells_and_fails_if_any_did() {
        let exited = TerminalStatus::Exited(TerminalExit {
            exit_code: 0,
            signal: None,
        });
        let failed = TerminalStatus::Failed {
            message: "wait failed".to_owned(),
        };
        let terminals = HashMap::from([
            (TerminalId::from_value(1), TerminalStatus::Running),
            (TerminalId::from_value(2), exited.clone()),
            (TerminalId::from_value(3), exited),
            (TerminalId::from_value(4), failed),
        ]);
        assert_eq!(ended_status(&workflow(1, &[]), &terminals), None);
        assert_eq!(
            ended_status(&workflow(2, &[]), &terminals),
            Some(WorkflowStatus::Exited)
        );
        assert_eq!(
            ended_status(&workflow(4, &[]), &terminals),
            Some(WorkflowStatus::Failed)
        );
        assert_eq!(ended_status(&workflow(0, &[2, 1]), &terminals), None);
        assert_eq!(
            ended_status(&workflow(0, &[2, 3]), &terminals),
            Some(WorkflowStatus::Exited)
        );
        assert_eq!(
            ended_status(&workflow(0, &[2, 4]), &terminals),
            Some(WorkflowStatus::Failed)
        );
        // An agent whose shell couldn't restart has no terminal.
        assert_eq!(
            ended_status(&workflow(0, &[0, 3]), &terminals),
            Some(WorkflowStatus::Failed)
        );
    }

    fn size() -> TerminalSize {
        TerminalSize {
            rows: 24,
            columns: 80,
            pixel_width: 0,
            pixel_height: 0,
        }
    }

    fn start(app: &Application, folder: &Path, request: u64) -> TerminalId {
        let receipt = app
            .handle_command(
                RequestId(request),
                Command::StartTerminal {
                    working_directory: folder.into(),
                    size: size(),
                },
            )
            .unwrap();
        assert_eq!(receipt.disposition, CommandDisposition::Accepted);
        app.snapshot()
            .unwrap()
            .terminals
            .last()
            .unwrap()
            .terminal_id
    }

    #[test]
    fn application_reads_closed_transcripts_after_relaunch_without_reusing_ids() {
        let data = tempfile::tempdir().unwrap();
        let folder = tempfile::tempdir().unwrap();
        let app = Application::with_config(data.path(), Config::default()).unwrap();
        let id = start(&app, folder.path(), 1);
        let command = [
            br"printf '\377\000\033[H__TWINE_HISTORY__\n'".as_slice(),
            b"\n",
        ]
        .concat();
        app.write_terminal_input(id, &command).unwrap();
        let deadline = Instant::now() + Duration::from_secs(3);
        let bytes = loop {
            while app.next_terminal_chunk().unwrap().is_some() {}
            let TranscriptRead::Output(page) =
                app.read_terminal_transcript(id, 0, 64 * 1024).unwrap()
            else {
                panic!("new terminal history should be retained");
            };
            if page
                .bytes
                .windows(5)
                .any(|bytes| bytes == [0xff, 0, 0x1b, b'[', b'H'])
            {
                break page.bytes;
            }
            assert!(
                Instant::now() < deadline,
                "shell did not produce binary history"
            );
            thread::sleep(Duration::from_millis(5));
        };
        app.handle_command(RequestId(2), Command::CloseTerminal { terminal_id: id })
            .unwrap();
        let expected = app
            .read_terminal_transcript(id, 1, bytes.len() - 1)
            .unwrap();
        drop(app);
        let app = Application::with_config(data.path(), Config::default()).unwrap();
        assert_eq!(
            app.read_terminal_transcript(id, 1, bytes.len() - 1)
                .unwrap(),
            expected
        );
        assert!(start(&app, folder.path(), 3).value() > id.value());
    }

    #[test]
    fn terminal_and_workflow_allocation_wait_without_holding_application_state() {
        for workflow in [
            None,
            Some(WorkflowKind::Terminal),
            Some(WorkflowKind::Agents),
        ] {
            let data = tempfile::tempdir().unwrap();
            let folder = tempfile::tempdir().unwrap();
            let app = Arc::new(Application::with_config(data.path(), Config::default()).unwrap());
            app.handle_command(
                RequestId(1),
                Command::OpenFolder {
                    path: folder.path().into(),
                },
            )
            .unwrap();
            let id = start(&app, folder.path(), 2);
            let stalled = app.terminal_output.stall_recording_worker(id);
            let command = if let Some(kind) = workflow {
                Command::CreateWorkflow {
                    folder: folder.path().into(),
                    session_id: None,
                    kind,
                    roles: if kind == WorkflowKind::Agents {
                        vec!["Implementer".into(), "Reviewer".into()]
                    } else {
                        Vec::new()
                    },
                    size: size(),
                }
            } else {
                Command::StartTerminal {
                    working_directory: folder.path().into(),
                    size: size(),
                }
            };
            let (sent, result) = mpsc::sync_channel(1);
            let starting = Arc::clone(&app);
            let starter = thread::spawn(move || {
                sent.send(starting.handle_command(RequestId(3), command))
                    .unwrap();
            });
            assert_state_available_during_allocation(&app);
            assert!(matches!(result.try_recv(), Err(mpsc::TryRecvError::Empty)));
            drop(stalled);
            assert_eq!(
                result
                    .recv_timeout(Duration::from_secs(3))
                    .unwrap()
                    .unwrap()
                    .disposition,
                CommandDisposition::Accepted
            );
            starter.join().unwrap();
        }
    }

    #[test]
    fn workflow_restoration_waits_without_holding_application_state() {
        for kind in [WorkflowKind::Terminal, WorkflowKind::Agents] {
            let data = tempfile::tempdir().unwrap();
            let folder = tempfile::tempdir().unwrap();
            let app = Arc::new(Application::with_config(data.path(), Config::default()).unwrap());
            app.handle_command(
                RequestId(1),
                Command::OpenFolder {
                    path: folder.path().into(),
                },
            )
            .unwrap();
            app.handle_command(
                RequestId(2),
                Command::CreateWorkflow {
                    folder: folder.path().into(),
                    session_id: None,
                    kind,
                    roles: if kind == WorkflowKind::Agents {
                        vec!["Implementer".into(), "Reviewer".into()]
                    } else {
                        Vec::new()
                    },
                    size: size(),
                },
            )
            .unwrap();
            let id = app.snapshot().unwrap().workflows.workflows[0].terminal_ids()[0];
            let stalled = app.terminal_output.stall_recording_worker(id);
            let restoring = Arc::clone(&app);
            let restore = thread::spawn(move || restoring.restore_workflows().unwrap());
            assert_state_available_during_allocation(&app);
            drop(stalled);
            restore.join().unwrap();
        }
    }

    fn assert_state_available_during_allocation(app: &Arc<Application>) {
        let deadline = Instant::now() + Duration::from_secs(2);
        while !app.terminal_output.allocation_is_pending() {
            assert!(
                Instant::now() < deadline,
                "allocation did not reach the stalled worker"
            );
            thread::yield_now();
        }
        let (sent, received) = mpsc::sync_channel(1);
        let observing = Arc::clone(app);
        let observer = thread::spawn(move || {
            let snapshot = observing.snapshot().unwrap();
            observing.events_after(snapshot.sequence, 8).unwrap();
            sent.send(()).unwrap();
        });
        received
            .recv_timeout(Duration::from_secs(1))
            .expect("state must remain available while storage is stalled");
        observer.join().unwrap();
    }
}
