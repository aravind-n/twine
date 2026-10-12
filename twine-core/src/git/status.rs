use std::collections::BTreeMap;
use std::io::{Read, Seek};
use std::os::unix::process::CommandExt;
use std::path::{Component, Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

use thiserror::Error;

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct GitSnapshot {
    pub repositories: Vec<GitRepository>,
    pub scanning: bool,
    pub error: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct GitRepository {
    pub root: PathBuf,
    pub changes: Vec<GitChange>,
    pub error: Option<String>,
    pub loading: bool,
}

impl GitRepository {
    pub(crate) fn unavailable(root: PathBuf, message: String) -> Self {
        Self {
            root,
            changes: Vec::new(),
            error: Some(message),
            loading: false,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum GitChangeKind {
    Modified,
    Added,
    Deleted,
    Renamed,
    Copied,
    TypeChanged,
}

impl GitChangeKind {
    #[must_use]
    pub fn symbol(self) -> &'static str {
        match self {
            Self::Modified => "M",
            Self::Added => "A",
            Self::Deleted => "D",
            Self::Renamed => "R",
            Self::Copied => "C",
            Self::TypeChanged => "T",
        }
    }

    fn parse(byte: u8) -> Result<Option<Self>, StatusError> {
        Ok(match byte {
            b'.' => None,
            b'M' => Some(Self::Modified),
            b'A' => Some(Self::Added),
            b'D' => Some(Self::Deleted),
            b'R' => Some(Self::Renamed),
            b'C' => Some(Self::Copied),
            b'T' => Some(Self::TypeChanged),
            _ => return Err(StatusError::InvalidOutput),
        })
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct GitChange {
    pub path: PathBuf,
    pub original_path: Option<PathBuf>,
    pub staged: Option<GitChangeKind>,
    pub unstaged: Option<GitChangeKind>,
    pub conflicted: bool,
    pub untracked: bool,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct GitDecoration {
    pub change: Option<GitChange>,
    pub contains_changes: bool,
    pub contains_conflicts: bool,
    pub deleted: bool,
}

#[derive(Debug, Error)]
pub(crate) enum StatusError {
    #[error("Could not read Git status.")]
    Read(#[from] std::io::Error),
    #[error("Git status timed out. It will retry automatically.")]
    Timeout,
    #[error("Git status exceeds the supported size. Status is unavailable.")]
    TooLarge,
    #[error("Git could not read this repository. Check its permissions and configuration.")]
    Failed,
    #[error("Git returned an unsupported status or filename.")]
    InvalidOutput,
}

pub(crate) fn read(root: &Path) -> Result<GitRepository, StatusError> {
    read_command(root, Command::new("git"))
}

fn read_command(root: &Path, mut command: Command) -> Result<GitRepository, StatusError> {
    command
        .args(["status", "--porcelain=v2", "-z"])
        .env("GIT_OPTIONAL_LOCKS", "0")
        .env_remove("GIT_DIR")
        .env_remove("GIT_WORK_TREE")
        .env_remove("GIT_COMMON_DIR")
        .env_remove("GIT_INDEX_FILE")
        .env_remove("GIT_OBJECT_DIRECTORY")
        .env_remove("GIT_ALTERNATE_OBJECT_DIRECTORIES");
    parse(root, &run(root, command, Duration::from_secs(2))?)
}

// Git may invoke filters or submodule processes. Terminate the entire isolated group
// on timeout, output-limit failures, and shutdown before releasing the output file.
struct StatusChild(Child);

impl Drop for StatusChild {
    fn drop(&mut self) {
        if let Ok(pid) = i32::try_from(self.0.id()) {
            // SAFETY: process_group(0) creates a separate group led by this child.
            unsafe {
                libc::kill(-pid, libc::SIGKILL);
            }
        }
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

fn run(root: &Path, mut command: Command, timeout: Duration) -> Result<Vec<u8>, StatusError> {
    const LIMIT: u64 = 8 * 1024 * 1024;
    let mut output = tempfile::tempfile()?;
    let mut child = StatusChild(
        command
            .process_group(0)
            .current_dir(root)
            .stdin(Stdio::null())
            .stdout(output.try_clone()?)
            .stderr(Stdio::null())
            .spawn()?,
    );
    let deadline = Instant::now() + timeout;
    loop {
        if output.metadata()?.len() > LIMIT {
            return Err(StatusError::TooLarge);
        }
        if let Some(status) = child.0.try_wait()? {
            if !status.success() {
                return Err(StatusError::Failed);
            }
            break;
        }
        if Instant::now() >= deadline {
            return Err(StatusError::Timeout);
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    output.rewind()?;
    let mut bytes = Vec::new();
    output.take(LIMIT + 1).read_to_end(&mut bytes)?;
    if bytes.len() as u64 > LIMIT {
        return Err(StatusError::TooLarge);
    }
    Ok(bytes)
}

fn path(root: &Path, value: &str) -> Result<PathBuf, StatusError> {
    let relative = Path::new(value);
    if value.is_empty()
        || relative
            .components()
            .any(|part| !matches!(part, Component::Normal(_)))
    {
        return Err(StatusError::InvalidOutput);
    }
    Ok(root.join(relative))
}

fn parse(root: &Path, bytes: &[u8]) -> Result<GitRepository, StatusError> {
    let text = std::str::from_utf8(bytes).map_err(|_| StatusError::InvalidOutput)?;
    let mut records = text.split_terminator('\0');
    let mut changes = BTreeMap::<PathBuf, GitChange>::new();
    for_record(&mut records, root, &mut changes)?;
    Ok(GitRepository {
        root: root.to_owned(),
        changes: changes.into_values().collect(),
        error: None,
        loading: false,
    })
}

fn for_record<'a>(
    records: &mut impl Iterator<Item = &'a str>,
    root: &Path,
    changes: &mut BTreeMap<PathBuf, GitChange>,
) -> Result<(), StatusError> {
    while let Some(record) = records.next() {
        if record.starts_with('#') {
            continue;
        }
        let tag = record
            .as_bytes()
            .first()
            .copied()
            .ok_or(StatusError::InvalidOutput)?;
        let fields: Vec<_> = record
            .splitn(
                match tag {
                    b'1' => 9,
                    b'2' => 10,
                    b'u' => 11,
                    b'?' => 2,
                    _ => return Err(StatusError::InvalidOutput),
                },
                ' ',
            )
            .collect();
        let expected = match tag {
            b'1' => 9,
            b'2' => 10,
            b'u' => 11,
            _ => 2,
        };
        if fields.len() != expected {
            return Err(StatusError::InvalidOutput);
        }
        let file = path(root, fields[expected - 1])?;
        let change = changes.entry(file.clone()).or_insert(GitChange {
            path: file,
            original_path: None,
            staged: None,
            unstaged: None,
            conflicted: false,
            untracked: false,
        });
        if tag == b'?' {
            change.untracked = true;
        } else if tag == b'u' {
            change.conflicted = true;
        } else {
            let xy = fields[1].as_bytes();
            if xy.len() != 2 {
                return Err(StatusError::InvalidOutput);
            }
            change.staged = GitChangeKind::parse(xy[0])?;
            change.unstaged = GitChangeKind::parse(xy[1])?;
            // Submodule content can be dirty even when the gitlink's XY columns are unchanged.
            if fields[2].starts_with('S') && fields[2].as_bytes().iter().skip(1).any(|b| *b != b'.')
            {
                change.unstaged.get_or_insert(GitChangeKind::Modified);
            }
        }
        if tag == b'2' {
            change.original_path = Some(path(
                root,
                records.next().ok_or(StatusError::InvalidOutput)?,
            )?);
        }
        if changes.len() > 50_000 {
            return Err(StatusError::TooLarge);
        }
    }
    Ok(())
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use std::fs;

    pub(crate) fn git(root: &Path, args: &[&str]) {
        let output = Command::new("git")
            .args([
                "-c",
                "user.name=Twine Test",
                "-c",
                "user.email=test@example.invalid",
                "-c",
                "commit.gpgsign=false",
            ])
            .args(args)
            .current_dir(root)
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
    }

    pub(crate) fn init(root: &Path) {
        fs::create_dir_all(root).unwrap();
        git(root, &["init", "-b", "main"]);
        fs::write(root.join("README.md"), "initial\n").unwrap();
        git(root, &["add", "."]);
        git(root, &["commit", "-m", "initial"]);
    }

    #[test]
    fn reads_both_columns_renames_deletions_untracked_and_preserves_index() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path();
        init(root);
        fs::write(root.join("README.md"), "staged\n").unwrap();
        git(root, &["add", "README.md"]);
        fs::write(root.join("README.md"), "unstaged\n").unwrap();
        fs::write(root.join("new 🌲\nfile.txt"), "new").unwrap();
        fs::write(root.join(".gitignore"), "ignored\n").unwrap();
        fs::write(root.join("ignored"), "ignored").unwrap();
        let index = fs::read(root.join(".git/index")).unwrap();
        let snapshot = read(root).unwrap();
        let change = snapshot
            .changes
            .iter()
            .find(|c| c.path.ends_with("README.md"))
            .unwrap();
        assert_eq!(change.staged, Some(GitChangeKind::Modified));
        assert_eq!(change.unstaged, Some(GitChangeKind::Modified));
        assert!(
            snapshot
                .changes
                .iter()
                .any(|c| c.path.ends_with("new 🌲\nfile.txt") && c.untracked)
        );
        assert!(!snapshot.changes.iter().any(|c| c.path.ends_with("ignored")));
        assert_eq!(fs::read(root.join(".git/index")).unwrap(), index);
        git(root, &["reset", "--hard", "HEAD"]);
        git(root, &["mv", "README.md", "renamed 🌲.md"]);
        let snapshot = read(root).unwrap();
        let rename = snapshot
            .changes
            .iter()
            .find(|c| c.path.ends_with("renamed 🌲.md"))
            .unwrap();
        assert_eq!(rename.staged, Some(GitChangeKind::Renamed));
        assert_eq!(
            rename.original_path.as_deref(),
            Some(root.join("README.md").as_path())
        );
        fs::remove_file(root.join("renamed 🌲.md")).unwrap();
        assert_eq!(
            read(root)
                .unwrap()
                .changes
                .iter()
                .find(|c| c.path.ends_with("renamed 🌲.md"))
                .unwrap()
                .unstaged,
            Some(GitChangeKind::Deleted)
        );
    }

    #[test]
    fn ignores_inherited_repository_storage_but_preserves_configuration() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path();
        init(root);
        let alternate = root.join(".git/alternate-index");
        fs::copy(root.join(".git/index"), &alternate).unwrap();
        fs::write(root.join("README.md"), "changed\n").unwrap();
        fs::write(root.join("new.txt"), "untracked\n").unwrap();
        let output = Command::new("git")
            .env("GIT_INDEX_FILE", &alternate)
            .args(["add", "README.md"])
            .current_dir(root)
            .output()
            .unwrap();
        assert!(output.status.success());
        let index = fs::read(root.join(".git/index")).unwrap();
        let mut command = Command::new("git");
        command
            .env("GIT_DIR", root.join("missing"))
            .env("GIT_WORK_TREE", root.join("missing"))
            .env("GIT_COMMON_DIR", root.join("missing"))
            .env("GIT_INDEX_FILE", &alternate)
            .env("GIT_OBJECT_DIRECTORY", root.join("missing"))
            .env("GIT_ALTERNATE_OBJECT_DIRECTORIES", root.join("missing"))
            .env("GIT_CONFIG_COUNT", "1")
            .env("GIT_CONFIG_KEY_0", "status.showUntrackedFiles")
            .env("GIT_CONFIG_VALUE_0", "no");
        let snapshot = read_command(root, command).unwrap();
        assert_eq!(snapshot.changes.len(), 1);
        assert_eq!(snapshot.changes[0].path, root.join("README.md"));
        assert_eq!(snapshot.changes[0].staged, None);
        assert_eq!(snapshot.changes[0].unstaged, Some(GitChangeKind::Modified));
        assert_eq!(fs::read(root.join(".git/index")).unwrap(), index);
    }

    #[test]
    fn follows_repository_rename_and_untracked_settings() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path();
        init(root);
        git(root, &["mv", "README.md", "renamed.md"]);
        git(root, &["config", "status.renames", "true"]);
        assert_eq!(
            read(root).unwrap().changes[0].staged,
            Some(GitChangeKind::Renamed)
        );
        git(root, &["config", "status.renames", "false"]);
        let snapshot = read(root).unwrap();
        assert_eq!(snapshot.changes.len(), 2);
        assert!(
            snapshot
                .changes
                .iter()
                .any(|c| c.staged == Some(GitChangeKind::Added))
        );
        assert!(
            snapshot
                .changes
                .iter()
                .any(|c| c.staged == Some(GitChangeKind::Deleted))
        );
        git(root, &["reset", "--hard", "HEAD"]);
        fs::create_dir(root.join("new-directory")).unwrap();
        fs::write(root.join("new-directory/file.txt"), "new\n").unwrap();
        git(root, &["config", "status.showUntrackedFiles", "no"]);
        assert_eq!(read(root).unwrap().changes, []);
        git(root, &["config", "status.showUntrackedFiles", "normal"]);
        assert_eq!(
            read(root).unwrap().changes[0].path,
            root.join("new-directory")
        );
        git(root, &["config", "status.showUntrackedFiles", "all"]);
        assert_eq!(
            read(root).unwrap().changes[0].path,
            root.join("new-directory/file.txt")
        );
    }

    #[test]
    fn follows_repository_submodule_ignore_settings() {
        let temp = tempfile::tempdir().unwrap();
        let source = tempfile::tempdir().unwrap();
        let root = temp.path();
        init(root);
        init(source.path());
        git(
            root,
            &[
                "-c",
                "protocol.file.allow=always",
                "submodule",
                "add",
                source.path().to_str().unwrap(),
                "module",
            ],
        );
        git(root, &["commit", "-am", "add module"]);
        fs::write(root.join("module/README.md"), "dirty\n").unwrap();
        git(root, &["config", "submodule.module.ignore", "none"]);
        assert_eq!(read(root).unwrap().changes[0].path, root.join("module"));
        git(root, &["config", "submodule.module.ignore", "all"]);
        assert_eq!(read(root).unwrap().changes, []);
    }

    #[test]
    fn reads_changes_in_unborn_detached_and_conflicted_checkouts() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path();
        git(root, &["init", "-b", "main"]);
        assert_eq!(read(root).unwrap().changes, []);
        fs::write(root.join("file"), "base\n").unwrap();
        git(root, &["add", "."]);
        git(root, &["commit", "-m", "base"]);
        git(root, &["branch", "upstream"]);
        fs::write(root.join("file"), "main\n").unwrap();
        git(root, &["commit", "-am", "main"]);
        let clean = read(root).unwrap();
        assert_eq!(clean.changes, []);
        git(root, &["checkout", "--detach"]);
        assert_eq!(read(root).unwrap().changes, []);
        git(root, &["checkout", "upstream"]);
        fs::write(root.join("file"), "other\n").unwrap();
        git(root, &["commit", "-am", "other"]);
        git(root, &["checkout", "main"]);
        let result = Command::new("git")
            .args([
                "-c",
                "user.name=Test",
                "-c",
                "user.email=test@example.invalid",
                "merge",
                "upstream",
            ])
            .current_dir(root)
            .output()
            .unwrap();
        assert!(!result.status.success());
        let conflict = read(root).unwrap();
        assert!(conflict.changes.iter().any(|c| c.conflicted));
    }

    #[test]
    fn invalid_output_and_stalled_commands_are_unavailable() {
        let root = tempfile::tempdir().unwrap();
        assert!(parse(root.path(), b"? ../escape\0").is_err());
        assert!(parse(root.path(), b"2 R. N... 1 1 1 a b R100 dest\0").is_err());
        assert!(parse(root.path(), b"? invalid\xff\0").is_err());
        let mut command = Command::new("/bin/sleep");
        command.arg("10");
        assert!(matches!(
            run(root.path(), command, Duration::from_millis(30)),
            Err(StatusError::Timeout)
        ));
        assert!(read(root.path()).is_err());
    }

    #[test]
    fn timeout_terminates_descendants_as_well_as_the_git_process() {
        let root = tempfile::tempdir().unwrap();
        let mut command = Command::new("/bin/sh");
        command.args(["-c", "/bin/sleep 30 & echo $! > child.pid; wait"]);
        assert!(matches!(
            run(root.path(), command, Duration::from_millis(100)),
            Err(StatusError::Timeout)
        ));
        let pid = fs::read_to_string(root.path().join("child.pid")).unwrap();
        let deadline = Instant::now() + Duration::from_secs(3);
        loop {
            let output = Command::new("ps")
                .args(["-o", "stat=", "-p", pid.trim()])
                .output()
                .unwrap();
            let state = String::from_utf8_lossy(&output.stdout);
            // A terminated orphan may briefly remain a zombie until the system reaps it.
            if state.trim().is_empty() || state.trim().starts_with('Z') {
                break;
            }
            assert!(
                Instant::now() < deadline,
                "descendant still running: {state}"
            );
            std::thread::sleep(Duration::from_millis(10));
        }
    }
}
