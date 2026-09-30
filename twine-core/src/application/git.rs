use std::path::Path;

use tracing::warn;

use super::{Application, ApplicationError, CommandDisposition, rejection};
use crate::event::{EventKind, StateEvent};
use crate::git::GitError;

impl Application {
    pub(super) fn refresh_git_branch(
        &self,
        folder: &Path,
    ) -> Result<CommandDisposition, ApplicationError> {
        self.refresh_git_branch_with(folder, crate::git::current_branch)
    }

    fn refresh_git_branch_with(
        &self,
        folder: &Path,
        read_branch: impl FnOnce(&Path) -> Result<Option<String>, GitError>,
    ) -> Result<CommandDisposition, ApplicationError> {
        if self.lock_inner()?.folders.state().open_folder.as_deref() != Some(folder) {
            return Ok(CommandDisposition::Rejected {
                code: "folderChanged".to_owned(),
                message: "The folder is no longer open.".to_owned(),
            });
        }
        // Git runs on the command caller's worker, without holding the application state lock.
        let branch = match read_branch(folder) {
            Ok(branch) => branch,
            Err(error) => {
                warn!(%error, "could not read the current Git branch");
                return Ok(rejection("gitBranchReadFailed", &error));
            }
        };
        let mut inner = self.lock_inner()?;
        if inner.folders.update_git_branch(folder, branch) {
            let folders = inner.folders.state().clone();
            inner
                .events
                .append(EventKind::State(StateEvent::FoldersChanged(folders)))?;
        }
        Ok(CommandDisposition::Accepted)
    }
}

#[cfg(test)]
mod tests {
    use super::GitError;
    use crate::{Application, Command, CommandDisposition, RequestId};

    #[test]
    fn failed_reads_preserve_the_known_branch_without_publishing_changes() {
        let folder = tempfile::tempdir().unwrap();
        let app = Application::with_event_capacity(128).unwrap();
        app.handle_command(
            RequestId(1),
            Command::OpenFolder {
                path: folder.path().to_owned(),
            },
        )
        .unwrap();
        app.refresh_git_branch_with(folder.path(), |_| Ok(Some("main".to_owned())))
            .unwrap();
        let before = app.snapshot().unwrap();

        for error in [
            GitError::Timeout,
            GitError::Read(std::io::Error::other("failed branch read")),
            GitError::OutputTooLarge,
        ] {
            let message = error.to_string();
            assert_eq!(
                app.refresh_git_branch_with(folder.path(), |_| Err(error))
                    .unwrap(),
                CommandDisposition::Rejected {
                    code: "gitBranchReadFailed".to_owned(),
                    message,
                }
            );
            let after = app.snapshot().unwrap();
            assert_eq!(after.folders, before.folders);
            assert_eq!(after.sequence, before.sequence);
            assert!(app.events_after(before.sequence, 16).unwrap().is_empty());
        }

        // A successful read with no branch still clears a previously known branch.
        assert_eq!(
            app.refresh_git_branch_with(folder.path(), |_| Ok(None))
                .unwrap(),
            CommandDisposition::Accepted
        );
        let after = app.snapshot().unwrap();
        assert_eq!(after.folders.current_branch, None);
        assert_eq!(after.sequence, before.sequence + 1);
    }

    #[test]
    fn refresh_reports_a_real_read_failure_and_keeps_the_previous_branch() {
        let folder = tempfile::tempdir().unwrap();
        let app = Application::with_event_capacity(128).unwrap();
        app.handle_command(
            RequestId(1),
            Command::OpenFolder {
                path: folder.path().to_owned(),
            },
        )
        .unwrap();
        app.refresh_git_branch_with(folder.path(), |_| Ok(Some("main".to_owned())))
            .unwrap();
        let before = app.snapshot().unwrap();
        std::fs::remove_dir_all(folder.path()).unwrap();

        let receipt = app
            .handle_command(
                RequestId(2),
                Command::RefreshGitBranch {
                    folder: folder.path().to_owned(),
                },
            )
            .unwrap();
        assert!(matches!(receipt.disposition,
            CommandDisposition::Rejected { ref code, .. } if code == "gitBranchReadFailed"));
        let after = app.snapshot().unwrap();
        assert_eq!(after.folders, before.folders);
        assert_eq!(after.sequence, before.sequence);
    }
}
