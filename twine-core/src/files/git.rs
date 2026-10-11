use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use super::{DirectoryListing, FileEntry, FileKind};
use crate::git::status::{GitChangeKind, GitDecoration, GitSnapshot};

pub(super) fn decorate(folder: &Path, directories: &mut [DirectoryListing], git: &GitSnapshot) {
    let mut decorations = BTreeMap::<PathBuf, GitDecoration>::new();
    for repository in &git.repositories {
        for change in &repository.changes {
            if !change.path.starts_with(folder) {
                continue;
            }
            // A nested repository owns its children; its enclosing repo retains gitlink status
            // in its own summary, but must not decorate the nested repository's files.
            if git.repositories.iter().any(|other| {
                other.root != repository.root
                    && other.root.starts_with(&repository.root)
                    && change.path.starts_with(&other.root)
            }) {
                continue;
            }
            let deleted = (change.conflicted
                || change.staged == Some(GitChangeKind::Deleted)
                || change.unstaged == Some(GitChangeKind::Deleted))
                && std::fs::symlink_metadata(&change.path)
                    .is_err_and(|e| e.kind() == std::io::ErrorKind::NotFound);
            decorations.entry(change.path.clone()).or_default().change = Some(change.clone());
            decorations.entry(change.path.clone()).or_default().deleted = deleted;
            let mut ancestor = change.path.parent();
            while let Some(path) = ancestor {
                if !path.starts_with(&repository.root) {
                    break;
                }
                let decoration = decorations.entry(path.to_owned()).or_default();
                decoration.contains_changes = true;
                decoration.contains_conflicts |= change.conflicted;
                ancestor = path.parent();
            }
            if deleted {
                // Include missing intermediate directories so deleted subtrees remain navigable.
                let mut path = change.path.clone();
                while let Some(parent) = path.parent() {
                    if !parent.starts_with(folder) {
                        break;
                    }
                    if let Some(listing) = directories
                        .iter_mut()
                        .find(|listing| listing.path == parent)
                        && !listing.entries.iter().any(|entry| entry.path == path)
                    {
                        if listing.error.is_some()
                            && std::fs::symlink_metadata(parent)
                                .is_err_and(|e| e.kind() == std::io::ErrorKind::NotFound)
                        {
                            listing.error = None;
                        }
                        listing.entries.push(FileEntry {
                            name: path
                                .file_name()
                                .unwrap_or_default()
                                .to_string_lossy()
                                .into_owned(),
                            kind: if path == change.path {
                                FileKind::File
                            } else {
                                FileKind::Directory
                            },
                            path: path.clone(),
                            git: None,
                        });
                    }
                    path = parent.to_owned();
                }
            }
        }
    }
    for directory in directories {
        for entry in &mut directory.entries {
            entry.git = decorations.get(&entry.path).cloned();
        }
        directory.entries.sort_by_cached_key(|entry| {
            (
                entry.kind != FileKind::Directory,
                entry.name.to_lowercase(),
                entry.name.clone(),
            )
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::files::FileBrowser;
    use crate::git::status::{
        read,
        tests::{git, init},
    };
    use std::fs;

    #[test]
    fn a_locally_deleted_conflict_stays_visible_in_files() {
        let temp = tempfile::tempdir().unwrap();
        let folder = temp.path();
        init(folder);
        git(folder, &["checkout", "-b", "other"]);
        fs::write(folder.join("README.md"), "other edit\n").unwrap();
        git(folder, &["commit", "-am", "other"]);
        git(folder, &["checkout", "main"]);
        git(folder, &["rm", "README.md"]);
        git(folder, &["commit", "-m", "delete"]);
        let merge = std::process::Command::new("git")
            .args([
                "-c",
                "user.name=Test",
                "-c",
                "user.email=test@example.invalid",
                "merge",
                "other",
            ])
            .current_dir(folder)
            .output()
            .unwrap();
        assert!(!merge.status.success());
        // Git leaves the other side's file; a user may remove it before resolving the index.
        fs::remove_file(folder.join("README.md")).unwrap();
        let mut browser = FileBrowser {
            git: GitSnapshot {
                repositories: vec![read(folder).unwrap()],
                ..GitSnapshot::default()
            },
            ..FileBrowser::default()
        };
        let snapshot = browser.poll(folder, &[], None, None).unwrap().unwrap();
        let row = snapshot.directories[0]
            .entries
            .iter()
            .find(|entry| entry.name == "README.md")
            .unwrap();
        let decoration = row.git.as_ref().unwrap();
        assert!(decoration.deleted);
        assert!(decoration.change.as_ref().unwrap().conflicted);
    }

    #[test]
    fn deleted_subtrees_and_nested_repository_ownership_survive_lazy_expansion() {
        let temp = tempfile::tempdir().unwrap();
        let folder = temp.path();
        init(folder);
        let nested = folder.join("nested");
        init(&nested);
        fs::create_dir(folder.join("gone")).unwrap();
        fs::write(folder.join("gone/file.txt"), "tracked").unwrap();
        git(folder, &["add", "gone"]);
        git(folder, &["commit", "-m", "directory"]);
        fs::remove_dir_all(folder.join("gone")).unwrap();
        fs::write(nested.join("README.md"), "nested edit").unwrap();
        let mut browser = FileBrowser {
            git: GitSnapshot {
                repositories: vec![read(folder).unwrap(), read(&nested).unwrap()],
                ..GitSnapshot::default()
            },
            ..FileBrowser::default()
        };
        let snapshot = browser
            .poll(folder, &[folder.join("gone"), nested.clone()], None, None)
            .unwrap()
            .unwrap();
        let gone = snapshot
            .directories
            .iter()
            .find(|d| d.path == folder.join("gone"))
            .unwrap();
        assert!(gone.error.is_none());
        assert!(gone.entries[0].git.as_ref().unwrap().deleted);
        let root = snapshot
            .directories
            .iter()
            .find(|d| d.path == folder)
            .unwrap();
        assert_eq!(root.entries.iter().filter(|e| e.name == "gone").count(), 1);
        let nested = snapshot
            .directories
            .iter()
            .find(|d| d.path == nested)
            .unwrap();
        let readme = nested
            .entries
            .iter()
            .find(|e| e.name == "README.md")
            .unwrap();
        let decoration = readme.git.as_ref().unwrap();
        assert!(!decoration.change.as_ref().unwrap().untracked);
        assert_eq!(
            decoration.change.as_ref().unwrap().unstaged,
            Some(GitChangeKind::Modified)
        );
    }
}
