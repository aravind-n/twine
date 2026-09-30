use std::path::{Path, PathBuf};

use super::{Application, ApplicationError};
use crate::files::{FileError, FileSaveOutcome, FileSaveRequest, FileSnapshot};

impl Application {
    /// Saves a bounded text edit, returning a conflict without writing when the disk version differs.
    /// Contents never enter the event journal. Call on a worker, as this performs disk I/O.
    ///
    /// # Errors
    /// Returns an error for a stale folder, invalid/unsupported paths, oversized text, or failed I/O.
    pub fn save_file(
        &self,
        request: &FileSaveRequest,
    ) -> Result<FileSaveOutcome, ApplicationError> {
        let _commands = self
            .commands
            .lock()
            .map_err(|_| ApplicationError::Poisoned)?;
        if self.lock_inner()?.folders.state().open_folder.as_deref()
            != Some(request.folder.as_path())
        {
            return Err(FileError::FolderChanged.into());
        }
        let result = crate::files::save(request);
        // Drop snapshots and in-flight scans from before this save/conflict check.
        self.files.clear();
        Ok(result?)
    }

    /// Watches only the visible directories and selected file on a dedicated worker. Returns no
    /// snapshot until the first scan completes or while the revision is unchanged. File contents
    /// stay out of the event journal, which would retain old versions. Poll at 500 ms intervals.
    ///
    /// # Errors
    /// Returns an error for a stale folder, invalid paths, or poisoned state locks.
    pub fn poll_files(
        &self,
        folder: &Path,
        directories: &[PathBuf],
        file: Option<&Path>,
        revision: Option<u64>,
    ) -> Result<Option<FileSnapshot>, ApplicationError> {
        let _commands = self
            .commands
            .lock()
            .map_err(|_| ApplicationError::Poisoned)?;
        if self.lock_inner()?.folders.state().open_folder.as_deref() != Some(folder) {
            return Err(FileError::FolderChanged.into());
        }
        Ok(self.files.poll(folder, directories, file, revision)?)
    }
}
