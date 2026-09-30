//! Built-in harness definitions and finding their binaries.

use std::collections::HashSet;
use std::ffi::{OsStr, OsString};
use std::io::{Read, Seek};
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::Mutex;
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use thiserror::Error;
use tracing::debug;

/// How long to wait for the login shell to report its `PATH`.
const LOGIN_SHELL_TIMEOUT: Duration = Duration::from_secs(5);
const MAX_LOGIN_SHELL_OUTPUT: u64 = 64 * 1024;
const PATH_START: &[u8] = b"__TWINE_PATH__";
const PATH_END: &[u8] = b"__TWINE_END__";

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub enum HarnessId {
    Codex,
    ClaudeCode,
    Pi,
}

/// How to launch one harness. Adding a harness means adding a definition here.
#[derive(Debug)]
pub(crate) struct HarnessDefinition {
    pub name: &'static str,
    pub binary: &'static str,
    /// Whether the harness reads a prompt that starts with `@` as a file path.
    pub reads_at_prefix_as_file: bool,
}

static CODEX: HarnessDefinition = HarnessDefinition {
    name: "Codex",
    binary: "codex",
    reads_at_prefix_as_file: false,
};
static CLAUDE_CODE: HarnessDefinition = HarnessDefinition {
    name: "Claude Code",
    binary: "claude",
    reads_at_prefix_as_file: false,
};
static PI: HarnessDefinition = HarnessDefinition {
    name: "pi",
    binary: "pi",
    reads_at_prefix_as_file: true,
};

impl HarnessId {
    pub(crate) fn definition(self) -> &'static HarnessDefinition {
        match self {
            Self::Codex => &CODEX,
            Self::ClaudeCode => &CLAUDE_CODE,
            Self::Pi => &PI,
        }
    }
}

impl HarnessDefinition {
    /// The launch arguments for `prompt`, which follows `--` so a leading dash is never a flag.
    pub(crate) fn arguments(&self, prompt: &str) -> Vec<OsString> {
        let prompt = if self.reads_at_prefix_as_file && prompt.starts_with('@') {
            format!(" {prompt}")
        } else {
            prompt.to_owned()
        };
        vec![OsString::from("--"), OsString::from(prompt)]
    }
}

/// A harness binary and the `PATH` it should run with.
#[derive(Debug, Eq, PartialEq)]
pub(crate) struct LocatedHarness {
    pub program: PathBuf,
    pub path: OsString,
}

#[derive(Debug, Error)]
pub enum HarnessError {
    #[error(
        "{name} wasn't found on your PATH. Install it or add `{binary}` to your PATH, then try again."
    )]
    NotFound {
        name: &'static str,
        binary: &'static str,
    },
}

/// Finds `definition`'s binary on the login shell's `PATH`, then on `process_path`.
///
/// A GUI app inherits a minimal `PATH`, so the login shell's is searched first.
pub(crate) fn locate_in(
    definition: &HarnessDefinition,
    login_path: Option<&OsStr>,
    process_path: Option<&OsStr>,
) -> Result<LocatedHarness, HarnessError> {
    let directories = unique_directories(login_path.into_iter().chain(process_path));
    let program = directories
        .iter()
        .map(|directory| directory.join(definition.binary))
        .find(|candidate| is_executable(candidate))
        .ok_or(HarnessError::NotFound {
            name: definition.name,
            binary: definition.binary,
        })?;
    let path = std::env::join_paths(&directories).unwrap_or_default();
    Ok(LocatedHarness { program, path })
}

fn unique_directories<'a>(paths: impl Iterator<Item = &'a OsStr>) -> Vec<PathBuf> {
    let mut seen = HashSet::new();
    paths
        .flat_map(|path| std::env::split_paths(path))
        .filter(|directory| !directory.as_os_str().is_empty() && seen.insert(directory.clone()))
        .collect()
}

fn is_executable(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    std::fs::metadata(path)
        .is_ok_and(|metadata| metadata.is_file() && metadata.permissions().mode() & 0o111 != 0)
}

/// The login shell's `PATH`, looked up once in the background so starting an agent never waits on
/// the user's shell startup files.
pub(crate) struct LoginPath(Mutex<LoginPathState>);

enum LoginPathState {
    Pending(JoinHandle<Option<OsString>>),
    Ready(Option<OsString>),
}

impl LoginPath {
    pub(crate) fn spawn(shell: PathBuf) -> Self {
        match thread::Builder::new()
            .name("login-path".to_owned())
            .spawn(move || login_shell_path(&shell))
        {
            Ok(handle) => Self(Mutex::new(LoginPathState::Pending(handle))),
            Err(error) => {
                debug!(%error, "failed to start the login PATH lookup");
                Self::ready(None)
            }
        }
    }

    pub(crate) fn ready(path: Option<OsString>) -> Self {
        Self(Mutex::new(LoginPathState::Ready(path)))
    }

    pub(crate) fn get(&self) -> Option<OsString> {
        let mut state = self
            .0
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if let LoginPathState::Pending(_) = &*state {
            let LoginPathState::Pending(handle) =
                std::mem::replace(&mut *state, LoginPathState::Ready(None))
            else {
                unreachable!("state was just checked to be pending");
            };
            *state = LoginPathState::Ready(handle.join().unwrap_or(None));
        }
        match &*state {
            LoginPathState::Ready(path) => path.clone(),
            LoginPathState::Pending(_) => None,
        }
    }
}

/// Asks an interactive login shell for its `PATH`, where version managers such as nvm and fnm are
/// usually set up. Only `PATH` is read, between markers so startup banners can't be mistaken for it.
fn login_shell_path(shell: &Path) -> Option<OsString> {
    // A file avoids blocking on a full pipe while the shell is being supervised.
    let mut output = tempfile::tempfile().ok()?;
    let child = Command::new(shell)
        .args(["-i", "-l", "-c"])
        .arg("printf '\\n__TWINE_PATH__%s__TWINE_END__\\n' \"$(printenv PATH)\"")
        .stdin(Stdio::null())
        .stdout(output.try_clone().ok()?)
        .stderr(Stdio::null())
        .spawn()
        .map_err(|error| debug!(%error, "failed to start the login shell for PATH lookup"))
        .ok()?;
    let mut child = ShellChild(child);
    let deadline = Instant::now() + LOGIN_SHELL_TIMEOUT;
    loop {
        if output.metadata().ok()?.len() > MAX_LOGIN_SHELL_OUTPUT {
            return None;
        }
        // The shell exiting is enough, even if a background job it started still holds the output.
        if child.0.try_wait().ok()?.is_some() {
            break;
        }
        if Instant::now() >= deadline {
            debug!("login shell PATH lookup timed out");
            return None;
        }
        thread::sleep(Duration::from_millis(5));
    }
    output.rewind().ok()?;
    let mut bytes = Vec::new();
    output
        .take(MAX_LOGIN_SHELL_OUTPUT)
        .read_to_end(&mut bytes)
        .ok()?;
    parse_path(&bytes)
}

/// Terminates the shell on every early return and reaps it on success.
struct ShellChild(Child);

impl Drop for ShellChild {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

fn parse_path(output: &[u8]) -> Option<OsString> {
    let start = find(output, PATH_START)? + PATH_START.len();
    let end = start + find(&output[start..], PATH_END)?;
    let path = &output[start..end];
    (!path.is_empty()).then(|| OsStr::from_bytes(path).to_owned())
}

fn find(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack
        .windows(needle.len())
        .position(|window| window == needle)
}

#[cfg(test)]
mod tests {
    use std::os::unix::fs::PermissionsExt;

    use super::*;

    #[test]
    fn prompt_follows_a_double_dash() {
        let arguments = HarnessId::ClaudeCode.definition().arguments("-fix it");
        assert_eq!(arguments, ["--", "-fix it"].map(OsString::from));
    }

    #[test]
    fn pi_keeps_an_at_prompt_from_being_read_as_a_file() {
        let pi = HarnessId::Pi.definition().arguments("@README.md summarize");
        assert_eq!(pi, ["--", " @README.md summarize"].map(OsString::from));
        let claude = HarnessId::ClaudeCode.definition().arguments("@README.md");
        assert_eq!(claude, ["--", "@README.md"].map(OsString::from));
    }

    #[test]
    fn parses_path_between_markers_and_ignores_banners() {
        assert_eq!(
            parse_path(b"PATH=/wrong\nbanner\n__TWINE_PATH__/a:/b__TWINE_END__\n"),
            Some(OsString::from("/a:/b"))
        );
        assert_eq!(parse_path(b"PATH=/wrong\n"), None);
        assert_eq!(parse_path(b"__TWINE_PATH____TWINE_END__"), None);
    }

    fn fake_shell(directory: &Path, body: &str) -> PathBuf {
        let shell = directory.join("shell");
        std::fs::write(&shell, format!("#!/bin/sh\n{body}\n")).unwrap();
        std::fs::set_permissions(&shell, std::fs::Permissions::from_mode(0o755)).unwrap();
        shell
    }

    #[test]
    fn login_path_comes_from_an_interactive_login_shell() {
        let directory = tempfile::tempdir().unwrap();
        // Like a zsh that only sets up its version manager in the interactive rc file.
        let shell = fake_shell(
            directory.path(),
            "echo banner PATH=/wrong\n[ \"$1 $2\" = '-i -l' ] && printf '\\n__TWINE_PATH__/interactive__TWINE_END__\\n'",
        );

        assert_eq!(
            LoginPath::spawn(shell).get(),
            Some(OsString::from("/interactive"))
        );
    }

    #[test]
    fn a_background_job_holding_the_output_does_not_delay_the_lookup() {
        let directory = tempfile::tempdir().unwrap();
        let shell = fake_shell(
            directory.path(),
            "sleep 30 &\nprintf '\\n__TWINE_PATH__/fast__TWINE_END__\\n'",
        );

        let started = Instant::now();
        let path = login_shell_path(&shell);

        assert_eq!(path, Some(OsString::from("/fast")));
        assert!(started.elapsed() < Duration::from_secs(4));
    }

    #[test]
    fn locates_an_executable_and_reports_a_missing_one() {
        let directory = tempfile::tempdir().expect("a directory should be available");
        let binary = directory.path().join("twine-test-harness");
        std::fs::write(&binary, "#!/bin/sh\n").expect("binary should be written");
        std::fs::set_permissions(&binary, std::fs::Permissions::from_mode(0o755))
            .expect("permissions should be set");
        let found = HarnessDefinition {
            name: "Test",
            binary: "twine-test-harness",
            reads_at_prefix_as_file: false,
        };
        let missing = HarnessDefinition {
            binary: "twine-no-such-harness",
            ..found
        };
        let path = Some(directory.path().as_os_str());

        let located = locate_in(&found, None, path).expect("binary is on PATH");
        let error = locate_in(&missing, None, path).expect_err("a missing binary is not found");

        assert_eq!(located.program, binary);
        assert!(error.to_string().contains("`twine-no-such-harness`"));
    }
}
