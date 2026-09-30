use std::path::{Path, PathBuf};
use std::sync::{Arc, Condvar, Mutex};
use std::thread::JoinHandle;
use std::time::Duration;

use super::{FileBrowser, FileError, FileSnapshot, validate_request};

#[derive(Clone, Eq, PartialEq)]
struct Request {
    folder: PathBuf,
    directories: Vec<PathBuf>,
    file: Option<PathBuf>,
}

#[derive(Default)]
struct State {
    request: Option<Request>,
    generation: u64,
    snapshot: Option<FileSnapshot>,
    stopped: bool,
}

/// A single worker, latest request and latest snapshot. Scans never hold application state or
/// command locks, and rapid selections cannot queue obsolete work or file contents.
pub(crate) struct FileWatcher {
    state: Arc<(Mutex<State>, Condvar)>,
    thread: Option<JoinHandle<()>>,
}

impl FileWatcher {
    pub(crate) fn new() -> Result<Self, FileError> {
        let state = Arc::new((Mutex::new(State::default()), Condvar::new()));
        let shared = Arc::clone(&state);
        let thread = crate::blocking_worker::spawn("twine-files".into(), move || {
            let mut browser = FileBrowser::default();
            watch(&shared, |request| {
                let Some(request) = request else {
                    browser.clear();
                    return None;
                };
                match browser.poll(
                    &request.folder,
                    &request.directories,
                    request.file.as_deref(),
                    None,
                ) {
                    Ok(snapshot) => snapshot,
                    Err(error) => {
                        tracing::error!(%error, "file scan failed");
                        None
                    }
                }
            });
        })
        .map_err(FileError::StartWatcher)?;
        Ok(Self {
            state,
            thread: Some(thread),
        })
    }

    pub(crate) fn clear(&self) {
        let mut state = self
            .state
            .0
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        state.request = None;
        state.snapshot = None;
        state.generation = state.generation.wrapping_add(1);
        self.state.1.notify_one();
    }

    pub(crate) fn poll(
        &self,
        folder: &Path,
        directories: &[PathBuf],
        file: Option<&Path>,
        revision: Option<u64>,
    ) -> Result<Option<FileSnapshot>, FileError> {
        validate_request(folder, directories, file)?;
        let mut directories = directories.to_vec();
        directories.sort();
        directories.dedup();
        let request = Request {
            folder: folder.to_owned(),
            directories,
            file: file.map(Path::to_owned),
        };
        let mut state = self
            .state
            .0
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if state.request.as_ref() != Some(&request) {
            state.request = Some(request);
            state.snapshot = None;
            state.generation = state.generation.wrapping_add(1);
            self.state.1.notify_one();
        }
        Ok(state
            .snapshot
            .as_ref()
            .filter(|snapshot| Some(snapshot.revision) != revision)
            .cloned())
    }
}

impl Drop for FileWatcher {
    fn drop(&mut self) {
        self.state
            .0
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .stopped = true;
        self.state.1.notify_one();
        if let Some(thread) = self.thread.take()
            && thread.join().is_err()
        {
            tracing::error!("file watcher panicked");
        }
    }
}

fn watch(
    shared: &(Mutex<State>, Condvar),
    mut scan: impl FnMut(Option<&Request>) -> Option<FileSnapshot>,
) {
    let mut state = shared
        .0
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    loop {
        if state.stopped {
            return;
        }
        let generation = state.generation;
        let request = state.request.clone();
        drop(state);
        let snapshot = scan(request.as_ref());
        state = shared
            .0
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if state.generation != generation {
            continue;
        }
        state.snapshot = snapshot;
        if state.stopped {
            return;
        }
        state = if state.request.is_some() {
            shared
                .1
                .wait_timeout(state, Duration::from_millis(500))
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .0
        } else {
            shared
                .1
                .wait(state)
                .unwrap_or_else(std::sync::PoisonError::into_inner)
        };
    }
}

#[cfg(test)]
mod tests {
    use std::sync::mpsc;
    use std::thread;
    use std::time::Instant;

    use super::*;

    #[test]
    fn stalled_scan_does_not_block_requests_or_publish_obsolete_results_and_worker_joins() {
        let state = Arc::new((Mutex::new(State::default()), Condvar::new()));
        let shared = Arc::clone(&state);
        let (entered_tx, entered_rx) = mpsc::channel();
        let (release_tx, release_rx) = mpsc::channel();
        let (stopped_tx, stopped_rx) = mpsc::channel();
        let thread = thread::spawn(move || {
            watch(&shared, |request| {
                let request = request?;
                if request.folder == Path::new("/old") {
                    entered_tx.send(()).unwrap();
                    release_rx.recv().unwrap();
                }
                Some(FileSnapshot {
                    revision: 1,
                    folder: request.folder.clone(),
                    directories: Vec::new(),
                    file: None,
                })
            });
            stopped_tx.send(()).unwrap();
        });
        let watcher = FileWatcher {
            state,
            thread: Some(thread),
        };
        assert!(
            watcher
                .poll(Path::new("/old"), &[], None, None)
                .unwrap()
                .is_none()
        );
        entered_rx.recv_timeout(Duration::from_secs(2)).unwrap();
        // The scan is deliberately blocked until after we submit its replacement.
        let start = Instant::now();
        assert!(
            watcher
                .poll(Path::new("/new"), &[], None, None)
                .unwrap()
                .is_none()
        );
        assert!(start.elapsed() < Duration::from_millis(100));
        release_tx.send(()).unwrap();
        let deadline = Instant::now() + Duration::from_secs(2);
        loop {
            if let Some(snapshot) = watcher.poll(Path::new("/new"), &[], None, None).unwrap() {
                assert_eq!(snapshot.folder, Path::new("/new"));
                break;
            }
            assert!(Instant::now() < deadline);
            thread::sleep(Duration::from_millis(5));
        }
        watcher.clear();
        assert!(watcher.state.0.lock().unwrap().snapshot.is_none());
        drop(watcher);
        stopped_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    }
}
