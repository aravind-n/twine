use std::collections::HashMap;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU8, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use portable_pty::{CommandBuilder, MasterPty};
use tracing::{debug, warn};

use super::launcher::{canonical_working_directory, default_shell_command};
use super::process::{SharedChild, terminate_child, terminate_unobserved_child, wait_for_child};
use super::pty::{StartingTerminal, spawn_terminal_process, spawn_terminal_reader};
use super::{TerminalError, TerminalExit, TerminalId, TerminalSize, TerminalStream};

const EXIT_REPORT_PENDING: u8 = 0;
const EXIT_REPORT_ENABLED: u8 = 1;
const EXIT_REPORT_SUPPRESSED: u8 = 2;

type ExitCallback = Arc<dyn Fn(TerminalId, Result<TerminalExit, String>) + Send + Sync + 'static>;

struct TerminalSession {
    master: Box<dyn MasterPty + Send>,
    writer: Arc<Mutex<Box<dyn Write + Send>>>,
    child: SharedChild,
    reader_cancelled: Arc<AtomicBool>,
    reader_thread: Option<JoinHandle<()>>,
    supervisor_thread: Option<JoinHandle<()>>,
}

pub(crate) struct TerminalManager {
    output: Arc<TerminalStream>,
    sessions: Mutex<HashMap<TerminalId, TerminalSession>>,
}

impl TerminalManager {
    pub(crate) fn new(output: Arc<TerminalStream>) -> Self {
        Self {
            output,
            sessions: Mutex::new(HashMap::new()),
        }
    }

    pub(crate) fn start_default_shell(
        &self,
        working_directory: &Path,
        size: TerminalSize,
        on_exit: ExitCallback,
    ) -> Result<TerminalId, TerminalError> {
        let working_directory = canonical_working_directory(working_directory)?;
        let command = default_shell_command(&working_directory);
        self.start_command(command, size, Some(working_directory), on_exit)
    }

    fn start_command(
        &self,
        command: CommandBuilder,
        size: TerminalSize,
        working_directory_handshake: Option<PathBuf>,
        on_exit: ExitCallback,
    ) -> Result<TerminalId, TerminalError> {
        let starting = spawn_terminal_process(command, size, working_directory_handshake)?;
        let StartingTerminal {
            master,
            reader,
            writer,
            child,
            reader_descriptor,
        } = starting;
        let terminal_id = match self.output.open() {
            Ok(terminal_id) => terminal_id,
            Err(error) => {
                terminate_unobserved_child(&child);
                return Err(error);
            }
        };

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
        let supervisor_thread =
            match spawn_terminal_supervisor(terminal_id, &child, &exit_reporting, on_exit) {
                Ok(thread) => thread,
                Err(error) => {
                    exit_reporting.store(EXIT_REPORT_SUPPRESSED, Ordering::Release);
                    let _ = self.output.cancel(terminal_id);
                    stop_session(
                        terminal_id,
                        TerminalSession {
                            master,
                            writer,
                            child,
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
            writer,
            child,
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
        let writer = Arc::clone(
            &self
                .lock_sessions()?
                .get(&terminal_id)
                .ok_or(TerminalError::NotOpen { terminal_id })?
                .writer,
        );
        let mut writer = writer.lock().map_err(|_| TerminalError::Poisoned)?;
        writer
            .write_all(bytes)
            .map_err(|error| TerminalError::Pty {
                operation: "write terminal input",
                message: error.to_string(),
            })?;
        writer.flush().map_err(|error| TerminalError::Pty {
            operation: "flush terminal input",
            message: error.to_string(),
        })
    }

    pub(crate) fn resize(
        &self,
        terminal_id: TerminalId,
        size: TerminalSize,
    ) -> Result<(), TerminalError> {
        let size = size.validate()?;
        self.lock_sessions()?
            .get(&terminal_id)
            .ok_or(TerminalError::NotOpen { terminal_id })?
            .master
            .resize(size.into())
            .map_err(|error| TerminalError::Pty {
                operation: "resize PTY",
                message: error.to_string(),
            })
    }

    pub(crate) fn close(&self, terminal_id: TerminalId) -> Result<(), TerminalError> {
        let session = self
            .lock_sessions()?
            .remove(&terminal_id)
            .ok_or(TerminalError::NotOpen { terminal_id })?;
        let _ = self.output.cancel(terminal_id);
        stop_session(terminal_id, session);
        debug!(terminal_id = terminal_id.value(), "terminal process closed");
        Ok(())
    }

    pub(crate) fn shutdown(&self) {
        let Ok(mut sessions) = self.sessions.lock() else {
            warn!("terminal session lock poisoned during shutdown");
            return;
        };
        for (terminal_id, session) in sessions.drain() {
            let _ = self.output.cancel(terminal_id);
            stop_session(terminal_id, session);
        }
    }

    fn lock_sessions(
        &self,
    ) -> Result<MutexGuard<'_, HashMap<TerminalId, TerminalSession>>, TerminalError> {
        self.sessions.lock().map_err(|_| TerminalError::Poisoned)
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
    on_exit: ExitCallback,
) -> Result<JoinHandle<()>, TerminalError> {
    let child = Arc::clone(child);
    let exit_reporting = Arc::clone(exit_reporting);
    thread::Builder::new()
        .name(format!("terminal-{}-supervisor", terminal_id.value()))
        .spawn(move || {
            let result = wait_for_child(&child);
            while exit_reporting.load(Ordering::Acquire) == EXIT_REPORT_PENDING {
                thread::sleep(Duration::from_millis(1));
            }
            if exit_reporting.load(Ordering::Acquire) == EXIT_REPORT_ENABLED {
                on_exit(terminal_id, result);
            }
        })
        .map_err(|error| TerminalError::Thread {
            operation: "start process supervisor",
            message: error.to_string(),
        })
}

fn stop_session(terminal_id: TerminalId, session: TerminalSession) {
    let TerminalSession {
        master,
        writer,
        child,
        reader_cancelled,
        reader_thread,
        supervisor_thread,
    } = session;
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

#[cfg(test)]
mod tests {
    use std::sync::mpsc;
    use std::time::{Instant, SystemTime};

    use super::super::launcher::shell_launcher_command;
    use super::super::pty::READ_CHUNK_BYTES;
    use super::*;

    #[test]
    fn shell_output_is_ordered_and_has_absolute_byte_offsets() {
        let stream = Arc::new(
            TerminalStream::new(64 * 1024, 256).expect("terminal stream should initialize"),
        );
        let manager = TerminalManager::new(Arc::clone(&stream));
        let directory = unique_test_directory();
        std::fs::create_dir(&directory).expect("test working directory should be created");
        let (exit_sender, exit_receiver) = mpsc::sync_channel(1);
        let mut command = shell_launcher_command(&directory, Path::new("/bin/sh"));
        command.env("TERM", "xterm-256color");
        let terminal_id = manager
            .start_command(
                command,
                TerminalSize {
                    rows: 24,
                    columns: 80,
                    pixel_width: 800,
                    pixel_height: 480,
                },
                Some(directory.clone()),
                Arc::new(move |terminal_id, result| {
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
            TerminalStream::new(64 * 1024, 256).expect("terminal stream should initialize"),
        );
        let manager = TerminalManager::new(Arc::clone(&stream));
        let directory = unique_test_directory();
        std::fs::create_dir(&directory).expect("test working directory should be created");
        let command = shell_launcher_command(&directory, Path::new("/bin/sh"));
        std::fs::remove_dir(&directory).expect("test working directory should be removed");

        let error = manager
            .start_command(
                command,
                TerminalSize {
                    rows: 24,
                    columns: 80,
                    pixel_width: 800,
                    pixel_height: 480,
                },
                Some(directory),
                Arc::new(|_, _| panic!("failed terminal must not report an exit event")),
            )
            .expect_err("startup should fail closed when the directory disappears");

        assert!(matches!(error, TerminalError::WorkingDirectory { .. }));
        assert!(stream.tracks_no_terminals());
    }

    #[test]
    fn closing_terminal_terminates_a_running_child() {
        let stream = Arc::new(
            TerminalStream::new(64 * 1024, 256).expect("terminal stream should initialize"),
        );
        let manager = TerminalManager::new(stream);
        let (exit_sender, exit_receiver) = mpsc::sync_channel(1);
        let mut command = CommandBuilder::new("/bin/sh");
        command.args(["-c", "trap '' HUP; while :; do sleep 1; done"]);
        let terminal_id = manager
            .start_command(
                command,
                TerminalSize {
                    rows: 24,
                    columns: 80,
                    pixel_width: 800,
                    pixel_height: 480,
                },
                None,
                Arc::new(move |terminal_id, result| {
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
            TerminalStream::new(64 * 1024, 256).expect("terminal stream should initialize"),
        );
        let manager = TerminalManager::new(stream);
        // Like an interactive shell restoring terminal modes as it exits.
        let mut command = CommandBuilder::new("/bin/sh");
        command.args([
            "-c",
            "trap 'printf restore; exit' HUP; while :; do sleep 0.01; done",
        ]);
        let terminal_id = manager
            .start_command(
                command,
                TerminalSize {
                    rows: 24,
                    columns: 80,
                    pixel_width: 800,
                    pixel_height: 480,
                },
                None,
                Arc::new(|_, _| {}),
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
            TerminalStream::new(64 * 1024, 256).expect("terminal stream should initialize"),
        );
        let manager = TerminalManager::new(stream);
        let (exit_sender, exit_receiver) = mpsc::sync_channel(1);
        let mut command = CommandBuilder::new("/bin/sh");
        command.args([
            "-c",
            "trap '' HUP; (trap '' HUP; while :; do sleep 1; done) & exit 0",
        ]);
        let terminal_id = manager
            .start_command(
                command,
                TerminalSize {
                    rows: 24,
                    columns: 80,
                    pixel_width: 800,
                    pixel_height: 480,
                },
                None,
                Arc::new(move |terminal_id, result| {
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
        let stream = Arc::new(
            TerminalStream::new(64 * 1024, 256).expect("terminal stream should initialize"),
        );
        let manager = TerminalManager::new(stream);
        let (exit_sender, exit_receiver) = mpsc::sync_channel(1);
        let ready_path = unique_test_directory().with_extension("pid");
        let mut command = CommandBuilder::new("/bin/sh");
        command.args([
            "-c",
            "/usr/bin/python3 -c 'import os, signal; os.setsid(); signal.signal(signal.SIGHUP, signal.SIG_IGN); open(os.environ[\"TWINE_TEST_READY\"], \"w\").write(str(os.getpid())); os.read(0, 1)' & while [ ! -s \"$TWINE_TEST_READY\" ]; do :; done; exit 0",
        ]);
        command.env("TWINE_TEST_READY", &ready_path);
        let terminal_id = manager
            .start_command(
                command,
                TerminalSize {
                    rows: 24,
                    columns: 80,
                    pixel_width: 800,
                    pixel_height: 480,
                },
                None,
                Arc::new(move |terminal_id, result| {
                    let _ = exit_sender.send((terminal_id, result));
                }),
            )
            .expect("shell with a detached descendant should start");

        assert_eq!(
            exit_receiver
                .recv_timeout(Duration::from_secs(2))
                .expect("supervisor should report the primary shell exit")
                .0,
            terminal_id
        );
        let descendant_id = std::fs::read_to_string(&ready_path)
            .expect("detached descendant should publish its process ID")
            .parse::<libc::pid_t>()
            .expect("detached descendant process ID should be valid");

        let started = Instant::now();
        manager
            .close(terminal_id)
            .expect("closing should cancel the PTY reader");
        assert!(started.elapsed() < Duration::from_secs(1));

        let deadline = Instant::now() + Duration::from_secs(2);
        while process_exists(descendant_id) {
            assert!(
                Instant::now() < deadline,
                "detached descendant should exit after the PTY master closes"
            );
            thread::sleep(Duration::from_millis(10));
        }
        std::fs::remove_file(ready_path).expect("test process ID file should be removed");
    }

    #[test]
    fn input_remains_responsive_when_output_queue_is_full() {
        let stream = Arc::new(
            TerminalStream::new(READ_CHUNK_BYTES, 1).expect("terminal stream should initialize"),
        );
        let manager = TerminalManager::new(Arc::clone(&stream));
        let (exit_sender, exit_receiver) = mpsc::sync_channel(1);
        let terminal_id = manager
            .start_command(
                CommandBuilder::new("/usr/bin/yes"),
                TerminalSize {
                    rows: 24,
                    columns: 80,
                    pixel_width: 800,
                    pixel_height: 480,
                },
                None,
                Arc::new(move |terminal_id, result| {
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
