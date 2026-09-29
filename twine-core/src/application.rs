use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard};

use thiserror::Error;
use tracing::{debug, info, warn};

use crate::config::Config;
use crate::event::{CommandResult, Event, EventError, EventJournal, EventKind, StateEvent};
use crate::folder::{FolderError, FolderState, Folders};
use crate::store::{Store, StoreError};
use crate::terminal::{
    TerminalChunk, TerminalError, TerminalId, TerminalManager, TerminalSize, TerminalState,
    TerminalStatus, TerminalStream,
};

const DATABASE_FILE_NAME: &str = "twine.db";
const DEFAULT_EVENT_CAPACITY: usize = 4_096;
const DEFAULT_TERMINAL_CAPACITY_BYTES: usize = 1024 * 1024;
const DEFAULT_TERMINAL_CAPACITY_CHUNKS: usize = 4_096;

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub struct RequestId(pub u64);

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Command {
    Ping,
    /// Opens the folder at an absolute path and records it as the most recent folder.
    OpenFolder {
        path: PathBuf,
    },
    /// Closes the open folder, so the window shows the start page.
    CloseFolder,
    RemoveRecentFolder {
        path: PathBuf,
    },
    StartTerminal {
        working_directory: PathBuf,
        size: TerminalSize,
    },
    CloseTerminal {
        terminal_id: TerminalId,
    },
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
    pub config: Config,
    pub folders: FolderState,
    pub terminals: Vec<TerminalState>,
}

#[derive(Debug)]
struct Inner {
    state: ApplicationState,
    folders: Folders,
    events: EventJournal,
    terminals: HashMap<TerminalId, TerminalStatus>,
}

pub struct Application {
    inner: Arc<Mutex<Inner>>,
    terminal_output: Arc<TerminalStream>,
    terminals: TerminalManager,
    config: Config,
}

impl Application {
    /// Creates the application with production queue limits and the user's config file, keeping
    /// its database in `data_directory`, and reopens the folder that was open when Twine last quit.
    ///
    /// # Errors
    ///
    /// Returns an error if the database cannot be opened or migrated, or the initial ready event
    /// cannot be recorded.
    pub fn new(data_directory: &Path) -> Result<Self, ApplicationError> {
        Self::with_config(data_directory, Config::load_user())
    }

    /// Creates the application like [`Application::new`], but with already validated
    /// configuration instead of the user's config file.
    ///
    /// # Errors
    ///
    /// Returns an error if the database cannot be opened or migrated, or the initial ready event
    /// cannot be recorded.
    pub fn with_config(data_directory: &Path, config: Config) -> Result<Self, ApplicationError> {
        let store = Store::open(&data_directory.join(DATABASE_FILE_NAME))?;
        Self::with_store(
            store,
            config,
            DEFAULT_EVENT_CAPACITY,
            DEFAULT_TERMINAL_CAPACITY_BYTES,
        )
    }

    /// Creates the application with an in-memory database, default configuration, and injectable
    /// limits for deterministic tests.
    #[cfg(test)]
    pub(crate) fn with_capacities(
        event_capacity: usize,
        terminal_capacity_bytes: usize,
    ) -> Result<Self, ApplicationError> {
        Self::with_store(
            Store::open_in_memory()?,
            Config::default(),
            event_capacity,
            terminal_capacity_bytes,
        )
    }

    fn with_store(
        store: Store,
        config: Config,
        event_capacity: usize,
        terminal_capacity_bytes: usize,
    ) -> Result<Self, ApplicationError> {
        let folders = Folders::restore(store)?;
        let mut events = EventJournal::new(event_capacity)?;
        events.append(EventKind::State(StateEvent::ApplicationReady))?;

        let terminal_output = Arc::new(TerminalStream::new(
            terminal_capacity_bytes,
            DEFAULT_TERMINAL_CAPACITY_CHUNKS,
        )?);
        let application = Self {
            config,
            inner: Arc::new(Mutex::new(Inner {
                state: ApplicationState::Ready,
                folders,
                events,
                terminals: HashMap::new(),
            })),
            terminal_output: Arc::clone(&terminal_output),
            terminals: TerminalManager::new(terminal_output),
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
        let disposition = match command {
            Command::Ping => {
                let mut inner = self.lock_inner()?;
                inner.events.append(EventKind::CommandCompleted {
                    request_id,
                    result: CommandResult::Pong,
                })?;
                CommandDisposition::Accepted
            }
            Command::OpenFolder { path } => self
                .lock_inner()?
                .update_folders(|folders| folders.open(&path))?,
            Command::CloseFolder => self.lock_inner()?.update_folders(Folders::close)?,
            Command::RemoveRecentFolder { path } => self
                .lock_inner()?
                .update_folders(|folders| folders.remove_recent(&path))?,
            Command::StartTerminal {
                working_directory,
                size,
            } => {
                // Hold state while the process starts so an immediately exiting shell cannot
                // publish its exit before the command-completion event.
                let mut inner = self.lock_inner()?;
                match self.start_terminal(&working_directory, size) {
                    Ok(terminal_id) => {
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
                            "command accepted"
                        );
                        return Ok(CommandReceipt {
                            request_id,
                            disposition: CommandDisposition::Accepted,
                        });
                    }
                    Err(error) => {
                        return Ok(rejected_receipt(
                            request_id,
                            "terminalStartFailed",
                            error.to_string(),
                        ));
                    }
                }
            }
            Command::CloseTerminal { terminal_id } => match self.terminals.close(terminal_id) {
                Ok(()) => {
                    let mut inner = self.lock_inner()?;
                    inner.terminals.remove(&terminal_id);
                    inner.events.append(EventKind::CommandCompleted {
                        request_id,
                        result: CommandResult::TerminalClosed { terminal_id },
                    })?;
                    debug!(
                        request_id = request_id.0,
                        terminal_id = terminal_id.value(),
                        "command accepted"
                    );
                    return Ok(CommandReceipt {
                        request_id,
                        disposition: CommandDisposition::Accepted,
                    });
                }
                Err(error) => {
                    return Ok(rejected_receipt(
                        request_id,
                        "terminalCloseFailed",
                        error.to_string(),
                    ));
                }
            },
        };
        match &disposition {
            CommandDisposition::Accepted => debug!(request_id = request_id.0, "command accepted"),
            CommandDisposition::Rejected { code, .. } => {
                debug!(request_id = request_id.0, code, "command rejected");
            }
        }
        Ok(CommandReceipt {
            request_id,
            disposition,
        })
    }

    /// Returns an atomic snapshot of application state and the latest event sequence.
    ///
    /// # Errors
    ///
    /// Returns an error if application state cannot be accessed.
    pub fn snapshot(&self) -> Result<Snapshot, ApplicationError> {
        let inner = self.lock_inner()?;
        let mut terminals = inner
            .terminals
            .iter()
            .map(|(terminal_id, status)| TerminalState {
                terminal_id: *terminal_id,
                status: status.clone(),
            })
            .collect::<Vec<_>>();
        terminals.sort_by_key(|terminal| terminal.terminal_id.value());
        Ok(Snapshot {
            sequence: inner.events.latest_sequence(),
            state: inner.state,
            config: self.config.clone(),
            folders: inner.folders.state().clone(),
            terminals,
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
        Ok(self.terminal_output.open()?)
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
        Ok(self.terminal_output.publish(terminal_id, bytes)?)
    }

    /// Removes the next terminal chunk from the binary output queue.
    ///
    /// # Errors
    ///
    /// Returns an error if the queue cannot be accessed.
    pub fn next_terminal_chunk(&self) -> Result<Option<TerminalChunk>, ApplicationError> {
        Ok(self.terminal_output.next_chunk()?)
    }

    /// Releases the retained byte offset for a terminal whose queued output has been drained.
    ///
    /// # Errors
    ///
    /// Returns an error if output for the terminal is still queued or the queue cannot be
    /// accessed.
    pub fn close_terminal_output(&self, terminal_id: TerminalId) -> Result<(), ApplicationError> {
        Ok(self.terminal_output.close(terminal_id)?)
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

    fn start_terminal(
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
                    warn!(terminal_id = terminal_id.value(), "application state lock poisoned after terminal exit");
                    return;
                };
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
                inner.terminals.insert(terminal_id, status);
                if let Err(error) = inner.events.append(EventKind::State(event)) {
                    warn!(terminal_id = terminal_id.value(), %error, "failed to record terminal exit");
                }
            }),
        )?)
    }

    fn lock_inner(&self) -> Result<MutexGuard<'_, Inner>, ApplicationError> {
        self.inner.lock().map_err(|_| ApplicationError::Poisoned)
    }
}

impl Inner {
    /// Applies a folder change and records the new folder state as an event if it changed. Invalid
    /// paths and folders that can't be opened reject the command; store failures are errors.
    fn update_folders(
        &mut self,
        change: impl FnOnce(&mut Folders) -> Result<(), FolderError>,
    ) -> Result<CommandDisposition, ApplicationError> {
        let previous = self.folders.state().clone();
        let result = change(&mut self.folders);
        if *self.folders.state() != previous {
            self.events
                .append(EventKind::State(StateEvent::FoldersChanged(
                    self.folders.state().clone(),
                )))?;
        }

        let (code, error) = match result {
            Ok(()) => return Ok(CommandDisposition::Accepted),
            Err(FolderError::Store(error)) => return Err(error.into()),
            Err(error @ FolderError::InvalidPath) => ("invalidPath", error),
            Err(error @ FolderError::Missing) => ("folderNotFound", error),
            Err(error @ FolderError::Inaccessible) => ("folderInaccessible", error),
        };
        Ok(CommandDisposition::Rejected {
            code: code.to_owned(),
            message: error.to_string(),
        })
    }
}

impl Drop for Application {
    fn drop(&mut self) {
        self.terminals.shutdown();
    }
}

fn rejected_receipt(request_id: RequestId, code: &str, message: String) -> CommandReceipt {
    CommandReceipt {
        request_id,
        disposition: CommandDisposition::Rejected {
            code: code.to_owned(),
            message,
        },
    }
}

#[derive(Debug, Error)]
pub enum ApplicationError {
    #[error(transparent)]
    Event(#[from] EventError),
    #[error("application state lock is poisoned")]
    Poisoned,
    #[error(transparent)]
    Store(#[from] StoreError),
    #[error(transparent)]
    Terminal(#[from] TerminalError),
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use super::*;
    use crate::config::{ColorScheme, Config};
    use crate::folder::{UnavailableFolder, UnavailableReason};

    #[test]
    fn snapshot_then_events_has_no_gap_or_repeat() {
        let data = tempfile::tempdir().expect("a data directory should be available");
        let application = Application::with_config(data.path(), Config::default())
            .expect("application should initialize");
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
            application.close_terminal_output(terminal_id),
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
            .close_terminal_output(terminal_id)
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
    fn folder_commands_publish_folder_state_after_the_snapshot() {
        let folder = tempfile::tempdir().expect("a folder should be available");
        let application =
            Application::with_capacities(16, 64).expect("application should initialize");
        let snapshot = application.snapshot().expect("snapshot should succeed");
        assert_eq!(snapshot.folders, FolderState::default());

        let receipt = application
            .handle_command(
                RequestId(1),
                Command::OpenFolder {
                    path: folder.path().to_owned(),
                },
            )
            .expect("command should succeed");
        assert_eq!(receipt.disposition, CommandDisposition::Accepted);
        let events = application
            .events_after(snapshot.sequence, 16)
            .expect("events should be available");
        let [event] = events.as_slice() else {
            panic!("expected one event, got {events:?}");
        };
        assert_eq!(event.sequence, snapshot.sequence + 1);
        let EventKind::State(StateEvent::FoldersChanged(folders)) = &event.kind else {
            panic!("expected a folder event, got {event:?}");
        };
        assert_eq!(folders.open_folder.as_deref(), Some(folder.path()));
        assert_eq!(
            application.snapshot().expect("snapshot should succeed"),
            Snapshot {
                sequence: event.sequence,
                state: ApplicationState::Ready,
                config: Config::default(),
                folders: folders.clone(),
                terminals: Vec::new(),
            }
        );
    }

    #[test]
    fn rejected_folder_commands_explain_themselves() {
        let application =
            Application::with_capacities(16, 64).expect("application should initialize");
        let missing = {
            let folder = tempfile::tempdir().expect("a folder should be available");
            folder.path().to_owned()
        }; // Dropping `folder` deletes it.
        let sequence = application
            .snapshot()
            .expect("snapshot should succeed")
            .sequence;

        let receipt = application
            .handle_command(
                RequestId(1),
                Command::OpenFolder {
                    path: missing.clone(),
                },
            )
            .expect("command should succeed");
        assert!(matches!(
            receipt.disposition,
            CommandDisposition::Rejected { ref code, .. } if code == "folderNotFound"
        ));
        let snapshot = application.snapshot().expect("snapshot should succeed");
        assert_eq!(snapshot.sequence, sequence + 1);
        assert_eq!(
            snapshot.folders.unavailable_folder,
            Some(UnavailableFolder {
                path: missing,
                reason: UnavailableReason::Missing,
            })
        );

        let receipt = application
            .handle_command(
                RequestId(2),
                Command::RemoveRecentFolder {
                    path: PathBuf::from("relative"),
                },
            )
            .expect("command should succeed");
        assert!(matches!(
            receipt.disposition,
            CommandDisposition::Rejected { ref code, .. } if code == "invalidPath"
        ));
        assert_eq!(
            application
                .snapshot()
                .expect("snapshot should succeed")
                .sequence,
            snapshot.sequence,
            "a command that changes nothing publishes no event"
        );
    }

    #[test]
    fn a_new_application_reopens_the_last_folder_from_its_data_directory() {
        let data = tempfile::tempdir().expect("a data directory should be available");
        let folder = tempfile::tempdir().expect("a folder should be available");
        let application = Application::with_config(data.path(), Config::default())
            .expect("application should initialize");
        application
            .handle_command(
                RequestId(1),
                Command::OpenFolder {
                    path: folder.path().to_owned(),
                },
            )
            .expect("command should succeed");
        drop(application);

        let relaunched = Application::with_config(data.path(), Config::default())
            .expect("application should initialize");
        assert_eq!(
            relaunched
                .snapshot()
                .expect("snapshot should succeed")
                .folders
                .open_folder
                .as_deref(),
            Some(folder.path())
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

    #[test]
    fn snapshot_contains_loaded_config() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("config.toml");
        std::fs::write(&path, "[appearance]\ncolor_scheme = 'dark'\n").unwrap();
        let application =
            Application::with_config(directory.path(), Config::load(&path).config).unwrap();
        assert_eq!(
            application
                .snapshot()
                .unwrap()
                .config
                .appearance
                .color_scheme,
            ColorScheme::Dark
        );
    }
}
