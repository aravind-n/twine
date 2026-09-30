use std::fs::File;
use std::io;
use std::path::{Component, Path};

use rustix::fs::{AtFlags, Dir, FileType, Mode, OFlags, open, openat, statat};

use super::{FileEntry, FileKind};

/// Open each component relative to its already-open parent. Renaming a parent or replacing it
/// with a link cannot redirect an in-flight read. Links are never followed inside the folder.
pub(super) fn open_file(folder: &Path, path: &Path, directory: bool) -> io::Result<File> {
    let flags = OFlags::RDONLY | OFlags::CLOEXEC | OFlags::NOFOLLOW | OFlags::NONBLOCK;
    let relative = path
        .strip_prefix(folder)
        .map_err(|_| io::ErrorKind::InvalidInput)?;
    let mut fd = open(folder, flags | OFlags::DIRECTORY, Mode::empty()).map_err(io::Error::from)?;
    let components: Vec<_> = relative.components().collect();
    for (index, component) in components.iter().enumerate() {
        let Component::Normal(name) = component else {
            return Err(io::ErrorKind::InvalidInput.into());
        };
        let stat = statat(&fd, *name, AtFlags::SYMLINK_NOFOLLOW).map_err(io::Error::from)?;
        if !matches!(
            FileType::from_raw_mode(stat.st_mode),
            FileType::Directory | FileType::RegularFile
        ) {
            return Err(io::ErrorKind::Unsupported.into());
        }
        let flags = if directory || index + 1 < components.len() {
            flags | OFlags::DIRECTORY
        } else {
            flags
        };
        fd = openat(&fd, *name, flags, Mode::empty()).map_err(io::Error::from)?;
    }
    Ok(File::from(fd))
}

pub(super) fn entries(folder: &Path, path: &Path) -> io::Result<Vec<FileEntry>> {
    let file = open_file(folder, path, true)?;
    let directory = Dir::read_from(&file).map_err(io::Error::from)?;
    let mut entries = Vec::new();
    for entry in directory {
        let entry = entry.map_err(io::Error::from)?;
        let name = entry.file_name().to_str().map_err(|_| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                "This folder contains a non-UTF-8 filename.",
            )
        })?;
        if matches!(name, "." | "..") {
            continue;
        }
        let kind = match entry.file_type() {
            FileType::Unknown => {
                let stat = statat(&file, entry.file_name(), AtFlags::SYMLINK_NOFOLLOW)
                    .map_err(io::Error::from)?;
                FileType::from_raw_mode(stat.st_mode)
            }
            kind => kind,
        };
        entries.push(FileEntry {
            path: path.join(name),
            name: name.to_owned(),
            kind: match kind {
                FileType::Directory => FileKind::Directory,
                FileType::RegularFile => FileKind::File,
                FileType::Symlink => FileKind::Symlink,
                _ => FileKind::Other,
            },
        });
    }
    entries.sort_by_cached_key(|entry| {
        (
            entry.kind != FileKind::Directory,
            entry.name.to_lowercase(),
            entry.name.clone(),
        )
    });
    Ok(entries)
}

pub(super) fn open_child(directory: &File, name: &std::ffi::OsStr) -> io::Result<File> {
    let stat = statat(directory, name, AtFlags::SYMLINK_NOFOLLOW).map_err(io::Error::from)?;
    if FileType::from_raw_mode(stat.st_mode) != FileType::RegularFile {
        return Err(io::ErrorKind::Unsupported.into());
    }
    let fd = openat(
        directory,
        name,
        OFlags::RDONLY | OFlags::CLOEXEC | OFlags::NOFOLLOW | OFlags::NONBLOCK,
        Mode::empty(),
    )
    .map_err(io::Error::from)?;
    Ok(File::from(fd))
}
