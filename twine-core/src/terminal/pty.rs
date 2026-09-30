use std::io::{Read, Write};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;

use portable_pty::{CommandBuilder, MasterPty, PtySize, native_pty_system};
use tracing::debug;

use super::launcher::verify_working_directory;
use super::process::{SharedChild, shared_child, terminate_unobserved_child};
use super::{TerminalError, TerminalId, TerminalSize, TerminalStream};

pub(super) const READ_CHUNK_BYTES: usize = 16 * 1024;
const READER_POLL_MILLISECONDS: libc::c_int = 50;

#[cfg(unix)]
pub(super) type TerminalReaderDescriptor = libc::c_int;

#[cfg(not(unix))]
pub(super) type TerminalReaderDescriptor = ();

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

pub(super) struct StartingTerminal {
    pub(super) master: Box<dyn MasterPty + Send>,
    pub(super) reader: Box<dyn Read + Send>,
    pub(super) writer: Arc<Mutex<Box<dyn Write + Send>>>,
    pub(super) child: SharedChild,
    pub(super) reader_descriptor: TerminalReaderDescriptor,
}

pub(super) fn spawn_terminal_process(
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
    let child = shared_child(child);
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

pub(super) fn spawn_terminal_reader(
    output: Arc<TerminalStream>,
    terminal_id: TerminalId,
    mut reader: Box<dyn Read + Send>,
    reader_descriptor: TerminalReaderDescriptor,
    cancelled: Arc<AtomicBool>,
) -> Result<JoinHandle<()>, TerminalError> {
    crate::blocking_worker::spawn(
        format!("terminal-{}-reader", terminal_id.value()),
        move || {
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
        },
    )
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
