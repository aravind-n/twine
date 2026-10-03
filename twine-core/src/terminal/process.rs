use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use portable_pty::Child;
use tracing::warn;

use super::TerminalExit;
#[cfg(unix)]
use crate::process::signal_process_group;
#[cfg(target_os = "macos")]
use crate::process::signal_session;

const SUPERVISOR_POLL_INTERVAL: Duration = Duration::from_millis(10);

type ExitResult = Result<TerminalExit, String>;
pub(super) type SharedChild = Arc<Mutex<ChildProcess>>;

pub(super) struct ChildProcess {
    child: Box<dyn Child + Send + Sync>,
    process_id: Option<u32>,
    exit: Option<ExitResult>,
}

/// Wraps a spawned child so its exit is observed and reaped exactly once.
pub(super) fn shared_child(child: Box<dyn Child + Send + Sync>) -> SharedChild {
    let process_id = child.process_id();
    Arc::new(Mutex::new(ChildProcess {
        child,
        process_id,
        exit: None,
    }))
}

pub(super) fn wait_for_child(child: &SharedChild) -> Result<TerminalExit, String> {
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

/// Checks the owned child without reaping it or signaling its process group.
pub(super) fn child_is_running(child: &SharedChild) -> bool {
    let Ok(mut process) = child.lock() else {
        return false;
    };
    process.exit.is_none() && matches!(child_exited_without_reaping(&mut process), Ok(false))
}

pub(super) fn terminate_unobserved_child(child: &SharedChild) {
    terminate_child(child);
}

pub(super) fn terminate_child(child: &SharedChild) {
    let mut process = match child.lock() {
        Ok(process) => process,
        Err(poisoned) => {
            warn!("terminal child lock poisoned during shutdown; recovering owned child");
            poisoned.into_inner()
        }
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
    crate::process::child_exited_without_reaping(process_id)
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
    let Some(process_id) = process
        .process_id
        .and_then(|value| i32::try_from(value).ok())
    else {
        warn!("terminal child has no usable process ID; killing the direct child");
        process.child.kill().map_err(|error| error.to_string())?;
        return reap_child(process);
    };
    if let Err(error) = signal_process_group(process_id, libc::SIGHUP)
        && error.raw_os_error() != Some(libc::ESRCH)
    {
        warn!(%error, process_id, "failed to hang up terminal process group");
    }
    #[cfg(target_os = "macos")]
    if let Err(error) = signal_session(process_id, libc::SIGHUP) {
        warn!(%error, process_id, "failed to hang up terminal session");
    }
    thread::sleep(Duration::from_millis(250));
    if let Err(error) = signal_process_group(process_id, libc::SIGKILL) {
        if error.raw_os_error() != Some(libc::ESRCH) {
            warn!(%error, process_id, "failed to kill terminal process group");
        }
        // The shell may have changed process groups. Still terminate the child Twine spawned.
        let _ = process.child.kill();
    }
    #[cfg(target_os = "macos")]
    if let Err(error) = signal_session(process_id, libc::SIGKILL) {
        warn!(%error, process_id, "failed to kill terminal session");
    }
    reap_child(process)
}

fn reap_child(process: &mut ChildProcess) -> ExitResult {
    process
        .child
        .wait()
        .map(|status| TerminalExit {
            exit_code: status.exit_code(),
            signal: status.signal().map(ToOwned::to_owned),
        })
        .map_err(|error| error.to_string())
}

#[cfg(not(unix))]
fn terminate_running_process(process: &mut ChildProcess) -> ExitResult {
    process.child.kill().map_err(|error| error.to_string())?;
    reap_child(process)
}
