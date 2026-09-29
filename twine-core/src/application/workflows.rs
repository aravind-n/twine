use std::path::Path;

use super::{Application, ApplicationError, CommandDisposition, RequestId};
use crate::event::{CommandResult, EventKind, StateEvent};
use crate::folder::Folders;
use crate::terminal::{TerminalSize, TerminalStatus};
use crate::workflow::{
    Session, SessionId, SessionStatus, Workflow, WorkflowId, WorkflowKind, WorkflowStatus,
    timestamp,
};

impl Application {
    pub(super) fn create_workflow(
        &self,
        request_id: RequestId,
        folder: &Path,
        kind: WorkflowKind,
        size: TerminalSize,
    ) -> Result<CommandDisposition, ApplicationError> {
        let mut inner = self.lock_inner()?;
        // A view whose folder has closed while awaiting startup must not create a shell elsewhere.
        if inner.folders.state().open_folder.as_deref() != Some(folder) {
            return Ok(reject(
                "folderChanged",
                "The workflow's folder is no longer open.",
            ));
        }
        let workflow_id = WorkflowId(inner.next_workflow_id);
        let next_workflow_id = inner
            .next_workflow_id
            .checked_add(1)
            .ok_or(ApplicationError::IdExhausted)?;
        let next_session_id = inner
            .next_session_id
            .checked_add(1)
            .ok_or(ApplicationError::IdExhausted)?;
        let terminal_id = match self.start_terminal(folder, size) {
            Ok(id) => id,
            Err(error) => return Ok(super::rejection("terminalStartFailed", &error)),
        };
        let started_at = timestamp();
        inner.next_workflow_id = next_workflow_id;
        inner.terminals.insert(terminal_id, TerminalStatus::Running);
        if inner.workflows.session.is_none() {
            let session = Session {
                session_id: SessionId(inner.next_session_id),
                name: "Session".to_owned(),
                folder: folder.to_owned(),
                status: SessionStatus::Active,
                started_at,
                ended_at: None,
            };
            inner.next_session_id = next_session_id;
            inner.workflows.session = Some(session.clone());
            inner
                .events
                .append(EventKind::State(StateEvent::SessionChanged(session)))?;
        }
        let workflow = Workflow {
            workflow_id,
            session_id: inner
                .workflows
                .session
                .as_ref()
                .expect("session was just created")
                .session_id,
            name: match kind {
                WorkflowKind::Draft => "New workflow".to_owned(),
                WorkflowKind::Terminal => "Terminal".to_owned(),
            },
            kind,
            terminal_id,
            status: WorkflowStatus::Running,
            started_at,
            ended_at: None,
        };
        inner.workflows.workflows.push(workflow.clone());
        inner
            .events
            .append(EventKind::State(StateEvent::WorkflowChanged(workflow)))?;
        inner.events.append(EventKind::CommandCompleted {
            request_id,
            result: CommandResult::WorkflowCreated { workflow_id },
        })?;
        Ok(CommandDisposition::Accepted)
    }

    pub(super) fn activate_workflow(
        &self,
        request_id: RequestId,
        workflow_id: WorkflowId,
    ) -> Result<CommandDisposition, ApplicationError> {
        let mut inner = self.lock_inner()?;
        let Some(workflow) = inner
            .workflows
            .workflows
            .iter_mut()
            .find(|workflow| workflow.workflow_id == workflow_id)
        else {
            return Ok(reject(
                "workflowNotFound",
                "The workflow is no longer open.",
            ));
        };
        // Activation changes the workflow type, never terminal ownership, timing, or process state.
        workflow.kind = WorkflowKind::Terminal;
        "Terminal".clone_into(&mut workflow.name);
        let workflow = workflow.clone();
        inner
            .events
            .append(EventKind::State(StateEvent::WorkflowChanged(workflow)))?;
        inner.events.append(EventKind::CommandCompleted {
            request_id,
            result: CommandResult::WorkflowActivated { workflow_id },
        })?;
        Ok(CommandDisposition::Accepted)
    }

    pub(super) fn close_workflow(
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
            let mut workflow = inner.workflows.workflows.remove(index);
            workflow.status = WorkflowStatus::Closed;
            workflow
                .ended_at
                .get_or_insert(timestamp().max(workflow.started_at));
            inner.terminals.remove(&workflow.terminal_id);
            let terminal_id = workflow.terminal_id;
            inner
                .events
                .append(EventKind::State(StateEvent::WorkflowChanged(workflow)))?;
            terminal_id
        };
        // Joining a supervisor while holding Inner would deadlock its exit callback.
        self.terminals.close(terminal_id)?;
        self.lock_inner()?
            .events
            .append(EventKind::CommandCompleted {
                request_id,
                result: CommandResult::WorkflowClosed { workflow_id },
            })?;
        Ok(CommandDisposition::Accepted)
    }

    pub(super) fn change_folder(
        &self,
        path: Option<&Path>,
    ) -> Result<CommandDisposition, ApplicationError> {
        let (disposition, terminal_ids) = {
            let mut inner = self.lock_inner()?;
            let previous = inner.folders.state().open_folder.clone();
            let disposition = inner.update_folders(|folders| match path {
                Some(path) => folders.open(path),
                None => Folders::close(folders),
            })?;
            if inner.folders.state().open_folder == previous {
                return Ok(disposition);
            }
            // Forget ownership before cleanup, so a late exit cannot resurrect a closed terminal.
            let terminal_ids = inner.terminals.keys().copied().collect::<Vec<_>>();
            inner.terminals.clear();
            for terminal_id in &terminal_ids {
                inner
                    .events
                    .append(EventKind::State(StateEvent::TerminalClosed {
                        terminal_id: *terminal_id,
                    }))?;
            }
            for mut workflow in std::mem::take(&mut inner.workflows.workflows) {
                workflow.status = WorkflowStatus::Closed;
                workflow
                    .ended_at
                    .get_or_insert(timestamp().max(workflow.started_at));
                inner
                    .events
                    .append(EventKind::State(StateEvent::WorkflowChanged(workflow)))?;
            }
            if let Some(mut session) = inner.workflows.session.take() {
                session.status = SessionStatus::Closed;
                session.ended_at = Some(timestamp().max(session.started_at));
                inner
                    .events
                    .append(EventKind::State(StateEvent::SessionChanged(session)))?;
            }
            (disposition, terminal_ids)
        };
        for terminal_id in terminal_ids {
            self.terminals.close(terminal_id)?;
        }
        Ok(disposition)
    }
}

fn reject(code: &str, message: &str) -> CommandDisposition {
    CommandDisposition::Rejected {
        code: code.to_owned(),
        message: message.to_owned(),
    }
}

#[cfg(test)]
mod tests;
