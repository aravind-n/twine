use std::fs::File;
use std::io::{self, Seek, Write};
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};

use rustix::fs::{AtFlags, Mode, OFlags, openat, renameat, unlinkat};

use super::{
    FileContent, FileError, FilePreview, FileVersion, TEXT_LIMIT, access, text, validate_request,
};

pub struct FileSaveRequest {
    pub folder: PathBuf,
    pub path: PathBuf,
    pub text: String,
    pub expected_version: FileVersion,
    pub overwrite: bool,
}

#[derive(Debug)]
pub enum FileSaveOutcome {
    Saved(FilePreview),
    Conflict(FilePreview),
}

pub(crate) fn save(request: &FileSaveRequest) -> Result<FileSaveOutcome, FileError> {
    validate_request(&request.folder, &[], Some(&request.path))?;
    if request.text.len() as u64
        + if request.expected_version.utf8_bom {
            3
        } else {
            0
        }
        > TEXT_LIMIT
    {
        return Err(FileError::TextTooLarge);
    }
    if !text::is_text(request.text.as_bytes()) {
        return Err(FileError::UnsupportedSave);
    }
    let parent = request.path.parent().ok_or(FileError::InvalidRequest)?;
    let directory = access::open_file(&request.folder, parent, true)?;
    save_in_directory(request, directory)
}

fn save_in_directory(
    request: &FileSaveRequest,
    directory: File,
) -> Result<FileSaveOutcome, FileError> {
    check_parent(request, &directory)?;
    let name = request.path.file_name().ok_or(FileError::InvalidRequest)?;
    let current = text::preview_from_file(&request.path, access::open_child(&directory, name));
    if !request.overwrite && current.version.as_ref() != Some(&request.expected_version) {
        return Ok(FileSaveOutcome::Conflict(current));
    }
    if !matches!(current.content, FileContent::Text(_) | FileContent::Missing) {
        return Err(FileError::UnsupportedSave);
    }
    let mode = if current.content == FileContent::Missing {
        0o600
    } else {
        let original = access::open_child(&directory, name)?;
        let permissions = original.metadata()?.permissions();
        if permissions.readonly() {
            return Err(FileError::Save(io::ErrorKind::PermissionDenied.into()));
        }
        permissions.mode() & 0o777
    };
    let mut temporary = TemporarySave::new(directory)?;
    if request.expected_version.utf8_bom {
        temporary.file.write_all(b"\xef\xbb\xbf")?;
    }
    temporary.file.write_all(request.text.as_bytes())?;
    temporary
        .file
        .set_permissions(std::fs::Permissions::from_mode(mode))?;
    temporary.file.sync_all()?;

    // Recheck after staging the bytes, immediately before replacing the directory entry.
    // External writers do not share our lock; no portable filesystem operation is a compare-and-swap.
    let latest = text::preview_from_file(
        &request.path,
        access::open_child(&temporary.directory, name),
    );
    if latest != current {
        return Ok(FileSaveOutcome::Conflict(latest));
    }
    check_parent(request, &temporary.directory)?;
    renameat(
        &temporary.directory,
        temporary.name.as_str(),
        &temporary.directory,
        name,
    )
    .map_err(io::Error::from)?;
    temporary.file.rewind()?;
    let (content, version) = text::read_file(&temporary.file)?;
    Ok(FileSaveOutcome::Saved(FilePreview {
        path: request.path.clone(),
        content,
        version,
    }))
}

fn check_parent(request: &FileSaveRequest, directory: &File) -> Result<(), FileError> {
    let parent = request.path.parent().ok_or(FileError::InvalidRequest)?;
    let current = access::open_file(&request.folder, parent, true)?.metadata()?;
    let pinned = directory.metadata()?;
    if (current.dev(), current.ino()) != (pinned.dev(), pinned.ino()) {
        return Err(FileError::Save(io::Error::other(
            "The parent folder moved or was replaced. Reopen the file.",
        )));
    }
    Ok(())
}

/// Staging and cleanup both use the pinned parent descriptor, even if its path is renamed.
struct TemporarySave {
    directory: File,
    file: File,
    name: String,
}

impl TemporarySave {
    fn new(directory: File) -> io::Result<Self> {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        for _ in 0..100 {
            let name = format!(
                ".twine-save-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            );
            match openat(
                &directory,
                name.as_str(),
                OFlags::CREATE | OFlags::EXCL | OFlags::RDWR | OFlags::CLOEXEC,
                Mode::RUSR | Mode::WUSR,
            ) {
                Ok(file) => {
                    return Ok(Self {
                        directory,
                        file: File::from(file),
                        name,
                    });
                }
                Err(rustix::io::Errno::EXIST) => {}
                Err(error) => return Err(error.into()),
            }
        }
        Err(io::Error::new(
            io::ErrorKind::AlreadyExists,
            "Could not create a temporary save file.",
        ))
    }
}

impl Drop for TemporarySave {
    fn drop(&mut self) {
        let _ = unlinkat(&self.directory, self.name.as_str(), AtFlags::empty());
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::path::Path;

    fn request(folder: &Path, path: &Path, replacement: &str) -> FileSaveRequest {
        FileSaveRequest {
            folder: folder.to_owned(),
            path: path.to_owned(),
            text: replacement.into(),
            expected_version: text::read_preview(folder, path).version.unwrap(),
            overwrite: false,
        }
    }

    #[test]
    fn replaced_parent_cannot_redirect_an_overwrite() {
        let root = tempfile::tempdir().unwrap();
        let parent = root.path().join("child");
        let moved = root.path().join("moved");
        fs::create_dir(&parent).unwrap();
        let path = parent.join("file");
        fs::write(&path, "original").unwrap();
        let mut edit = request(root.path(), &path, "my edits");
        edit.overwrite = true;
        let pinned = access::open_file(root.path(), &parent, true).unwrap();
        fs::rename(&parent, &moved).unwrap();
        fs::create_dir(&parent).unwrap();
        fs::write(&path, "replacement").unwrap();
        assert!(matches!(
            save_in_directory(&edit, pinned),
            Err(FileError::Save(_))
        ));
        assert_eq!(fs::read_to_string(&path).unwrap(), "replacement");
        assert_eq!(fs::read_to_string(moved.join("file")).unwrap(), "original");
    }

    #[test]
    fn saves_atomically_and_preserves_bom_line_endings_and_permissions() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("script");
        fs::write(&path, "\u{feff}first\r\n🌲\n").unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o751)).unwrap();
        let mut edit = request(root.path(), &path, "edited\r\n🌲\n");
        let FileSaveOutcome::Saved(saved) = save(&edit).unwrap() else {
            panic!("save conflicted")
        };
        assert_eq!(fs::read_to_string(&path).unwrap(), "\u{feff}edited\r\n🌲\n");
        assert_eq!(
            fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o751
        );
        assert_eq!(saved, text::read_preview(root.path(), &path));
        assert_eq!(fs::read_dir(root.path()).unwrap().count(), 1);
        edit.expected_version = saved.version.unwrap();
        edit.text = String::new();
        assert!(matches!(save(&edit).unwrap(), FileSaveOutcome::Saved(_)));
        assert_eq!(fs::read(&path).unwrap(), b"\xef\xbb\xbf");
    }

    #[test]
    fn changed_replaced_and_deleted_files_conflict_until_explicit_overwrite() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("file");
        for change in 0..3 {
            fs::write(&path, "original").unwrap();
            let mut edit = request(root.path(), &path, "my edits");
            match change {
                0 => fs::write(&path, "external").unwrap(), // Same size, immediate write.
                1 => {
                    let other = root.path().join("other");
                    fs::write(&other, "original").unwrap(); // Even identical bytes have a new identity.
                    fs::rename(other, &path).unwrap();
                }
                _ => fs::remove_file(&path).unwrap(),
            }
            let before = fs::read(&path).ok();
            assert!(matches!(save(&edit).unwrap(), FileSaveOutcome::Conflict(_)));
            assert_eq!(fs::read(&path).ok(), before);
            edit.overwrite = true;
            assert!(matches!(save(&edit).unwrap(), FileSaveOutcome::Saved(_)));
            assert_eq!(fs::read_to_string(&path).unwrap(), "my edits");
        }
    }

    #[test]
    fn refuses_escape_links_special_files_and_oversize_edits() {
        let root = tempfile::tempdir().unwrap();
        let outside = tempfile::tempdir().unwrap();
        let path = root.path().join("file");
        let target = outside.path().join("target");
        fs::write(&path, "inside").unwrap();
        fs::write(&target, "outside").unwrap();
        let mut edit = request(root.path(), &path, "edited");
        edit.text = "a".repeat(usize::try_from(TEXT_LIMIT).unwrap() + 1);
        assert!(matches!(save(&edit), Err(FileError::TextTooLarge)));
        edit.text = "edit\0".into();
        assert!(matches!(save(&edit), Err(FileError::UnsupportedSave)));
        edit.text = "edit".into();
        edit.path = target.clone();
        assert!(matches!(save(&edit), Err(FileError::InvalidRequest)));
        edit.path = path.clone();
        fs::remove_file(&path).unwrap();
        std::os::unix::fs::symlink(&target, &path).unwrap();
        assert!(matches!(save(&edit).unwrap(), FileSaveOutcome::Conflict(_)));
        edit.overwrite = true;
        assert!(matches!(save(&edit), Err(FileError::UnsupportedSave)));
        assert_eq!(fs::read_to_string(target).unwrap(), "outside");
        fs::remove_file(&path).unwrap();
        let _listener = std::os::unix::net::UnixListener::bind(&path).unwrap();
        assert!(matches!(save(&edit), Err(FileError::UnsupportedSave)));
    }
}
