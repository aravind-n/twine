use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use portable_pty::Child;
use tracing::warn;

use super::TerminalExit;

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
    if let Err(error) = signal_terminal_session(process_id, libc::SIGHUP) {
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
    if let Err(error) = signal_terminal_session(process_id, libc::SIGKILL) {
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

#[cfg(unix)]
fn signal_process_group(process_id: i32, signal: i32) -> std::io::Result<()> {
    // SAFETY: The child is live and unreaped under its ownership lock, and portable-pty creates a
    // process group whose ID matches this PID before exec.
    let result = unsafe { libc::kill(-process_id, signal) };
    if result == 0 {
        Ok(())
    } else {
        Err(std::io::Error::last_os_error())
    }
}

#[cfg(target_os = "macos")]
fn signal_terminal_session(session_id: libc::pid_t, signal: i32) -> std::io::Result<()> {
    if session_id == unsafe { libc::getsid(0) } {
        return Err(std::io::Error::other(
            "terminal shares Twine's process session",
        ));
    }

    // proc_listallpids returns PID counts, while its buffer size is measured in bytes.
    let required = unsafe { libc::proc_listallpids(std::ptr::null_mut(), 0) };
    if required < 0 {
        return Err(std::io::Error::last_os_error());
    }
    let mut capacity =
        usize::try_from(required).map_err(|_| std::io::Error::other("invalid process count"))? + 64;
    let pids = loop {
        let mut pids = vec![0; capacity];
        let bytes = (capacity * std::mem::size_of::<libc::pid_t>())
            .try_into()
            .map_err(|_| std::io::Error::other("process list is too large"))?;
        let count = unsafe { libc::proc_listallpids(pids.as_mut_ptr().cast(), bytes) };
        if count < 0 {
            return Err(std::io::Error::last_os_error());
        }
        let count =
            usize::try_from(count).map_err(|_| std::io::Error::other("invalid process count"))?;
        if count == capacity {
            capacity *= 2;
            continue;
        }
        pids.truncate(count);
        break pids;
    };

    for pid in pids.into_iter().filter(|&pid| pid > 0) {
        // A job-control shell can move background jobs into another process group, but they
        // remain in its PTY session even if the shell exits and they are reparented.
        if unsafe { libc::getsid(pid) } != session_id {
            continue;
        }
        if unsafe { libc::kill(pid, signal) } != 0 {
            let error = std::io::Error::last_os_error();
            if error.raw_os_error() != Some(libc::ESRCH) {
                warn!(%error, pid, signal, "failed to signal terminal session member");
            }
        }
    }
    Ok(())
}

#[cfg(not(unix))]
fn terminate_running_process(process: &mut ChildProcess) -> ExitResult {
    process.child.kill().map_err(|error| error.to_string())?;
    reap_child(process)
}
