use std::ffi::{OsStr, OsString};
use std::io::Read;
use std::path::{Path, PathBuf};

use portable_pty::CommandBuilder;

use super::TerminalError;

pub(super) fn canonical_working_directory(path: &Path) -> Result<PathBuf, TerminalError> {
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

/// The user's login shell, started in `working_directory` through the launcher handshake.
pub(super) fn default_shell_command(
    working_directory: &Path,
    shell: &Path,
    integrate: bool,
) -> Result<(CommandBuilder, Option<super::shell::ShellIntegration>), TerminalError> {
    let mut command = shell_launcher(working_directory, shell);
    let integration = if integrate {
        super::shell::ShellIntegration::prepare(shell, &mut command)?
    } else {
        None
    };
    if integration.is_none() {
        command.arg("-l");
    }
    set_terminal_environment(&mut command);
    Ok((command, integration))
}

/// The user's login shell.
pub(crate) fn login_shell() -> PathBuf {
    PathBuf::from(CommandBuilder::new_default_prog().get_shell())
}

/// `program` with `arguments`, started in `working_directory` through the launcher handshake.
pub(super) fn program_launcher_command(
    working_directory: &Path,
    program: &Path,
    arguments: &[OsString],
    path: &OsStr,
    environment: &[(&str, &str)],
) -> CommandBuilder {
    let mut command = CommandBuilder::new("/bin/sh");
    command.args([
        "-c",
        "if cd \"$1\" 2>/dev/null; then printf '\\036'; shift; exec \"$@\"; else printf '\\037'; exit 125; fi",
        "twine-program-launcher",
    ]);
    command.arg(working_directory.as_os_str());
    command.arg(program.as_os_str());
    command.args(arguments);
    command.env("PATH", path);
    set_terminal_environment(&mut command);
    for (name, value) in environment {
        command.env(name, value);
    }
    command
}

/// Each PTY belongs to Twine, even when the app was started from another terminal.
/// Inherited Apple Terminal session metadata otherwise installs its Bash EXIT trap,
/// preventing our command hooks and saving state under the parent's session identity.
fn set_terminal_environment(command: &mut CommandBuilder) {
    command.env("TERM", "xterm-256color");
    command.env("COLORTERM", "truecolor");
    command.env("TERM_PROGRAM", "Twine");
    command.env_remove("TERM_PROGRAM_VERSION");
    command.env_remove("TERM_SESSION_ID");
}

#[cfg(test)]
pub(super) fn shell_launcher_command(working_directory: &Path, shell: &Path) -> CommandBuilder {
    let mut command = shell_launcher(working_directory, shell);
    command.arg("-l");
    command
}

fn shell_launcher(working_directory: &Path, shell: &Path) -> CommandBuilder {
    let mut command = CommandBuilder::new("/bin/sh");
    command.args([
        "-c",
        "if cd \"$1\" 2>/dev/null; then printf '\\036'; shift; exec \"$@\"; else printf '\\037'; exit 125; fi",
        "twine-shell-launcher",
    ]);
    command.arg(working_directory.as_os_str());
    command.arg(shell.as_os_str());
    command
}

pub(super) fn verify_working_directory(
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
