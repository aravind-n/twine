use std::collections::VecDeque;

use thiserror::Error;

use crate::application::RequestId;
use crate::folder::FolderState;
use crate::terminal::{TerminalExit, TerminalId};
use crate::workflow::{SessionId, Workflow, WorkflowId, WorkflowState};

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum StateEvent {
    ApplicationReady,
    WorkflowsChanged(WorkflowState),
    WorkflowChanged(Workflow),
    /// The open folder or the recent folders changed. Carries the complete new folder state.
    FoldersChanged(FolderState),
    TerminalClosed {
        terminal_id: TerminalId,
    },
    TerminalExited {
        terminal_id: TerminalId,
        exit: TerminalExit,
    },
    TerminalFailed {
        terminal_id: TerminalId,
        message: String,
    },
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum CommandResult {
    SessionCreated { session_id: SessionId },
    SessionRenamed { session_id: SessionId },
    SessionSelected { session_id: SessionId },
    SessionDeleted { session_id: SessionId },
    Pong,
    WorkflowCreated { workflow_id: WorkflowId },
    WorkflowActivated { workflow_id: WorkflowId },
    WorkflowClosed { workflow_id: WorkflowId },
    TerminalStarted { terminal_id: TerminalId },
    TerminalClosed { terminal_id: TerminalId },
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum EventKind {
    State(StateEvent),
    CommandCompleted {
        request_id: RequestId,
        result: CommandResult,
    },
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Event {
    pub sequence: u64,
    pub kind: EventKind,
}

#[derive(Debug)]
pub(crate) struct EventJournal {
    capacity: usize,
    events: VecDeque<Event>,
    latest_sequence: u64,
}

impl EventJournal {
    pub(crate) fn new(capacity: usize) -> Result<Self, EventError> {
        if capacity == 0 {
            return Err(EventError::ZeroCapacity);
        }

        Ok(Self {
            capacity,
            events: VecDeque::with_capacity(capacity),
            latest_sequence: 0,
        })
    }

    pub(crate) fn append(&mut self, kind: EventKind) -> Result<Event, EventError> {
        let sequence = self
            .latest_sequence
            .checked_add(1)
            .ok_or(EventError::SequenceOverflow)?;
        let event = Event { sequence, kind };
        self.events.push_back(event.clone());
        self.latest_sequence = sequence;

        if self.events.len() > self.capacity {
            self.events.pop_front();
        }

        Ok(event)
    }

    pub(crate) const fn latest_sequence(&self) -> u64 {
        self.latest_sequence
    }

    pub(crate) fn after(&self, sequence: u64, limit: usize) -> Result<Vec<Event>, EventError> {
        if limit == 0 {
            return Err(EventError::ZeroLimit);
        }

        if let Some(oldest) = self.events.front() {
            let oldest_cursor = oldest.sequence.saturating_sub(1);
            if sequence < oldest_cursor {
                return Err(EventError::CursorExpired {
                    requested: sequence,
                    oldest_available: oldest.sequence,
                });
            }
        }

        Ok(self
            .events
            .iter()
            .filter(|event| event.sequence > sequence)
            .take(limit)
            .cloned()
            .collect())
    }
}

#[derive(Debug, Error)]
pub enum EventError {
    #[error(
        "event cursor {requested} has expired; the oldest available event is {oldest_available}"
    )]
    CursorExpired {
        requested: u64,
        oldest_available: u64,
    },
    #[error("event sequence overflowed")]
    SequenceOverflow,
    #[error("event journal capacity must be greater than zero")]
    ZeroCapacity,
    #[error("event batch limit must be greater than zero")]
    ZeroLimit,
}
