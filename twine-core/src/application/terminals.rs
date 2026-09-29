use std::path::Path;
use std::sync::Arc;

use tracing::{debug, warn};

use super::{Application, ApplicationError, CommandDisposition, Inner, RequestId, rejection};
use crate::event::{CommandResult, EventKind, StateEvent};
use crate::terminal::{TerminalChunk, TerminalExit, TerminalId, TerminalSize, TerminalStatus};

impl Application {
    /// Starts a shell and records it as running, or rejects the command if the shell can't start.
    pub(super) fn start_terminal_command(
        &self,
        request_id: RequestId,
        working_directory: &Path,
        size: TerminalSize,
    ) -> Result<CommandDisposition, ApplicationError> {
        // Hold state while the process starts so an immediately exiting shell cannot publish its
        // exit before the command-completion event.
        let mut inner = self.lock_inner()?;
        let terminal_id = match self.start_terminal(working_directory, size) {
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
                .any(|workflow| workflow.terminal_id == terminal_id)
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
        working_directory: &Path,
        size: TerminalSize,
    ) -> Result<TerminalId, ApplicationError> {
        let inner = Arc::downgrade(&self.inner);
        Ok(self.terminals.start_default_shell(
            working_directory,
            size,
            Arc::new(move |terminal_id, result| {
                let Some(inner) = inner.upgrade() else { return };
                let Ok(mut inner) = inner.lock() else {
                    warn!(
                        terminal_id = terminal_id.value(),
                        "application state lock poisoned after terminal exit"
                    );
                    return;
                };
                inner.record_terminal_exit(terminal_id, result);
            }),
        )?)
    }
}

impl Inner {
    /// Records how a shell ended, in the terminal's status and as an event.
    pub(super) fn record_terminal_exit(
        &mut self,
        terminal_id: TerminalId,
        result: Result<TerminalExit, String>,
    ) {
        if !self.terminals.contains_key(&terminal_id) {
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
        if let Some(workflow) = self
            .workflows
            .workflows
            .iter_mut()
            .find(|workflow| workflow.terminal_id == terminal_id)
        {
            workflow.status = match &status {
                TerminalStatus::Exited(_) => crate::workflow::WorkflowStatus::Exited,
                TerminalStatus::Failed { .. } => crate::workflow::WorkflowStatus::Failed,
                TerminalStatus::Running => return,
            };
            workflow.ended_at = Some(crate::workflow::timestamp().max(workflow.started_at));
            let workflow = workflow.clone();
            if let Err(error) = self
                .events
                .append(EventKind::State(StateEvent::WorkflowChanged(workflow)))
            {
                warn!(%error, "failed to record workflow exit");
            }
        }
        self.terminals.insert(terminal_id, status);
        if let Err(error) = self.events.append(EventKind::State(event)) {
            warn!(terminal_id = terminal_id.value(), %error, "failed to record terminal exit");
        }
    }
}
