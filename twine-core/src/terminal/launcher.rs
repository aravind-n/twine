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
pub(super) fn default_shell_command(working_directory: &Path) -> CommandBuilder {
    let shell = CommandBuilder::new_default_prog().get_shell();
    let mut command = shell_launcher_command(working_directory, Path::new(&shell));
    command.env("TERM", "xterm-256color");
    command.env("COLORTERM", "truecolor");
    command
}

pub(super) fn shell_launcher_command(working_directory: &Path, shell: &Path) -> CommandBuilder {
    let mut command = CommandBuilder::new("/bin/sh");
    command.args([
        "-c",
        "if cd \"$1\" 2>/dev/null; then printf '\\036'; exec \"$2\" -l; else printf '\\037'; exit 125; fi",
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
