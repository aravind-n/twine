//! Content-addressed full details. Timeline snapshots carry small previews; readers page the
//! original UTF-8 without truncating what was recorded. Files are private to Twine.

use std::fmt::Write as _;
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};

use sha2::{Digest, Sha256};

use super::StoreError;

#[derive(Debug)]
pub(super) struct TracePayloads {
    directory: PathBuf,
    _temporary: Option<tempfile::TempDir>,
}

impl TracePayloads {
    pub(super) fn prune(
        &self,
        budget: u64,
        protected: &std::collections::HashSet<String>,
        clear: bool,
    ) -> Result<(u64, u64), StoreError> {
        let mut files = Vec::new();
        let mut total = 0;
        for entry in std::fs::read_dir(&self.directory).map_err(StoreError::TracePayload)? {
            let entry = entry.map_err(StoreError::TracePayload)?;
            let name = entry.file_name().to_string_lossy().into_owned();
            if name.len() != 64
                || !name.bytes().all(|b| b.is_ascii_hexdigit())
                || !entry
                    .file_type()
                    .map_err(StoreError::TracePayload)?
                    .is_file()
            {
                continue;
            }
            let metadata = entry.metadata().map_err(StoreError::TracePayload)?;
            total += metadata.len();
            files.push((
                name,
                metadata.len(),
                metadata.modified().unwrap_or(std::time::UNIX_EPOCH),
            ));
        }
        files.sort_by_key(|f| f.2);
        let mut count = files.len() as u64;
        for (name, bytes, _) in files {
            if protected.contains(&name) || (!clear && total <= budget) {
                continue;
            }
            match std::fs::remove_file(self.directory.join(name)) {
                Ok(()) => {
                    total -= bytes;
                    count -= 1;
                }
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
                Err(e) => return Err(StoreError::TracePayload(e)),
            }
        }
        Ok((total, count))
    }
    pub(super) fn save_file(&self, path: &Path) -> Result<(String, u64), StoreError> {
        let mut source = std::fs::File::open(path).map_err(StoreError::TracePayload)?;
        let mut file =
            tempfile::NamedTempFile::new_in(&self.directory).map_err(StoreError::TracePayload)?;
        let mut hash = Sha256::new();
        let mut buffer = vec![0; 64 * 1024];
        let mut total = 0;
        loop {
            let count = source.read(&mut buffer).map_err(StoreError::TracePayload)?;
            if count == 0 {
                break;
            }
            hash.update(&buffer[..count]);
            file.write_all(&buffer[..count])
                .map_err(StoreError::TracePayload)?;
            total += count as u64;
        }
        let mut key = String::with_capacity(64);
        for byte in hash.finalize() {
            let _ = write!(key, "{byte:02x}");
        }
        file.as_file()
            .sync_all()
            .map_err(StoreError::TracePayload)?;
        match file.persist_noclobber(self.directory.join(&key)) {
            Ok(_) => {}
            Err(error) if error.error.kind() == std::io::ErrorKind::AlreadyExists => {}
            Err(error) => return Err(StoreError::TracePayload(error.error)),
        }
        Ok((key, total))
    }
    pub(super) fn new(database: Option<&str>) -> Result<Self, StoreError> {
        let (directory, temporary) = if let Some(path) = database.filter(|p| !p.is_empty()) {
            (Path::new(path).with_extension("trace-details"), None)
        } else {
            let temp = tempfile::tempdir().map_err(StoreError::TracePayload)?;
            (temp.path().to_owned(), Some(temp))
        };
        std::fs::create_dir_all(&directory).map_err(StoreError::TracePayload)?;
        Ok(Self {
            directory,
            _temporary: temporary,
        })
    }

    pub(super) fn save(&self, text: &str) -> Result<Option<String>, StoreError> {
        if text.len() <= crate::harness::steps::MAX_DETAIL_BYTES {
            return Ok(None);
        }
        let mut key = String::with_capacity(64);
        for byte in Sha256::digest(text.as_bytes()) {
            let _ = write!(key, "{byte:02x}");
        }
        let path = self.directory.join(&key);
        if !path.exists() {
            let mut file = tempfile::NamedTempFile::new_in(&self.directory)
                .map_err(StoreError::TracePayload)?;
            file.write_all(text.as_bytes())
                .map_err(StoreError::TracePayload)?;
            file.as_file()
                .sync_all()
                .map_err(StoreError::TracePayload)?;
            match file.persist_noclobber(path) {
                Ok(_) => {}
                Err(error) if error.error.kind() == std::io::ErrorKind::AlreadyExists => {}
                Err(error) => return Err(StoreError::TracePayload(error.error)),
            }
        }
        Ok(Some(key))
    }

    pub(super) fn read(
        &self,
        key: &str,
        offset: u64,
        limit: usize,
    ) -> Result<(String, u64), StoreError> {
        if key.len() != 64 || !key.bytes().all(|b| b.is_ascii_hexdigit()) {
            return Err(StoreError::InvalidIdentifier);
        }
        let mut file =
            std::fs::File::open(self.directory.join(key)).map_err(StoreError::TracePayload)?;
        let total = file.metadata().map_err(StoreError::TracePayload)?.len();
        file.seek(SeekFrom::Start(offset))
            .map_err(StoreError::TracePayload)?;
        let mut bytes = Vec::new();
        file.take(limit as u64)
            .read_to_end(&mut bytes)
            .map_err(StoreError::TracePayload)?;
        let mut end = bytes.len();
        while std::str::from_utf8(&bytes[..end]).is_err() && bytes.len() - end < 4 {
            end -= 1;
        }
        let text = std::str::from_utf8(&bytes[..end])
            .map_err(|_| StoreError::InvalidIdentifier)?
            .to_owned();
        Ok((text, total))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn full_details_survive_restart_and_utf8_page_boundaries() {
        let temp = tempfile::tempdir().unwrap();
        let database = temp.path().join("twine.db");
        let original = "☃".repeat(20_000);
        let key = TracePayloads::new(database.to_str())
            .unwrap()
            .save(&original)
            .unwrap()
            .unwrap();
        let payloads = TracePayloads::new(database.to_str()).unwrap();
        let mut result = String::new();
        while result.len() < original.len() {
            let (page, total) = payloads.read(&key, result.len() as u64, 4096).unwrap();
            assert_eq!(total, original.len() as u64);
            assert_ne!(page, "");
            result.push_str(&page);
        }
        assert_eq!(result, original);
    }
}
