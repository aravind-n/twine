use std::collections::{HashMap, VecDeque};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU8, Ordering};
use std::sync::{Arc, Condvar, Mutex, MutexGuard};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use portable_pty::{Child, CommandBuilder, MasterPty, PtySize, native_pty_system};
use thiserror::Error;
use tracing::{debug, warn};

const READ_CHUNK_BYTES: usize = 16 * 1024;
const EXIT_REPORT_PENDING: u8 = 0;
const EXIT_REPORT_ENABLED: u8 = 1;
const EXIT_REPORT_SUPPRESSED: u8 = 2;
const READER_POLL_MILLISECONDS: libc::c_int = 50;
const SUPERVISOR_POLL_INTERVAL: Duration = Duration::from_millis(10);

#[cfg(unix)]
type TerminalReaderDescriptor = libc::c_int;

#[cfg(not(unix))]
type TerminalReaderDescriptor = ();

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub struct TerminalId(u64);

impl TerminalId {
    #[must_use]
    pub const fn from_value(value: u64) -> Self {
        Self(value)
    }

    #[must_use]
    pub const fn value(self) -> u64 {
        self.0
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct TerminalSize {
    pub rows: u16,
    pub columns: u16,
    pub pixel_width: u16,
    pub pixel_height: u16,
}

impl TerminalSize {
    /// # Errors
    ///
    /// Returns an error when either character dimension is zero.
    pub fn validate(self) -> Result<Self, TerminalError> {
        if self.rows == 0 || self.columns == 0 {
            return Err(TerminalError::InvalidSize {
                rows: self.rows,
                columns: self.columns,
            });
        }
        Ok(self)
    }
}

impl From<TerminalSize> for PtySize {
    fn from(size: TerminalSize) -> Self {
        Self {
            rows: size.rows,
            cols: size.columns,
            pixel_width: size.pixel_width,
            pixel_height: size.pixel_height,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TerminalExit {
    pub exit_code: u32,
    pub signal: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum TerminalStatus {
    Running,
    Exited(TerminalExit),
    Failed { message: String },
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TerminalState {
    pub terminal_id: TerminalId,
    pub status: TerminalStatus,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TerminalChunk {
    pub terminal_id: TerminalId,
    pub offset: u64,
    pub bytes: Vec<u8>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum StreamState {
    Open,
    Finished,
}

#[derive(Debug)]
struct StreamEntry {
    next_offset: u64,
    state: StreamState,
}

#[derive(Debug)]
struct StreamInner {
    buffered_bytes: usize,
    chunks: VecDeque<TerminalChunk>,
    entries: HashMap<TerminalId, StreamEntry>,
    next_terminal_id: u64,
}

#[derive(Debug)]
pub(crate) struct TerminalStream {
    capacity_bytes: usize,
    capacity_chunks: usize,
    inner: Mutex<StreamInner>,
    space_available: Condvar,
}

impl TerminalStream {
    pub(crate) fn new(
        capacity_bytes: usize,
        capacity_chunks: usize,
    ) -> Result<Self, TerminalError> {
        if capacity_bytes == 0 || capacity_chunks == 0 {
            return Err(TerminalError::ZeroCapacity);
        }

        Ok(Self {
            capacity_bytes,
            capacity_chunks,
            inner: Mutex::new(StreamInner {
                buffered_bytes: 0,
                chunks: VecDeque::new(),
                entries: HashMap::new(),
                next_terminal_id: 1,
            }),
            space_available: Condvar::new(),
        })
    }

    pub(crate) fn open(&self) -> Result<TerminalId, TerminalError> {
        let mut inner = self.lock_inner()?;
        let terminal_id = TerminalId(inner.next_terminal_id);
        inner.next_terminal_id = inner
            .next_terminal_id
            .checked_add(1)
            .ok_or(TerminalError::TerminalIdOverflow)?;
        inner.entries.insert(
            terminal_id,
            StreamEntry {
                next_offset: 0,
                state: StreamState::Open,
            },
        );
        Ok(terminal_id)
    }

    pub(crate) fn publish(
        &self,
        terminal_id: TerminalId,
        bytes: Vec<u8>,
    ) -> Result<u64, TerminalError> {
        self.publish_inner(terminal_id, bytes, false)
    }

    fn publish_blocking(
        &self,
        terminal_id: TerminalId,
        bytes: Vec<u8>,
    ) -> Result<u64, TerminalError> {
        self.publish_inner(terminal_id, bytes, true)
    }

    fn publish_inner(
        &self,
        terminal_id: TerminalId,
        bytes: Vec<u8>,
        wait_for_space: bool,
    ) -> Result<u64, TerminalError> {
        let chunk_bytes = bytes.len();
        if chunk_bytes == 0 {
            return Err(TerminalError::EmptyChunk);
        }
        if chunk_bytes > self.capacity_bytes {
            return Err(TerminalError::ChunkTooLarge {
                chunk_bytes,
                capacity_bytes: self.capacity_bytes,
            });
        }

        let mut inner = self.lock_inner()?;
        loop {
            let entry = inner
                .entries
                .get(&terminal_id)
                .ok_or(TerminalError::NotOpen { terminal_id })?;
            if entry.state != StreamState::Open {
                return Err(TerminalError::NotOpen { terminal_id });
            }

            let chunk_space = inner.chunks.len() < self.capacity_chunks;
            let byte_space = chunk_bytes <= self.capacity_bytes - inner.buffered_bytes;
            if chunk_space && byte_space {
                break;
            }
            if !wait_for_space {
                if !chunk_space {
                    return Err(TerminalError::QueueFull {
                        capacity_chunks: self.capacity_chunks,
                    });
                }
                return Err(TerminalError::BufferFull {
                    requested_bytes: chunk_bytes,
                    available_bytes: self.capacity_bytes - inner.buffered_bytes,
                });
            }

            inner = self
                .space_available
                .wait(inner)
                .map_err(|_| TerminalError::Poisoned)?;
        }

        let entry = inner
            .entries
            .get_mut(&terminal_id)
            .ok_or(TerminalError::NotOpen { terminal_id })?;
        let offset = entry.next_offset;
        entry.next_offset = offset
            .checked_add(u64::try_from(chunk_bytes).map_err(|_| TerminalError::OffsetOverflow)?)
            .ok_or(TerminalError::OffsetOverflow)?;
        inner.buffered_bytes += chunk_bytes;
        inner.chunks.push_back(TerminalChunk {
            terminal_id,
            offset,
            bytes,
        });
        Ok(offset)
    }

    pub(crate) fn next_chunk(&self) -> Result<Option<TerminalChunk>, TerminalError> {
        let mut inner = self.lock_inner()?;
        let chunk = inner.chunks.pop_front();
        if let Some(chunk) = &chunk {
            inner.buffered_bytes -= chunk.bytes.len();
            Self::remove_drained_entry(&mut inner, chunk.terminal_id);
            self.space_available.notify_all();
        }
        Ok(chunk)
    }

    fn finish(&self, terminal_id: TerminalId) -> Result<(), TerminalError> {
        let mut inner = self.lock_inner()?;
        let entry = inner
            .entries
            .get_mut(&terminal_id)
            .ok_or(TerminalError::NotOpen { terminal_id })?;
        if entry.state == StreamState::Open {
            entry.state = StreamState::Finished;
        }
        Self::remove_drained_entry(&mut inner, terminal_id);
        self.space_available.notify_all();
        Ok(())
    }

    fn cancel(&self, terminal_id: TerminalId) -> Result<(), TerminalError> {
        let mut inner = self.lock_inner()?;
        if !inner.entries.contains_key(&terminal_id) {
            return Err(TerminalError::NotOpen { terminal_id });
        }
        let mut removed_bytes = 0;
        inner.chunks.retain(|chunk| {
            if chunk.terminal_id == terminal_id {
                removed_bytes += chunk.bytes.len();
                false
            } else {
                true
            }
        });
        inner.buffered_bytes -= removed_bytes;
        inner.entries.remove(&terminal_id);
        self.space_available.notify_all();
        Ok(())
    }

    pub(crate) fn close(&self, terminal_id: TerminalId) -> Result<(), TerminalError> {
        let mut inner = self.lock_inner()?;
        if !inner.entries.contains_key(&terminal_id) {
            return Err(TerminalError::NotOpen { terminal_id });
        }
        if inner
            .chunks
            .iter()
            .any(|chunk| chunk.terminal_id == terminal_id)
        {
            return Err(TerminalError::PendingOutput { terminal_id });
        }
        inner.entries.remove(&terminal_id);
        self.space_available.notify_all();
        Ok(())
    }

    fn remove_drained_entry(inner: &mut StreamInner, terminal_id: TerminalId) {
        let has_chunks = inner
            .chunks
            .iter()
            .any(|chunk| chunk.terminal_id == terminal_id);
        let is_closed = inner
            .entries
            .get(&terminal_id)
            .is_some_and(|entry| entry.state != StreamState::Open);
        if is_closed && !has_chunks {
            inner.entries.remove(&terminal_id);
        }
    }

    fn lock_inner(&self) -> Result<MutexGuard<'_, StreamInner>, TerminalError> {
        self.inner.lock().map_err(|_| TerminalError::Poisoned)
    }
}

type ExitCallback = Arc<dyn Fn(TerminalId, Result<TerminalExit, String>) + Send + Sync + 'static>;
type ExitResult = Result<TerminalExit, String>;
type SharedChild = Arc<Mutex<ChildProcess>>;

struct ChildProcess {
    child: Box<dyn Child + Send + Sync>,
    process_id: Option<u32>,
    exit: Option<ExitResult>,
}

struct TerminalSession {
    master: Box<dyn MasterPty + Send>,
    writer: Arc<Mutex<Box<dyn Write + Send>>>,
    child: SharedChild,
    reader_cancelled: Arc<AtomicBool>,
    reader_thread: Option<JoinHandle<()>>,
    supervisor_thread: Option<JoinHandle<()>>,
}

struct StartingTerminal {
    master: Box<dyn MasterPty + Send>,
    reader: Box<dyn Read + Send>,
    writer: Arc<Mutex<Box<dyn Write + Send>>>,
    child: SharedChild,
    reader_descriptor: TerminalReaderDescriptor,
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
        let shell = CommandBuilder::new_default_prog().get_shell();
        let mut command = shell_launcher_command(&working_directory, Path::new(&shell));
        command.env("TERM", "xterm-256color");
        command.env("COLORTERM", "truecolor");
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

fn spawn_terminal_process(
    command: CommandBuilder,
    size: TerminalSize,
    working_directory_handshake: Option<PathBuf>,
) -> Result<StartingTerminal, TerminalError> {
    let pair = native_pty_system()
        .openpty(size.validate()?.into())
        .map_err(|error| TerminalError::Pty {
            operation: "open PTY",
            message: error.to_string(),
        })?;
    let reader_descriptor = terminal_reader_descriptor(pair.master.as_ref())?;
    let child = pair
        .slave
        .spawn_command(command)
        .map_err(|error| TerminalError::Pty {
            operation: "spawn shell",
            message: error.to_string(),
        })?;
    drop(pair.slave);
    let process_id = child.process_id();
    let child = Arc::new(Mutex::new(ChildProcess {
        child,
        process_id,
        exit: None,
    }));
    let mut reader = pair.master.try_clone_reader().map_err(|error| {
        terminate_unobserved_child(&child);
        TerminalError::Pty {
            operation: "clone PTY reader",
            message: error.to_string(),
        }
    })?;
    if let Some(working_directory) = working_directory_handshake
        && let Err(error) = verify_working_directory(&mut reader, &working_directory)
    {
        terminate_unobserved_child(&child);
        return Err(error);
    }
    let writer = pair.master.take_writer().map_err(|error| {
        terminate_unobserved_child(&child);
        TerminalError::Pty {
            operation: "take PTY writer",
            message: error.to_string(),
        }
    })?;
    Ok(StartingTerminal {
        master: pair.master,
        reader,
        writer: Arc::new(Mutex::new(writer)),
        child,
        reader_descriptor,
    })
}

#[cfg(unix)]
fn terminal_reader_descriptor(
    master: &(dyn MasterPty + Send),
) -> Result<TerminalReaderDescriptor, TerminalError> {
    master.as_raw_fd().ok_or_else(|| TerminalError::Pty {
        operation: "inspect PTY reader",
        message: "native PTY did not expose a file descriptor".to_owned(),
    })
}

#[cfg(not(unix))]
fn terminal_reader_descriptor(
    _master: &(dyn MasterPty + Send),
) -> Result<TerminalReaderDescriptor, TerminalError> {
    Ok(())
}

fn spawn_terminal_reader(
    output: Arc<TerminalStream>,
    terminal_id: TerminalId,
    mut reader: Box<dyn Read + Send>,
    reader_descriptor: TerminalReaderDescriptor,
    cancelled: Arc<AtomicBool>,
) -> Result<JoinHandle<()>, TerminalError> {
    thread::Builder::new()
        .name(format!("terminal-{}-reader", terminal_id.value()))
        .spawn(move || {
            let mut buffer = vec![0; READ_CHUNK_BYTES];
            loop {
                match wait_for_terminal_output(reader_descriptor, &cancelled) {
                    Ok(true) => {}
                    Ok(false) => break,
                    Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
                    Err(error) => {
                        debug!(terminal_id = terminal_id.value(), %error, "terminal reader poll stopped");
                        break;
                    }
                }
                match reader.read(&mut buffer) {
                    Ok(0) => break,
                    Ok(count) => {
                        if output
                            .publish_blocking(terminal_id, buffer[..count].to_vec())
                            .is_err()
                        {
                            break;
                        }
                    }
                    Err(error) if error.kind() == std::io::ErrorKind::Interrupted => {}
                    Err(error) => {
                        debug!(terminal_id = terminal_id.value(), %error, "terminal reader stopped");
                        break;
                    }
                }
            }
            let _ = output.finish(terminal_id);
        })
        .map_err(|error| TerminalError::Thread {
            operation: "start PTY reader",
            message: error.to_string(),
        })
}

#[cfg(unix)]
fn wait_for_terminal_output(
    descriptor: TerminalReaderDescriptor,
    cancelled: &AtomicBool,
) -> std::io::Result<bool> {
    loop {
        if cancelled.load(Ordering::Acquire) {
            return Ok(false);
        }
        let mut poll_descriptor = libc::pollfd {
            fd: descriptor,
            events: libc::POLLIN,
            revents: 0,
        };
        // SAFETY: `poll_descriptor` is valid for one entry for the duration of the call. The PTY
        // master stays owned by the session until this reader thread has joined.
        let result = unsafe { libc::poll(&raw mut poll_descriptor, 1, READER_POLL_MILLISECONDS) };
        if result > 0 {
            return Ok(!cancelled.load(Ordering::Acquire));
        }
        if result < 0 {
            return Err(std::io::Error::last_os_error());
        }
    }
}

#[cfg(not(unix))]
fn wait_for_terminal_output(
    _descriptor: TerminalReaderDescriptor,
    cancelled: &AtomicBool,
) -> std::io::Result<bool> {
    Ok(!cancelled.load(Ordering::Acquire))
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

fn canonical_working_directory(path: &Path) -> Result<PathBuf, TerminalError> {
    let canonical =
        std::fs::canonicalize(path).map_err(|error| TerminalError::WorkingDirectory {
            path: path.to_path_buf(),
            message: error.to_string(),
        })?;
    let metadata =
        std::fs::metadata(&canonical).map_err(|error| TerminalError::WorkingDirectory {
            path: path.to_path_buf(),
            message: error.to_string(),
        })?;
    if !metadata.is_dir() {
        return Err(TerminalError::WorkingDirectory {
            path: path.to_path_buf(),
            message: "path is not a directory".to_owned(),
        });
    }
    Ok(canonical)
}

fn shell_launcher_command(working_directory: &Path, shell: &Path) -> CommandBuilder {
    let mut command = CommandBuilder::new("/bin/sh");
    command.args([
        "-c",
        "if cd \"$1\" 2>/dev/null; then printf '\\036'; exec \"$2\" -l; else printf '\\037'; exit 125; fi",
        "twine-shell-launcher",
    ]);
    command.arg(working_directory.as_os_str());
    command.arg(shell.as_os_str());
    command
}

fn verify_working_directory(
    reader: &mut dyn Read,
    working_directory: &Path,
) -> Result<(), TerminalError> {
    let mut marker = [0];
    reader
        .read_exact(&mut marker)
        .map_err(|error| TerminalError::WorkingDirectory {
            path: working_directory.to_path_buf(),
            message: format!("shell launcher did not confirm its working directory: {error}"),
        })?;
    if marker == [0x1e] {
        Ok(())
    } else {
        Err(TerminalError::WorkingDirectory {
            path: working_directory.to_path_buf(),
            message: "directory became unavailable before the shell started".to_owned(),
        })
    }
}

fn wait_for_child(child: &SharedChild) -> Result<TerminalExit, String> {
    loop {
        let mut process = child
            .lock()
            .map_err(|_| "terminal child lock is poisoned".to_owned())?;
        if let Some(exit) = &process.exit {
            return exit.clone();
        }
        match child_exited_without_reaping(&mut process) {
            Ok(true) => {
                if let Some(exit) = &process.exit {
                    return exit.clone();
                }
                let exit = terminate_running_process(&mut process);
                process.exit = Some(exit.clone());
                return exit;
            }
            Ok(false) => {}
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(error) => return Err(error.to_string()),
        }
        drop(process);
        thread::sleep(SUPERVISOR_POLL_INTERVAL);
    }
}

fn terminate_unobserved_child(child: &SharedChild) {
    terminate_child(child);
}

fn terminate_child(child: &SharedChild) {
    let Ok(mut process) = child.lock() else {
        warn!("terminal child lock poisoned during shutdown");
        return;
    };
    if process.exit.is_some() {
        return;
    }
    loop {
        match child_exited_without_reaping(&mut process) {
            Ok(_) => break,
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => {}
            Err(error) if is_no_child_error(&error) => {
                process.exit = Some(Err(error.to_string()));
                return;
            }
            Err(error) => {
                warn!(%error, "failed to inspect terminal process; forcing shutdown");
                break;
            }
        }
    }
    if process.exit.is_some() {
        return;
    }
    let exit = terminate_running_process(&mut process);
    process.exit = Some(exit);
}

#[cfg(unix)]
fn child_exited_without_reaping(process: &mut ChildProcess) -> std::io::Result<bool> {
    let process_id = process
        .process_id
        .and_then(|value| libc::pid_t::try_from(value).ok())
        .ok_or_else(|| std::io::Error::other("terminal child has no usable process ID"))?;
    let wait_id = libc::id_t::try_from(process_id)
        .map_err(|_| std::io::Error::other("terminal child has no usable wait ID"))?;
    // SAFETY: `siginfo` is zero-initialized as required for WNOHANG, and the owned, unreaped child
    // PID stays valid while the process lock is held. WNOWAIT deliberately preserves that identity.
    let mut siginfo: libc::siginfo_t = unsafe { std::mem::zeroed() };
    let result = unsafe {
        libc::waitid(
            libc::P_PID,
            wait_id,
            &raw mut siginfo,
            libc::WEXITED | libc::WNOHANG | libc::WNOWAIT,
        )
    };
    if result != 0 {
        return Err(std::io::Error::last_os_error());
    }
    // SAFETY: A successful waitid call with WEXITED initializes the SIGCHLD process fields.
    Ok(unsafe { siginfo.si_pid() } != 0)
}

#[cfg(not(unix))]
fn child_exited_without_reaping(process: &mut ChildProcess) -> std::io::Result<bool> {
    process.child.try_wait().map(|status| {
        if let Some(status) = status {
            process.exit = Some(Ok(TerminalExit {
                exit_code: status.exit_code(),
                signal: status.signal().map(ToOwned::to_owned),
            }));
            true
        } else {
            false
        }
    })
}

#[cfg(unix)]
fn is_no_child_error(error: &std::io::Error) -> bool {
    error.raw_os_error() == Some(libc::ECHILD)
}

#[cfg(not(unix))]
const fn is_no_child_error(_error: &std::io::Error) -> bool {
    false
}

#[cfg(unix)]
fn terminate_running_process(process: &mut ChildProcess) -> ExitResult {
    let process_id = process
        .process_id
        .and_then(|value| i32::try_from(value).ok())
        .ok_or_else(|| "terminal child has no usable process ID".to_owned())?;
    signal_process_group(process_id, libc::SIGHUP);
    thread::sleep(Duration::from_millis(250));
    signal_process_group(process_id, libc::SIGKILL);
    process
        .child
        .wait()
        .map(|status| TerminalExit {
            exit_code: status.exit_code(),
            signal: status.signal().map(ToOwned::to_owned),
        })
        .map_err(|error| error.to_string())
}

#[cfg(unix)]
fn signal_process_group(process_id: i32, signal: i32) {
    // SAFETY: The child is live and unreaped under its ownership lock, and portable-pty creates a
    // process group whose ID matches this PID before exec.
    let result = unsafe { libc::kill(-process_id, signal) };
    if result != 0 {
        let error = std::io::Error::last_os_error();
        if error.raw_os_error() != Some(libc::ESRCH) {
            warn!(%error, process_id, signal, "failed to signal terminal process group");
        }
    }
}

#[cfg(not(unix))]
fn terminate_running_process(process: &mut ChildProcess) -> ExitResult {
    process.child.kill().map_err(|error| error.to_string())?;
    process
        .child
        .wait()
        .map(|status| TerminalExit {
            exit_code: status.exit_code(),
            signal: status.signal().map(ToOwned::to_owned),
        })
        .map_err(|error| error.to_string())
}

fn stop_session(terminal_id: TerminalId, mut session: TerminalSession) {
    session.reader_cancelled.store(true, Ordering::Release);
    terminate_child(&session.child);
    if let Some(thread) = session.reader_thread.take()
        && thread.join().is_err()
    {
        warn!(
            terminal_id = terminal_id.value(),
            "terminal reader thread panicked"
        );
    }
    if let Some(thread) = session.supervisor_thread.take()
        && thread.join().is_err()
    {
        warn!(
            terminal_id = terminal_id.value(),
            "terminal supervisor thread panicked"
        );
    }
}

#[derive(Debug, Error)]
pub enum TerminalError {
    #[error(
        "terminal output buffer is full: requested {requested_bytes} bytes, {available_bytes} available"
    )]
    BufferFull {
        requested_bytes: usize,
        available_bytes: usize,
    },
    #[error("terminal output chunk has {chunk_bytes} bytes, exceeding capacity {capacity_bytes}")]
    ChunkTooLarge {
        chunk_bytes: usize,
        capacity_bytes: usize,
    },
    #[error("terminal output chunks must not be empty")]
    EmptyChunk,
    #[error("terminal size must be nonzero, received {columns} columns by {rows} rows")]
    InvalidSize { rows: u16, columns: u16 },
    #[error("terminal byte offset overflowed")]
    OffsetOverflow,
    #[error("terminal {terminal_id:?} is not open")]
    NotOpen { terminal_id: TerminalId },
    #[error("terminal {terminal_id:?} still has queued output")]
    PendingOutput { terminal_id: TerminalId },
    #[error("failed to {operation}: {message}")]
    Pty {
        operation: &'static str,
        message: String,
    },
    #[error("terminal state lock is poisoned")]
    Poisoned,
    #[error("terminal output queue reached its {capacity_chunks}-chunk capacity")]
    QueueFull { capacity_chunks: usize },
    #[error("terminal ID counter overflowed")]
    TerminalIdOverflow,
    #[error("failed to {operation}: {message}")]
    Thread {
        operation: &'static str,
        message: String,
    },
    #[error("cannot use {path} as a terminal working directory: {message}")]
    WorkingDirectory { path: PathBuf, message: String },
    #[error("terminal output capacity must be greater than zero")]
    ZeroCapacity,
}

#[cfg(test)]
mod tests {
    use std::sync::mpsc;
    use std::time::{Duration, Instant, SystemTime};

    use super::*;

    #[test]
    fn queue_is_bounded_by_chunk_count() {
        let stream = TerminalStream::new(64, 2).expect("stream should initialize");
        let terminal_id = stream.open().expect("terminal should open");

        stream
            .publish(terminal_id, vec![1])
            .expect("first chunk should fit");
        stream
            .publish(terminal_id, vec![2])
            .expect("second chunk should fit");
        assert!(matches!(
            stream.publish(terminal_id, vec![3]),
            Err(TerminalError::QueueFull { capacity_chunks: 2 })
        ));
    }

    #[test]
    fn empty_chunks_are_rejected() {
        let stream = TerminalStream::new(64, 2).expect("stream should initialize");
        let terminal_id = stream.open().expect("terminal should open");
        assert!(matches!(
            stream.publish(terminal_id, Vec::new()),
            Err(TerminalError::EmptyChunk)
        ));
    }

    #[test]
    fn closing_drained_terminals_reclaims_offset_state() {
        let stream = TerminalStream::new(64, 2).expect("stream should initialize");

        for _ in 0..10_000 {
            let terminal_id = stream.open().expect("terminal should open");
            stream
                .publish(terminal_id, vec![1])
                .expect("terminal output should fit");
            assert!(matches!(
                stream.close(terminal_id),
                Err(TerminalError::PendingOutput { .. })
            ));
            let chunk = stream
                .next_chunk()
                .expect("read should succeed")
                .expect("chunk should exist");
            assert_eq!(chunk.offset, 0);
            stream
                .close(terminal_id)
                .expect("drained terminal should close");
            assert!(matches!(
                stream.publish(terminal_id, vec![2]),
                Err(TerminalError::NotOpen { .. })
            ));
        }

        let inner = stream.lock_inner().expect("stream should remain available");
        assert!(inner.entries.is_empty());
    }

    #[test]
    fn newly_opened_terminal_gets_a_fresh_id_and_zero_offset() {
        let stream = TerminalStream::new(64, 2).expect("stream should initialize");
        let first = stream.open().expect("first terminal should open");
        stream
            .publish(first, vec![1])
            .expect("terminal output should fit");
        stream.next_chunk().expect("read should succeed");
        stream.close(first).expect("terminal should close");

        let second = stream.open().expect("second terminal should open");
        assert_ne!(first, second);
        assert_eq!(
            stream
                .publish(second, vec![2])
                .expect("new terminal output should fit"),
            0
        );
    }

    #[test]
    fn cancelling_terminal_discards_its_buffered_output() {
        let stream = TerminalStream::new(4, 2).expect("stream should initialize");
        let first = stream.open().expect("first terminal should open");
        let second = stream.open().expect("second terminal should open");
        stream
            .publish(first, vec![1, 2, 3, 4])
            .expect("first terminal should fill the queue");

        stream.cancel(first).expect("terminal should cancel");
        assert!(matches!(
            stream.publish(first, vec![5]),
            Err(TerminalError::NotOpen { .. })
        ));
        stream
            .publish(second, vec![6, 7, 8, 9])
            .expect("cancelled output should release queue capacity");
        assert_eq!(
            stream
                .next_chunk()
                .expect("output should be readable")
                .expect("second terminal output should remain")
                .terminal_id,
            second
        );
    }

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
        assert!(
            stream
                .lock_inner()
                .expect("stream should remain available")
                .entries
                .is_empty()
        );
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
            if stream
                .lock_inner()
                .expect("stream should remain available")
                .chunks
                .len()
                == 1
            {
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
