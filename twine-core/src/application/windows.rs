use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};

use super::{Application, ApplicationError, DATABASE_FILE_NAME, DEFAULT_EVENT_CAPACITY};
use crate::config::Config;
use crate::folder::Folders;
use crate::store::Store;
use crate::terminal::TranscriptRecorder;

struct WindowStorage {
    recorder: Arc<TranscriptRecorder>,
    windows: usize,
}

/// The registry owns the recorder until the last runtime has stopped its processes. Creation and
/// final shutdown share the lock, so a new window never races the previous recorder's owner lock.
static STORAGE: OnceLock<Mutex<HashMap<PathBuf, WindowStorage>>> = OnceLock::new();

pub(super) struct WindowStorageLease {
    path: PathBuf,
}

impl Drop for WindowStorageLease {
    fn drop(&mut self) {
        let mut storage = STORAGE
            .get_or_init(Mutex::default)
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if let Some(entry) = storage.get_mut(&self.path) {
            entry.windows -= 1;
            if entry.windows == 0 {
                entry.recorder.shutdown();
                storage.remove(&self.path);
            }
        }
    }
}

impl Application {
    /// Creates an independent window runtime sharing durable history with the other windows.
    /// Only the first runtime recovers interrupted work and restores a previously open folder.
    ///
    /// # Errors
    /// Returns an error if storage, recovery, or runtime initialization fails.
    pub fn new_window(data_directory: &Path) -> Result<Self, ApplicationError> {
        std::fs::create_dir_all(data_directory).map_err(|source| {
            crate::store::StoreError::CreateDirectory {
                path: data_directory.into(),
                source,
            }
        })?;
        let path = std::fs::canonicalize(data_directory).map_err(|source| {
            crate::store::StoreError::ResolveDirectory {
                path: data_directory.into(),
                source,
            }
        })?;
        let mut storage = STORAGE
            .get_or_init(Mutex::default)
            .lock()
            .map_err(|_| ApplicationError::Poisoned)?;
        let restore = !storage.contains_key(&path);
        let transcripts = match storage.get(&path) {
            Some(entry) => Arc::clone(&entry.recorder),
            None => Arc::new(TranscriptRecorder::open(&path.join("transcripts"))?),
        };
        let mut store = Store::open(&data_directory.join(DATABASE_FILE_NAME))?;
        if restore {
            store.recover_interrupted_work()?;
        }
        let folders = Folders::for_window(store, restore)?;
        let mut application = Self::with_folders(
            folders,
            Config::load_user(),
            DEFAULT_EVENT_CAPACITY,
            Arc::clone(&transcripts),
            true,
        )?;
        storage
            .entry(path.clone())
            .or_insert_with(|| WindowStorage {
                recorder: transcripts,
                windows: 0,
            })
            .windows += 1;
        application.window_storage = Some(WindowStorageLease { path });
        Ok(application)
    }

    /// Returns every folder that should reopen after app shutdown, including unavailable folders.
    ///
    /// # Errors
    /// Returns an error if the database or runtime state cannot be read.
    pub fn restorable_folders(&self) -> Result<Vec<PathBuf>, ApplicationError> {
        Ok(self.lock_inner()?.folders.restorable_paths()?)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        Command, CommandDisposition, RequestId, TerminalSize, TerminalStatus, TranscriptRead,
        WorkflowKind,
    };
    use std::thread;
    use std::time::{Duration, Instant};

    #[test]
    fn a_new_window_waits_for_final_recording_shutdown() {
        let data = tempfile::tempdir().unwrap();
        let folder = tempfile::tempdir().unwrap();
        let app = Application::new_window(data.path()).unwrap();
        open(&app, folder.path());
        let id = terminal(&app, folder.path());
        let stalled = app.terminal_output.stall_recording_worker(id);
        let key = std::fs::canonicalize(data.path()).unwrap();
        let recorder = Arc::clone(
            &STORAGE
                .get()
                .unwrap()
                .lock()
                .unwrap()
                .get(&key)
                .unwrap()
                .recorder,
        );
        let dropping = thread::spawn(move || drop(app));
        let deadline = Instant::now() + Duration::from_secs(5);
        while !recorder.is_shutting_down() {
            assert!(
                Instant::now() < deadline,
                "shutdown never acquired storage ownership"
            );
            thread::yield_now();
        }
        let path = data.path().to_owned();
        let (sender, receiver) = std::sync::mpsc::channel();
        let opening = thread::spawn(move || {
            let app = Application::new_window(&path);
            sender
                .send(
                    app.as_ref()
                        .map(|app| app.snapshot().unwrap().folders.open_folder.clone())
                        .map_err(ToString::to_string),
                )
                .unwrap();
        });
        assert!(matches!(
            receiver.recv_timeout(Duration::from_millis(25)),
            Err(std::sync::mpsc::RecvTimeoutError::Timeout)
        ));
        drop(stalled);
        dropping.join().unwrap();
        assert_eq!(
            receiver
                .recv_timeout(Duration::from_secs(5))
                .unwrap()
                .unwrap()
                .as_deref(),
            Some(folder.path())
        );
        opening.join().unwrap();
    }

    #[test]
    fn an_additional_missing_restored_window_owns_and_closes_its_entry() {
        let data = tempfile::tempdir().unwrap();
        let missing = tempfile::tempdir().unwrap();
        let missing_path = missing.path().to_owned();
        let available = tempfile::tempdir().unwrap();
        let first = Application::new_window(data.path()).unwrap();
        open(&first, &missing_path);
        let second = Application::new_window(data.path()).unwrap();
        open(&second, available.path());
        drop(first);
        drop(second);
        drop(missing);
        let primary = Application::new_window(data.path()).unwrap();
        let restored = Application::new_window(data.path()).unwrap();
        assert_eq!(
            restored
                .handle_command(
                    RequestId(1),
                    Command::RestoreFolder {
                        path: missing_path.clone()
                    }
                )
                .unwrap()
                .disposition,
            CommandDisposition::Accepted
        );
        assert_eq!(
            restored
                .snapshot()
                .unwrap()
                .folders
                .unavailable_folder
                .unwrap()
                .path,
            missing_path
        );
        restored
            .handle_command(RequestId(2), Command::CloseFolder)
            .unwrap();
        assert_eq!(primary.restorable_folders().unwrap(), [available.path()]);
    }

    fn open(app: &Application, path: &Path) {
        assert_eq!(
            app.handle_command(RequestId(1), Command::OpenFolder { path: path.into() })
                .unwrap()
                .disposition,
            CommandDisposition::Accepted
        );
    }

    fn terminal(app: &Application, path: &Path) -> crate::TerminalId {
        app.handle_command(
            RequestId(2),
            Command::CreateWorkflow {
                folder: path.into(),
                session_id: None,
                kind: WorkflowKind::Terminal,
                roles: vec![],
                size: TerminalSize {
                    rows: 24,
                    columns: 80,
                    pixel_width: 800,
                    pixel_height: 480,
                },
            },
        )
        .unwrap();
        app.snapshot()
            .unwrap()
            .workflows
            .workflows
            .last()
            .unwrap()
            .terminal_ids()[0]
    }

    #[test]
    fn windows_share_history_without_recovering_or_stopping_live_work() {
        let data = tempfile::tempdir().unwrap();
        let a = tempfile::tempdir().unwrap();
        let b = tempfile::tempdir().unwrap();
        let first = Application::new_window(data.path()).unwrap();
        open(&first, a.path());
        let first_id = terminal(&first, a.path());
        let first_workflow = first.snapshot().unwrap().workflows.workflows[0].clone();
        let second = Application::new_window(data.path()).unwrap();
        assert!(second.snapshot().unwrap().folders.open_folder.is_none());
        open(&second, b.path());
        let second_id = terminal(&second, b.path());
        assert_ne!(first_id, second_id);
        assert_eq!(
            first.snapshot().unwrap().workflows.workflows[0],
            first_workflow
        );
        assert_eq!(first.restorable_folders().unwrap(), [b.path(), a.path()]);
        assert!(
            first
                .snapshot()
                .unwrap()
                .terminals
                .iter()
                .all(|t| t.status == TerminalStatus::Running)
        );

        second
            .handle_command(RequestId(3), Command::CloseFolder)
            .unwrap();
        drop(second);
        assert_eq!(first.restorable_folders().unwrap(), [a.path()]);
        first
            .write_terminal_input(first_id, b"printf surviving\\n\n")
            .unwrap();
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            let TranscriptRead::Output(page) =
                first.read_terminal_transcript(first_id, 0, 4096).unwrap()
            else {
                panic!("output expected")
            };
            if String::from_utf8_lossy(&page.bytes).contains("surviving") {
                break;
            }
            assert!(
                Instant::now() < deadline,
                "the remaining window stopped recording"
            );
            thread::sleep(Duration::from_millis(10));
        }
        drop(first);
        let relaunched = Application::new_window(data.path()).unwrap();
        assert_eq!(
            relaunched
                .snapshot()
                .unwrap()
                .folders
                .open_folder
                .as_deref(),
            Some(a.path())
        );
        assert_eq!(relaunched.restorable_folders().unwrap(), [a.path()]);
    }

    #[test]
    fn all_open_folders_restore_and_open_folders_survive_the_recent_limit() {
        let data = tempfile::tempdir().unwrap();
        let folders = (0..12)
            .map(|_| tempfile::tempdir().unwrap())
            .collect::<Vec<_>>();
        let mut windows = Vec::new();
        for folder in &folders {
            let app = Application::new_window(data.path()).unwrap();
            open(&app, folder.path());
            windows.push(app);
        }
        assert_eq!(windows[0].restorable_folders().unwrap().len(), 12);
        assert_eq!(
            windows[11].snapshot().unwrap().folders.recent_folders.len(),
            10
        );
        drop(windows);
        let app = Application::new_window(data.path()).unwrap();
        assert_eq!(app.restorable_folders().unwrap().len(), 12);
        assert_eq!(
            app.snapshot().unwrap().folders.open_folder.as_deref(),
            Some(folders[11].path())
        );
    }

    #[test]
    fn forgetting_another_windows_recent_folder_keeps_its_restore_entry() {
        let data = tempfile::tempdir().unwrap();
        let folder = tempfile::tempdir().unwrap();
        let first = Application::new_window(data.path()).unwrap();
        open(&first, folder.path());
        let second = Application::new_window(data.path()).unwrap();
        std::fs::remove_dir_all(folder.path()).unwrap();
        second
            .handle_command(
                RequestId(1),
                Command::RemoveRecentFolder {
                    path: folder.path().into(),
                },
            )
            .unwrap();
        assert_eq!(
            second.snapshot().unwrap().folders.recent_folders,
            Vec::new()
        );
        assert_eq!(second.restorable_folders().unwrap(), [folder.path()]);
        std::fs::create_dir_all(folder.path()).unwrap();
        drop(first);
        drop(second);
        let relaunched = Application::new_window(data.path()).unwrap();
        assert_eq!(
            relaunched
                .snapshot()
                .unwrap()
                .folders
                .open_folder
                .as_deref(),
            Some(folder.path())
        );
    }

    #[test]
    fn replacing_an_unavailable_restored_folder_clears_its_restore_entry() {
        let data = tempfile::tempdir().unwrap();
        let missing = tempfile::tempdir().unwrap();
        let path = missing.path().to_owned();
        let replacement = tempfile::tempdir().unwrap();
        let first = Application::new_window(data.path()).unwrap();
        open(&first, &path);
        drop(first);
        drop(missing);
        let restored = Application::new_window(data.path()).unwrap();
        assert_eq!(
            restored
                .snapshot()
                .unwrap()
                .folders
                .unavailable_folder
                .unwrap()
                .path,
            path
        );
        let rejected_path = data.path().join("also-missing");
        assert!(matches!(
            restored
                .handle_command(
                    RequestId(4),
                    Command::OpenFolder {
                        path: rejected_path
                    }
                )
                .unwrap()
                .disposition,
            CommandDisposition::Rejected { .. }
        ));
        open(&restored, replacement.path());
        assert_eq!(restored.restorable_folders().unwrap(), [replacement.path()]);
    }
}
