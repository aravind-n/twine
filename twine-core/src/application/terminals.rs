use std::collections::HashMap;
use std::path::Path;
use std::sync::Arc;

use tracing::{debug, warn};

use super::{Application, ApplicationError, CommandDisposition, Inner, RequestId, rejection};
use crate::event::{CommandResult, EventKind, StateEvent};
use crate::terminal::{TerminalChunk, TerminalExit, TerminalId, TerminalSize, TerminalStatus};
use crate::workflow::{Workflow, WorkflowKind, WorkflowStatus, timestamp};

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
        Ok(self.terminals.start_default_shell(
            working_directory,
            size,
            Arc::new(self.exit_callback()),
        )?)
    }

    /// Records a terminal's process exit in application state.
    pub(super) fn exit_callback(
        &self,
    ) -> impl Fn(TerminalId, Result<TerminalExit, String>) + Send + Sync + 'static {
        let inner = Arc::downgrade(&self.inner);
        move |terminal_id, result| {
            let Some(inner) = inner.upgrade() else { return };
            let Ok(mut inner) = inner.lock() else {
                warn!(
                    terminal_id = terminal_id.value(),
                    "application state lock poisoned after terminal exit"
                );
                return;
            };
            inner.record_terminal_exit(terminal_id, result);
        }
    }
}

impl Inner {
    /// Records how a shell ended, in the terminal's status and as an event, and ends the workflow
    /// that owns it once all of that workflow's shells have ended.
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
        self.terminals.insert(terminal_id, status);
        if let Some(workflow) = self.workflows.workflows.iter_mut().find(|workflow| {
            workflow.status == WorkflowStatus::Running
                && workflow.terminal_ids().contains(&terminal_id)
        }) && let Some(status) = ended_status(workflow, &self.terminals)
        {
            // Only a running workflow ends here, so a cancelled agent keeps its cancelled status. An
            // exit only means the processes ended, never that the work succeeded.
            workflow.status = status;
            workflow.ended_at = Some(timestamp().max(workflow.started_at));
            if workflow.kind == WorkflowKind::SingleAgent {
                if let Err(error) = self
                    .folders
                    .store()
                    .update_agent_status(workflow.workflow_id, workflow.status)
                {
                    warn!(%error, "failed to record the agent's exit");
                }
                // Recording the trace exit event belongs here once traces exist (TWINE-23).
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
    use super::*;
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
}
