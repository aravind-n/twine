use std::path::Path;

use tracing::warn;

use super::{Application, ApplicationError, CommandDisposition};
use crate::event::{EventKind, StateEvent};

impl Application {
    pub(super) fn refresh_git_branch(
        &self,
        folder: &Path,
    ) -> Result<CommandDisposition, ApplicationError> {
        if self.lock_inner()?.folders.state().open_folder.as_deref() != Some(folder) {
            return Ok(CommandDisposition::Rejected {
                code: "folderChanged".to_owned(),
                message: "The folder is no longer open.".to_owned(),
            });
        }
        // Git runs on the command caller's worker, without holding the application state lock.
        let branch = match crate::git::current_branch(folder) {
            Ok(branch) => branch,
            Err(error) => {
                warn!(%error, "could not read the current Git branch");
                None
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
