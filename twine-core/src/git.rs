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
pub(crate) mod tests;
