use std::collections::{BTreeMap, HashSet, VecDeque};
use std::fs::{self, File, OpenOptions, TryLockError};
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};

use tracing::warn;

use super::{Limits, Recording, TranscriptError, TranscriptPage, TranscriptRead, TranscriptSize};
use crate::terminal::{TerminalChunk, TerminalId, TerminalSize};

const MAGIC: &[u8; 8] = b"TWINE-T1";
const SIZE_MAGIC: &[u8; 8] = b"TWINE-S1";
const MAX_SIZE_ENTRIES: usize = 8192;
const METADATA: &str = "metadata";
const NEXT_METADATA: &str = "metadata.next";
// Each of the two manifest files is capped at 1 MiB, including a replacement in progress.
const MAX_METADATA_BYTES: usize = 1024 * 1024;

#[derive(Clone, Debug)]
struct Segment {
    id: u64,
    terminal_id: u64,
    start: u64,
    length: u64,
}

struct Manifest {
    next_terminal_id: u64,
    next_segment_id: u64,
    ends: BTreeMap<u64, u64>,
    segments: VecDeque<Segment>,
    sizes: VecDeque<(u64, TranscriptSize)>,
}

impl Default for Manifest {
    fn default() -> Self {
        Self {
            next_terminal_id: 1,
            next_segment_id: 1,
            ends: BTreeMap::new(),
            segments: VecDeque::new(),
            sizes: VecDeque::new(),
        }
    }
}

pub(super) struct Storage {
    directory: PathBuf,
    // The lock is held until the storage worker exits, including orderly queue draining.
    ownership: File,
    manifest: Manifest,
    limits: Limits,
}

impl Drop for Storage {
    fn drop(&mut self) {
        // Closing alone leaves flock held by descriptors inherited across fork. Unlock after the
        // owning worker stops, even if a child has not yet reached exec/descriptor cleanup.
        if let Err(error) = self.ownership.unlock() {
            warn!(%error, "failed to release terminal transcript directory ownership");
        }
    }
}

impl Storage {
    pub(super) fn open(directory: &Path, limits: Limits) -> Result<Self, TranscriptError> {
        validate_limits(limits)?;
        fs::create_dir_all(directory)?;
        let ownership = private_file()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(directory.join("owner.lock"))?;
        ownership.try_lock().map_err(|error| match error {
            TryLockError::WouldBlock => TranscriptError::AlreadyOpen,
            TryLockError::Error(error) => TranscriptError::Io(error),
        })?;
        // Own the lock before decoding/recovery, so initialization failures unlock too.
        let mut storage = Self {
            directory: directory.into(),
            ownership,
            manifest: Manifest::default(),
            limits,
        };
        let path = directory.join(METADATA);
        let manifest = match File::open(&path) {
            Ok(file) => Manifest::decode(file, limits)?,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                // Losing the manifest must not reset identifiers in an existing store.
                recover_initial_manifest(directory)?;
                Manifest::default()
            }
            Err(error) => return Err(error.into()),
        };
        storage.manifest = manifest;
        storage.recover()?;
        storage.persist()?;
        Ok(storage)
    }

    pub(super) fn allocate(&mut self) -> Result<TerminalId, TranscriptError> {
        let id = self.manifest.next_terminal_id;
        self.manifest.next_terminal_id = id.checked_add(1).ok_or(TranscriptError::Overflow)?;
        let removed = self.make_entry(id, 0);
        // Allocation and expiration survive reopening before this ID reaches any caller.
        self.persist()?;
        self.remove_files(&removed)?;
        Ok(TerminalId::from_value(id))
    }

    pub(super) fn append_recording(
        &mut self,
        recording: &Recording,
    ) -> Result<(), TranscriptError> {
        let id = recording.chunk.terminal_id.value();
        if recording.geometry_lost {
            self.manifest.sizes.retain(|(terminal, _)| *terminal != id);
            // A surviving resize at offset zero must not make an incomplete geometry prefix
            // appear replayable again after overflow.
            return self.append_with_sizes(&recording.chunk, &[]);
        }
        for &resize in &recording.sizes {
            if resize.size.rows == 0
                || resize.size.columns == 0
                || resize.offset < recording.chunk.offset
                || resize.offset >= recording.chunk.offset + recording.chunk.bytes.len() as u64
            {
                return Err(TranscriptError::Corrupt("invalid recording geometry"));
            }
        }
        self.append_with_sizes(&recording.chunk, &recording.sizes)
    }

    #[cfg(test)]
    pub(super) fn append(&mut self, chunk: &TerminalChunk) -> Result<(), TranscriptError> {
        self.append_with_sizes(chunk, &[])
    }

    fn append_with_sizes(
        &mut self,
        chunk: &TerminalChunk,
        sizes: &[TranscriptSize],
    ) -> Result<(), TranscriptError> {
        let terminal_id = chunk.terminal_id.value();
        self.check_id(chunk.terminal_id)?;
        if chunk.bytes.is_empty() {
            return Err(TranscriptError::Corrupt("empty recording chunk"));
        }
        if let Some(end) = self.manifest.ends.get(&terminal_id) {
            if *end != chunk.offset {
                return Err(TranscriptError::Corrupt("noncontiguous recording offsets"));
            }
        } else {
            // An active terminal may outlive its metadata under retention pressure. Its producer
            // still owns the absolute offset; everything before that offset has expired.
            let removed = self.make_entry(terminal_id, chunk.offset);
            self.persist()?;
            self.remove_files(&removed)?;
        }
        chunk
            .offset
            .checked_add(u64::try_from(chunk.bytes.len()).map_err(|_| TranscriptError::Overflow)?)
            .ok_or(TranscriptError::Overflow)?;
        let mut remaining = chunk.bytes.as_slice();
        while !remaining.is_empty() {
            let tail = self
                .manifest
                .segments
                .iter()
                .rposition(|segment| segment.terminal_id == terminal_id);
            let available = tail.map_or(self.limits.segment_bytes, |index| {
                self.limits.segment_bytes - self.manifest.segments[index].length
            });
            let available = if available == 0 {
                self.limits.segment_bytes
            } else {
                available
            };
            let count = remaining
                .len()
                .min(usize::try_from(available).map_err(|_| TranscriptError::Overflow)?);
            self.append_piece(terminal_id, &remaining[..count], sizes)?;
            remaining = &remaining[count..];
        }
        Ok(())
    }

    fn append_piece(
        &mut self,
        terminal_id: u64,
        bytes: &[u8],
        sizes: &[TranscriptSize],
    ) -> Result<(), TranscriptError> {
        let length = u64::try_from(bytes.len()).map_err(|_| TranscriptError::Overflow)?;
        let tail = self.writable_tail(terminal_id, length);
        let removed = self.make_room(terminal_id, length, tail.is_none());
        if !removed.is_empty() {
            // Publish the new retained ranges before deleting files; a crash can leave harmless
            // orphan files, but cannot leave the committed manifest pointing at deleted output.
            self.persist()?;
            self.remove_files(&removed)?;
        }
        let tail = self.writable_tail(terminal_id, length);
        let (id, new_segment) = if let Some(index) = tail {
            (self.manifest.segments[index].id, false)
        } else {
            let id = self.manifest.next_segment_id;
            self.manifest.next_segment_id = id.checked_add(1).ok_or(TranscriptError::Overflow)?;
            (id, true)
        };
        let mut options = private_file();
        options.write(true).append(true);
        if new_segment {
            options.create_new(true);
        }
        let mut file = options.open(self.segment_path(id))?;
        file.write_all(bytes)?;
        file.sync_all()?;
        let start = self.manifest.ends[&terminal_id];
        if let Some(index) = tail {
            self.manifest.segments[index].length += length;
        } else {
            self.manifest.segments.push_back(Segment {
                id,
                terminal_id,
                start,
                length,
            });
        }
        self.manifest.ends.insert(
            terminal_id,
            start.checked_add(length).ok_or(TranscriptError::Overflow)?,
        );
        self.manifest.sizes.extend(
            sizes
                .iter()
                .filter(|resize| resize.offset >= start && resize.offset < start + length)
                .map(|resize| (terminal_id, *resize)),
        );
        while self.manifest.sizes.len() > MAX_SIZE_ENTRIES {
            let oldest = self
                .manifest
                .sizes
                .front()
                .expect("size history exceeds its limit")
                .0;
            self.manifest
                .sizes
                .retain(|(terminal, _)| *terminal != oldest);
        }
        // A trailing write without this commit is discarded during recovery.
        self.persist()
    }

    fn writable_tail(&self, terminal_id: u64, length: u64) -> Option<usize> {
        self.manifest
            .segments
            .iter()
            .rposition(|segment| segment.terminal_id == terminal_id)
            .filter(|&index| {
                self.manifest.segments[index].length <= self.limits.segment_bytes - length
            })
    }

    fn make_entry(&mut self, id: u64, end: u64) -> Vec<u64> {
        let mut removed = Vec::new();
        while self.manifest.ends.len() >= self.limits.terminal_count {
            let oldest = *self
                .manifest
                .ends
                .first_key_value()
                .expect("nonzero metadata limit")
                .0;
            self.manifest.ends.remove(&oldest);
            self.manifest
                .sizes
                .retain(|(terminal, _)| *terminal != oldest);
            self.manifest.segments.retain(|segment| {
                if segment.terminal_id == oldest {
                    removed.push(segment.id);
                    false
                } else {
                    true
                }
            });
        }
        self.manifest.ends.insert(id, end);
        removed
    }

    fn make_room(&mut self, terminal_id: u64, length: u64, new_segment: bool) -> Vec<u64> {
        let mut removed = Vec::new();
        while self.retained_bytes(Some(terminal_id)) > self.limits.terminal_bytes - length {
            let index = self
                .manifest
                .segments
                .iter()
                .position(|segment| segment.terminal_id == terminal_id)
                .expect("terminal over its budget has a segment");
            removed.push(
                self.manifest
                    .segments
                    .remove(index)
                    .expect("segment exists")
                    .id,
            );
        }
        while self.retained_bytes(None) > self.limits.total_bytes - length
            || (new_segment && self.manifest.segments.len() >= self.limits.segment_count)
        {
            removed.push(
                self.manifest
                    .segments
                    .pop_front()
                    .expect("store over its budget has a segment")
                    .id,
            );
        }
        removed
    }

    fn retained_bytes(&self, terminal_id: Option<u64>) -> u64 {
        self.manifest
            .segments
            .iter()
            .filter(|segment| terminal_id.is_none_or(|id| segment.terminal_id == id))
            .map(|segment| segment.length)
            .sum()
    }

    pub(super) fn read(
        &self,
        terminal_id: TerminalId,
        offset: u64,
        limit: usize,
    ) -> Result<TranscriptRead, TranscriptError> {
        self.check_id(terminal_id)?;
        let expired = |nearest_retained_offset| TranscriptRead::Expired {
            terminal_id,
            requested_offset: offset,
            nearest_retained_offset,
        };
        let Some(&end_offset) = self.manifest.ends.get(&terminal_id.value()) else {
            return Ok(expired(None));
        };
        if offset > end_offset {
            return Err(TranscriptError::OutOfRange {
                requested: offset,
                end_offset,
            });
        }
        let first = self
            .manifest
            .segments
            .iter()
            .find(|segment| segment.terminal_id == terminal_id.value());
        let retained_offset = first.map_or(end_offset, |segment| segment.start);
        if offset < retained_offset {
            return Ok(expired(first.map(|segment| segment.start)));
        }
        let count = usize::try_from(
            (end_offset - offset).min(u64::try_from(limit).map_err(|_| TranscriptError::Overflow)?),
        )
        .map_err(|_| TranscriptError::Overflow)?;
        let mut bytes = vec![0; count];
        let mut written = 0;
        let mut position = offset;
        for segment in self
            .manifest
            .segments
            .iter()
            .filter(|segment| segment.terminal_id == terminal_id.value())
        {
            let end = segment.start + segment.length;
            if position >= end || written == count {
                continue;
            }
            if position < segment.start {
                return Err(TranscriptError::Corrupt("gap in retained transcript"));
            }
            let length = (count - written)
                .min(usize::try_from(end - position).map_err(|_| TranscriptError::Overflow)?);
            let mut file = File::open(self.segment_path(segment.id))?;
            file.seek(SeekFrom::Start(position - segment.start))?;
            file.read_exact(&mut bytes[written..written + length])?;
            written += length;
            position += u64::try_from(length).map_err(|_| TranscriptError::Overflow)?;
        }
        if written != count {
            return Err(TranscriptError::Corrupt(
                "missing retained transcript bytes",
            ));
        }
        Ok(TranscriptRead::Output(TranscriptPage {
            terminal_id,
            offset,
            next_offset: position,
            end_offset,
            bytes,
            sizes: self
                .manifest
                .sizes
                .iter()
                .filter_map(|(id, resize)| {
                    (*id == terminal_id.value()
                        && resize.offset >= offset
                        && resize.offset < position)
                        .then_some(*resize)
                })
                .collect(),
            replay_available: retained_offset == 0
                && self
                    .manifest
                    .sizes
                    .iter()
                    .find(|(id, _)| *id == terminal_id.value())
                    .is_some_and(|(_, resize)| resize.offset == 0),
        }))
    }

    fn check_id(&self, terminal_id: TerminalId) -> Result<(), TranscriptError> {
        if terminal_id.value() == 0 || terminal_id.value() >= self.manifest.next_terminal_id {
            return Err(TranscriptError::NotFound { terminal_id });
        }
        Ok(())
    }

    fn segment_path(&self, id: u64) -> PathBuf {
        self.directory.join(format!("{id:016x}.bytes"))
    }

    fn persist(&self) -> Result<(), TranscriptError> {
        let bytes = self.manifest.encode()?;
        let mut file = private_file()
            .write(true)
            .create(true)
            .truncate(true)
            .open(self.directory.join(NEXT_METADATA))?;
        file.write_all(&bytes)?;
        file.sync_all()?;
        fs::rename(
            self.directory.join(NEXT_METADATA),
            self.directory.join(METADATA),
        )?;
        self.sync_directory()
    }

    fn remove_files(&self, ids: &[u64]) -> Result<(), TranscriptError> {
        for &id in ids {
            fs::remove_file(self.segment_path(id))?;
        }
        if !ids.is_empty() {
            self.sync_directory()?;
        }
        Ok(())
    }

    fn sync_directory(&self) -> Result<(), TranscriptError> {
        File::open(&self.directory)?.sync_all()?;
        Ok(())
    }

    fn recover(&self) -> Result<(), TranscriptError> {
        let retained: HashSet<_> = self
            .manifest
            .segments
            .iter()
            .map(|segment| segment.id)
            .collect();
        for segment in &self.manifest.segments {
            let file = private_file()
                .write(true)
                .open(self.segment_path(segment.id))?;
            if file.metadata()?.len() < segment.length {
                return Err(TranscriptError::Corrupt("committed segment was truncated"));
            }
            file.set_len(segment.length)?;
            file.sync_all()?;
        }
        for entry in fs::read_dir(&self.directory)? {
            let entry = entry?;
            let name = entry.file_name();
            let name = name.to_string_lossy();
            let orphan = name
                .strip_suffix(".bytes")
                .filter(|stem| stem.len() == 16)
                .and_then(|stem| u64::from_str_radix(stem, 16).ok())
                .is_some_and(|id| !retained.contains(&id));
            if orphan || name == NEXT_METADATA {
                fs::remove_file(entry.path())?;
            }
        }
        self.sync_directory()
    }
}

fn private_file() -> OpenOptions {
    let mut options = OpenOptions::new();
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    options
}

fn recover_initial_manifest(directory: &Path) -> Result<(), TranscriptError> {
    for entry in fs::read_dir(directory)? {
        let entry = entry?;
        if entry.file_name() == "owner.lock" {
            continue;
        }
        if entry.file_name() == NEXT_METADATA {
            let mut pending = Vec::new();
            File::open(entry.path())?
                .take(41)
                .read_to_end(&mut pending)?;
            // No IDs escape the first initialization. Only a prefix of the exact initial
            // manifest is recoverable when the committed manifest never existed.
            if Manifest::default().encode()?.starts_with(&pending) {
                continue;
            }
        }
        return Err(TranscriptError::Corrupt(
            "missing manifest in a nonempty store",
        ));
    }
    Ok(())
}

fn validate_limits(limits: Limits) -> Result<(), TranscriptError> {
    let metadata_bytes = limits
        .terminal_count
        .checked_mul(16)
        .and_then(|bytes| {
            limits
                .segment_count
                .checked_mul(32)
                .and_then(|segments| bytes.checked_add(segments))
        })
        .and_then(|bytes| bytes.checked_add(40));
    if limits.segment_bytes == 0
        || limits.terminal_bytes < limits.segment_bytes
        || limits.total_bytes < limits.terminal_bytes
        || limits.terminal_count == 0
        || limits.segment_count == 0
        || limits.pending_bytes == 0
        || limits.pending_jobs == 0
        || metadata_bytes.is_none_or(|bytes| bytes > MAX_METADATA_BYTES)
    {
        return Err(TranscriptError::InvalidStorageLimits);
    }
    Ok(())
}

impl Manifest {
    fn encode(&self) -> Result<Vec<u8>, TranscriptError> {
        let mut bytes = MAGIC.to_vec();
        for number in [
            self.next_terminal_id,
            self.next_segment_id,
            u64::try_from(self.ends.len()).map_err(|_| TranscriptError::Overflow)?,
            u64::try_from(self.segments.len()).map_err(|_| TranscriptError::Overflow)?,
        ] {
            bytes.extend_from_slice(&number.to_le_bytes());
        }
        for (&id, &end) in &self.ends {
            bytes.extend_from_slice(&id.to_le_bytes());
            bytes.extend_from_slice(&end.to_le_bytes());
        }
        for segment in &self.segments {
            for number in [
                segment.id,
                segment.terminal_id,
                segment.start,
                segment.length,
            ] {
                bytes.extend_from_slice(&number.to_le_bytes());
            }
        }
        if !self.sizes.is_empty() {
            bytes.extend_from_slice(SIZE_MAGIC);
            bytes.extend_from_slice(&(self.sizes.len() as u64).to_le_bytes());
        }
        for (id, resize) in &self.sizes {
            let grid = u64::from(resize.size.rows)
                | (u64::from(resize.size.columns) << 16)
                | (u64::from(resize.size.pixel_width) << 32)
                | (u64::from(resize.size.pixel_height) << 48);
            for number in [*id, resize.offset, grid] {
                bytes.extend_from_slice(&number.to_le_bytes());
            }
        }
        if bytes.len() > MAX_METADATA_BYTES {
            return Err(TranscriptError::Corrupt("manifest exceeds its size limit"));
        }
        Ok(bytes)
    }

    fn decode(file: File, limits: Limits) -> Result<Self, TranscriptError> {
        let mut bytes = Vec::new();
        file.take((MAX_METADATA_BYTES as u64) + 1)
            .read_to_end(&mut bytes)?;
        if bytes.len() > MAX_METADATA_BYTES || !bytes.starts_with(MAGIC) {
            return Err(TranscriptError::Corrupt("invalid manifest header"));
        }
        let mut input = &bytes[8..];
        let next_terminal_id = take_number(&mut input)?;
        let next_segment_id = take_number(&mut input)?;
        let terminal_count =
            usize::try_from(take_number(&mut input)?).map_err(|_| TranscriptError::Overflow)?;
        let segment_count =
            usize::try_from(take_number(&mut input)?).map_err(|_| TranscriptError::Overflow)?;
        if next_terminal_id == 0
            || next_segment_id == 0
            || terminal_count > limits.terminal_count
            || segment_count > limits.segment_count
            || input.len() < terminal_count * 16 + segment_count * 32
        {
            return Err(TranscriptError::Corrupt("invalid manifest counts"));
        }
        let mut ends = BTreeMap::new();
        for _ in 0..terminal_count {
            let id = take_number(&mut input)?;
            let end = take_number(&mut input)?;
            if id == 0 || id >= next_terminal_id || ends.insert(id, end).is_some() {
                return Err(TranscriptError::Corrupt("invalid terminal metadata"));
            }
        }
        let mut segments = VecDeque::new();
        let mut previous_id = 0;
        let mut previous_ends = BTreeMap::new();
        let mut terminal_sizes = BTreeMap::new();
        let mut total_bytes = 0_u64;
        for _ in 0..segment_count {
            let segment = Segment {
                id: take_number(&mut input)?,
                terminal_id: take_number(&mut input)?,
                start: take_number(&mut input)?,
                length: take_number(&mut input)?,
            };
            let end = segment
                .start
                .checked_add(segment.length)
                .ok_or(TranscriptError::Overflow)?;
            if segment.id <= previous_id
                || segment.id >= next_segment_id
                || segment.length == 0
                || segment.length > limits.segment_bytes
                || !ends.contains_key(&segment.terminal_id)
                || previous_ends
                    .get(&segment.terminal_id)
                    .is_some_and(|previous| *previous != segment.start)
            {
                return Err(TranscriptError::Corrupt("invalid segment metadata"));
            }
            previous_id = segment.id;
            previous_ends.insert(segment.terminal_id, end);
            let size = terminal_sizes.entry(segment.terminal_id).or_insert(0_u64);
            *size = size
                .checked_add(segment.length)
                .ok_or(TranscriptError::Overflow)?;
            total_bytes = total_bytes
                .checked_add(segment.length)
                .ok_or(TranscriptError::Overflow)?;
            segments.push_back(segment);
        }
        if previous_ends
            .iter()
            .any(|(id, end)| ends.get(id) != Some(end))
            || terminal_sizes
                .values()
                .any(|size| *size > limits.terminal_bytes)
            || total_bytes > limits.total_bytes
        {
            return Err(TranscriptError::Corrupt("invalid retained ranges"));
        }
        let sizes = decode_sizes(input, &ends)?;
        Ok(Self {
            next_terminal_id,
            next_segment_id,
            ends,
            segments,
            sizes,
        })
    }
}

fn decode_sizes(
    mut input: &[u8],
    ends: &BTreeMap<u64, u64>,
) -> Result<VecDeque<(u64, TranscriptSize)>, TranscriptError> {
    let mut sizes = VecDeque::new();
    if !input.is_empty() {
        if !input.starts_with(SIZE_MAGIC) {
            return Err(TranscriptError::Corrupt("invalid size history header"));
        }
        input = &input[8..];
        let count =
            usize::try_from(take_number(&mut input)?).map_err(|_| TranscriptError::Overflow)?;
        if count > MAX_SIZE_ENTRIES || input.len() != count * 24 {
            return Err(TranscriptError::Corrupt("invalid size history count"));
        }
        let mut previous = BTreeMap::new();
        for _ in 0..count {
            let id = take_number(&mut input)?;
            let offset = take_number(&mut input)?;
            let grid = take_number(&mut input)?;
            let size = TerminalSize {
                rows: u16::from_le_bytes([grid.to_le_bytes()[0], grid.to_le_bytes()[1]]),
                columns: u16::from_le_bytes([grid.to_le_bytes()[2], grid.to_le_bytes()[3]]),
                pixel_width: u16::from_le_bytes([grid.to_le_bytes()[4], grid.to_le_bytes()[5]]),
                pixel_height: u16::from_le_bytes([grid.to_le_bytes()[6], grid.to_le_bytes()[7]]),
            };
            if size.rows == 0
                || size.columns == 0
                || ends.get(&id).is_none_or(|end| offset >= *end)
                || previous
                    .insert(id, offset)
                    .is_some_and(|earlier| earlier > offset)
            {
                return Err(TranscriptError::Corrupt("invalid size history"));
            }
            sizes.push_back((id, TranscriptSize { offset, size }));
        }
    }
    Ok(sizes)
}

fn take_number(input: &mut &[u8]) -> Result<u64, TranscriptError> {
    let (number, rest) = input
        .split_first_chunk::<8>()
        .ok_or(TranscriptError::Corrupt("truncated manifest"))?;
    *input = rest;
    Ok(u64::from_le_bytes(*number))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn limits() -> Limits {
        Limits {
            segment_bytes: 4,
            terminal_bytes: 8,
            total_bytes: 12,
            terminal_count: 3,
            segment_count: 3,
            pending_bytes: 16,
            pending_jobs: 4,
        }
    }

    fn append(storage: &mut Storage, id: TerminalId, offset: u64, bytes: &[u8]) {
        storage
            .append(&TerminalChunk {
                terminal_id: id,
                offset,
                bytes: bytes.to_vec(),
            })
            .unwrap();
    }

    fn page(storage: &Storage, id: TerminalId, offset: u64, limit: usize) -> TranscriptPage {
        let TranscriptRead::Output(page) = storage.read(id, offset, limit).unwrap() else {
            panic!("retained output should be available");
        };
        page
    }

    #[test]
    fn geometry_survives_segment_commits_paging_and_reopening() {
        let directory = tempfile::tempdir().unwrap();
        let budget = Limits {
            terminal_bytes: 16,
            total_bytes: 32,
            segment_count: 8,
            ..limits()
        };
        let mut storage = Storage::open(directory.path(), budget).unwrap();
        let id = storage.allocate().unwrap();
        let size = |offset, columns| TranscriptSize {
            offset,
            size: TerminalSize {
                rows: 3,
                columns,
                pixel_width: 0,
                pixel_height: 0,
            },
        };
        let sizes = vec![size(0, 10), size(3, 6), size(3, 12), size(7, 8)];
        storage
            .append_recording(&Recording {
                chunk: TerminalChunk {
                    terminal_id: id,
                    offset: 0,
                    bytes: b"abcdefghijkl".to_vec(),
                },
                sizes: sizes.clone(),
                geometry_lost: false,
            })
            .unwrap();
        assert!(page(&storage, id, 0, 3).replay_available);
        assert_eq!(page(&storage, id, 0, 3).sizes, sizes[..1]);
        assert_eq!(page(&storage, id, 3, 4).sizes, sizes[1..3]);
        drop(storage);
        let mut storage = Storage::open(directory.path(), budget).unwrap();
        assert_eq!(page(&storage, id, 0, 12).sizes, sizes);
        storage
            .append_recording(&Recording {
                chunk: TerminalChunk {
                    terminal_id: id,
                    offset: 12,
                    bytes: b"next".to_vec(),
                },
                sizes: vec![size(12, 9)],
                geometry_lost: true,
            })
            .unwrap();
        assert!(!page(&storage, id, 0, 16).replay_available);
        assert_eq!(page(&storage, id, 0, 16).bytes, b"abcdefghijklnext");
    }

    #[test]
    fn legacy_transcripts_and_pruned_prefixes_cannot_claim_replay() {
        let directory = tempfile::tempdir().unwrap();
        let mut storage = Storage::open(directory.path(), limits()).unwrap();
        let id = storage.allocate().unwrap();
        append(&mut storage, id, 0, b"old");
        drop(storage);
        let mut storage = Storage::open(directory.path(), limits()).unwrap();
        assert!(!page(&storage, id, 0, 3).replay_available);
        for offset in [3, 7, 11] {
            append(&mut storage, id, offset, b"more");
        }
        assert!(matches!(
            storage.read(id, 0, 3).unwrap(),
            TranscriptRead::Expired { .. }
        ));
        assert!(!page(&storage, id, 11, 4).replay_available);
    }

    #[test]
    fn reads_binary_bytes_inside_chunks_and_across_segments_and_terminals() {
        let directory = tempfile::tempdir().unwrap();
        let mut storage = Storage::open(
            directory.path(),
            Limits {
                terminal_bytes: 16,
                total_bytes: 32,
                segment_count: 8,
                ..limits()
            },
        )
        .unwrap();
        let first = storage.allocate().unwrap();
        let second = storage.allocate().unwrap();
        assert!(page(&storage, first, 0, 8).bytes.is_empty());
        append(&mut storage, first, 0, &[0, 0xff, 0x1b]);
        append(&mut storage, second, 0, b"other");
        append(&mut storage, first, 3, b"[2J\n");
        let read = page(&storage, first, 1, 5);
        assert_eq!(read.bytes, [0xff, 0x1b, b'[', b'2', b'J']);
        assert_eq!((read.offset, read.next_offset, read.end_offset), (1, 6, 7));
        assert_eq!(page(&storage, first, 6, 8).bytes, b"\n");
        assert_eq!(page(&storage, second, 0, 8).bytes, b"other");
        assert!(page(&storage, first, 7, 8).bytes.is_empty());
        assert!(matches!(
            storage.read(first, 8, 1),
            Err(TranscriptError::OutOfRange {
                requested: 8,
                end_offset: 7
            })
        ));
        assert!(matches!(
            storage.read(TerminalId::from_value(0), 0, 1),
            Err(TranscriptError::NotFound { .. })
        ));
        assert!(matches!(
            storage.read(TerminalId::from_value(3), 0, 1),
            Err(TranscriptError::NotFound { .. })
        ));
    }

    #[test]
    fn per_terminal_pruning_returns_the_exact_first_retained_offset_after_reopening() {
        let directory = tempfile::tempdir().unwrap();
        let mut storage = Storage::open(directory.path(), limits()).unwrap();
        let id = storage.allocate().unwrap();
        append(&mut storage, id, 0, b"0123456789");
        let expired = TranscriptRead::Expired {
            terminal_id: id,
            requested_offset: 3,
            nearest_retained_offset: Some(4),
        };
        assert_eq!(storage.read(id, 3, 8).unwrap(), expired);
        assert_eq!(page(&storage, id, 4, 8).bytes, b"456789");
        drop(storage);
        let mut reopened = Storage::open(directory.path(), limits()).unwrap();
        assert_eq!(reopened.read(id, 3, 8).unwrap(), expired);
        append(&mut reopened, id, 10, b"ab");
        assert_eq!(page(&reopened, id, 4, 8).bytes, b"456789ab");
        assert!(reopened.allocate().unwrap().value() > id.value());
    }

    #[test]
    fn global_byte_and_segment_count_limits_expire_other_terminals_without_resetting_offsets() {
        let directory = tempfile::tempdir().unwrap();
        let mut storage = Storage::open(directory.path(), limits()).unwrap();
        let first = storage.allocate().unwrap();
        let second = storage.allocate().unwrap();
        append(&mut storage, first, 0, b"abcd");
        append(&mut storage, second, 0, b"01234567");
        let third = storage.allocate().unwrap();
        append(&mut storage, third, 0, b"more");
        assert_eq!(
            storage.read(first, 0, 8).unwrap(),
            TranscriptRead::Expired {
                terminal_id: first,
                requested_offset: 0,
                nearest_retained_offset: None,
            }
        );
        assert_eq!(page(&storage, second, 0, 8).bytes, b"01234567");
        append(&mut storage, first, 4, b"ef");
        assert_eq!(
            storage.read(first, 0, 8).unwrap(),
            TranscriptRead::Expired {
                terminal_id: first,
                requested_offset: 0,
                nearest_retained_offset: Some(4),
            }
        );
        assert_eq!(page(&storage, first, 4, 8).bytes, b"ef");
        assert!(storage.retained_bytes(None) <= 12);
        assert!(storage.manifest.segments.len() <= 3);
    }

    #[test]
    fn metadata_and_short_segments_remain_bounded_across_many_terminals() {
        let directory = tempfile::tempdir().unwrap();
        let mut storage = Storage::open(directory.path(), limits()).unwrap();
        let first = storage.allocate().unwrap();
        append(&mut storage, first, 0, b"a");
        for _ in 0..100 {
            let id = storage.allocate().unwrap();
            append(&mut storage, id, 0, b"b");
            let files: Vec<_> = fs::read_dir(directory.path())
                .unwrap()
                .map(|entry| entry.unwrap())
                .collect();
            assert!(files.len() <= 5); // Three segments, manifest, ownership lock.
            let total: u64 = files
                .iter()
                .map(|entry| entry.metadata().unwrap().len())
                .sum();
            assert!(total <= 12 + 40 + 3 * 16 + 3 * 32);
            assert!(storage.manifest.ends.len() <= 3);
        }
        assert_eq!(
            storage.read(first, 0, 1).unwrap(),
            TranscriptRead::Expired {
                terminal_id: first,
                requested_offset: 0,
                nearest_retained_offset: None,
            }
        );
        drop(storage);
        let mut storage = Storage::open(directory.path(), limits()).unwrap();
        assert_eq!(storage.allocate().unwrap().value(), 102);
    }

    #[test]
    fn segment_count_bounds_fragmented_output_without_metadata_eviction() {
        let directory = tempfile::tempdir().unwrap();
        let mut bounded = limits();
        bounded.terminal_count = 10;
        let mut storage = Storage::open(directory.path(), bounded).unwrap();
        let first = storage.allocate().unwrap();
        append(&mut storage, first, 0, b"a");
        for _ in 0..3 {
            let id = storage.allocate().unwrap();
            append(&mut storage, id, 0, b"b");
        }
        assert_eq!(
            storage.read(first, 0, 1).unwrap(),
            TranscriptRead::Expired {
                terminal_id: first,
                requested_offset: 0,
                nearest_retained_offset: None,
            }
        );
        assert_eq!(storage.manifest.segments.len(), 3);
    }

    #[test]
    fn an_evicted_active_terminal_can_record_again_at_its_absolute_offset() {
        let directory = tempfile::tempdir().unwrap();
        let mut storage = Storage::open(directory.path(), limits()).unwrap();
        let first = storage.allocate().unwrap();
        append(&mut storage, first, 0, b"old");
        for _ in 0..3 {
            storage.allocate().unwrap();
        }
        append(&mut storage, first, 3, b"new");
        assert_eq!(page(&storage, first, 3, 8).bytes, b"new");
        assert_eq!(
            storage.read(first, 0, 8).unwrap(),
            TranscriptRead::Expired {
                terminal_id: first,
                requested_offset: 0,
                nearest_retained_offset: Some(3),
            }
        );
        drop(storage);
        let storage = Storage::open(directory.path(), limits()).unwrap();
        assert_eq!(page(&storage, first, 3, 8).bytes, b"new");
    }

    #[test]
    fn interrupted_append_and_pruning_leave_only_committed_output_after_recovery() {
        let directory = tempfile::tempdir().unwrap();
        let mut storage = Storage::open(directory.path(), limits()).unwrap();
        let id = storage.allocate().unwrap();
        append(&mut storage, id, 0, b"abc");
        let segment_path = storage.segment_path(1);
        private_file()
            .append(true)
            .open(&segment_path)
            .unwrap()
            .write_all(b"uncommitted")
            .unwrap();
        let orphan_path = storage.segment_path(2);
        fs::write(&orphan_path, b"orphan").unwrap();
        fs::write(directory.path().join(NEXT_METADATA), b"partial metadata").unwrap();
        drop(storage);
        let mut storage = Storage::open(directory.path(), limits()).unwrap();
        assert_eq!(page(&storage, id, 0, 8).bytes, b"abc");
        assert_eq!(fs::metadata(segment_path).unwrap().len(), 3);
        assert!(!orphan_path.exists());
        assert!(!directory.path().join(NEXT_METADATA).exists());
        let removed = storage.manifest.segments.pop_front().unwrap();
        storage.persist().unwrap(); // Simulate a crash before unlinking the pruned file.
        let pruned_path = storage.segment_path(removed.id);
        drop(storage);
        let storage = Storage::open(directory.path(), limits()).unwrap();
        assert!(!pruned_path.exists());
        assert_eq!(
            storage.read(id, 0, 1).unwrap(),
            TranscriptRead::Expired {
                terminal_id: id,
                requested_offset: 0,
                nearest_retained_offset: None,
            }
        );
    }

    #[test]
    fn incomplete_committed_data_and_corrupt_metadata_are_explicit_errors() {
        let directory = tempfile::tempdir().unwrap();
        let mut storage = Storage::open(directory.path(), limits()).unwrap();
        let id = storage.allocate().unwrap();
        append(&mut storage, id, 0, b"abc");
        fs::write(storage.segment_path(1), b"a").unwrap();
        drop(storage);
        let Err(error) = Storage::open(directory.path(), limits()) else {
            panic!("truncated committed data must not reopen");
        };
        assert!(matches!(error, TranscriptError::Corrupt(_)), "{error:?}");
        fs::write(directory.path().join(METADATA), b"invalid").unwrap();
        assert!(matches!(
            Storage::open(directory.path(), limits()),
            Err(TranscriptError::Corrupt(_))
        ));
        fs::remove_file(directory.path().join(METADATA)).unwrap();
        assert!(matches!(
            Storage::open(directory.path(), limits()),
            Err(TranscriptError::Corrupt(_))
        ));
    }

    #[test]
    fn directory_has_only_one_writer_and_releases_ownership_on_drop() {
        let directory = tempfile::tempdir().unwrap();
        let storage = Storage::open(directory.path(), limits()).unwrap();
        assert!(matches!(
            Storage::open(directory.path(), limits()),
            Err(TranscriptError::AlreadyOpen)
        ));
        drop(storage);
        assert!(Storage::open(directory.path(), limits()).is_ok());
    }

    #[test]
    fn interrupted_initial_manifest_recovers_without_resetting_allocated_ids() {
        let initial = Manifest::default().encode().unwrap();
        for length in [0, 1, 8, 20, initial.len()] {
            let directory = tempfile::tempdir().unwrap();
            fs::write(directory.path().join(NEXT_METADATA), &initial[..length]).unwrap();
            let mut storage = Storage::open(directory.path(), limits()).unwrap();
            assert_eq!(storage.allocate().unwrap().value(), 1);
        }
        let directory = tempfile::tempdir().unwrap();
        let populated = Manifest {
            next_terminal_id: 2,
            ..Manifest::default()
        };
        fs::write(
            directory.path().join(NEXT_METADATA),
            populated.encode().unwrap(),
        )
        .unwrap();
        assert!(matches!(
            Storage::open(directory.path(), limits()),
            Err(TranscriptError::Corrupt(_))
        ));
    }

    #[test]
    fn dropping_the_store_releases_ownership_even_if_a_clone_keeps_its_descriptor() {
        let directory = tempfile::tempdir().unwrap();
        let storage = Storage::open(directory.path(), limits()).unwrap();
        let inherited = storage.ownership.try_clone().unwrap();
        assert!(matches!(
            Storage::open(directory.path(), limits()),
            Err(TranscriptError::AlreadyOpen)
        ));
        drop(storage);
        let reopened = Storage::open(directory.path(), limits());
        assert!(
            reopened.is_ok(),
            "ownership must end when the owning store drops"
        );
        drop(inherited);
    }
}
