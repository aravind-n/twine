//! Child ownership and process-group cleanup shared by terminals and discovery helpers.

use std::io;
use std::os::unix::process::CommandExt;
use std::process::{Child, Command, ExitStatus};

use tracing::warn;

/// A helper in its own session. Retain its PID until all its children have been stopped, including
/// when the helper exits successfully, so process and session IDs cannot be reused during cleanup.
pub(crate) struct CommandChild {
    child: Child,
    reaped: bool,
}

impl CommandChild {
    pub(crate) fn spawn(command: &mut Command) -> io::Result<Self> {
        // SAFETY: The pre-exec closure invokes only the async-signal-safe setsid syscall and
        // constructs an OS error on failure. This child hasn't yet become a process-group leader.
        unsafe {
            command.pre_exec(|| {
                if libc::setsid() == -1 {
                    Err(io::Error::last_os_error())
                } else {
                    Ok(())
                }
            });
        }
        command.spawn().map(|child| Self {
            child,
            reaped: false,
        })
    }

    pub(crate) fn has_exited(&mut self) -> io::Result<bool> {
        let pid = libc::pid_t::try_from(self.child.id())
            .map_err(|_| io::Error::other("child has no usable process ID"))?;
        let result = child_exited_without_reaping(pid);
        if result
            .as_ref()
            .is_err_and(|error| error.raw_os_error() == Some(libc::ECHILD))
        {
            // Another reaper removed the child, so its identity is no longer safe to signal.
            self.reaped = true;
        }
        result
    }

    pub(crate) fn finish(&mut self) -> io::Result<ExitStatus> {
        self.terminate();
        let status = self.child.wait()?;
        self.reaped = true;
        Ok(status)
    }

    fn terminate(&mut self) {
        if self.reaped {
            return;
        }
        if let Ok(pid) = libc::pid_t::try_from(self.child.id()) {
            if let Err(error) = signal_process_group(pid, libc::SIGKILL)
                && error.raw_os_error() != Some(libc::ESRCH)
            {
                warn!(%error, pid, "failed to kill helper process group");
            }
            #[cfg(target_os = "macos")]
            if let Err(error) = signal_session(pid, libc::SIGKILL) {
                warn!(%error, pid, "failed to kill helper process session");
            }
        }
        let _ = self.child.kill();
    }
}

impl Drop for CommandChild {
    fn drop(&mut self) {
        if !self.reaped {
            self.terminate();
            let _ = self.child.wait();
        }
    }
}

#[cfg(unix)]
pub(crate) fn child_exited_without_reaping(process_id: libc::pid_t) -> io::Result<bool> {
    let wait_id = libc::id_t::try_from(process_id)
        .map_err(|_| std::io::Error::other("child has no usable wait ID"))?;
    // SAFETY: `siginfo` is zero-initialized as required for WNOHANG, and the owned, unreaped child
    // PID stays valid throughout the owned child lifetime. WNOWAIT deliberately preserves that identity.
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

#[cfg(unix)]
pub(crate) fn signal_process_group(process_id: i32, signal: i32) -> std::io::Result<()> {
    // SAFETY: Callers retain an owned, unreaped child whose PID identifies its process group.
    let result = unsafe { libc::kill(-process_id, signal) };
    if result == 0 {
        Ok(())
    } else {
        Err(std::io::Error::last_os_error())
    }
}

#[cfg(target_os = "macos")]
pub(crate) fn signal_session(session_id: libc::pid_t, signal: i32) -> std::io::Result<()> {
    if session_id == unsafe { libc::getsid(0) } {
        return Err(std::io::Error::other(
            "child shares Twine's process session",
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
        // remain in its session even if the shell exits and they are reparented.
        if unsafe { libc::getsid(pid) } != session_id {
            continue;
        }
        if unsafe { libc::kill(pid, signal) } != 0 {
            let error = std::io::Error::last_os_error();
            if error.raw_os_error() != Some(libc::ESRCH) {
                warn!(%error, pid, signal, "failed to signal process session member");
            }
        }
    }
    Ok(())
}

#[cfg(test)]
pub(crate) mod tests {
    use std::path::Path;
    #[cfg(target_os = "macos")]
    use std::process::Stdio;
    use std::thread;
    use std::time::{Duration, Instant};

    #[cfg(target_os = "macos")]
    use super::*;

    /// A fixture-owned process, with cleanup even when a regression assertion fails.
    pub(crate) struct FixtureProcess(pub(crate) libc::pid_t);

    impl FixtureProcess {
        pub(crate) fn read(path: &Path) -> Self {
            let deadline = Instant::now() + Duration::from_secs(5);
            loop {
                if let Ok(contents) = std::fs::read_to_string(path)
                    && let Ok(pid) = contents.trim().parse::<libc::pid_t>()
                    && pid > 0
                {
                    return Self(pid);
                }
                assert!(Instant::now() < deadline, "fixture never published its PID");
                thread::sleep(Duration::from_millis(5));
            }
        }

        pub(crate) fn is_running(&self) -> bool {
            // SAFETY: The positive PID was published by this test's own fixture.
            unsafe { libc::kill(self.0, 0) == 0 }
        }

        pub(crate) fn assert_stopped(&self) {
            let deadline = Instant::now() + Duration::from_secs(3);
            while self.is_running() {
                assert!(
                    Instant::now() < deadline,
                    "fixture process was left running"
                );
                thread::sleep(Duration::from_millis(5));
            }
        }
    }

    impl Drop for FixtureProcess {
        fn drop(&mut self) {
            if self.is_running() {
                // SAFETY: Stop only the fixture-owned process if its test failed to clean it up.
                unsafe { libc::kill(self.0, libc::SIGKILL) };
            }
        }
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn finishing_an_exited_helper_stops_jobs_in_other_process_groups() {
        let directory = tempfile::tempdir().unwrap();
        let pid_path = directory.path().join("child.pid");
        let mut command = Command::new("/bin/sh");
        command
            .args(["-c", "set -m; sleep 60 & echo $! > \"$1\"", "fixture"])
            .arg(&pid_path)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        let mut helper = CommandChild::spawn(&mut command).unwrap();
        let child = FixtureProcess::read(&pid_path);
        let parent_pid = libc::pid_t::try_from(helper.child.id()).unwrap();
        let deadline = Instant::now() + Duration::from_secs(3);
        while !helper.has_exited().unwrap() {
            assert!(Instant::now() < deadline);
            thread::sleep(Duration::from_millis(5));
        }
        // SAFETY: Both PIDs belong to this fixture; the parent is still owned and unreaped.
        assert_ne!(unsafe { libc::getpgid(child.0) }, parent_pid);
        assert_eq!(unsafe { libc::getsid(child.0) }, parent_pid);
        assert!(helper.finish().unwrap().success());
        child.assert_stopped();
    }
}
