use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard};

use thiserror::Error;
use tracing::{debug, info};

use crate::config::Config;
use crate::event::{CommandResult, Event, EventError, EventJournal, EventKind, StateEvent};
use crate::folder::{FolderError, FolderState, Folders};
use crate::store::{Store, StoreError};
use crate::terminal::{
    TerminalError, TerminalId, TerminalManager, TerminalSize, TerminalState, TerminalStatus,
    TerminalStream, TranscriptError, TranscriptRecorder,
};

use crate::harness::{HarnessId, LoginPath};
use crate::workflow::{SessionId, WorkflowId, WorkflowKind, WorkflowState};

mod agents;
mod files;
mod git;
mod harness_steps;
#[cfg(test)]
mod recovery;
mod resume_agents;
mod run_inputs;
mod runs;
mod sessions;
mod terminals;
mod traces;
mod workflow_types;
mod workflows;

const DATABASE_FILE_NAME: &str = "twine.db";
const DEFAULT_EVENT_CAPACITY: usize = 4_096;
const DEFAULT_TERMINAL_CAPACITY_BYTES: usize = 1024 * 1024;
const DEFAULT_TERMINAL_CAPACITY_CHUNKS: usize = 4_096;

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub struct RequestId(pub u64);

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Command {
    Ping,
    ValidateWorkflowType {
        definition: crate::WorkflowTypeDefinition,
    },
    SaveWorkflowType {
        source: Option<crate::WorkflowTypeRef>,
        definition: crate::WorkflowTypeDefinition,
    },
    /// Opens the folder at an absolute path and records it as the most recent folder.
    OpenFolder {
        path: PathBuf,
    },
    /// Closes the open folder, so the window shows the start page.
    CloseFolder,
    /// Used by a departing window; an old folder must not close its replacement.
    CloseFolderIfOpen {
        path: PathBuf,
    },
    RemoveRecentFolder {
        path: PathBuf,
    },
    RefreshGitBranch {
        folder: PathBuf,
    },
    CreateSession {
        folder: PathBuf,
        name: String,
    },
    RenameSession {
        session_id: SessionId,
        name: String,
    },
    SelectSession {
        session_id: SessionId,
    },
    DeleteSession {
        session_id: SessionId,
    },
    CreateWorkflow {
        folder: PathBuf,
        session_id: Option<SessionId>,
        kind: WorkflowKind,
        /// One role per agent, in order. Agents workflows need at least one; other kinds take none.
        roles: Vec<String>,
        size: TerminalSize,
    },
    ActivateWorkflow {
        workflow_id: WorkflowId,
    },
    NameDraftWorkflow {
        workflow_id: WorkflowId,
        name: String,
    },
    CloseWorkflow {
        workflow_id: WorkflowId,
    },
    /// Runs a draft workflow as a single agent: `harness` started with `prompt`, or waiting for
    /// the user in its terminal when `prompt` is empty.
    StartAgent {
        workflow_id: WorkflowId,
        harness: HarnessId,
        /// The harness's model, or its own default when absent.
        model: Option<String>,
        /// The harness's effort level, or its own default when absent.
        effort: Option<String>,
        /// Skips the harness's permission prompts, where it has them.
        yolo: bool,
        prompt: String,
        size: TerminalSize,
    },
    ResumeAgent {
        workflow_id: WorkflowId,
        session: String,
    },
    /// Stops a running agent, leaving its workflow open.
    CancelAgent {
        workflow_id: WorkflowId,
    },
    /// Starts a workflow run. With an empty `prompt`, the first stage asks the user for the task
    /// and reports it when it completes.
    StartWorkflowRun {
        workflow_id: WorkflowId,
        workflow_type: crate::WorkflowTypeRef,
        prompt: String,
        roles: Vec<crate::RoleLaunch>,
        size: TerminalSize,
    },
    CompleteWorkflowRole {
        workflow_id: WorkflowId,
        agent_id: crate::AgentId,
        generation: u64,
        signal: crate::CompletionSignal,
    },
    /// A follow-up to a first-stage agent starts another cycle with the same conversations.
    ContinueWorkflowRun {
        workflow_id: WorkflowId,
        agent_id: crate::AgentId,
        generation: u64,
        mode_revision: u64,
    },
    SetWorkflowIndividualMode {
        workflow_id: WorkflowId,
        generation: u64,
        mode_revision: u64,
        individual_mode: bool,
    },
    CancelWorkflowRun {
        workflow_id: WorkflowId,
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
    pub workflows: WorkflowState,
    pub traces: Vec<crate::TraceSummary>,
    pub workflow_types: Vec<crate::WorkflowType>,
}

#[derive(Debug)]
struct Inner {
    state: ApplicationState,
    folders: Folders,
    events: EventJournal,
    terminals: HashMap<TerminalId, TerminalStatus>,
    workflows: WorkflowState,
    trace_spans: HashMap<TerminalId, crate::TraceSpanId>,
    step_terminals: HashMap<TerminalId, WorkflowId>,
    pending_trace_endings: HashMap<TerminalId, traces::PendingTraceEnding>,
    command_shells: std::collections::HashSet<TerminalId>,
    shell_process_endings: HashMap<TerminalId, traces::PendingTraceEnding>,
    pending_shell_marks: std::collections::VecDeque<crate::terminal::ShellObservation>,
    pending_shell_workflows: HashMap<TerminalId, crate::Workflow>,
}

pub struct Application {
    files: crate::files::FileWatcher,
    // Serialize lifetime commands without holding state while joining terminal supervisors.
    commands: Mutex<()>,
    inner: Arc<Mutex<Inner>>,
    terminal_output: Arc<TerminalStream>,
    terminals: TerminalManager,
    /// Shared with threads that list harness models.
    login_path: Arc<LoginPath>,
    /// Makes harness lookup search only this `PATH`, so tests don't depend on installed tools.
    #[cfg(test)]
    harness_path: Option<std::ffi::OsString>,
    config: Config,
    run_processes: Mutex<HashMap<WorkflowId, runs::RunProcesses>>,
    harness_steps: Mutex<HashMap<TerminalId, harness_steps::HarnessRecording>>,
}

impl Application {
    /// Creates the application with production queue limits and the user's config file, keeping
    /// its database in `data_directory`, and reopens the folder that was open when Twine last quit.
    ///
    /// # Errors
    ///
    /// Returns an error if the database cannot be opened or migrated, transcript storage cannot
    /// be opened or is owned by another core, or the initial ready event cannot be recorded.
    pub fn new(data_directory: &Path) -> Result<Self, ApplicationError> {
        Self::with_config(data_directory, Config::load_user())
    }

    /// Creates the application like [`Application::new`], but with already validated
    /// configuration instead of the user's config file.
    ///
    /// # Errors
    ///
    /// Returns an error if the database cannot be opened or migrated, transcript storage cannot
    /// be opened or is owned by another core, or the initial ready event cannot be recorded.
    pub fn with_config(data_directory: &Path, config: Config) -> Result<Self, ApplicationError> {
        // Acquire directory ownership before migrating or recovering any durable state.
        let transcripts = Arc::new(TranscriptRecorder::open(
            &data_directory.join("transcripts"),
        )?);
        let store = Store::open(&data_directory.join(DATABASE_FILE_NAME))?;
        Self::with_store(store, config, DEFAULT_EVENT_CAPACITY, transcripts)
    }

    /// Creates the application with an in-memory database, default configuration, and an
    /// injectable event limit for deterministic tests.
    #[cfg(test)]
    pub(crate) fn with_event_capacity(event_capacity: usize) -> Result<Self, ApplicationError> {
        let mut application = Self::with_store(
            Store::open_in_memory()?,
            Config::default(),
            event_capacity,
            Arc::new(TranscriptRecorder::temporary()?),
        )?;
        application
            .terminals
            .set_test_shell(PathBuf::from("/bin/sh"));
        Ok(application)
    }

    fn with_store(
        mut store: Store,
        config: Config,
        event_capacity: usize,
        transcripts: Arc<TranscriptRecorder>,
    ) -> Result<Self, ApplicationError> {
        // Recover every folder, including closed or currently unavailable folders, before ready.
        store.recover_interrupted_work()?;
        let folders = Folders::restore(store)?;
        let mut events = EventJournal::new(event_capacity)?;
        events.append(EventKind::State(StateEvent::ApplicationReady))?;

        let terminal_output = Arc::new(TerminalStream::new(
            DEFAULT_TERMINAL_CAPACITY_BYTES,
            DEFAULT_TERMINAL_CAPACITY_CHUNKS,
            transcripts,
        )?);
        let terminals = TerminalManager::new(Arc::clone(&terminal_output));
        #[cfg(test)]
        let terminals = {
            let mut terminals = terminals;
            // Unit tests must not depend on the developer's login shell or startup config.
            terminals.set_test_shell(PathBuf::from("/bin/sh"));
            terminals
        };
        let application = Self {
            files: crate::files::FileWatcher::new()?,
            run_processes: Mutex::new(HashMap::new()),
            harness_steps: Mutex::new(HashMap::new()),
            commands: Mutex::new(()),
            config,
            inner: Arc::new(Mutex::new(Inner {
                state: ApplicationState::Ready,
                folders,
                events,
                terminals: HashMap::new(),
                workflows: WorkflowState::default(),
                trace_spans: HashMap::new(),
                step_terminals: HashMap::new(),
                pending_trace_endings: HashMap::new(),
                command_shells: std::collections::HashSet::new(),
                shell_process_endings: HashMap::new(),
                pending_shell_marks: std::collections::VecDeque::new(),
                pending_shell_workflows: HashMap::new(),
            })),
            terminal_output: Arc::clone(&terminal_output),
            terminals,
            // Unit tests must not start the developer's login shell.
            #[cfg(test)]
            login_path: Arc::new(LoginPath::ready(None)),
            #[cfg(not(test))]
            login_path: Arc::new(LoginPath::spawn(crate::terminal::login_shell())),
            #[cfg(test)]
            harness_path: None,
        };

        application.restore_workflows()?;
        info!("application core initialized");
        Ok(application)
    }

    /// Handles a command and returns its immediate acceptance result.
    ///
    /// # Errors
    ///
    /// Returns an error if application state cannot be accessed or the resulting event cannot be
    /// recorded.
    #[expect(clippy::too_many_lines, reason = "one short arm per command")]
    pub fn handle_command(
        &self,
        request_id: RequestId,
        command: Command,
    ) -> Result<CommandReceipt, ApplicationError> {
        let _command_guard = self
            .commands
            .lock()
            .map_err(|_| ApplicationError::Poisoned)?;
        self.lock_inner()?.retry_trace_endings();
        self.poll_harness_steps()?;
        self.poll_shell_observations()?;
        let disposition = match command {
            Command::ValidateWorkflowType { definition } => {
                self.validate_workflow_type(request_id, &definition)?
            }
            Command::SaveWorkflowType { source, definition } => {
                self.save_workflow_type(request_id, source, &definition)?
            }
            Command::Ping => {
                let mut inner = self.lock_inner()?;
                inner.events.append(EventKind::CommandCompleted {
                    request_id,
                    result: CommandResult::Pong,
                })?;
                CommandDisposition::Accepted
            }
            Command::OpenFolder { path } => self.change_folder(Some(&path))?,
            Command::CloseFolder => self.change_folder(None)?,
            Command::CloseFolderIfOpen { path } => {
                if self.lock_inner()?.folders.state().open_folder.as_deref() == Some(path.as_path())
                {
                    self.change_folder(None)?
                } else {
                    CommandDisposition::Accepted
                }
            }
            Command::RemoveRecentFolder { path } => self
                .lock_inner()?
                .update_folders(|folders| folders.remove_recent(&path))?,
            Command::RefreshGitBranch { folder } => self.refresh_git_branch(&folder)?,
            Command::CreateSession { folder, name } => {
                self.create_session(request_id, &folder, &name)?
            }
            Command::RenameSession { session_id, name } => {
                self.rename_session(request_id, session_id, &name)?
            }
            Command::SelectSession { session_id } => self.select_session(request_id, session_id)?,
            Command::DeleteSession { session_id } => self.delete_session(request_id, session_id)?,
            Command::CreateWorkflow {
                folder,
                session_id,
                kind,
                roles,
                size,
            } => self.create_workflow(request_id, &folder, session_id, kind, &roles, size)?,
            Command::ActivateWorkflow { workflow_id } => {
                self.activate_workflow(request_id, workflow_id)?
            }
            Command::NameDraftWorkflow { workflow_id, name } => {
                self.name_draft_workflow(workflow_id, &name)?
            }
            Command::CloseWorkflow { workflow_id } => {
                self.close_workflow(request_id, workflow_id)?
            }
            Command::StartAgent {
                workflow_id,
                harness,
                model,
                effort,
                yolo,
                prompt,
                size,
            } => self.start_agent(
                request_id,
                workflow_id,
                harness,
                (model.as_deref(), effort.as_deref(), yolo),
                &prompt,
                size,
            )?,
            Command::ResumeAgent {
                workflow_id,
                session,
            } => self.resume_agent(request_id, workflow_id, &session)?,
            Command::CancelAgent { workflow_id } => self.cancel_agent(request_id, workflow_id)?,
            Command::StartWorkflowRun {
                workflow_id,
                workflow_type,
                prompt,
                roles,
                size,
            } => self.start_workflow_run(workflow_id, workflow_type, prompt, &roles, size)?,
            Command::CompleteWorkflowRole {
                workflow_id,
                agent_id,
                generation,
                signal,
            } => self.complete_workflow_role(workflow_id, agent_id, generation, signal)?,
            Command::ContinueWorkflowRun {
                workflow_id,
                agent_id,
                generation,
                mode_revision,
            } => self.continue_workflow_run(workflow_id, agent_id, generation, mode_revision)?,
            Command::SetWorkflowIndividualMode {
                workflow_id,
                generation,
                mode_revision,
                individual_mode,
            } => self.set_workflow_individual_mode(
                workflow_id,
                generation,
                mode_revision,
                individual_mode,
            )?,
            Command::CancelWorkflowRun { workflow_id } => self.cancel_workflow_run(workflow_id)?,
            Command::StartTerminal {
                working_directory,
                size,
            } => self.start_terminal_command(request_id, &working_directory, size)?,
            Command::CloseTerminal { terminal_id } => {
                self.close_terminal_command(request_id, terminal_id)?
            }
        };
        self.prune_run_processes()?;
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
        self.poll_harness_steps()?;
        self.poll_shell_observations()?;
        self.poll_workflow_signals()?;
        let mut inner = self.lock_inner()?;
        let workflow_types =
            crate::workflow_type::WorkflowCatalog::new(inner.folders.store()).list()?;
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
            workflows: inner.workflows.clone(),
            traces: match &inner.folders.state().open_folder {
                Some(folder) => inner.folders.read_store().trace_summaries(folder)?,
                None => Vec::new(),
            },
            workflow_types,
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
        self.poll_shell_observations()?;
        self.poll_workflow_signals()?;
        Ok(self.lock_inner()?.events.after(sequence, limit)?)
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
        Ok(rejection(code, &error))
    }
}

impl Drop for Application {
    fn drop(&mut self) {
        let _ = self.poll_harness_steps();
        let _ = self.poll_shell_observations();
        if let Ok(mut inner) = self.inner.lock() {
            inner.retry_trace_endings();
            let ids = inner
                .trace_spans
                .keys()
                .chain(inner.step_terminals.keys())
                .copied()
                .collect::<std::collections::HashSet<_>>();
            for id in ids {
                if let Ok(observation) = self.terminals.observe(id)
                    && let Err(error) =
                        inner.stop_trace(id, observation, "Process stopped when Twine quit.")
                {
                    tracing::warn!(%error, "failed to persist trace during shutdown");
                }
            }
            // Exit callbacks are ignored after explicit shutdown takes ownership of stopping.
            inner.terminals.clear();
        }
        self.terminals.shutdown();
        self.terminal_output.shutdown_recording();
    }
}

fn rejection(code: &str, error: &dyn std::error::Error) -> CommandDisposition {
    CommandDisposition::Rejected {
        code: code.to_owned(),
        message: error.to_string(),
    }
}

#[derive(Debug, Error)]
pub enum ApplicationError {
    #[error(transparent)]
    Harness(#[from] crate::harness::HarnessError),
    #[error(transparent)]
    Catalog(#[from] crate::CatalogError),
    #[error(transparent)]
    Files(#[from] crate::files::FileError),
    #[error(transparent)]
    Event(#[from] EventError),
    #[error("session or workflow identifiers exhausted")]
    IdExhausted,
    #[error("application state lock is poisoned")]
    Poisoned,
    #[error(transparent)]
    Store(#[from] StoreError),
    #[error(transparent)]
    Terminal(#[from] TerminalError),
    #[error(transparent)]
    Transcript(#[from] TranscriptError),
    #[error(transparent)]
    Trace(#[from] crate::TraceError),
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
        assert_eq!(
            application
                .events_after(events[0].sequence, 16)
                .expect("up-to-date cursor should succeed"),
            []
        );
    }

    #[test]
    fn expired_cursor_is_explicit() {
        let application =
            Application::with_event_capacity(2).expect("application should initialize");
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
    fn folder_commands_publish_folder_state_after_the_snapshot() {
        let folder = tempfile::tempdir().expect("a folder should be available");
        let application =
            Application::with_event_capacity(16).expect("application should initialize");
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
                workflows: WorkflowState::default(),
                traces: Vec::new(),
                workflow_types: application.workflow_types().unwrap(),
            }
        );
    }

    #[test]
    fn rejected_terminal_commands_explain_themselves() {
        let application =
            Application::with_event_capacity(16).expect("application should initialize");
        let missing = {
            let folder = tempfile::tempdir().expect("a folder should be available");
            folder.path().to_owned()
        }; // Dropping `folder` deletes it.
        let sequence = application
            .snapshot()
            .expect("snapshot should succeed")
            .sequence;

        let start = application
            .handle_command(
                RequestId(1),
                Command::StartTerminal {
                    working_directory: missing,
                    size: TerminalSize {
                        rows: 24,
                        columns: 80,
                        pixel_width: 800,
                        pixel_height: 480,
                    },
                },
            )
            .expect("command should succeed");
        assert!(matches!(
            start.disposition,
            CommandDisposition::Rejected { ref code, .. } if code == "terminalStartFailed"
        ));

        let close = application
            .handle_command(
                RequestId(2),
                Command::CloseTerminal {
                    terminal_id: TerminalId::from_value(99),
                },
            )
            .expect("command should succeed");
        assert!(matches!(
            close.disposition,
            CommandDisposition::Rejected { ref code, .. } if code == "terminalCloseFailed"
        ));

        let snapshot = application.snapshot().expect("snapshot should succeed");
        assert_eq!(snapshot.sequence, sequence);
        assert_eq!(snapshot.terminals, []);
    }

    #[test]
    fn rejected_folder_commands_explain_themselves() {
        let application =
            Application::with_event_capacity(16).expect("application should initialize");
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
            Application::with_event_capacity(3_000).expect("application should initialize"),
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
        std::fs::write(
            &path,
            "[appearance]\ncolor_scheme = 'dark'\n[terminal]\nfont_family = 'Menlo'\nfont_size = 15.5\n",
        )
        .unwrap();
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
        let config = application.snapshot().unwrap().config;
        assert_eq!(config.terminal.font_family, "Menlo");
        assert!((config.terminal.font_size.points() - 15.5).abs() < f64::EPSILON);
    }
}
