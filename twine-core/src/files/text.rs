use std::fs::{File, Metadata};
use std::hash::{DefaultHasher, Hash, Hasher};
use std::io::{self, Read};
use std::os::unix::fs::MetadataExt;
use std::path::Path;

use super::{FileContent, FilePreview, FileVersion, TEXT_LIMIT, access};

pub(crate) fn read_preview(folder: &Path, path: &Path) -> FilePreview {
    preview_from_file(path, access::open_file(folder, path, false))
}

pub(super) fn preview_from_file(path: &Path, file: io::Result<File>) -> FilePreview {
    let result = file.and_then(|file| read_file(&file));
    let (content, version) = match result {
        Ok(value) => value,
        Err(error) => (
            match error.kind() {
                io::ErrorKind::NotFound => FileContent::Missing,
                io::ErrorKind::Unsupported => FileContent::Unsupported,
                _ => FileContent::Unavailable(error.to_string()),
            },
            None,
        ),
    };
    FilePreview {
        path: path.to_owned(),
        content,
        version,
    }
}

pub(super) fn read_file(file: &File) -> io::Result<(FileContent, Option<FileVersion>)> {
    let before = file.metadata()?;
    if !before.is_file() {
        return Err(io::ErrorKind::Unsupported.into());
    }
    if before.len() > TEXT_LIMIT {
        return Ok((FileContent::TooLarge, None));
    }
    let mut bytes = Vec::new();
    file.take(TEXT_LIMIT + 1).read_to_end(&mut bytes)?;
    if bytes.len() as u64 > TEXT_LIMIT {
        return Ok((FileContent::TooLarge, None));
    }
    let after = file.metadata()?;
    if identity(&before) != identity(&after) {
        return Err(io::Error::other(
            "The file changed while it was being read. Try again.",
        ));
    }
    let utf8_bom = bytes.starts_with(b"\xef\xbb\xbf");
    let mut hash = DefaultHasher::new();
    identity(&after).hash(&mut hash);
    bytes.hash(&mut hash);
    let version = FileVersion {
        fingerprint: format!("{:016x}", hash.finish()),
        utf8_bom,
    };
    if !is_text(&bytes) {
        return Ok((FileContent::Binary, None));
    }
    let text = String::from_utf8(bytes).map_err(|_| io::ErrorKind::InvalidData)?;
    let text = text.strip_prefix('\u{feff}').unwrap_or(&text).to_owned();
    Ok((FileContent::Text(text), Some(version)))
}

pub(super) fn is_text(bytes: &[u8]) -> bool {
    std::str::from_utf8(bytes).is_ok()
        && !bytes
            .iter()
            .any(|byte| *byte == 0 || (*byte < 32 && !matches!(*byte, 9..=13)))
}

fn identity(metadata: &Metadata) -> (u64, u64, u64, i64, i64, i64, i64) {
    (
        metadata.dev(),
        metadata.ino(),
        metadata.len(),
        metadata.mtime(),
        metadata.mtime_nsec(),
        metadata.ctime(),
        metadata.ctime_nsec(),
    )
}
