use std::fs;
use std::io::ErrorKind;
use std::path::{Component, Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use thiserror::Error;
use tracing::warn;

use crate::store::{Store, StoreError, StoredFolder};

/// How many recently opened folders Twine remembers.
const MAX_RECENT_FOLDERS: i64 = 10;

/// The open folder and the recent folders the start page lists.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct FolderState {
    /// The open folder's current branch, refreshed on demand and never persisted.
    pub current_branch: Option<String>,
    /// The folder the window shows, or `None` while it shows the start page.
    pub open_folder: Option<PathBuf>,
    /// Recently opened folders, most recent first.
    pub recent_folders: Vec<RecentFolder>,
    /// A folder that just failed to open, so the start page can say why it's showing. Cleared when
    /// a folder opens or closes.
    pub unavailable_folder: Option<UnavailableFolder>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RecentFolder {
    pub path: PathBuf,
    /// Whether nothing, or something other than a folder, is at `path` now. Missing folders stay
    /// listed until removed.
    pub is_missing: bool,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct UnavailableFolder {
    pub path: PathBuf,
    pub reason: UnavailableReason,
}

/// Why a folder can't be opened.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum UnavailableReason {
    /// Nothing is at the path, or something other than a folder is.
    Missing,
    /// The folder can't be read, for example because Twine doesn't have permission.
    Inaccessible,
}

/// Folder state, kept in sync with the store.
#[derive(Debug)]
pub(crate) struct Folders {
    store: Store,
    state: FolderState,
    window_mode: bool,
    data_version: i64,
    /// Durable restore ownership is independent of failed folder-picker attempts.
    owned_path: Option<PathBuf>,
}

impl Folders {
    pub(crate) fn read_store(&self) -> &Store {
        &self.store
    }

    pub(crate) fn store(&mut self) -> &mut Store {
        &mut self.store
    }

    pub(crate) fn update_git_branch(&mut self, folder: &Path, branch: Option<String>) -> bool {
        if self.state.open_folder.as_deref() != Some(folder) || self.state.current_branch == branch
        {
            return false;
        }
        self.state.current_branch = branch;
        true
    }

    /// Loads the recent folders and reopens the folder that was open when Twine last quit. If it
    /// can't be opened, the start page shows and says why. It stays the last open folder, so a
    /// later launch reopens it once it's back, for example when its drive is reconnected.
    pub(crate) fn restore(store: Store) -> Result<Self, StoreError> {
        let mut state = FolderState::default();
        for StoredFolder { path, is_open } in store.recent_folders()? {
            let reason = unavailable_reason(&path);
            if is_open && state.open_folder.is_none() && state.unavailable_folder.is_none() {
                match reason {
                    None => state.open_folder = Some(path.clone()),
                    Some(reason) => {
                        warn!(?reason, "the last open folder can't be reopened");
                        state.unavailable_folder = Some(UnavailableFolder {
                            path: path.clone(),
                            reason,
                        });
                    }
                }
            }
            state.recent_folders.push(RecentFolder {
                is_missing: reason == Some(UnavailableReason::Missing),
                path,
            });
        }
        let data_version = store.data_version()?;
        Ok(Self {
            store,
            state,
            window_mode: false,
            data_version,
            owned_path: None,
        })
    }

    /// Additional windows start blank; only the first restores a previously open folder.
    pub(crate) fn for_window(store: Store, restore: bool) -> Result<Self, StoreError> {
        let restored = if restore {
            store.open_folder_paths()?.into_iter().next()
        } else {
            None
        };
        let mut folders = Self::restore(store)?;
        folders.window_mode = true;
        folders.state.open_folder = None;
        folders.state.unavailable_folder = None;
        folders.owned_path.clone_from(&restored);
        if let Some(path) = restored {
            match unavailable_reason(&path) {
                None => folders.state.open_folder = Some(path),
                Some(reason) => {
                    folders.state.unavailable_folder = Some(UnavailableFolder { path, reason });
                }
            }
        }
        Ok(folders)
    }

    pub(crate) fn restorable_paths(&self) -> Result<Vec<PathBuf>, StoreError> {
        self.store.open_folder_paths()
    }

    /// Refresh shared recents without replacing this window's open folder or processes.
    pub(crate) fn refresh_shared(&mut self) -> Result<bool, StoreError> {
        let version = self.store.data_version()?;
        if !self.window_mode || version == self.data_version {
            return Ok(false);
        }
        self.state.recent_folders = check_recent_folders(self.store.recent_folders()?);
        self.data_version = version;
        Ok(true)
    }

    pub(crate) const fn state(&self) -> &FolderState {
        &self.state
    }

    /// Attaches this window to a saved entry even when the folder is currently unavailable.
    pub(crate) fn restore_path(&mut self, path: &Path) -> Result<(), FolderError> {
        let path = PathBuf::from(normalize(path)?);
        if !self.window_mode || !self.store.open_folder_paths()?.contains(&path) {
            return Err(FolderError::InvalidPath);
        }
        let unavailable = unavailable_reason(&path).map(|reason| UnavailableFolder {
            path: path.clone(),
            reason,
        });
        self.state.open_folder = unavailable.is_none().then(|| path.clone());
        self.owned_path = Some(path);
        self.state.unavailable_folder = unavailable;
        self.state.current_branch = None;
        Ok(())
    }

    /// Opens the folder at `path` and records it as the most recent folder.
    ///
    /// A folder that can't be opened becomes the unavailable folder, and a missing one is marked as
    /// missing in the recent folders.
    pub(crate) fn open(&mut self, path: &Path) -> Result<(), FolderError> {
        let path = normalize(path)?;
        if let Some(reason) = unavailable_reason(Path::new(&path)) {
            let path = PathBuf::from(path);
            for folder in &mut self.state.recent_folders {
                if folder.path == path {
                    folder.is_missing = reason == UnavailableReason::Missing;
                }
            }
            self.state.unavailable_folder = Some(UnavailableFolder { path, reason });
            return Err(match reason {
                UnavailableReason::Missing => FolderError::Missing,
                UnavailableReason::Inaccessible => FolderError::Inaccessible,
            });
        }

        let stored = if self.window_mode {
            self.store.record_window_folder_opened(
                &path,
                unix_millis(),
                MAX_RECENT_FOLDERS,
                self.owned_path.as_deref(),
                false,
            )?
        } else {
            self.store
                .record_folder_opened(&path, unix_millis(), MAX_RECENT_FOLDERS)?
        };
        if self.window_mode {
            self.owned_path = Some(PathBuf::from(&path));
        }
        self.state = FolderState {
            current_branch: None,
            open_folder: Some(PathBuf::from(path)),
            recent_folders: check_recent_folders(stored),
            unavailable_folder: None,
        };
        Ok(())
    }

    /// Closes the open folder, so the window shows the start page now and after the next launch.
    pub(crate) fn close(&mut self) -> Result<(), FolderError> {
        let stored = if self.window_mode {
            self.store
                .record_window_folder_closed(self.owned_path.as_deref())?
        } else {
            self.store.record_folder_closed()?
        };
        self.owned_path = None;
        self.state = FolderState {
            current_branch: None,
            open_folder: None,
            recent_folders: check_recent_folders(stored),
            unavailable_folder: None,
        };
        Ok(())
    }

    /// Forgets the recent folder at `path`.
    pub(crate) fn remove_recent(&mut self, path: &Path) -> Result<(), FolderError> {
        let path = normalize(path)?;
        let stored = if self.window_mode {
            let owns_unavailable = self.owned_path.as_deref() == Some(Path::new(&path))
                && self.state.open_folder.is_none();
            let stored = self
                .store
                .remove_recent_folder_preserving_windows(&path, !owns_unavailable)?;
            if owns_unavailable {
                self.owned_path = None;
            }
            stored
        } else {
            self.store.remove_recent_folder(&path)?
        };
        self.state.recent_folders = check_recent_folders(stored);
        if self
            .state
            .unavailable_folder
            .as_ref()
            .is_some_and(|folder| folder.path == Path::new(&path))
        {
            self.state.unavailable_folder = None;
        }
        Ok(())
    }
}

/// Marks the stored folders that are missing from the file system.
fn check_recent_folders(stored: Vec<StoredFolder>) -> Vec<RecentFolder> {
    stored
        .into_iter()
        .map(|folder| RecentFolder {
            is_missing: unavailable_reason(&folder.path) == Some(UnavailableReason::Missing),
            path: folder.path,
        })
        .collect()
}

/// Returns why the folder at `path` can't be opened, or `None` if it can. Only a missing path counts
/// as missing; other errors, such as a denied permission, may hide a folder that still exists.
fn unavailable_reason(path: &Path) -> Option<UnavailableReason> {
    match fs::metadata(path) {
        Ok(metadata) if metadata.is_dir() => None,
        Ok(_) => Some(UnavailableReason::Missing),
        Err(error) if matches!(error.kind(), ErrorKind::NotFound | ErrorKind::NotADirectory) => {
            Some(UnavailableReason::Missing)
        }
        Err(error) => {
            warn!(kind = %error.kind(), "a folder can't be read");
            Some(UnavailableReason::Inaccessible)
        }
    }
}

/// Returns `path` as UTF-8 text without repeated separators, `.` components, or a trailing
/// separator, so each folder has one stored form.
fn normalize(path: &Path) -> Result<String, FolderError> {
    if !path.is_absolute() || path.components().any(|part| part == Component::ParentDir) {
        return Err(FolderError::InvalidPath);
    }
    path.components()
        .collect::<PathBuf>()
        .into_os_string()
        .into_string()
        .map_err(|_| FolderError::InvalidPath)
}

fn unix_millis() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |elapsed| {
            i64::try_from(elapsed.as_millis()).unwrap_or(i64::MAX)
        })
}

#[derive(Debug, Error)]
pub(crate) enum FolderError {
    #[error("a folder path must be absolute UTF-8 without `..` components")]
    InvalidPath,
    #[error("the folder can't be read")]
    Inaccessible,
    #[error("the folder no longer exists")]
    Missing,
    #[error(transparent)]
    Store(#[from] StoreError),
}

#[cfg(test)]
mod tests {
    use std::os::unix::fs::PermissionsExt;

    use tempfile::TempDir;

    use super::*;

    struct Fixture {
        data: TempDir,
        folders: TempDir,
    }

    impl Fixture {
        fn new() -> Self {
            Self {
                data: tempfile::tempdir().expect("a data directory should be available"),
                folders: tempfile::tempdir().expect("a folder directory should be available"),
            }
        }

        /// Restores folder state from the fixture's database, as a launch does.
        fn launch(&self) -> Folders {
            let store =
                Store::open(&self.data.path().join("twine.db")).expect("the store should open");
            Folders::restore(store).expect("folders should restore")
        }

        fn folder(&self, name: &str) -> PathBuf {
            let path = self.folders.path().join(name);
            fs::create_dir_all(&path).expect("the folder should be created");
            path
        }
    }

    fn present(path: &Path) -> RecentFolder {
        RecentFolder {
            path: path.to_owned(),
            is_missing: false,
        }
    }

    fn missing(path: &Path) -> RecentFolder {
        RecentFolder {
            path: path.to_owned(),
            is_missing: true,
        }
    }

    fn unavailable(path: &Path, reason: UnavailableReason) -> UnavailableFolder {
        UnavailableFolder {
            path: path.to_owned(),
            reason,
        }
    }

    #[test]
    fn the_first_launch_has_no_open_or_recent_folders() {
        let fixture = Fixture::new();
        assert_eq!(*fixture.launch().state(), FolderState::default());
    }

    #[test]
    fn relaunching_reopens_the_last_open_folder() {
        let fixture = Fixture::new();
        let first = fixture.folder("first");
        let second = fixture.folder("second");
        let mut folders = fixture.launch();
        folders.open(&first).expect("first should open");
        folders.open(&second).expect("second should open");
        drop(folders);

        assert_eq!(
            *fixture.launch().state(),
            FolderState {
                current_branch: None,
                open_folder: Some(second.clone()),
                recent_folders: vec![present(&second), present(&first)],
                unavailable_folder: None,
            }
        );
    }

    #[test]
    fn closing_the_folder_shows_the_start_page_after_relaunch() {
        let fixture = Fixture::new();
        let folder = fixture.folder("project");
        let mut folders = fixture.launch();
        folders.open(&folder).expect("the folder should open");
        folders.close().expect("the folder should close");
        assert_eq!(folders.state().open_folder, None);
        drop(folders);

        assert_eq!(
            *fixture.launch().state(),
            FolderState {
                current_branch: None,
                open_folder: None,
                recent_folders: vec![present(&folder)],
                unavailable_folder: None,
            }
        );
    }

    #[test]
    fn a_deleted_last_folder_falls_back_to_the_start_page_until_it_returns() {
        let fixture = Fixture::new();
        let folder = fixture.folder("project");
        let mut folders = fixture.launch();
        folders.open(&folder).expect("the folder should open");
        drop(folders);
        fs::remove_dir(&folder).expect("the folder should be deleted");

        assert_eq!(
            *fixture.launch().state(),
            FolderState {
                current_branch: None,
                open_folder: None,
                recent_folders: vec![missing(&folder)],
                unavailable_folder: Some(unavailable(&folder, UnavailableReason::Missing)),
            }
        );

        fs::create_dir(&folder).expect("the folder should be recreated");
        assert_eq!(
            *fixture.launch().state(),
            FolderState {
                current_branch: None,
                open_folder: Some(folder.clone()),
                recent_folders: vec![present(&folder)],
                unavailable_folder: None,
            }
        );
    }

    #[test]
    fn an_unreadable_folder_is_inaccessible_rather_than_missing() {
        /// Restores the parent's permissions, even if an assertion fails, so the fixture can be
        /// deleted.
        struct Unlock<'a>(&'a Path);

        impl Drop for Unlock<'_> {
            fn drop(&mut self) {
                let _ = fs::set_permissions(self.0, fs::Permissions::from_mode(0o755));
            }
        }

        let fixture = Fixture::new();
        let folder = fixture.folder("parent/project");
        let parent = folder.parent().expect("the folder should have a parent");
        let mut folders = fixture.launch();
        folders.open(&folder).expect("the folder should open");
        drop(folders);

        fs::set_permissions(parent, fs::Permissions::from_mode(0o000))
            .expect("the parent's permissions should change");
        let _unlock = Unlock(parent);
        if fs::metadata(&folder).is_ok() {
            // Running as root, which ignores permissions.
            return;
        }

        let mut folders = fixture.launch();
        assert_eq!(
            *folders.state(),
            FolderState {
                current_branch: None,
                open_folder: None,
                recent_folders: vec![present(&folder)],
                unavailable_folder: Some(unavailable(&folder, UnavailableReason::Inaccessible)),
            }
        );
        assert!(matches!(
            folders.open(&folder),
            Err(FolderError::Inaccessible)
        ));
        assert_eq!(folders.state().recent_folders, [present(&folder)]);
    }

    #[test]
    fn opening_a_missing_recent_folder_marks_it_and_can_remove_it() {
        let fixture = Fixture::new();
        let kept = fixture.folder("kept");
        let deleted = fixture.folder("deleted");
        let mut folders = fixture.launch();
        folders.open(&deleted).expect("the folder should open");
        folders.open(&kept).expect("the folder should open");
        folders.close().expect("the folder should close");
        fs::remove_dir(&deleted).expect("the folder should be deleted");

        assert!(matches!(folders.open(&deleted), Err(FolderError::Missing)));
        assert_eq!(
            *folders.state(),
            FolderState {
                current_branch: None,
                open_folder: None,
                recent_folders: vec![present(&kept), missing(&deleted)],
                unavailable_folder: Some(unavailable(&deleted, UnavailableReason::Missing)),
            }
        );

        folders
            .remove_recent(&deleted)
            .expect("the missing folder should be removed");
        assert_eq!(
            *folders.state(),
            FolderState {
                current_branch: None,
                open_folder: None,
                recent_folders: vec![present(&kept)],
                unavailable_folder: None,
            }
        );
        drop(folders);
        assert_eq!(fixture.launch().state().recent_folders, [present(&kept)]);
    }

    #[test]
    fn reopening_moves_a_folder_to_the_front_and_the_list_is_capped() {
        let fixture = Fixture::new();
        let paths: Vec<_> = (0..12)
            .map(|index| fixture.folder(&format!("folder-{index}")))
            .collect();
        let mut folders = fixture.launch();
        for path in &paths {
            folders.open(path).expect("the folder should open");
        }
        folders.open(&paths[5]).expect("the folder should reopen");

        let recent_paths: Vec<_> = folders
            .state()
            .recent_folders
            .iter()
            .map(|folder| folder.path.clone())
            .collect();
        let mut expected = vec![paths[5].clone()];
        expected.extend(
            paths[2..12]
                .iter()
                .rev()
                .filter(|path| **path != paths[5])
                .cloned(),
        );
        assert_eq!(recent_paths, expected);
        assert_eq!(recent_paths.len(), 10);
    }

    #[test]
    fn paths_are_normalized_and_invalid_paths_are_rejected() {
        let fixture = Fixture::new();
        let folder = fixture.folder("project");
        let mut folders = fixture.launch();
        let untidy = format!("{}//./", folder.display());
        folders
            .open(Path::new(&untidy))
            .expect("an untidy path should open");
        assert_eq!(
            folders.state().open_folder.as_deref(),
            Some(folder.as_path())
        );
        assert_eq!(folders.state().recent_folders, [present(&folder)]);

        for invalid in ["relative/path", "/tmp/../tmp"] {
            assert!(matches!(
                folders.open(Path::new(invalid)),
                Err(FolderError::InvalidPath)
            ));
            assert!(matches!(
                folders.remove_recent(Path::new(invalid)),
                Err(FolderError::InvalidPath)
            ));
        }
        assert_eq!(
            folders.state().open_folder.as_deref(),
            Some(folder.as_path())
        );
    }

    #[test]
    fn a_file_is_not_a_folder() {
        let fixture = Fixture::new();
        let file = fixture.folders.path().join("file.txt");
        fs::write(&file, "text").expect("the file should be written");
        let mut folders = fixture.launch();

        assert!(matches!(folders.open(&file), Err(FolderError::Missing)));
        assert_eq!(
            folders.state().unavailable_folder,
            Some(unavailable(&file, UnavailableReason::Missing))
        );
        assert_eq!(folders.state().recent_folders, []);
    }
}
