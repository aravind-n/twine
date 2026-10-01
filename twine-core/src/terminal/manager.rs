use std::collections::HashMap;
use std::ffi::{OsStr, OsString};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU8, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use portable_pty::{CommandBuilder, MasterPty};
use tracing::{debug, warn};

use super::launcher::{
    canonical_working_directory, default_shell_command, program_launcher_command,
};
use super::process::{SharedChild, terminate_child, terminate_unobserved_child, wait_for_child};
use super::pty::{StartingTerminal, spawn_terminal_process, spawn_terminal_reader};
use super::{TerminalError, TerminalExit, TerminalId, TerminalSize, TerminalStream};

mod cleanup;

const EXIT_REPORT_PENDING: u8 = 0;
const EXIT_REPORT_ENABLED: u8 = 1;
const EXIT_REPORT_SUPPRESSED: u8 = 2;

#[derive(Clone, Debug)]
pub(crate) struct TerminalObservation {
    pub integrated_shell: bool,
    pub observed_at: u64,
    pub byte_offset: u64,
    pub boundary_sizes: Option<Vec<TerminalSize>>,
}

type ExitCallback = Arc<
    dyn Fn(TerminalId, Result<TerminalExit, String>, TerminalObservation) + Send + Sync + 'static,
>;

struct TerminalSession {
    master: Box<dyn MasterPty + Send>,
    size: TerminalSize,
    writer: Arc<Mutex<Box<dyn Write + Send>>>,
    input_closed: Arc<AtomicBool>,
    child: SharedChild,
    output_position: Arc<super::ReplayPosition>,
    reader_cancelled: Arc<AtomicBool>,
    reader_thread: Option<JoinHandle<()>>,
    supervisor_thread: Option<JoinHandle<()>>,
}

pub(crate) struct TerminalManager {
    output: Arc<TerminalStream>,
    #[cfg(test)]
    test_shell: Option<PathBuf>,
    #[cfg(test)]
    test_shell_home: Option<PathBuf>,
    /// How many more default shells may start before a start fails.
    #[cfg(test)]
    test_starts_before_failure: std::sync::atomic::AtomicUsize,
    sessions: Mutex<HashMap<TerminalId, TerminalSession>>,
    integrations: Mutex<HashMap<TerminalId, super::shell::ShellIntegration>>,
    cleanup: cleanup::TerminalCleanup,
}

impl TerminalManager {
    pub(crate) fn new(output: Arc<TerminalStream>) -> Self {
        Self {
            output,
            #[cfg(test)]
            test_shell: None,
            #[cfg(test)]
            test_shell_home: None,
            #[cfg(test)]
            test_starts_before_failure: std::sync::atomic::AtomicUsize::new(usize::MAX),
            sessions: Mutex::new(HashMap::new()),
            integrations: Mutex::new(HashMap::new()),
            cleanup: cleanup::TerminalCleanup::default(),
        }
    }

    #[cfg(test)]
    pub(crate) fn set_test_shell(&mut self, shell: PathBuf) {
        self.test_shell = Some(shell);
    }

    #[cfg(test)]
    pub(crate) fn set_test_shell_home(&mut self, home: PathBuf) {
        self.test_shell_home = Some(home);
    }

    /// Makes every default shell start after the next `starts` fail.
    #[cfg(test)]
    pub(crate) fn fail_starts_after(&self, starts: usize) {
        self.test_starts_before_failure
            .store(starts, Ordering::Release);
    }

    pub(crate) fn start_default_shell(
        &self,
        terminal_id: TerminalId,
        working_directory: &Path,
        size: TerminalSize,
        on_exit: ExitCallback,
        integrate: bool,
    ) -> Result<TerminalId, TerminalError> {
        #[cfg(test)]
        if self
            .test_starts_before_failure
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |starts| {
                starts.checked_sub(1)
            })
            .is_err()
        {
            let _ = self.output.cancel(terminal_id);
            return Err(TerminalError::Pty {
                operation: "start a test shell",
                message: "the test made this start fail".to_owned(),
            });
        }
        let working_directory = match canonical_working_directory(working_directory) {
            Ok(path) => path,
            Err(error) => {
                let _ = self.output.cancel(terminal_id);
                return Err(error);
            }
        };
        let shell = super::launcher::login_shell();
        #[cfg(test)]
        let shell = self.test_shell.clone().unwrap_or(shell);
        let (command, integration) =
            match default_shell_command(&working_directory, &shell, integrate) {
                Ok(prepared) => prepared,
                Err(error) => {
                    let _ = self.output.cancel(terminal_id);
                    return Err(error);
                }
            };
        #[cfg(test)]
        let command = {
            let mut command = command;
            if let Some(home) = &self.test_shell_home {
                if integrate && shell.file_name().is_some_and(|name| name == "bash") {
                    command.env("TWINE_USER_HOME", home);
                } else {
                    command.env("HOME", home);
                }
                command.env("TWINE_USER_ZDOTDIR", home);
                command.env("XDG_CONFIG_HOME", home.join(".config"));
                command.env("HISTFILE", home.join(".history"));
            }
            command
        };
        if let Some(integration) = integration {
            self.output
                .integrate_shell(terminal_id, integration.token.clone())?;
            self.integrations
                .lock()
                .map_err(|_| TerminalError::Poisoned)?
                .insert(terminal_id, integration);
        }
        let result =
            self.start_command(terminal_id, command, size, Some(working_directory), on_exit);
        if result.is_err() {
            self.integrations
                .lock()
                .map_err(|_| TerminalError::Poisoned)?
                .remove(&terminal_id);
        }
        result
    }

    pub(crate) fn reserve_terminal(&self) -> Result<TerminalId, TerminalError> {
        self.output.open()
    }

    /// Releases a reserved stream when a workflow cannot start all of its shells.
    pub(crate) fn cancel_reserved_terminal(
        &self,
        terminal_id: TerminalId,
    ) -> Result<(), TerminalError> {
        self.output.cancel(terminal_id)
    }

    /// Starts `program` in `working_directory` with the given environment `PATH`.
    #[expect(
        clippy::too_many_arguments,
        reason = "the reserved ID keeps transcript allocation outside application-state locks"
    )]
    pub(crate) fn start_program(
        &self,
        terminal_id: TerminalId,
        working_directory: &Path,
        program: &Path,
        arguments: &[OsString],
        path: &OsStr,
        size: TerminalSize,
        on_exit: ExitCallback,
    ) -> Result<TerminalId, TerminalError> {
        let working_directory = match canonical_working_directory(working_directory) {
            Ok(path) => path,
            Err(error) => {
                let _ = self.output.cancel(terminal_id);
                return Err(error);
            }
        };
        let command = program_launcher_command(&working_directory, program, arguments, path);
        self.start_command(terminal_id, command, size, Some(working_directory), on_exit)
    }

    /// The last size the terminal was given, if it is open.
    pub(crate) fn size(&self, terminal_id: TerminalId) -> Option<TerminalSize> {
        Some(self.lock_sessions().ok()?.get(&terminal_id)?.size)
    }

    /// Stops the process but keeps the terminal open, so its output stays readable until closed.
    pub(crate) fn terminate(&self, terminal_id: TerminalId) -> Result<(), TerminalError> {
        let child = {
            let sessions = self.lock_sessions()?;
            let session = sessions
                .get(&terminal_id)
                .ok_or(TerminalError::NotOpen { terminal_id })?;
            session.input_closed.store(true, Ordering::Release);
            Arc::clone(&session.child)
        };
        terminate_child(&child);
        Ok(())
    }

    fn start_command(
        &self,
        terminal_id: TerminalId,
        command: CommandBuilder,
        size: TerminalSize,
        working_directory_handshake: Option<PathBuf>,
        on_exit: ExitCallback,
    ) -> Result<TerminalId, TerminalError> {
        let output_position = self.output.replay_position(terminal_id)?;
        if let Err(error) = size
            .validate()
            .and_then(|size| self.output.record_size(terminal_id, size))
        {
            let _ = self.output.cancel(terminal_id);
            return Err(error);
        }
        let starting = match spawn_terminal_process(command, size, working_directory_handshake) {
            Ok(starting) => starting,
            Err(error) => {
                let _ = self.output.cancel(terminal_id);
                return Err(error);
            }
        };
        let StartingTerminal {
            master,
            reader,
            writer,
            child,
            reader_descriptor,
        } = starting;
        let reader_cancelled = Arc::new(AtomicBool::new(false));
        let reader_thread = match spawn_terminal_reader(
            Arc::clone(&self.output),
            terminal_id,
            reader,
            reader_descriptor,
            Arc::clone(&reader_cancelled),
        ) {
            Ok(thread) => thread,
            Err(error) => {
                let _ = self.output.cancel(terminal_id);
                terminate_unobserved_child(&child);
                return Err(error);
            }
        };

        let exit_reporting = Arc::new(AtomicU8::new(EXIT_REPORT_PENDING));
        let input_closed = Arc::new(AtomicBool::new(false));
        let supervisor_thread = match spawn_terminal_supervisor(
            terminal_id,
            &child,
            &exit_reporting,
            Arc::clone(&input_closed),
            Arc::clone(&output_position),
            on_exit,
        ) {
            Ok(thread) => thread,
            Err(error) => {
                exit_reporting.store(EXIT_REPORT_SUPPRESSED, Ordering::Release);
                let _ = self.output.cancel(terminal_id);
                stop_session(
                    terminal_id,
                    TerminalSession {
                        master,
                        size,
                        writer,
                        input_closed,
                        child,
                        output_position,
                        reader_cancelled,
                        reader_thread: Some(reader_thread),
                        supervisor_thread: None,
                    },
                );
                return Err(error);
            }
        };

        let session = TerminalSession {
            master,
            size,
            writer,
            input_closed,
            child,
            output_position,
            reader_cancelled,
            reader_thread: Some(reader_thread),
            supervisor_thread: Some(supervisor_thread),
        };
        match self.lock_sessions() {
            Ok(mut sessions) => {
                sessions.insert(terminal_id, session);
                exit_reporting.store(EXIT_REPORT_ENABLED, Ordering::Release);
            }
            Err(error) => {
                exit_reporting.store(EXIT_REPORT_SUPPRESSED, Ordering::Release);
                let _ = self.output.cancel(terminal_id);
                stop_session(terminal_id, session);
                return Err(error);
            }
        }
        debug!(
            terminal_id = terminal_id.value(),
            "terminal process started"
        );
        Ok(terminal_id)
    }

    pub(crate) fn write_input(
        &self,
        terminal_id: TerminalId,
        bytes: &[u8],
    ) -> Result<(), TerminalError> {
        if bytes.is_empty() {
            return Ok(());
        }
        let (writer, input_closed) = {
            let sessions = self.lock_sessions()?;
            let session = sessions
                .get(&terminal_id)
                .ok_or(TerminalError::NotOpen { terminal_id })?;
            (
                Arc::clone(&session.writer),
                Arc::clone(&session.input_closed),
            )
        };
        let mut writer = writer.lock().map_err(|_| TerminalError::Poisoned)?;
        if input_closed.load(Ordering::Acquire) {
            return Err(TerminalError::NotRunning { terminal_id });
        }
        writer
            .write_all(bytes)
            .and_then(|()| writer.flush())
            .map_err(|error| {
                // The PTY can hang up before the supervisor publishes the process exit.
                if terminal_input_closed(&error) {
                    input_closed.store(true, Ordering::Release);
                    TerminalError::NotRunning { terminal_id }
                } else {
                    TerminalError::Pty {
                        operation: "write terminal input",
                        message: error.to_string(),
                    }
                }
            })?;
        Ok(())
    }

    pub(crate) fn resize(
        &self,
        terminal_id: TerminalId,
        size: TerminalSize,
    ) -> Result<(), TerminalError> {
        let size = size.validate()?;
        let mut sessions = self.lock_sessions()?;
        let session = sessions
            .get_mut(&terminal_id)
            .ok_or(TerminalError::NotOpen { terminal_id })?;
        if session.input_closed.load(Ordering::Acquire) {
            return Err(TerminalError::NotRunning { terminal_id });
        }
        self.output
            .change_size(terminal_id, size, || {
                session
                    .master
                    .resize(size.into())
                    .map_err(|error| TerminalError::Pty {
                        operation: "resize PTY",
                        message: error.to_string(),
                    })
            })
            .map_err(|error| match error {
                // The reader can finish and drain its stream before the supervisor marks
                // input closed. The session still exists; this is an exit, not an invalid ID.
                TerminalError::NotOpen { .. } => {
                    session.input_closed.store(true, Ordering::Release);
                    TerminalError::NotRunning { terminal_id }
                }
                error => error,
            })?;
        session.size = size;
        Ok(())
    }

    pub(crate) fn observe(
        &self,
        terminal_id: TerminalId,
    ) -> Result<TerminalObservation, TerminalError> {
        let sessions = self.lock_sessions()?;
        let session = sessions
            .get(&terminal_id)
            .ok_or(TerminalError::NotOpen { terminal_id })?;
        session.output_position.observe()
    }

    pub(crate) fn close(&self, terminal_id: TerminalId) -> Result<(), TerminalError> {
        let session = self
            .lock_sessions()?
            .remove(&terminal_id)
            .ok_or(TerminalError::NotOpen { terminal_id })?;
        let _ = self.output.cancel(terminal_id);
        stop_session(terminal_id, session);
        self.integrations
            .lock()
            .map_err(|_| TerminalError::Poisoned)?
            .remove(&terminal_id);
        debug!(terminal_id = terminal_id.value(), "terminal process closed");
        Ok(())
    }

    /// Retires a replaced terminal without holding up the new terminal's startup responses.
    /// Shutdown still waits for the retired process and both of its workers to finish.
    pub(crate) fn close_in_background(&self, terminal_id: TerminalId) -> Result<(), TerminalError> {
        let session = self
            .lock_sessions()?
            .remove(&terminal_id)
            .ok_or(TerminalError::NotOpen { terminal_id })?;
        session.input_closed.store(true, Ordering::Release);
        let _ = self.output.cancel(terminal_id);
        let integration = self
            .integrations
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .remove(&terminal_id);
        self.cleanup.close(terminal_id, session, integration);
        Ok(())
    }

    /// Closes the terminals together, so their hang-up grace periods overlap instead of adding up.
    /// Every open one closes even if another wasn't open; the first that wasn't is the error.
    pub(crate) fn close_all(&self, terminal_ids: &[TerminalId]) -> Result<(), TerminalError> {
        let mut result = Ok(());
        let mut sessions = Vec::with_capacity(terminal_ids.len());
        {
            let mut open = self.lock_sessions()?;
            for &terminal_id in terminal_ids {
                if let Some(session) = open.remove(&terminal_id) {
                    sessions.push((terminal_id, session));
                } else {
                    warn!(
                        terminal_id = terminal_id.value(),
                        "terminal to close is not open"
                    );
                    if result.is_ok() {
                        result = Err(TerminalError::NotOpen { terminal_id });
                    }
                }
            }
        }
        for (terminal_id, _) in &sessions {
            let _ = self.output.cancel(*terminal_id);
        }
        stop_sessions(sessions);
        let mut integrations = self
            .integrations
            .lock()
            .map_err(|_| TerminalError::Poisoned)?;
        for id in terminal_ids {
            integrations.remove(id);
        }
        debug!(count = terminal_ids.len(), "terminal processes closed");
        result
    }

    pub(crate) fn shutdown(&self) {
        let mut sessions = match self.sessions.lock() {
            Ok(sessions) => sessions,
            Err(poisoned) => {
                warn!("terminal session lock poisoned during shutdown; recovering owned sessions");
                poisoned.into_inner()
            }
        };
        let owned_sessions = std::mem::take(&mut *sessions);
        drop(sessions);
        for terminal_id in owned_sessions.keys() {
            let _ = self.output.cancel(*terminal_id);
        }
        stop_sessions(owned_sessions.into_iter().collect());
        self.cleanup.shutdown();
        self.integrations
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clear();
    }

    fn lock_sessions(
        &self,
    ) -> Result<MutexGuard<'_, HashMap<TerminalId, TerminalSession>>, TerminalError> {
        self.sessions.lock().map_err(|_| TerminalError::Poisoned)
    }

    #[cfg(test)]
    fn start_test_command(
        &self,
        command: CommandBuilder,
        size: TerminalSize,
        working_directory_handshake: Option<PathBuf>,
        on_exit: ExitCallback,
    ) -> Result<TerminalId, TerminalError> {
        let id = self.reserve_terminal()?;
        self.start_command(id, command, size, working_directory_handshake, on_exit)
    }
}

impl Drop for TerminalManager {
    fn drop(&mut self) {
        self.shutdown();
    }
}

fn spawn_terminal_supervisor(
    terminal_id: TerminalId,
    child: &SharedChild,
    exit_reporting: &Arc<AtomicU8>,
    input_closed: Arc<AtomicBool>,
    output_position: Arc<super::ReplayPosition>,
    on_exit: ExitCallback,
) -> Result<JoinHandle<()>, TerminalError> {
    let child = Arc::clone(child);
    let exit_reporting = Arc::clone(exit_reporting);
    crate::blocking_worker::spawn(
        format!("terminal-{}-supervisor", terminal_id.value()),
        move || {
            let result = wait_for_child(&child);
            input_closed.store(true, Ordering::Release);
            let observation = output_position
                .observe()
                .unwrap_or_else(|_| TerminalObservation {
                    integrated_shell: false,
                    observed_at: crate::workflow::timestamp(),
                    byte_offset: 0,
                    boundary_sizes: None,
                });
            while exit_reporting.load(Ordering::Acquire) == EXIT_REPORT_PENDING {
                thread::sleep(Duration::from_millis(1));
            }
            if exit_reporting.load(Ordering::Acquire) == EXIT_REPORT_ENABLED {
                on_exit(terminal_id, result, observation);
            }
        },
    )
    .map_err(|error| TerminalError::Thread {
        operation: "start process supervisor",
        message: error.to_string(),
    })
}

/// Stops sessions on worker threads, so each one's hang-up grace period overlaps the others'. If a
/// worker can't start, the ones that did, and this thread, stop its sessions instead.
fn stop_sessions(sessions: Vec<(TerminalId, TerminalSession)>) {
    let extra_workers = sessions.len().saturating_sub(1);
    let pending = Mutex::new(sessions);
    let stop_pending = || {
        loop {
            // Pop before stopping, so the lock isn't held while a session stops.
            let next = pending.lock().unwrap_or_else(PoisonError::into_inner).pop();
            let Some((terminal_id, session)) = next else {
                break;
            };
            stop_session(terminal_id, session);
        }
    };
    thread::scope(|scope| {
        let workers: Vec<_> = (0..extra_workers)
            .map_while(|_| {
                crate::blocking_worker::spawn_scoped(scope, "terminal-stop".into(), stop_pending)
                    .ok()
            })
            .collect();
        stop_pending();
        for worker in workers {
            if worker.join().is_err() {
                warn!("terminal stop thread panicked");
            }
        }
    });
}

fn stop_session(terminal_id: TerminalId, session: TerminalSession) {
    let TerminalSession {
        master,
        size: _,
        writer,
        input_closed,
        child,
        output_position: _,
        reader_cancelled,
        reader_thread,
        supervisor_thread,
    } = session;
    input_closed.store(true, Ordering::Release);
    reader_cancelled.store(true, Ordering::Release);
    if let Some(thread) = reader_thread
        && thread.join().is_err()
    {
        warn!(
            terminal_id = terminal_id.value(),
            "terminal reader thread panicked"
        );
    }
    // Close the PTY master before waiting for the child. A shell that exits as session leader waits
    // for its unread terminal output to drain, and only the hangup from closing the master ends that
    // wait now that nothing reads the output.
    drop(writer);
    drop(master);
    terminate_child(&child);
    if let Some(thread) = supervisor_thread
        && thread.join().is_err()
    {
        warn!(
            terminal_id = terminal_id.value(),
            "terminal supervisor thread panicked"
        );
    }
}

fn terminal_input_closed(error: &std::io::Error) -> bool {
    if error.kind() == std::io::ErrorKind::BrokenPipe {
        return true;
    }
    #[cfg(unix)]
    if error.raw_os_error() == Some(libc::EIO) {
        return true;
    }
    false
}

#[cfg(test)]
mod tests {
    use std::sync::mpsc;
    use std::time::{Instant, SystemTime};

    use super::super::launcher::shell_launcher_command;
    use super::super::pty::READ_CHUNK_BYTES;
    use super::*;

    #[cfg(unix)]
    #[test]
    fn background_close_returns_while_reaping_is_blocked_and_shutdown_joins_it() {
        let stream = Arc::new(TerminalStream::for_test(64 * 1024, 256).unwrap());
        let manager = Arc::new(TerminalManager::new(Arc::clone(&stream)));
        let directory = tempfile::tempdir().unwrap();
        let pid_file = directory.path().join("shell.pid");
        let mut command = CommandBuilder::new("/bin/sh");
        command.args(["-c", "echo $$ > \"$TWINE_TEST_PID\"; read line"]);
        command.env("TWINE_TEST_PID", &pid_file);
        let terminal_id = manager
            .start_test_command(command, test_terminal_size(), None, Arc::new(|_, _, _| {}))
            .unwrap();
        let pid = read_process_id(&pid_file);
        let child = Arc::clone(&manager.lock_sessions().unwrap()[&terminal_id].child);
        // Hold process supervision here to test nonblocking admission without relying on a
        // scheduler-sensitive timeout shorter than the process's normal hang-up grace period.
        let blocked_reaping = child.lock().unwrap();
        let closing = Arc::clone(&manager);
        let (sender, receiver) = mpsc::sync_channel(1);
        let closer = thread::spawn(move || {
            sender
                .send(closing.close_in_background(terminal_id))
                .unwrap();
        });
        let result = receiver.recv_timeout(Duration::from_secs(5));
        // Unblock cleanup even when admission fails, so a failed assertion cannot strand a child.
        drop(blocked_reaping);
        closer.join().unwrap();
        result
            .expect("background close waited for process reaping")
            .unwrap();
        assert!(manager.size(terminal_id).is_none());
        assert!(matches!(
            manager.write_input(terminal_id, b"late input"),
            Err(TerminalError::NotOpen { .. })
        ));
        assert!(stream.tracks_no_terminals());

        manager.shutdown();
        assert!(!process_exists(pid), "retired shell survived shutdown");
        manager.shutdown();
    }

    #[test]
    fn stopped_terminals_reject_input_and_resize_but_keep_final_output() {
        for terminate in [false, true] {
            let stream = Arc::new(TerminalStream::for_test(64 * 1024, 256).unwrap());
            let manager = TerminalManager::new(Arc::clone(&stream));
            let (sender, receiver) = mpsc::sync_channel(1);
            let mut command = CommandBuilder::new("/bin/sh");
            command.args(["-c", "printf final-output; read line"]);
            let terminal_id = manager
                .start_test_command(
                    command,
                    test_terminal_size(),
                    None,
                    Arc::new(move |_, exit, _| sender.send(exit).unwrap()),
                )
                .unwrap();
            let deadline = Instant::now() + Duration::from_secs(5);
            while manager.observe(terminal_id).unwrap().byte_offset < 12 {
                assert!(Instant::now() < deadline, "final output was not recorded");
                thread::sleep(Duration::from_millis(5));
            }
            if terminate {
                manager.terminate(terminal_id).unwrap();
            } else {
                manager.write_input(terminal_id, b"\n").unwrap();
            }
            receiver
                .recv_timeout(Duration::from_secs(5))
                .unwrap()
                .unwrap();
            assert!(matches!(
                manager.write_input(terminal_id, b"late input"),
                Err(TerminalError::NotRunning { terminal_id: id }) if id == terminal_id
            ));
            assert!(matches!(
                manager.resize(terminal_id, test_terminal_size()),
                Err(TerminalError::NotRunning { terminal_id: id }) if id == terminal_id
            ));
            let mut output = Vec::new();
            drain_output(&stream, terminal_id, &mut 0, &mut output);
            assert!(String::from_utf8_lossy(&output).contains("final-output"));
            manager.close(terminal_id).unwrap();
        }
    }

    #[test]
    fn reader_finishing_before_process_exit_rejects_resize_as_not_running() {
        let stream = Arc::new(TerminalStream::for_test(64 * 1024, 256).unwrap());
        let manager = TerminalManager::new(Arc::clone(&stream));
        let mut command = CommandBuilder::new("/bin/sh");
        command.args(["-c", "read line"]);
        let terminal_id = manager
            .start_test_command(command, test_terminal_size(), None, Arc::new(|_, _, _| {}))
            .unwrap();
        // Reproduce reader EOF before the independent supervisor observes the child exit.
        stream.finish(terminal_id).unwrap();
        assert!(stream.tracks_no_terminals());
        assert!(
            !manager.lock_sessions().unwrap()[&terminal_id]
                .input_closed
                .load(Ordering::Acquire)
        );
        assert!(matches!(
            manager.resize(terminal_id, test_terminal_size()),
            Err(TerminalError::NotRunning { terminal_id: id }) if id == terminal_id
        ));
        assert!(manager.observe(terminal_id).is_ok());
        manager.close(terminal_id).unwrap();
        assert!(matches!(
            manager.resize(terminal_id, test_terminal_size()),
            Err(TerminalError::NotOpen { terminal_id: id }) if id == terminal_id
        ));
    }

    #[test]
    fn only_pty_hangups_are_classified_as_stopped_input() {
        assert!(terminal_input_closed(
            &std::io::ErrorKind::BrokenPipe.into()
        ));
        #[cfg(unix)]
        assert!(terminal_input_closed(&std::io::Error::from_raw_os_error(
            libc::EIO
        )));
        for kind in [
            std::io::ErrorKind::PermissionDenied,
            std::io::ErrorKind::Other,
        ] {
            assert!(!terminal_input_closed(&kind.into()));
        }
    }

    #[test]
    fn shell_output_is_ordered_and_has_absolute_byte_offsets() {
        let stream = Arc::new(
            TerminalStream::for_test(64 * 1024, 256).expect("terminal stream should initialize"),
        );
        let manager = TerminalManager::new(Arc::clone(&stream));
        let directory = unique_test_directory();
        std::fs::create_dir(&directory).expect("test working directory should be created");
        let (exit_sender, exit_receiver) = mpsc::sync_channel(1);
        let mut command = shell_launcher_command(&directory, Path::new("/bin/sh"));
        command.env("TERM", "xterm-256color");
        let terminal_id = manager
            .start_test_command(
                command,
                TerminalSize {
                    rows: 24,
                    columns: 80,
                    pixel_width: 800,
                    pixel_height: 480,
                },
                Some(directory.clone()),
                Arc::new(move |terminal_id, result, _| {
                    let _ = exit_sender.send((terminal_id, result));
                }),
            )
            .expect("shell should start");

        manager
            .write_input(
                terminal_id,
                b"pwd\nprintf '__TWINE_ONE__\\n'\nprintf '__TWINE_TWO__\\n'\n",
            )
            .expect("shell input should be written");
        manager
            .resize(
                terminal_id,
                TerminalSize {
                    rows: 37,
                    columns: 101,
                    pixel_width: 1_010,
                    pixel_height: 740,
                },
            )
            .expect("terminal should resize");
        manager
            .write_input(terminal_id, b"stty size\nexit 7\n")
            .expect("resized shell input should be written");

        let deadline = Instant::now() + Duration::from_secs(5);
        let mut output = Vec::new();
        let mut expected_offset = 0_u64;
        let exit = loop {
            drain_output(&stream, terminal_id, &mut expected_offset, &mut output);
            if let Ok(exit) = exit_receiver.try_recv() {
                break exit;
            }
            assert!(
                Instant::now() < deadline,
                "shell did not exit before timeout; output: {}",
                String::from_utf8_lossy(&output)
            );
            thread::sleep(Duration::from_millis(5));
        };
        drain_output(&stream, terminal_id, &mut expected_offset, &mut output);

        let text = String::from_utf8_lossy(&output);
        let first = text
            .find("__TWINE_ONE__")
            .expect("first marker should appear");
        let second = text
            .find("__TWINE_TWO__")
            .expect("second marker should appear");
        assert!(first < second, "shell output markers should stay ordered");
        assert!(
            text.contains(directory.to_string_lossy().as_ref()),
            "shell should run in the requested directory"
        );
        assert!(
            text.contains("37 101"),
            "the child should observe the resized PTY"
        );
        assert_eq!(exit.0, terminal_id);
        assert_eq!(
            exit.1.expect("shell wait should succeed"),
            TerminalExit {
                exit_code: 7,
                signal: None,
            }
        );

        manager.close(terminal_id).expect("terminal should close");
        std::fs::remove_dir(directory).expect("test working directory should be removed");
    }

    #[test]
    fn shell_start_fails_if_working_directory_disappears_before_launch() {
        let stream = Arc::new(
            TerminalStream::for_test(64 * 1024, 256).expect("terminal stream should initialize"),
        );
        let manager = TerminalManager::new(Arc::clone(&stream));
        let directory = unique_test_directory();
        std::fs::create_dir(&directory).expect("test working directory should be created");
        let command = shell_launcher_command(&directory, Path::new("/bin/sh"));
        std::fs::remove_dir(&directory).expect("test working directory should be removed");

        let error = manager
            .start_test_command(
                command,
                TerminalSize {
                    rows: 24,
                    columns: 80,
                    pixel_width: 800,
                    pixel_height: 480,
                },
                Some(directory),
                Arc::new(|_, _, _| panic!("failed terminal must not report an exit event")),
            )
            .expect_err("startup should fail closed when the directory disappears");

        assert!(matches!(error, TerminalError::WorkingDirectory { .. }));
        assert!(stream.tracks_no_terminals());
    }

    #[test]
    fn closing_terminal_terminates_a_running_child() {
        let stream = Arc::new(
            TerminalStream::for_test(64 * 1024, 256).expect("terminal stream should initialize"),
        );
        let manager = TerminalManager::new(stream);
        let (exit_sender, exit_receiver) = mpsc::sync_channel(1);
        let mut command = CommandBuilder::new("/bin/sh");
        command.args(["-c", "trap '' HUP; while :; do sleep 1; done"]);
        let terminal_id = manager
            .start_test_command(
                command,
                TerminalSize {
                    rows: 24,
                    columns: 80,
                    pixel_width: 800,
                    pixel_height: 480,
                },
                None,
                Arc::new(move |terminal_id, result, _| {
                    let _ = exit_sender.send((terminal_id, result));
                }),
            )
            .expect("child should start");

        let started = Instant::now();
        manager
            .close(terminal_id)
            .expect("closing should terminate the child");

        assert!(started.elapsed() < Duration::from_secs(5));
        assert_eq!(
            exit_receiver
                .recv_timeout(Duration::from_secs(1))
                .expect("supervisor should report the terminated child")
                .0,
            terminal_id
        );
    }

    #[test]
    fn closing_terminal_does_not_wait_for_output_written_on_hangup() {
        let stream = Arc::new(
            TerminalStream::for_test(64 * 1024, 256).expect("terminal stream should initialize"),
        );
        let manager = TerminalManager::new(stream);
        // Like an interactive shell restoring terminal modes as it exits.
        let mut command = CommandBuilder::new("/bin/sh");
        command.args([
            "-c",
            "trap 'printf restore; exit' HUP; while :; do sleep 0.01; done",
        ]);
        let terminal_id = manager
            .start_test_command(
                command,
                TerminalSize {
                    rows: 24,
                    columns: 80,
                    pixel_width: 800,
                    pixel_height: 480,
                },
                None,
                Arc::new(|_, _, _| {}),
            )
            .expect("child should start");
        thread::sleep(Duration::from_millis(100));

        let (closed_sender, closed_receiver) = mpsc::sync_channel(1);
        thread::spawn(move || {
            let _ = closed_sender.send(manager.close(terminal_id));
        });
        closed_receiver
            .recv_timeout(Duration::from_secs(5))
            .expect("closing should not wait for the exiting child's output to drain")
            .expect("terminal should close");
    }

    #[test]
    fn shell_exit_terminates_descendants_that_keep_the_pty_open() {
        let stream = Arc::new(
            TerminalStream::for_test(64 * 1024, 256).expect("terminal stream should initialize"),
        );
        let manager = TerminalManager::new(stream);
        let (exit_sender, exit_receiver) = mpsc::sync_channel(1);
        let mut command = CommandBuilder::new("/bin/sh");
        command.args([
            "-c",
            "trap '' HUP; (trap '' HUP; while :; do sleep 1; done) & exit 0",
        ]);
        let terminal_id = manager
            .start_test_command(
                command,
                TerminalSize {
                    rows: 24,
                    columns: 80,
                    pixel_width: 800,
                    pixel_height: 480,
                },
                None,
                Arc::new(move |terminal_id, result, _| {
                    let _ = exit_sender.send((terminal_id, result));
                }),
            )
            .expect("shell with a background child should start");

        assert_eq!(
            exit_receiver
                .recv_timeout(Duration::from_secs(2))
                .expect("supervisor should report the primary shell exit")
                .0,
            terminal_id
        );
        let started = Instant::now();
        manager
            .close(terminal_id)
            .expect("closing should join the drained PTY reader");
        assert!(started.elapsed() < Duration::from_secs(1));
    }

    #[cfg(unix)]
    #[test]
    fn close_cancels_reader_when_detached_descendant_keeps_slave_open() {
        if let Some(directory) = std::env::var_os("TWINE_TEST_DETACHED_PTY_DIRECTORY") {
            run_detached_pty_fixture(Path::new(&directory));
            return;
        }
        let stream = Arc::new(
            TerminalStream::for_test(64 * 1024, 256).expect("terminal stream should initialize"),
        );
        let manager = TerminalManager::new(Arc::clone(&stream));
        let (exit_sender, exit_receiver) = mpsc::sync_channel(1);
        // Removing this directory also releases the descendant on failed assertions.
        let directory = tempfile::tempdir().expect("fixture directory should be created");
        let ready_path = directory.path().join("descendant.pid");
        let mut command = CommandBuilder::new(std::env::current_exe().unwrap());
        // Isolate reader cancellation from the EOF caused by a controlling session's hangup.
        command.set_controlling_tty(false);
        command.args(DETACHED_PTY_FIXTURE_ARGS);
        command.env("TWINE_TEST_DETACHED_PTY_DIRECTORY", directory.path());
        command.env("TWINE_TEST_DETACHED_PTY_ROLE", "parent");
        let terminal_id = manager
            .start_test_command(
                command,
                TerminalSize {
                    rows: 24,
                    columns: 80,
                    pixel_width: 800,
                    pixel_height: 480,
                },
                None,
                Arc::new(move |terminal_id, result, _| {
                    let _ = exit_sender.send((terminal_id, result));
                }),
            )
            .expect("parent with a detached descendant should start");

        let descendant_id = read_process_id(&ready_path);
        let (exited_id, result) = exit_receiver
            .recv_timeout(Duration::from_secs(2))
            .expect("supervisor should report the parent exit");
        assert_eq!(exited_id, terminal_id);
        assert_eq!(result.expect("parent exit should be observed").exit_code, 0);
        assert!(
            process_exists(descendant_id),
            "descendant should hold the PTY open"
        );
        // SAFETY: This probes the fixture PID published above without changing its session.
        assert_eq!(unsafe { libc::getsid(descendant_id) }, descendant_id);
        assert!(
            !manager
                .lock_sessions()
                .unwrap()
                .get(&terminal_id)
                .unwrap()
                .reader_thread
                .as_ref()
                .unwrap()
                .is_finished(),
            "reader should still be waiting on the retained slave"
        );

        let started = Instant::now();
        manager
            .close(terminal_id)
            .expect("closing should cancel the PTY reader");
        assert!(started.elapsed() < Duration::from_secs(1));
        assert!(stream.tracks_no_terminals());
        assert!(process_exists(descendant_id));

        directory
            .close()
            .expect("fixture directory should be removed");
        let deadline = Instant::now() + Duration::from_secs(2);
        while process_exists(descendant_id) {
            assert!(
                Instant::now() < deadline,
                "detached descendant should exit after fixture cleanup"
            );
            thread::sleep(Duration::from_millis(10));
        }
    }

    #[test]
    fn input_remains_responsive_when_output_queue_is_full() {
        let stream = Arc::new(
            TerminalStream::for_test(READ_CHUNK_BYTES, 1)
                .expect("terminal stream should initialize"),
        );
        let manager = TerminalManager::new(Arc::clone(&stream));
        let (exit_sender, exit_receiver) = mpsc::sync_channel(1);
        let terminal_id = manager
            .start_test_command(
                CommandBuilder::new("/usr/bin/yes"),
                TerminalSize {
                    rows: 24,
                    columns: 80,
                    pixel_width: 800,
                    pixel_height: 480,
                },
                None,
                Arc::new(move |terminal_id, result, _| {
                    let _ = exit_sender.send((terminal_id, result));
                }),
            )
            .expect("output-heavy child should start");

        let deadline = Instant::now() + Duration::from_secs(2);
        loop {
            if stream.queued_chunk_count() == 1 {
                break;
            }
            assert!(Instant::now() < deadline, "output queue did not fill");
            thread::sleep(Duration::from_millis(5));
        }

        manager
            .write_input(terminal_id, b"\x03")
            .expect("interrupt input should not wait for output capacity");
        assert_eq!(
            exit_receiver
                .recv_timeout(Duration::from_secs(2))
                .expect("interrupt should terminate the output-heavy child")
                .0,
            terminal_id
        );
        manager.close(terminal_id).expect("terminal should close");
    }

    #[test]
    fn input_and_shutdown_remain_responsive_when_recording_queue_is_full() {
        let directory = tempfile::tempdir().unwrap();
        let transcripts =
            Arc::new(super::super::TranscriptRecorder::open(directory.path()).unwrap());
        let stream =
            Arc::new(TerminalStream::new(8 * 1024 * 1024, 1024, Arc::clone(&transcripts)).unwrap());
        let manager = TerminalManager::new(Arc::clone(&stream));
        let (sent, received) = mpsc::sync_channel(1);
        let id = manager
            .start_test_command(
                CommandBuilder::new("/usr/bin/yes"),
                test_terminal_size(),
                None,
                Arc::new(move |id, exit, _| {
                    let _ = sent.send((id, exit));
                }),
            )
            .unwrap();
        let stalled = transcripts.stall_worker(id);
        let deadline = Instant::now() + Duration::from_secs(3);
        while !transcripts.recording_queue_is_full() {
            assert!(Instant::now() < deadline, "recording queue did not fill");
            thread::sleep(Duration::from_millis(5));
        }
        manager.resize(id, test_terminal_size()).unwrap();
        manager.write_input(id, b"\x03").unwrap();
        assert_eq!(received.recv_timeout(Duration::from_secs(2)).unwrap().0, id);
        let start = Instant::now();
        manager.shutdown();
        assert!(start.elapsed() < Duration::from_secs(1));
        assert!(stream.tracks_no_terminals());
        drop(stalled);
        transcripts.shutdown();
        let reopened = super::super::TranscriptRecorder::open(directory.path()).unwrap();
        assert!(matches!(
            reopened.read(id, 0, 1).unwrap(),
            super::super::TranscriptRead::Output(_)
        ));
    }

    #[cfg(unix)]
    #[test]
    fn shutdown_reaps_multiple_shells_and_descendants_with_a_full_output_queue() {
        let stream = Arc::new(
            TerminalStream::for_test(READ_CHUNK_BYTES, 1)
                .expect("terminal stream should initialize"),
        );
        let manager = TerminalManager::new(Arc::clone(&stream));
        let directory = unique_test_directory();
        std::fs::create_dir(&directory).expect("test directory should be created");

        let mut quiet_shell = CommandBuilder::new("/bin/sh");
        quiet_shell.args([
            "-c",
            "trap '' HUP; echo $$ > \"$TWINE_TEST_DIR/shell.pid\"; \
             (trap '' HUP; while :; do sleep 1; done) & \
             echo $! > \"$TWINE_TEST_DIR/descendant.pid\"; \
             while :; do sleep 1; done",
        ]);
        quiet_shell.env("TWINE_TEST_DIR", &directory);
        let quiet_id = manager
            .start_test_command(
                quiet_shell,
                test_terminal_size(),
                None,
                Arc::new(|_, _, _| {}),
            )
            .expect("shell with descendant should start");

        let mut noisy_shell = CommandBuilder::new("/bin/sh");
        noisy_shell.args([
            "-c",
            "echo $$ > \"$TWINE_TEST_DIR/noisy.pid\"; exec /usr/bin/yes",
        ]);
        noisy_shell.env("TWINE_TEST_DIR", &directory);
        let noisy_id = manager
            .start_test_command(
                noisy_shell,
                test_terminal_size(),
                None,
                Arc::new(|_, _, _| {}),
            )
            .expect("output-heavy shell should start");

        let process_ids = ["shell.pid", "descendant.pid", "noisy.pid"]
            .map(|name| read_process_id(&directory.join(name)));
        let deadline = Instant::now() + Duration::from_secs(2);
        while stream.queued_chunk_count() == 0 {
            assert!(Instant::now() < deadline, "output queue did not fill");
            thread::sleep(Duration::from_millis(5));
        }

        let started = Instant::now();
        manager.shutdown();
        assert!(started.elapsed() < Duration::from_secs(5));
        assert!(
            manager
                .lock_sessions()
                .expect("sessions should lock")
                .is_empty()
        );
        assert!(stream.tracks_no_terminals());
        for process_id in process_ids {
            let deadline = Instant::now() + Duration::from_secs(2);
            while process_exists(process_id) {
                assert!(
                    Instant::now() < deadline,
                    "process {process_id} survived shutdown"
                );
                thread::sleep(Duration::from_millis(10));
            }
        }
        manager.shutdown();
        assert_ne!(quiet_id, noisy_id);
        std::fs::remove_dir_all(directory).expect("test directory should be removed");
    }

    #[cfg(unix)]
    #[test]
    fn close_all_stops_terminals_together_and_reports_one_that_was_not_open() {
        let stream = Arc::new(
            TerminalStream::for_test(64 * 1024, 256).expect("terminal stream should initialize"),
        );
        let manager = TerminalManager::new(Arc::clone(&stream));
        let directory = unique_test_directory();
        std::fs::create_dir(&directory).expect("test directory should be created");
        // Each shell ignores the hangup, so closing it waits out the whole grace period.
        let start = |name: &str| {
            let mut shell = CommandBuilder::new("/bin/sh");
            shell.args([
                "-c",
                &format!(
                    "trap '' HUP; echo $$ > \"$TWINE_TEST_DIR/{name}.pid\"; \
                     while :; do sleep 1; done"
                ),
            ]);
            shell.env("TWINE_TEST_DIR", &directory);
            let terminal_id = manager
                .start_test_command(shell, test_terminal_size(), None, Arc::new(|_, _, _| {}))
                .expect("shell should start");
            (
                terminal_id,
                read_process_id(&directory.join(format!("{name}.pid"))),
            )
        };

        let (single, _) = start("single");
        let started = Instant::now();
        manager
            .close_all(&[single])
            .expect("the shell should close");
        let one = started.elapsed();

        let shells = ["first", "second", "third"].map(start);
        let missing = TerminalId::from_value(u64::MAX);
        let started = Instant::now();
        let result = manager.close_all(&[shells[0].0, missing, shells[1].0, shells[2].0]);
        let three = started.elapsed();
        assert!(
            matches!(result, Err(TerminalError::NotOpen { terminal_id }) if terminal_id == missing)
        );
        assert!(
            manager
                .lock_sessions()
                .expect("sessions should lock")
                .is_empty()
        );
        for (_, process_id) in shells {
            assert!(
                !process_exists(process_id),
                "process {process_id} survived close_all"
            );
        }
        // Closed together, three shells take about as long as one, not three times as long.
        assert!(
            three < one * 2,
            "closing three shells took {three:?}; closing one took {one:?}"
        );
        std::fs::remove_dir_all(directory).expect("test directory should be removed");
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn shutdown_kills_background_job_in_another_process_group() {
        let stream = Arc::new(
            TerminalStream::for_test(READ_CHUNK_BYTES, 16)
                .expect("terminal stream should initialize"),
        );
        let manager = TerminalManager::new(Arc::clone(&stream));
        let directory = unique_test_directory();
        std::fs::create_dir(&directory).expect("test directory should be created");

        let mut shell = CommandBuilder::new("/bin/sh");
        shell.args([
            "-c",
            "trap '' HUP; set -m; echo $$ > \"$TWINE_TEST_DIR/shell.pid\"; \
             (trap '' HUP; while :; do sleep 1; done) & \
             echo $! > \"$TWINE_TEST_DIR/descendant.pid\"; \
             while :; do sleep 1; done",
        ]);
        shell.env("TWINE_TEST_DIR", &directory);
        manager
            .start_test_command(shell, test_terminal_size(), None, Arc::new(|_, _, _| {}))
            .expect("shell should start");

        let shell_id = read_process_id(&directory.join("shell.pid"));
        let descendant_id = read_process_id(&directory.join("descendant.pid"));
        let shell_group = unsafe { libc::getpgid(shell_id) };
        let descendant_group = unsafe { libc::getpgid(descendant_id) };
        manager.shutdown();

        assert!(shell_group > 0);
        assert!(descendant_group > 0);
        assert_ne!(shell_group, descendant_group);
        assert!(stream.tracks_no_terminals());
        for process_id in [shell_id, descendant_id] {
            let deadline = Instant::now() + Duration::from_secs(2);
            while process_exists(process_id) {
                assert!(
                    Instant::now() < deadline,
                    "process {process_id} survived shutdown"
                );
                thread::sleep(Duration::from_millis(10));
            }
        }
        std::fs::remove_dir_all(directory).expect("test directory should be removed");
    }

    #[cfg(unix)]
    #[test]
    fn shutdown_recovers_poisoned_session_and_child_locks() {
        let stream = Arc::new(
            TerminalStream::for_test(64 * 1024, 256).expect("terminal stream should initialize"),
        );
        let manager = TerminalManager::new(Arc::clone(&stream));
        let directory = unique_test_directory();
        std::fs::create_dir(&directory).expect("test directory should be created");
        let mut command = CommandBuilder::new("/bin/sh");
        command.args([
            "-c",
            "echo $$ > \"$TWINE_TEST_DIR/shell.pid\"; trap '' HUP; while :; do sleep 1; done",
        ]);
        command.env("TWINE_TEST_DIR", &directory);
        let terminal_id = manager
            .start_test_command(command, test_terminal_size(), None, Arc::new(|_, _, _| {}))
            .expect("shell should start");
        let process_id = read_process_id(&directory.join("shell.pid"));
        let child = Arc::clone(
            &manager
                .lock_sessions()
                .expect("sessions should lock")
                .get(&terminal_id)
                .expect("terminal should be registered")
                .child,
        );

        thread::scope(|scope| {
            assert!(
                scope
                    .spawn(|| {
                        let _guard = child.lock().expect("child should lock");
                        panic!("poison the child lock");
                    })
                    .join()
                    .is_err()
            );
            assert!(
                scope
                    .spawn(|| {
                        let _guard = manager.sessions.lock().expect("sessions should lock");
                        panic!("poison the session lock");
                    })
                    .join()
                    .is_err()
            );
        });

        manager.shutdown();
        assert!(stream.tracks_no_terminals());
        let deadline = Instant::now() + Duration::from_secs(2);
        while process_exists(process_id) {
            assert!(
                Instant::now() < deadline,
                "process survived poisoned-lock shutdown"
            );
            thread::sleep(Duration::from_millis(10));
        }
        std::fs::remove_dir_all(directory).expect("test directory should be removed");
    }

    fn test_terminal_size() -> TerminalSize {
        TerminalSize {
            rows: 24,
            columns: 80,
            pixel_width: 800,
            pixel_height: 480,
        }
    }

    #[cfg(unix)]
    const DETACHED_PTY_FIXTURE_ARGS: [&str; 4] = [
        "--exact",
        "terminal::manager::tests::close_cancels_reader_when_detached_descendant_keeps_slave_open",
        "--nocapture",
        "--test-threads=1",
    ];

    #[cfg(unix)]
    fn run_detached_pty_fixture(directory: &Path) {
        let ready_path = directory.join("descendant.pid");
        match std::env::var("TWINE_TEST_DETACHED_PTY_ROLE")
            .unwrap()
            .as_str()
        {
            "parent" => {
                #[expect(
                    clippy::zombie_processes,
                    reason = "the fixture parent exits first, reparenting its detached descendant"
                )]
                let child = std::process::Command::new(std::env::current_exe().unwrap())
                    .args(DETACHED_PTY_FIXTURE_ARGS)
                    .env("TWINE_TEST_DETACHED_PTY_ROLE", "descendant")
                    .spawn()
                    .expect("Rust descendant should start");
                assert_eq!(
                    read_process_id(&ready_path),
                    libc::pid_t::try_from(child.id()).unwrap()
                );
                // Child::drop leaves this detached process alive with the inherited PTY descriptors.
            }
            "descendant" => {
                // SAFETY: This isolated helper process changes only its own signal disposition and
                // Unix session. Its parent waits for readiness before exiting and hanging up.
                unsafe {
                    assert_ne!(libc::signal(libc::SIGHUP, libc::SIG_IGN), libc::SIG_ERR);
                    assert_ne!(libc::setsid(), -1);
                }
                std::fs::write(&ready_path, std::process::id().to_string())
                    .expect("descendant should publish readiness");
                // Keep the slave open without reading it: a read can return on session hangup.
                while directory.is_dir() {
                    thread::sleep(Duration::from_millis(10));
                }
            }
            role => panic!("unknown detached PTY fixture role: {role}"),
        }
    }

    #[cfg(unix)]
    fn read_process_id(path: &Path) -> libc::pid_t {
        let deadline = Instant::now() + Duration::from_secs(2);
        loop {
            if let Ok(contents) = std::fs::read_to_string(path)
                && let Ok(process_id) = contents.trim().parse()
            {
                return process_id;
            }
            assert!(
                Instant::now() < deadline,
                "process ID was not written to {}",
                path.display()
            );
            thread::sleep(Duration::from_millis(10));
        }
    }

    fn drain_output(
        stream: &TerminalStream,
        terminal_id: TerminalId,
        expected_offset: &mut u64,
        output: &mut Vec<u8>,
    ) {
        while let Some(chunk) = stream
            .next_chunk()
            .expect("terminal output should be readable")
        {
            assert_eq!(chunk.terminal_id, terminal_id);
            assert_eq!(chunk.offset, *expected_offset);
            *expected_offset +=
                u64::try_from(chunk.bytes.len()).expect("test output length should fit");
            output.extend(chunk.bytes);
        }
    }

    fn unique_test_directory() -> PathBuf {
        let nanos = SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .expect("system time should be after the Unix epoch")
            .as_nanos();
        std::env::temp_dir().join(format!(
            "twine-terminal-test-{}-{nanos}",
            std::process::id()
        ))
    }

    #[cfg(unix)]
    fn process_exists(process_id: libc::pid_t) -> bool {
        // SAFETY: Signal zero does not mutate the target and is the standard liveness probe.
        let result = unsafe { libc::kill(process_id, 0) };
        result == 0 || std::io::Error::last_os_error().raw_os_error() != Some(libc::ESRCH)
    }
}
