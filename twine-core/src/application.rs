use std::sync::{Mutex, MutexGuard};

use thiserror::Error;
use tracing::{debug, info};

use crate::event::{CommandResult, Event, EventError, EventJournal, EventKind, StateEvent};
use crate::terminal::{TerminalChunk, TerminalError, TerminalId, TerminalStream};

const DEFAULT_EVENT_CAPACITY: usize = 4_096;
const DEFAULT_TERMINAL_CAPACITY_BYTES: usize = 1024 * 1024;
const DEFAULT_TERMINAL_CAPACITY_CHUNKS: usize = 4_096;

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub struct RequestId(pub u64);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Command {
    Ping,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum CommandDisposition {
    Accepted,
    Rejected { code: String, message: String },
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CommandReceipt {
    pub request_id: RequestId,
    pub disposition: CommandDisposition,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ApplicationState {
    Ready,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Snapshot {
    pub sequence: u64,
    pub state: ApplicationState,
}

#[derive(Debug)]
struct Inner {
    state: ApplicationState,
    events: EventJournal,
}

#[derive(Debug)]
pub struct Application {
    inner: Mutex<Inner>,
    terminal: TerminalStream,
}

impl Application {
    /// Creates the application with production queue limits.
    ///
    /// # Errors
    ///
    /// Returns an error if the initial ready event cannot be recorded.
    pub fn new() -> Result<Self, ApplicationError> {
        Self::with_capacities(DEFAULT_EVENT_CAPACITY, DEFAULT_TERMINAL_CAPACITY_BYTES)
    }

    /// Creates the application with injectable limits for deterministic tests.
    ///
    /// # Errors
    ///
    /// Returns an error when either capacity is zero or the initial event cannot be recorded.
    pub(crate) fn with_capacities(
        event_capacity: usize,
        terminal_capacity_bytes: usize,
    ) -> Result<Self, ApplicationError> {
        let mut events = EventJournal::new(event_capacity)?;
        events.append(EventKind::State(StateEvent::ApplicationReady))?;

        let application = Self {
            inner: Mutex::new(Inner {
                state: ApplicationState::Ready,
                events,
            }),
            terminal: TerminalStream::new(
                terminal_capacity_bytes,
                DEFAULT_TERMINAL_CAPACITY_CHUNKS,
            )?,
        };

        info!("application core initialized");
        Ok(application)
    }

    /// Handles a command and returns its immediate acceptance result.
    ///
    /// # Errors
    ///
    /// Returns an error if application state cannot be accessed or the resulting event cannot be
    /// recorded.
    pub fn handle_command(
        &self,
        request_id: RequestId,
        command: Command,
    ) -> Result<CommandReceipt, ApplicationError> {
        match command {
            Command::Ping => {
                let mut inner = self.lock_inner()?;
                inner.events.append(EventKind::CommandCompleted {
                    request_id,
                    result: CommandResult::Pong,
                })?;
                debug!(request_id = request_id.0, "command accepted");
                Ok(CommandReceipt {
                    request_id,
                    disposition: CommandDisposition::Accepted,
                })
            }
        }
    }

    /// Returns an atomic snapshot of application state and the latest event sequence.
    ///
    /// # Errors
    ///
    /// Returns an error if application state cannot be accessed.
    pub fn snapshot(&self) -> Result<Snapshot, ApplicationError> {
        let inner = self.lock_inner()?;
        Ok(Snapshot {
            sequence: inner.events.latest_sequence(),
            state: inner.state,
        })
    }

    /// Returns at most `limit` events whose sequence is strictly greater than `sequence`.
    ///
    /// # Errors
    ///
    /// Returns an error if the cursor has expired, the limit is invalid, or application state
    /// cannot be accessed.
    pub fn events_after(
        &self,
        sequence: u64,
        limit: usize,
    ) -> Result<Vec<Event>, ApplicationError> {
        Ok(self.lock_inner()?.events.after(sequence, limit)?)
    }

    /// Allocates a fresh identity for one terminal byte stream.
    ///
    /// # Errors
    ///
    /// Returns an error if the terminal ID space is exhausted or the terminal registry cannot be
    /// accessed.
    pub fn open_terminal(&self) -> Result<TerminalId, ApplicationError> {
        Ok(self.terminal.open()?)
    }

    /// Publishes terminal output without routing it through the structured event journal.
    ///
    /// # Errors
    ///
    /// Returns an error when the byte offset overflows, the chunk is larger than the queue, the
    /// bounded queue is full, or the queue cannot be accessed.
    pub fn publish_terminal_output(
        &self,
        terminal_id: TerminalId,
        bytes: Vec<u8>,
    ) -> Result<u64, ApplicationError> {
        Ok(self.terminal.publish(terminal_id, bytes)?)
    }

    /// Removes the next terminal chunk from the binary output queue.
    ///
    /// # Errors
    ///
    /// Returns an error if the queue cannot be accessed.
    pub fn next_terminal_chunk(&self) -> Result<Option<TerminalChunk>, ApplicationError> {
        Ok(self.terminal.next_chunk()?)
    }

    /// Releases the retained byte offset for a terminal whose queued output has been drained.
    ///
    /// # Errors
    ///
    /// Returns an error if output for the terminal is still queued or the queue cannot be
    /// accessed.
    pub fn close_terminal(&self, terminal_id: TerminalId) -> Result<(), ApplicationError> {
        Ok(self.terminal.close(terminal_id)?)
    }

    fn lock_inner(&self) -> Result<MutexGuard<'_, Inner>, ApplicationError> {
        self.inner.lock().map_err(|_| ApplicationError::Poisoned)
    }
}

#[derive(Debug, Error)]
pub enum ApplicationError {
    #[error(transparent)]
    Event(#[from] EventError),
    #[error("application state lock is poisoned")]
    Poisoned,
    #[error(transparent)]
    Terminal(#[from] TerminalError),
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use super::*;

    #[test]
    fn snapshot_then_events_has_no_gap_or_repeat() {
        let application = Application::new().expect("application should initialize");
        let snapshot = application.snapshot().expect("snapshot should succeed");

        let receipt = application
            .handle_command(RequestId(41), Command::Ping)
            .expect("command should succeed");
        let events = application
            .events_after(snapshot.sequence, 16)
            .expect("events should be available");

        assert_eq!(receipt.request_id, RequestId(41));
        assert_eq!(receipt.disposition, CommandDisposition::Accepted);
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].sequence, snapshot.sequence + 1);
        assert_eq!(
            events[0].kind,
            EventKind::CommandCompleted {
                request_id: RequestId(41),
                result: CommandResult::Pong,
            }
        );
        assert!(
            application
                .events_after(events[0].sequence, 16)
                .expect("up-to-date cursor should succeed")
                .is_empty()
        );
    }

    #[test]
    fn expired_cursor_is_explicit() {
        let application =
            Application::with_capacities(2, 64).expect("application should initialize");
        application
            .handle_command(RequestId(1), Command::Ping)
            .expect("first command should succeed");
        application
            .handle_command(RequestId(2), Command::Ping)
            .expect("second command should succeed");

        let error = application
            .events_after(0, 16)
            .expect_err("the evicted cursor should fail");

        assert!(matches!(
            error,
            ApplicationError::Event(EventError::CursorExpired {
                requested: 0,
                oldest_available: 2,
            })
        ));
    }

    #[test]
    fn terminal_output_has_absolute_offsets_and_backpressure() {
        let application =
            Application::with_capacities(4, 5).expect("application should initialize");
        let terminal_id = application.open_terminal().expect("terminal should open");

        assert_eq!(
            application
                .publish_terminal_output(terminal_id, vec![0, 1, 2])
                .expect("first chunk should fit"),
            0
        );
        assert_eq!(
            application
                .publish_terminal_output(terminal_id, vec![3, 4])
                .expect("second chunk should fit"),
            3
        );
        assert!(matches!(
            application.publish_terminal_output(terminal_id, vec![5]),
            Err(ApplicationError::Terminal(TerminalError::BufferFull { .. }))
        ));

        let first = application
            .next_terminal_chunk()
            .expect("read should succeed")
            .expect("chunk should exist");
        assert_eq!(first.terminal_id, terminal_id);
        assert_eq!(first.offset, 0);
        assert_eq!(first.bytes, vec![0, 1, 2]);

        assert_eq!(
            application
                .publish_terminal_output(terminal_id, vec![5])
                .expect("space should be reusable"),
            5
        );

        assert!(matches!(
            application.close_terminal(terminal_id),
            Err(ApplicationError::Terminal(
                TerminalError::PendingOutput { .. }
            ))
        ));
        while application
            .next_terminal_chunk()
            .expect("read should succeed")
            .is_some()
        {}
        application
            .close_terminal(terminal_id)
            .expect("drained terminal should close");
        assert!(matches!(
            application.publish_terminal_output(terminal_id, vec![6]),
            Err(ApplicationError::Terminal(TerminalError::NotOpen { .. }))
        ));

        let next_terminal_id = application
            .open_terminal()
            .expect("next terminal should open");
        assert_ne!(next_terminal_id, terminal_id);
        assert_eq!(
            application
                .publish_terminal_output(next_terminal_id, vec![6])
                .expect("fresh terminal should start at zero"),
            0
        );
    }

    #[test]
    fn concurrent_snapshots_and_commands_keep_sequences_contiguous() {
        const COMMANDS_PER_THREAD: usize = 500;
        const THREADS: usize = 4;

        let application = Arc::new(
            Application::with_capacities(3_000, 64).expect("application should initialize"),
        );
        let snapshot = application.snapshot().expect("snapshot should succeed");
        let finished = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let handles: Vec<_> = (0..THREADS)
            .map(|thread| {
                let application = Arc::clone(&application);
                let finished = Arc::clone(&finished);
                std::thread::spawn(move || {
                    for request in 0..COMMANDS_PER_THREAD {
                        application
                            .handle_command(
                                RequestId(
                                    u64::try_from(thread * COMMANDS_PER_THREAD + request)
                                        .expect("test request ID should fit"),
                                ),
                                Command::Ping,
                            )
                            .expect("command should succeed");
                        if request % 25 == 0 {
                            std::thread::yield_now();
                        }
                    }
                    finished.fetch_add(1, std::sync::atomic::Ordering::Release);
                })
            })
            .collect();

        while finished.load(std::sync::atomic::Ordering::Acquire) != THREADS {
            let concurrent_snapshot = application.snapshot().expect("snapshot should succeed");
            let events = application
                .events_after(concurrent_snapshot.sequence, THREADS * COMMANDS_PER_THREAD)
                .expect("snapshot cursor should remain available");
            for (index, event) in events.iter().enumerate() {
                assert_eq!(
                    event.sequence,
                    concurrent_snapshot.sequence
                        + u64::try_from(index).expect("test index should fit")
                        + 1
                );
            }
        }

        for handle in handles {
            handle.join().expect("command thread should not panic");
        }

        let events = application
            .events_after(snapshot.sequence, THREADS * COMMANDS_PER_THREAD)
            .expect("all events should remain available");
        assert_eq!(events.len(), THREADS * COMMANDS_PER_THREAD);
        for (index, event) in events.iter().enumerate() {
            assert_eq!(
                event.sequence,
                snapshot.sequence + u64::try_from(index).expect("test index should fit") + 1
            );
        }
    }
}
