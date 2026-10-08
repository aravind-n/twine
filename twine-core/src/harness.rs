//! Built-in harness definitions and finding their binaries.

use std::collections::HashSet;
use std::ffi::{OsStr, OsString};
use std::io::{Read, Seek};
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use thiserror::Error;
use tracing::debug;

use crate::process::CommandChild;

pub(crate) mod antigravity;
pub(crate) mod claude;
pub(crate) mod codex;
pub(crate) mod launch;
pub(crate) mod models;
pub(crate) mod pi;
pub(crate) mod resume;
pub(crate) mod steps;

/// How long to wait for the login shell to report its `PATH`.
const LOGIN_SHELL_TIMEOUT: Duration = Duration::from_secs(5);
const MAX_LOGIN_SHELL_OUTPUT: u64 = 64 * 1024;
const PATH_START: &[u8] = b"__TWINE_PATH__";
const PATH_END: &[u8] = b"__TWINE_END__";

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum HarnessId {
    Codex,
    ClaudeCode,
    Pi,
    Antigravity,
    Omp,
    Opencode,
}

/// How to launch one harness. Adding a harness means adding a definition here.
#[derive(Debug)]
pub(crate) struct HarnessDefinition {
    pub name: &'static str,
    pub binary: &'static str,
    /// Whether the harness reads a prompt that starts with `@` as a file path.
    pub reads_at_prefix_as_file: bool,
    /// A flag for an initial prompt that keeps the harness interactive, when it needs one.
    pub prompt_option: Option<&'static str>,
    /// An explicit interactive subcommand, when positional prompts could select another command.
    pub subcommand: Option<&'static str>,
}

static CODEX: HarnessDefinition = HarnessDefinition {
    name: "Codex",
    binary: "codex",
    reads_at_prefix_as_file: false,
    prompt_option: None,
    subcommand: None,
};
static CLAUDE_CODE: HarnessDefinition = HarnessDefinition {
    name: "Claude Code",
    binary: "claude",
    reads_at_prefix_as_file: false,
    prompt_option: None,
    subcommand: None,
};
static PI: HarnessDefinition = HarnessDefinition {
    name: "pi",
    binary: "pi",
    reads_at_prefix_as_file: true,
    prompt_option: None,
    subcommand: None,
};
static ANTIGRAVITY: HarnessDefinition = HarnessDefinition {
    name: "Antigravity",
    binary: "agy",
    reads_at_prefix_as_file: false,
    prompt_option: Some("--prompt-interactive"),
    subcommand: None,
};
static OMP: HarnessDefinition = HarnessDefinition {
    name: "OMP",
    binary: "omp",
    // OMP treats everything after `--` as literal text, including `@` prefixes.
    reads_at_prefix_as_file: false,
    prompt_option: None,
    subcommand: Some("launch"),
};
static OPENCODE: HarnessDefinition = HarnessDefinition {
    name: "OpenCode",
    binary: "opencode",
    reads_at_prefix_as_file: false,
    prompt_option: Some("--prompt"),
    subcommand: Some("mini"),
};

impl HarnessId {
    pub(crate) fn definition(self) -> &'static HarnessDefinition {
        match self {
            Self::Codex => &CODEX,
            Self::ClaudeCode => &CLAUDE_CODE,
            Self::Pi => &PI,
            Self::Antigravity => &ANTIGRAVITY,
            Self::Omp => &OMP,
            Self::Opencode => &OPENCODE,
        }
    }
}

impl HarnessDefinition {
    /// An interactive prompt, protected from being read as a flag even with a leading dash.
    pub(crate) fn arguments(&self, prompt: &str) -> Vec<OsString> {
        let prompt = if self.reads_at_prefix_as_file && prompt.starts_with('@') {
            format!(" {prompt}")
        } else {
            prompt.to_owned()
        };
        match self.prompt_option {
            Some(option) => vec![OsString::from(format!("{option}={prompt}"))],
            None => vec![OsString::from("--"), OsString::from(prompt)],
        }
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
pub(crate) struct LoginPath {
    state: Mutex<LoginPathState>,
    cancelled: Arc<AtomicBool>,
}

enum LoginPathState {
    Pending(JoinHandle<Option<OsString>>),
    Ready(Option<OsString>),
}

impl LoginPath {
    pub(crate) fn spawn(shell: PathBuf) -> Self {
        let cancelled = Arc::new(AtomicBool::new(false));
        let flag = Arc::clone(&cancelled);
        match crate::blocking_worker::spawn("login-path".into(), move || {
            login_shell_path(&shell, &flag)
        }) {
            Ok(handle) => Self {
                state: Mutex::new(LoginPathState::Pending(handle)),
                cancelled,
            },
            Err(error) => {
                debug!(%error, "failed to start the login PATH lookup");
                Self::ready(None)
            }
        }
    }

    pub(crate) fn ready(path: Option<OsString>) -> Self {
        Self {
            state: Mutex::new(LoginPathState::Ready(path)),
            cancelled: Arc::new(AtomicBool::new(false)),
        }
    }

    pub(crate) fn get(&self) -> Option<OsString> {
        let mut state = self
            .state
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
        if self.cancelled.load(Ordering::Relaxed) {
            return None;
        }
        match &*state {
            LoginPathState::Ready(path) => path.clone(),
            LoginPathState::Pending(_) => None,
        }
    }

    pub(crate) fn cancel(&self) {
        self.cancelled.store(true, Ordering::Relaxed);
    }

    pub(crate) fn shutdown(&self) {
        self.cancel();
        // `get` joins even a cancelled lookup, so every caller waits for process cleanup.
        let _ = self.get();
    }
}

impl Drop for LoginPath {
    fn drop(&mut self) {
        self.shutdown();
    }
}

/// Asks an interactive login shell for its `PATH`, where version managers such as nvm and fnm are
/// usually set up. Only `PATH` is read, between markers so startup banners can't be mistaken for it.
fn login_shell_path(shell: &Path, cancelled: &AtomicBool) -> Option<OsString> {
    if cancelled.load(Ordering::Relaxed) {
        return None;
    }
    // A file avoids blocking on a full pipe while the shell is being supervised.
    let mut output = tempfile::tempfile().ok()?;
    let mut command = Command::new(shell);
    command
        .args(["-i", "-l", "-c"])
        .arg("printf '\\n__TWINE_PATH__%s__TWINE_END__\\n' \"$(printenv PATH)\"")
        .stdin(Stdio::null())
        .stdout(output.try_clone().ok()?)
        .stderr(Stdio::null());
    let mut child = CommandChild::spawn(&mut command)
        .map_err(|error| debug!(%error, "failed to start the login shell for PATH lookup"))
        .ok()?;
    let deadline = Instant::now() + LOGIN_SHELL_TIMEOUT;
    loop {
        if cancelled.load(Ordering::Relaxed) {
            return None;
        }
        if output.metadata().ok()?.len() > MAX_LOGIN_SHELL_OUTPUT {
            return None;
        }
        if child.has_exited().ok()? {
            // Stop background jobs before reaping the shell and releasing its process identity.
            child.finish().ok()?;
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
    use crate::process::tests::FixtureProcess;

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
    fn antigravity_keeps_initial_prompts_interactive_and_literal() {
        let definition = HarnessId::Antigravity.definition();
        assert_eq!(definition.binary, "agy");
        for prompt in ["-fix it", "@README.md summarize", "first line\nsecond line"] {
            assert_eq!(
                definition.arguments(prompt),
                [OsString::from(format!("--prompt-interactive={prompt}"))]
            );
        }
    }

    #[test]
    fn omp_treats_flag_file_and_command_shaped_prompts_as_literal_text() {
        let definition = HarnessId::Omp.definition();
        assert_eq!(definition.binary, "omp");
        assert_eq!(definition.subcommand, Some("launch"));
        for prompt in ["-fix it", "@README.md", "models", "line one\nline two"] {
            assert_eq!(
                definition.arguments(prompt),
                ["--", prompt].map(OsString::from)
            );
        }
    }

    #[test]
    fn opencode_keeps_prompts_out_of_its_directory_and_command_arguments() {
        let definition = HarnessId::Opencode.definition();
        assert_eq!(definition.binary, "opencode");
        assert_eq!(definition.subcommand, Some("mini"));
        for prompt in ["-fix it", "@README.md", "models", "line one\nline two"] {
            assert_eq!(
                definition.arguments(prompt),
                [OsString::from(format!("--prompt={prompt}"))]
            );
        }
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
        let pid_path = directory.path().join("child.pid");
        let shell = fake_shell(
            directory.path(),
            &format!(
                "sleep 60 & echo $! > '{}'; printf '\\n__TWINE_PATH__/fast__TWINE_END__\\n'",
                pid_path.display()
            ),
        );

        let started = Instant::now();
        let path = login_shell_path(&shell, &AtomicBool::new(false));

        assert_eq!(path, Some(OsString::from("/fast")));
        assert!(started.elapsed() < Duration::from_secs(4));
        FixtureProcess::read(&pid_path).assert_stopped();
    }

    #[test]
    fn dropping_an_unused_login_path_stops_and_joins_its_shell() {
        let directory = tempfile::tempdir().unwrap();
        let pid_path = directory.path().join("shell.pid");
        let shell = fake_shell(
            directory.path(),
            &format!("echo $$ > '{}'; exec sleep 60", pid_path.display()),
        );
        let path = LoginPath::spawn(shell);
        let shell = FixtureProcess::read(&pid_path);
        let started = Instant::now();
        drop(path);
        assert!(started.elapsed() < Duration::from_secs(2));
        assert!(
            !shell.is_running(),
            "shutdown reaps the login shell before returning"
        );
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
            prompt_option: None,
            subcommand: None,
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
