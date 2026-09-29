//! Reads the current branch without changing the repository.

use std::ffi::OsStr;
use std::io::{Read, Seek};
use std::path::Path;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

use thiserror::Error;

pub(crate) fn current_branch(folder: &Path) -> Result<Option<String>, GitError> {
    read_branch(folder, OsStr::new("git"), Duration::from_secs(1))
}

fn read_branch(
    folder: &Path,
    executable: &OsStr,
    timeout: Duration,
) -> Result<Option<String>, GitError> {
    const MAX_OUTPUT: u64 = 4096;
    // A file avoids blocking on a full pipe while the command is being supervised.
    let mut output = tempfile::tempfile()?;
    let mut child = GitChild(
        Command::new(executable)
            .args(["symbolic-ref", "--quiet", "--short", "HEAD"])
            .current_dir(folder)
            .env("GIT_OPTIONAL_LOCKS", "0")
            .env_remove("GIT_DIR")
            .env_remove("GIT_WORK_TREE")
            .env_remove("GIT_COMMON_DIR")
            .stdin(Stdio::null())
            .stdout(output.try_clone()?)
            .stderr(Stdio::null())
            .spawn()?,
    );
    let deadline = Instant::now() + timeout;
    let status = loop {
        if output.metadata()?.len() > MAX_OUTPUT {
            return Err(GitError::OutputTooLarge);
        }
        if let Some(status) = child.0.try_wait()? {
            break status;
        }
        if Instant::now() >= deadline {
            return Err(GitError::Timeout);
        }
        std::thread::sleep(Duration::from_millis(5));
    };
    // Detached HEAD and folders outside repositories have no current branch to display.
    if !status.success() {
        return Ok(None);
    }
    output.rewind()?;
    let mut bytes = Vec::new();
    output.take(MAX_OUTPUT + 1).read_to_end(&mut bytes)?;
    if bytes.len() as u64 > MAX_OUTPUT {
        return Err(GitError::OutputTooLarge);
    }
    let name = std::str::from_utf8(&bytes)?.trim();
    Ok((!name.is_empty()).then(|| name.to_owned()))
}

/// Reap the child on success and terminate it on every early return.
struct GitChild(Child);

impl Drop for GitChild {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

#[derive(Debug, Error)]
pub(crate) enum GitError {
    #[error("could not run the Git branch read")]
    Read(#[from] std::io::Error),
    #[error("the Git branch name is not valid UTF-8")]
    Encoding(#[from] std::str::Utf8Error),
    #[error("the Git branch read timed out")]
    Timeout,
    #[error("the Git branch read returned too much output")]
    OutputTooLarge,
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::os::unix::fs::PermissionsExt;
    use std::path::Path;
    use std::time::{Duration, Instant};

    use super::{GitError, current_branch, read_branch};
    use crate::{Application, Command, CommandDisposition, EventKind, RequestId, StateEvent};

    fn repository(folder: &Path) {
        // Minimal valid Git metadata avoids repository mutations even in the test setup.
        fs::create_dir_all(folder.join(".git/objects")).unwrap();
        fs::create_dir_all(folder.join(".git/refs/heads")).unwrap();
        fs::write(folder.join(".git/HEAD"), "ref: refs/heads/main\n").unwrap();
    }

    #[test]
    fn stalled_branch_read_times_out_and_reaps_the_child() {
        let folder = tempfile::tempdir().unwrap();
        let executable = folder.path().join("stalled-git");
        fs::write(
            &executable,
            "#!/bin/sh\necho $$ > git.pid\nexec /bin/sleep 10\n",
        )
        .unwrap();
        fs::set_permissions(&executable, fs::Permissions::from_mode(0o700)).unwrap();
        let started = Instant::now();
        assert!(matches!(
            read_branch(
                folder.path(),
                executable.as_os_str(),
                Duration::from_secs(1)
            ),
            Err(GitError::Timeout)
        ));
        assert!(started.elapsed() < Duration::from_secs(3));
        let pid: libc::pid_t = fs::read_to_string(folder.path().join("git.pid"))
            .unwrap()
            .trim()
            .parse()
            .unwrap();
        assert!(pid > 0);
        // SAFETY: This is the positive PID of our child; a null status pointer is permitted.
        assert_eq!(
            unsafe { libc::waitpid(pid, std::ptr::null_mut(), libc::WNOHANG) },
            -1
        );
        assert_eq!(
            std::io::Error::last_os_error().raw_os_error(),
            Some(libc::ECHILD)
        );
        // A later branch read still succeeds after the timed-out child has been cleaned up.
        repository(folder.path());
        assert_eq!(
            current_branch(folder.path()).unwrap().as_deref(),
            Some("main")
        );
    }

    #[test]
    fn oversized_branch_output_is_rejected() {
        let folder = tempfile::tempdir().unwrap();
        let executable = folder.path().join("verbose-git");
        fs::write(&executable, "#!/bin/sh\nprintf '%5000s' ' '\n").unwrap();
        fs::set_permissions(&executable, fs::Permissions::from_mode(0o700)).unwrap();
        assert!(matches!(
            read_branch(
                folder.path(),
                executable.as_os_str(),
                Duration::from_secs(1)
            ),
            Err(GitError::OutputTooLarge)
        ));
    }

    #[test]
    fn branch_read_handles_unborn_heads_subdirectories_detached_heads_and_non_repositories() {
        let folder = tempfile::tempdir().unwrap();
        assert_eq!(current_branch(folder.path()).unwrap(), None);
        repository(folder.path());
        assert_eq!(
            current_branch(folder.path()).unwrap().as_deref(),
            Some("main")
        );
        let nested = folder.path().join("src/nested");
        fs::create_dir_all(&nested).unwrap();
        assert_eq!(current_branch(&nested).unwrap().as_deref(), Some("main"));
        fs::write(
            folder.path().join(".git/HEAD"),
            "0123456789012345678901234567890123456789\n",
        )
        .unwrap();
        assert_eq!(current_branch(folder.path()).unwrap(), None);
    }

    #[test]
    fn linked_worktree_reads_its_own_head() {
        let root = tempfile::tempdir().unwrap();
        let main = root.path().join("main");
        repository(&main);
        let worktree = root.path().join("linked");
        let metadata = main.join(".git/worktrees/linked");
        fs::create_dir_all(&metadata).unwrap();
        fs::create_dir_all(&worktree).unwrap();
        fs::write(
            worktree.join(".git"),
            format!("gitdir: {}\n", metadata.display()),
        )
        .unwrap();
        fs::write(metadata.join("commondir"), "../..\n").unwrap();
        fs::write(
            metadata.join("gitdir"),
            format!("{}\n", worktree.join(".git").display()),
        )
        .unwrap();
        fs::write(metadata.join("HEAD"), "ref: refs/heads/linked-branch\n").unwrap();
        assert_eq!(
            current_branch(&worktree).unwrap().as_deref(),
            Some("linked-branch")
        );
        assert_eq!(current_branch(&main).unwrap().as_deref(), Some("main"));
    }

    #[test]
    fn refresh_publishes_only_changes_and_never_attaches_an_old_branch_to_a_new_folder() {
        let folder = tempfile::tempdir().unwrap();
        let other = tempfile::tempdir().unwrap();
        repository(folder.path());
        let app = Application::with_event_capacity(128).unwrap();
        app.handle_command(
            RequestId(1),
            Command::OpenFolder {
                path: folder.path().to_owned(),
            },
        )
        .unwrap();
        let refresh = || Command::RefreshGitBranch {
            folder: folder.path().to_owned(),
        };
        app.handle_command(RequestId(2), refresh()).unwrap();
        let snapshot = app.snapshot().unwrap();
        assert_eq!(snapshot.folders.current_branch.as_deref(), Some("main"));
        app.handle_command(RequestId(3), refresh()).unwrap();
        assert_eq!(app.snapshot().unwrap().sequence, snapshot.sequence);

        fs::write(folder.path().join(".git/HEAD"), "ref: refs/heads/feature\n").unwrap();
        app.handle_command(RequestId(4), refresh()).unwrap();
        let events = app.events_after(snapshot.sequence, 16).unwrap();
        assert!(
            matches!(&events[0].kind, EventKind::State(StateEvent::FoldersChanged(folders))
            if folders.current_branch.as_deref() == Some("feature"))
        );
        app.handle_command(
            RequestId(5),
            Command::OpenFolder {
                path: other.path().to_owned(),
            },
        )
        .unwrap();
        assert_eq!(app.snapshot().unwrap().folders.current_branch, None);
        assert!(
            matches!(app.handle_command(RequestId(6), refresh()).unwrap().disposition,
            CommandDisposition::Rejected { ref code, .. } if code == "folderChanged")
        );
        assert_eq!(app.snapshot().unwrap().folders.current_branch, None);
    }
}
