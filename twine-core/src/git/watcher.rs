use std::io::{self, Read};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Condvar, Mutex};
use std::thread::JoinHandle;
use std::time::Duration;

use super::status::{self, GitRepository, GitSnapshot};
use crate::files::{FileKind, access};

#[derive(Default)]
struct State {
    folder: Option<PathBuf>,
    generation: u64,
    snapshot: GitSnapshot,
    stopped: bool,
}

pub(crate) struct GitWatcher {
    shared: Arc<(Mutex<State>, Condvar)>,
    thread: Option<JoinHandle<()>>,
}

impl GitWatcher {
    pub(crate) fn new() -> io::Result<Self> {
        let shared = Arc::new((Mutex::new(State::default()), Condvar::new()));
        let state = Arc::clone(&shared);
        let thread = crate::blocking_worker::spawn("twine-git".into(), move || watch(&state))?;
        Ok(Self {
            shared,
            thread: Some(thread),
        })
    }

    pub(crate) fn poll(&self, folder: Option<&Path>) -> GitSnapshot {
        let mut state = self
            .shared
            .0
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if state.folder.as_deref() != folder {
            state.folder = folder.map(Path::to_owned);
            state.generation = state.generation.wrapping_add(1);
            state.snapshot = GitSnapshot {
                scanning: folder.is_some(),
                ..GitSnapshot::default()
            };
            self.shared.1.notify_one();
        }
        state.snapshot.clone()
    }
}

impl Drop for GitWatcher {
    fn drop(&mut self) {
        self.shared
            .0
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .stopped = true;
        self.shared.1.notify_one();
        if let Some(thread) = self.thread.take()
            && thread.join().is_err()
        {
            tracing::error!("Git status worker panicked");
        }
    }
}

fn watch(shared: &(Mutex<State>, Condvar)) {
    let mut state = shared
        .0
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    loop {
        if state.stopped {
            return;
        }
        let generation = state.generation;
        let folder = state.folder.clone();
        drop(state);
        if let Some(folder) = folder {
            let current = || {
                let state = shared
                    .0
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner);
                !state.stopped && state.generation == generation
            };
            let (roots, error) = discover(&folder, &current);
            let previous = shared
                .0
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .snapshot
                .clone();
            scan(roots, &previous, error, status::read, |snapshot| {
                let mut state = shared
                    .0
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner);
                if state.stopped || state.generation != generation {
                    return false;
                }
                state.snapshot = snapshot.clone();
                true
            });
            state = shared
                .0
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            if state.generation != generation {
                continue;
            }
        } else {
            state = shared
                .0
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            if state.generation != generation {
                continue;
            }
        }
        if state.stopped {
            return;
        }
        state = if state.folder.is_some() {
            shared
                .1
                .wait_timeout(state, Duration::from_secs(2))
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

fn scan(
    roots: Vec<PathBuf>,
    previous: &GitSnapshot,
    error: Option<String>,
    mut read: impl FnMut(&Path) -> Result<GitRepository, status::StatusError>,
    mut publish: impl FnMut(&GitSnapshot) -> bool,
) {
    // Publish every boundary first, including roots that have not returned a status yet.
    let repositories = roots
        .iter()
        .map(|root| {
            previous
                .repositories
                .iter()
                .find(|repo| repo.root == *root)
                .cloned()
                .unwrap_or_else(|| {
                    let mut repository =
                        GitRepository::unavailable(root.clone(), "Reading Git status…".into());
                    repository.loading = true;
                    repository
                })
        })
        .collect();
    let scanning = roots.iter().any(|root| {
        !previous
            .repositories
            .iter()
            .any(|repo| repo.root == *root && !repo.loading)
    });
    let mut snapshot = GitSnapshot {
        repositories,
        scanning,
        error,
    };
    if !publish(&snapshot) {
        return;
    }
    for (index, root) in roots.into_iter().enumerate() {
        snapshot.repositories[index] = read(&root).unwrap_or_else(|error| {
            tracing::debug!(%error, "Git status unavailable");
            GitRepository::unavailable(root, error.to_string())
        });
        if !publish(&snapshot) {
            return;
        }
    }
    snapshot.scanning = false;
    publish(&snapshot);
}

fn discover(folder: &Path, current: &impl Fn() -> bool) -> (Vec<PathBuf>, Option<String>) {
    let mut pending = vec![(folder.to_owned(), 0)];
    let mut roots = Vec::new();
    let mut visited = 0;
    let mut error = None;
    while let Some((path, depth)) = pending.pop() {
        if !current() {
            break;
        }
        visited += 1;
        if visited > 4096 || roots.len() >= 128 {
            error = Some("Repository discovery reached its limit. Open a smaller folder to inspect the remaining repositories.".into());
            break;
        }
        let Ok(entries) = access::entries(folder, &path) else {
            error = Some("Some folders could not be inspected for repositories.".into());
            continue;
        };
        if let Some(metadata) = entries.iter().find(|entry| entry.name == ".git") {
            match metadata.kind {
                FileKind::Directory => roots.push(path.clone()),
                FileKind::File => match primary_git_file(folder, &metadata.path) {
                    Ok(true) => roots.push(path.clone()),
                    Ok(false) => continue, // Do not descend into additional linked worktrees.
                    Err(_) => {
                        error = Some("Some Git metadata could not be inspected.".into());
                        continue;
                    }
                },
                _ => continue,
            }
        }
        for entry in entries
            .into_iter()
            .rev()
            .filter(|entry| entry.kind == FileKind::Directory)
        {
            if matches!(
                entry.name.as_str(),
                ".git"
                    | "node_modules"
                    | "target"
                    | "out"
                    | ".build"
                    | "build"
                    | ".cache"
                    | "vendor"
                    | "Pods"
            ) {
                continue;
            }
            if depth >= 24 {
                error = Some("Repository discovery reached its depth limit. Open a nested folder to inspect it.".into());
            } else {
                pending.push((entry.path, depth + 1));
            }
        }
    }
    roots.sort();
    (roots, error)
}

fn primary_git_file(folder: &Path, path: &Path) -> io::Result<bool> {
    let mut text = String::new();
    access::open_file(folder, path, false)?
        .take(4097)
        .read_to_string(&mut text)?;
    if text.len() > 4096 {
        return Err(io::ErrorKind::InvalidData.into());
    }
    let target = text
        .strip_prefix("gitdir: ")
        .ok_or(io::ErrorKind::InvalidData)?
        .trim_end_matches(['\r', '\n']);
    let git_dir = path
        .parent()
        .ok_or(io::ErrorKind::InvalidInput)?
        .join(target);
    // Submodules and --separate-git-dir checkouts have a gitfile but no commondir.
    match std::fs::symlink_metadata(git_dir.join("commondir")) {
        Ok(_) => Ok(false),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(true),
        Err(error) => Err(error),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::git::status::tests::{git, init};
    use std::fs;
    use std::time::Instant;

    #[test]
    fn publishes_each_result_with_all_boundaries_before_the_next_read_finishes() {
        let root = PathBuf::from("/folder/primary");
        let nested = root.join("nested");
        let roots = vec![root.clone(), nested.clone()];
        let (published_tx, published_rx) = std::sync::mpsc::channel();
        let (release_tx, release_rx) = std::sync::mpsc::channel();
        let thread = std::thread::spawn(move || {
            scan(
                roots,
                &GitSnapshot::default(),
                None,
                |path| {
                    if path == nested {
                        release_rx.recv().unwrap();
                    }
                    let mut repository = GitRepository::unavailable(path.to_owned(), String::new());
                    repository.error = None;
                    Ok(repository)
                },
                |snapshot| {
                    published_tx.send(snapshot.clone()).unwrap();
                    true
                },
            );
        });
        let initial = published_rx.recv_timeout(Duration::from_secs(2)).unwrap();
        assert_eq!(initial.repositories.len(), 2);
        assert!(initial.repositories.iter().all(|repo| repo.loading));
        let ready = published_rx.recv_timeout(Duration::from_secs(2)).unwrap();
        assert!(!ready.repositories[0].loading);
        assert!(ready.repositories[0].error.is_none());
        assert!(ready.repositories[1].loading);
        assert!(published_rx.try_recv().is_err());
        release_tx.send(()).unwrap();
        thread.join().unwrap();
        let snapshots: Vec<_> = published_rx.into_iter().collect();
        assert!(!snapshots.last().unwrap().scanning);
    }

    #[test]
    fn discovers_independent_nested_repositories_but_not_links_or_worktrees() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path();
        let first = root.join("first");
        let nested = root.join("services/api");
        init(&first);
        init(&nested);
        let linked = root.join("linked");
        git(
            &first,
            &["worktree", "add", "-b", "task", linked.to_str().unwrap()],
        );
        std::os::unix::fs::symlink(&first, root.join("alias")).unwrap();
        let (roots, error) = discover(root, &|| true);
        assert_eq!(roots, [first, nested]);
        assert!(error.is_none());
        assert_eq!(discover(&linked, &|| true).0, Vec::<PathBuf>::new());
        assert_eq!(discover(root, &|| false).0, Vec::<PathBuf>::new());
    }

    #[test]
    fn polls_without_waiting_and_drops_results_from_an_old_folder() {
        let temp = tempfile::tempdir().unwrap();
        let other = tempfile::tempdir().unwrap();
        init(temp.path());
        fs::write(temp.path().join("README.md"), "changed").unwrap();
        let watcher = GitWatcher::new().unwrap();
        assert!(watcher.poll(Some(temp.path())).scanning);
        let start = Instant::now();
        assert!(watcher.poll(Some(other.path())).scanning);
        assert!(start.elapsed() < Duration::from_millis(500));
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            let snapshot = watcher.poll(Some(other.path()));
            if !snapshot.scanning {
                assert_eq!(snapshot.repositories, []);
                break;
            }
            assert!(Instant::now() < deadline);
            std::thread::sleep(Duration::from_millis(10));
        }
        assert_eq!(watcher.poll(None), GitSnapshot::default());
    }
}
