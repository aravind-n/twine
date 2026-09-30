//! Lazy directory listings and a bounded text preview. A dedicated worker watches only expanded
//! directories and the selected file, with a single latest snapshot for the client to poll.
use std::io::{self, Read};
use std::path::{Component, Path, PathBuf};

use thiserror::Error;

mod access;
mod watcher;
pub(crate) use watcher::FileWatcher;

pub const TEXT_LIMIT: u64 = 2 * 1024 * 1024;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct FileEntry {
    pub path: PathBuf,
    pub name: String,
    pub kind: FileKind,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum FileKind {
    Directory,
    File,
    Symlink,
    Other,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DirectoryListing {
    pub path: PathBuf,
    pub entries: Vec<FileEntry>,
    pub error: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum FileContent {
    Text(String),
    Binary,
    TooLarge,
    Missing,
    Unsupported,
    Unavailable(String),
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct FilePreview {
    pub path: PathBuf,
    pub content: FileContent,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct FileSnapshot {
    pub revision: u64,
    pub folder: PathBuf,
    pub directories: Vec<DirectoryListing>,
    pub file: Option<FilePreview>,
}

#[derive(Default)]
pub(crate) struct FileBrowser {
    snapshot: Option<FileSnapshot>,
    revision: u64,
}

impl FileBrowser {
    pub(crate) fn clear(&mut self) {
        self.snapshot = None;
    }

    pub(crate) fn poll(
        &mut self,
        folder: &Path,
        directories: &[PathBuf],
        file: Option<&Path>,
        revision: Option<u64>,
    ) -> Result<Option<FileSnapshot>, FileError> {
        validate_request(folder, directories, file)?;
        let mut paths = directories.to_vec();
        paths.push(folder.to_owned());
        paths.sort();
        paths.dedup();
        let next = FileSnapshot {
            revision: self.revision,
            folder: folder.to_owned(),
            directories: paths
                .iter()
                .map(|path| list_directory(folder, path))
                .collect(),
            file: file.map(|path| FilePreview {
                path: path.to_owned(),
                content: read_text(folder, path),
            }),
        };
        if self.snapshot.as_ref() != Some(&next) {
            self.revision = self
                .revision
                .checked_add(1)
                .ok_or(FileError::RevisionOverflow)?;
            self.snapshot = Some(FileSnapshot {
                revision: self.revision,
                ..next
            });
        }
        Ok(if revision == Some(self.revision) {
            None
        } else {
            self.snapshot.clone()
        })
    }
}

fn validate_request(
    folder: &Path,
    directories: &[PathBuf],
    file: Option<&Path>,
) -> Result<(), FileError> {
    if !folder.is_absolute() || directories.len() > 256 {
        return Err(FileError::InvalidRequest);
    }
    for path in directories
        .iter()
        .map(PathBuf::as_path)
        .chain(file)
        .chain(std::iter::once(folder))
    {
        if !path.starts_with(folder)
            || path
                .components()
                .any(|part| matches!(part, Component::ParentDir))
        {
            return Err(FileError::InvalidRequest);
        }
    }
    Ok(())
}

fn list_directory(folder: &Path, path: &Path) -> DirectoryListing {
    let result = access::entries(folder, path);
    match result {
        Ok(entries) => DirectoryListing {
            path: path.to_owned(),
            entries,
            error: None,
        },
        Err(error) => DirectoryListing {
            path: path.to_owned(),
            entries: Vec::new(),
            error: Some(error.to_string()),
        },
    }
}

fn read_text(folder: &Path, path: &Path) -> FileContent {
    match read_bytes(folder, path) {
        Ok(Some(bytes)) => {
            if bytes
                .iter()
                .any(|byte| *byte == 0 || (*byte < 32 && !matches!(*byte, 9..=13)))
            {
                return FileContent::Binary;
            }
            match String::from_utf8(bytes) {
                Ok(text) => FileContent::Text(text.trim_start_matches('\u{feff}').to_owned()),
                Err(_) => FileContent::Binary,
            }
        }
        Ok(None) => FileContent::TooLarge,
        Err(error) => match error.kind() {
            io::ErrorKind::NotFound => FileContent::Missing,
            io::ErrorKind::Unsupported => FileContent::Unsupported,
            _ => FileContent::Unavailable(error.to_string()),
        },
    }
}

fn read_bytes(folder: &Path, path: &Path) -> io::Result<Option<Vec<u8>>> {
    let file = access::open_file(folder, path, false)?;
    let metadata = file.metadata()?;
    if !metadata.is_file() {
        return Err(io::ErrorKind::Unsupported.into());
    }
    if metadata.len() > TEXT_LIMIT {
        return Ok(None);
    }
    let mut bytes = Vec::new();
    file.take(TEXT_LIMIT + 1).read_to_end(&mut bytes)?;
    Ok((bytes.len() as u64 <= TEXT_LIMIT).then_some(bytes))
}

#[derive(Debug, Error)]
pub enum FileError {
    #[error("The folder is no longer open.")]
    FolderChanged,
    #[error("Could not start file watcher: {0}")]
    StartWatcher(#[source] io::Error),
    #[error("File paths must stay inside the open folder; at most 256 folders can be expanded.")]
    InvalidRequest,
    #[error("File revision counter exhausted.")]
    RevisionOverflow,
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs::{self, OpenOptions};

    #[test]
    fn replacement_links_cannot_redirect_root_or_ancestor_reads() {
        let parent = tempfile::tempdir().unwrap();
        let root = parent.path().join("root");
        let outside = parent.path().join("outside");
        fs::create_dir_all(root.join("child")).unwrap();
        fs::create_dir_all(&outside).unwrap();
        fs::write(root.join("child/file"), "inside").unwrap();
        fs::write(outside.join("file"), "outside").unwrap();
        let mut opened = access::open_file(&root, &root.join("child/file"), false).unwrap();
        fs::rename(root.join("child"), root.join("moved")).unwrap();
        std::os::unix::fs::symlink(&outside, root.join("child")).unwrap();
        let mut text = String::new();
        opened.read_to_string(&mut text).unwrap();
        assert_eq!(text, "inside");
        assert_eq!(
            read_text(&root, &root.join("child/file")),
            FileContent::Unsupported
        );
        fs::rename(&root, parent.path().join("old-root")).unwrap();
        std::os::unix::fs::symlink(&outside, &root).unwrap();
        assert!(list_directory(&root, &root).error.is_some());
        assert!(!matches!(
            read_text(&root, &root.join("file")),
            FileContent::Text(_)
        ));
    }

    #[test]
    fn lists_only_requested_children_and_keeps_empty_directories() {
        let root = tempfile::tempdir().unwrap();
        let nested = root.path().join("nested");
        fs::create_dir(&nested).unwrap();
        fs::write(nested.join("hidden-until-expanded.txt"), "hello").unwrap();
        fs::create_dir(root.path().join("empty")).unwrap();
        fs::write(root.path().join("a.txt"), "root").unwrap();
        let mut browser = FileBrowser::default();
        let initial = browser.poll(root.path(), &[], None, None).unwrap().unwrap();
        assert_eq!(initial.directories.len(), 1);
        let entries = &initial.directories[0].entries;
        assert_eq!(
            entries
                .iter()
                .map(|entry| entry.name.as_str())
                .collect::<Vec<_>>(),
            ["empty", "nested", "a.txt"]
        );
        let expanded = browser
            .poll(root.path(), &[nested], None, Some(initial.revision))
            .unwrap()
            .unwrap();
        assert_eq!(expanded.directories.len(), 2);
        assert_eq!(
            expanded.directories[1].entries[0].name,
            "hidden-until-expanded.txt"
        );
        assert!(
            browser
                .poll(
                    root.path(),
                    &[root.path().join("nested")],
                    None,
                    Some(expanded.revision)
                )
                .unwrap()
                .is_none()
        );
        let empty = list_directory(root.path(), &root.path().join("empty"));
        assert!(empty.entries.is_empty());
        assert!(empty.error.is_none());
    }

    #[test]
    fn polls_creation_edits_atomic_replacement_rename_deletion_and_recreation() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("file.txt");
        let mut browser = FileBrowser::default();
        let initial = browser
            .poll(root.path(), &[], Some(&path), None)
            .unwrap()
            .unwrap();
        assert_eq!(initial.file.unwrap().content, FileContent::Missing);
        fs::write(&path, "first").unwrap();
        let created = browser
            .poll(root.path(), &[], Some(&path), Some(initial.revision))
            .unwrap()
            .unwrap();
        assert_eq!(
            created.file.unwrap().content,
            FileContent::Text("first".into())
        );
        fs::write(&path, "edits").unwrap(); // Same length, including rapid successive saves.
        let edited = browser
            .poll(root.path(), &[], Some(&path), Some(created.revision))
            .unwrap()
            .unwrap();
        assert_eq!(
            edited.file.unwrap().content,
            FileContent::Text("edits".into())
        );
        let replacement = root.path().join("replacement");
        fs::write(&replacement, "saved").unwrap();
        fs::rename(&replacement, &path).unwrap();
        let replaced = browser
            .poll(root.path(), &[], Some(&path), Some(edited.revision))
            .unwrap()
            .unwrap();
        assert_eq!(
            replaced.file.unwrap().content,
            FileContent::Text("saved".into())
        );
        fs::rename(&path, root.path().join("renamed.txt")).unwrap();
        let renamed = browser
            .poll(root.path(), &[], Some(&path), Some(replaced.revision))
            .unwrap()
            .unwrap();
        assert_eq!(renamed.file.unwrap().content, FileContent::Missing);
        assert_eq!(renamed.directories[0].entries[0].name, "renamed.txt");
        fs::remove_file(root.path().join("renamed.txt")).unwrap();
        let deleted = browser
            .poll(root.path(), &[], Some(&path), Some(renamed.revision))
            .unwrap()
            .unwrap();
        assert!(deleted.directories[0].entries.is_empty());
        fs::write(&path, "back").unwrap();
        assert_eq!(
            browser
                .poll(root.path(), &[], Some(&path), Some(deleted.revision))
                .unwrap()
                .unwrap()
                .file
                .unwrap()
                .content,
            FileContent::Text("back".into())
        );
    }

    #[test]
    fn text_preview_has_bounded_reads_and_explicit_non_text_states() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("file");
        for bytes in [b"hello\0world".as_slice(), &[0xff, 0xfe], &[1, 2, 3]] {
            fs::write(&path, bytes).unwrap();
            assert_eq!(read_text(root.path(), &path), FileContent::Binary);
        }
        fs::write(&path, "\u{feff}hello\r\n🌲\n").unwrap();
        assert_eq!(
            read_text(root.path(), &path),
            FileContent::Text("hello\r\n🌲\n".into())
        );
        fs::write(&path, []).unwrap();
        assert_eq!(
            read_text(root.path(), &path),
            FileContent::Text(String::new())
        );
        fs::write(&path, vec![b'a'; usize::try_from(TEXT_LIMIT).unwrap()]).unwrap();
        assert!(matches!(
            read_text(root.path(), &path),
            FileContent::Text(_)
        ));
        OpenOptions::new()
            .write(true)
            .open(&path)
            .unwrap()
            .set_len(TEXT_LIMIT + 1)
            .unwrap();
        assert_eq!(read_text(root.path(), &path), FileContent::TooLarge);
        assert_eq!(
            read_text(root.path(), root.path()),
            FileContent::Unsupported
        );
    }

    #[test]
    fn refuses_path_escape_links_and_special_files() {
        let root = tempfile::tempdir().unwrap();
        let outside = tempfile::tempdir().unwrap();
        let link = root.path().join("link");
        std::os::unix::fs::symlink(outside.path(), &link).unwrap();
        assert_eq!(read_text(root.path(), &link), FileContent::Unsupported);
        assert!(list_directory(root.path(), &link).error.is_some());
        let socket = root.path().join("socket");
        let _listener = std::os::unix::net::UnixListener::bind(&socket).unwrap();
        assert_eq!(read_text(root.path(), &socket), FileContent::Unsupported);
        let mut browser = FileBrowser::default();
        for path in [outside.path().to_owned(), root.path().join("../escape")] {
            assert!(matches!(
                browser.poll(root.path(), &[], Some(&path), None),
                Err(FileError::InvalidRequest)
            ));
        }
    }
}
