use std::collections::{HashMap, VecDeque};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex, MutexGuard};

use super::{
    Recording, TerminalChunk, TerminalError, TerminalId, TerminalSize, TranscriptError,
    TranscriptRead, TranscriptRecorder, TranscriptSize,
};

#[derive(Debug, Default)]
struct ReplayState {
    offset: u64,
    sizes: Vec<TranscriptSize>,
    lost_at: Option<u64>,
}

#[derive(Debug, Default)]
pub(crate) struct ReplayPosition {
    inner: Mutex<ReplayState>,
    pub(super) finished: AtomicBool,
    integrated_shell: AtomicBool,
}

impl ReplayPosition {
    pub(crate) fn observe(&self) -> Result<super::TerminalObservation, TerminalError> {
        let replay = self.inner.lock().map_err(|_| TerminalError::Poisoned)?;
        Ok(super::TerminalObservation {
            integrated_shell: self.integrated_shell.load(Ordering::Acquire),
            observed_at: crate::workflow::timestamp(),
            byte_offset: replay.offset,
            boundary_sizes: replay
                .lost_at
                .is_none()
                .then(|| replay.sizes.iter().map(|resize| resize.size).collect()),
        })
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum StreamState {
    Open,
    Finished,
}

struct StreamEntry {
    next_offset: Arc<AtomicU64>,
    reserved_offset: u64,
    state: StreamState,
    cancelled: Arc<AtomicBool>,
    sizes: Vec<TranscriptSize>,
    geometry_lost: bool,
    replay_position: Arc<ReplayPosition>,
    shell_decoder: Option<super::shell::ShellDecoder>,
}

struct StreamInner {
    buffered_bytes: usize,
    chunks: VecDeque<TerminalChunk>,
    entries: HashMap<TerminalId, StreamEntry>,
    shell_observations: VecDeque<ShellObservation>,
    shell_losses: HashMap<TerminalId, super::TerminalObservation>,
}

#[derive(Clone, Debug)]
pub(crate) struct ShellObservation {
    pub terminal_id: TerminalId,
    pub mark: super::ShellMark,
    pub observation: super::TerminalObservation,
}

impl StreamInner {
    fn observe_shell(&mut self, chunk: &TerminalChunk, recorded: bool) {
        let terminal_id = chunk.terminal_id;
        let offset = chunk.offset;
        let marks = self
            .entries
            .get_mut(&terminal_id)
            .and_then(|entry| entry.shell_decoder.as_mut())
            .map(|decoder| decoder.feed(&chunk.bytes, offset))
            .unwrap_or_default();
        for (mark, byte_offset) in marks {
            let replay = self
                .entries
                .get(&terminal_id)
                .and_then(|entry| entry.replay_position.inner.lock().ok());
            let boundary_sizes = replay.as_ref().and_then(|position| {
                (recorded && position.lost_at.is_none_or(|lost| lost != byte_offset)).then(|| {
                    position
                        .sizes
                        .iter()
                        .filter(|size| size.offset == byte_offset)
                        .map(|size| size.size)
                        .collect()
                })
            });
            let observation = super::TerminalObservation {
                integrated_shell: true,
                observed_at: crate::workflow::timestamp(),
                byte_offset,
                boundary_sizes,
            };
            drop(replay);
            // Metadata never blocks terminal output. On overflow stop tracking this shell and
            // expose the lost boundary instead of inventing command endings.
            if self.shell_observations.len() >= 256 {
                self.shell_observations
                    .retain(|item| item.terminal_id != terminal_id);
                if let Some(entry) = self.entries.get_mut(&terminal_id) {
                    entry.shell_decoder = None;
                }
                self.shell_losses.insert(terminal_id, observation);
                break;
            }
            let lost = mark == super::ShellMark::Lost;
            self.shell_observations.push_back(ShellObservation {
                terminal_id,
                mark,
                observation,
            });
            if lost {
                if let Some(entry) = self.entries.get_mut(&terminal_id) {
                    entry.shell_decoder = None;
                }
                break;
            }
        }
    }
}

pub(crate) struct TerminalStream {
    capacity_bytes: usize,
    capacity_chunks: usize,
    inner: Mutex<StreamInner>,
    space_available: Condvar,
    transcripts: Arc<TranscriptRecorder>,
}

impl TerminalStream {
    #[cfg(test)]
    pub(crate) fn stall_recording_worker(
        &self,
        terminal_id: TerminalId,
    ) -> std::sync::mpsc::Receiver<Result<TranscriptRead, TranscriptError>> {
        self.transcripts.stall_worker(terminal_id)
    }

    #[cfg(test)]
    pub(crate) fn allocation_is_pending(&self) -> bool {
        self.transcripts.allocation_is_pending()
    }

    pub(crate) fn new(
        capacity_bytes: usize,
        capacity_chunks: usize,
        transcripts: Arc<TranscriptRecorder>,
    ) -> Result<Self, TerminalError> {
        if capacity_bytes == 0 || capacity_chunks == 0 {
            return Err(TerminalError::ZeroCapacity);
        }

        Ok(Self {
            capacity_bytes,
            capacity_chunks,
            inner: Mutex::new(StreamInner {
                buffered_bytes: 0,
                chunks: VecDeque::new(),
                entries: HashMap::new(),
                shell_observations: VecDeque::new(),
                shell_losses: HashMap::new(),
            }),
            space_available: Condvar::new(),
            transcripts,
        })
    }

    pub(crate) fn open(&self) -> Result<TerminalId, TerminalError> {
        // Allocation performs disk I/O on the storage worker without holding the live queue lock.
        let terminal_id = self.transcripts.allocate()?;
        let mut inner = self.lock_inner()?;
        inner.entries.insert(
            terminal_id,
            StreamEntry {
                next_offset: Arc::new(AtomicU64::new(0)),
                reserved_offset: 0,
                state: StreamState::Open,
                cancelled: Arc::new(AtomicBool::new(false)),
                sizes: Vec::new(),
                geometry_lost: false,
                replay_position: Arc::new(ReplayPosition::default()),
                shell_decoder: None,
            },
        );
        Ok(terminal_id)
    }

    pub(super) fn integrate_shell(
        &self,
        terminal_id: TerminalId,
        token: String,
    ) -> Result<(), TerminalError> {
        let mut inner = self.lock_inner()?;
        let entry = inner
            .entries
            .get_mut(&terminal_id)
            .ok_or(TerminalError::NotOpen { terminal_id })?;
        entry
            .replay_position
            .integrated_shell
            .store(true, Ordering::Release);
        entry.shell_decoder = Some(super::shell::ShellDecoder::new(token));
        Ok(())
    }

    pub(crate) fn take_shell_observations(&self) -> Result<Vec<ShellObservation>, TerminalError> {
        let mut inner = self.lock_inner()?;
        let mut observations: Vec<_> = inner.shell_observations.drain(..).collect();
        observations.extend(
            inner
                .shell_losses
                .drain()
                .map(|(terminal_id, observation)| ShellObservation {
                    terminal_id,
                    mark: super::ShellMark::Lost,
                    observation,
                }),
        );
        Ok(observations)
    }

    pub(crate) fn reader_finished(&self, id: TerminalId) -> bool {
        self.lock_inner().ok().is_none_or(|inner| {
            !inner
                .shell_observations
                .iter()
                .any(|item| item.terminal_id == id)
                && !inner.shell_losses.contains_key(&id)
                && inner
                    .entries
                    .get(&id)
                    .is_none_or(|entry| entry.replay_position.finished.load(Ordering::Acquire))
        })
    }

    pub(super) fn publish_blocking(
        &self,
        terminal_id: TerminalId,
        bytes: Vec<u8>,
    ) -> Result<u64, TerminalError> {
        let chunk_bytes = bytes.len();
        if chunk_bytes == 0 {
            return Err(TerminalError::EmptyChunk);
        }
        if chunk_bytes > self.capacity_bytes {
            return Err(TerminalError::ChunkTooLarge {
                chunk_bytes,
                capacity_bytes: self.capacity_bytes,
            });
        }

        // Each terminal has exactly one producer (its PTY reader). Reserve the shared absolute
        // offset before recording, so both storage and live delivery use the same byte positions.
        let (offset, cancelled, sizes, geometry_lost) = {
            let mut inner = self.lock_inner()?;
            let entry = inner
                .entries
                .get_mut(&terminal_id)
                .filter(|entry| entry.state == StreamState::Open)
                .ok_or(TerminalError::NotOpen { terminal_id })?;
            let offset = entry.reserved_offset;
            let next_offset = offset
                .checked_add(u64::try_from(chunk_bytes).map_err(|_| TerminalError::OffsetOverflow)?)
                .ok_or(TerminalError::OffsetOverflow)?;
            entry.reserved_offset = next_offset;
            (
                offset,
                Arc::clone(&entry.cancelled),
                std::mem::take(&mut entry.sizes),
                std::mem::take(&mut entry.geometry_lost),
            )
        };
        let chunk = TerminalChunk {
            terminal_id,
            offset,
            bytes,
        };
        let recording = self.transcripts.record(
            Recording {
                chunk: chunk.clone(),
                sizes,
                geometry_lost,
            },
            &cancelled,
        );
        if matches!(recording, Err(TranscriptError::Cancelled)) {
            return Err(TerminalError::NotOpen { terminal_id });
        }
        // Recording failures are exposed by transcript reads. Live output and input remain usable.
        // Accepted recording survives a subsequent cancellation of the live queue.
        let mut inner = self.lock_inner()?;
        inner.observe_shell(&chunk, recording.is_ok());
        if recording.is_ok()
            && let Some(entry) = inner.entries.get_mut(&terminal_id)
        {
            let accepted = chunk.offset + chunk.bytes.len() as u64;
            entry.next_offset.store(accepted, Ordering::Release);
            let mut replay = entry
                .replay_position
                .inner
                .lock()
                .map_err(|_| TerminalError::Poisoned)?;
            replay.offset = accepted;
            replay.sizes.retain(|resize| resize.offset >= accepted);
            if replay.lost_at.is_some_and(|offset| offset < accepted) {
                replay.lost_at = None;
            }
        }
        loop {
            let entry = inner
                .entries
                .get(&terminal_id)
                .ok_or(TerminalError::NotOpen { terminal_id })?;
            if entry.state != StreamState::Open {
                return Err(TerminalError::NotOpen { terminal_id });
            }

            let chunk_space = inner.chunks.len() < self.capacity_chunks;
            let byte_space = chunk_bytes <= self.capacity_bytes - inner.buffered_bytes;
            if chunk_space && byte_space {
                break;
            }
            inner = self
                .space_available
                .wait(inner)
                .map_err(|_| TerminalError::Poisoned)?;
        }

        inner.buffered_bytes += chunk_bytes;
        inner.chunks.push_back(chunk);
        Ok(offset)
    }

    /// Capture geometry at the same boundary used to reserve output offsets. This never waits
    /// for storage, so resizing and input remain usable under recording backpressure.
    pub(crate) fn record_size(
        &self,
        terminal_id: TerminalId,
        size: TerminalSize,
    ) -> Result<(), TerminalError> {
        self.change_size(terminal_id, size, || Ok(()))
    }

    pub(crate) fn change_size(
        &self,
        terminal_id: TerminalId,
        size: TerminalSize,
        change: impl FnOnce() -> Result<(), TerminalError>,
    ) -> Result<(), TerminalError> {
        let mut inner = self.lock_inner()?;
        let entry = inner
            .entries
            .get_mut(&terminal_id)
            .ok_or(TerminalError::NotOpen { terminal_id })?;
        change()?;
        if entry.sizes.len() == 256 {
            entry.sizes.clear();
            entry.geometry_lost = true;
        }
        entry.sizes.push(TranscriptSize {
            offset: entry.reserved_offset,
            size,
        });
        let mut replay = entry
            .replay_position
            .inner
            .lock()
            .map_err(|_| TerminalError::Poisoned)?;
        if replay.sizes.len() == 256 {
            replay.sizes.clear();
            replay.lost_at = Some(entry.reserved_offset);
        }
        replay.sizes.push(TranscriptSize {
            offset: entry.reserved_offset,
            size,
        });
        Ok(())
    }

    pub(crate) fn replay_position(
        &self,
        terminal_id: TerminalId,
    ) -> Result<Arc<ReplayPosition>, TerminalError> {
        self.lock_inner()?
            .entries
            .get(&terminal_id)
            .map(|entry| Arc::clone(&entry.replay_position))
            .ok_or(TerminalError::NotOpen { terminal_id })
    }

    /// The process retains this counter after the live queue is drained or cancelled.
    #[cfg(test)]
    pub(crate) fn output_position(
        &self,
        terminal_id: TerminalId,
    ) -> Result<Arc<AtomicU64>, TerminalError> {
        self.lock_inner()?
            .entries
            .get(&terminal_id)
            .map(|entry| Arc::clone(&entry.next_offset))
            .ok_or(TerminalError::NotOpen { terminal_id })
    }

    pub(crate) fn next_chunk(&self) -> Result<Option<TerminalChunk>, TerminalError> {
        let mut inner = self.lock_inner()?;
        let chunk = inner.chunks.pop_front();
        if let Some(chunk) = &chunk {
            inner.buffered_bytes -= chunk.bytes.len();
            Self::remove_drained_entry(&mut inner, chunk.terminal_id);
            self.space_available.notify_all();
        }
        Ok(chunk)
    }

    pub(super) fn finish(&self, terminal_id: TerminalId) -> Result<(), TerminalError> {
        let mut inner = self.lock_inner()?;
        let entry = inner
            .entries
            .get_mut(&terminal_id)
            .ok_or(TerminalError::NotOpen { terminal_id })?;
        entry
            .replay_position
            .finished
            .store(true, Ordering::Release);
        if entry.state == StreamState::Open {
            entry.state = StreamState::Finished;
        }
        Self::remove_drained_entry(&mut inner, terminal_id);
        self.space_available.notify_all();
        Ok(())
    }

    pub(super) fn cancel(&self, terminal_id: TerminalId) -> Result<(), TerminalError> {
        let mut inner = self.lock_inner()?;
        if let Some(entry) = inner.entries.get(&terminal_id) {
            entry
                .replay_position
                .finished
                .store(true, Ordering::Release);
        }
        inner
            .entries
            .get(&terminal_id)
            .ok_or(TerminalError::NotOpen { terminal_id })?
            .cancelled
            .store(true, Ordering::Release);
        let mut removed_bytes = 0;
        inner.chunks.retain(|chunk| {
            if chunk.terminal_id == terminal_id {
                removed_bytes += chunk.bytes.len();
                false
            } else {
                true
            }
        });
        inner.buffered_bytes -= removed_bytes;
        inner.entries.remove(&terminal_id);
        self.space_available.notify_all();
        drop(inner);
        self.transcripts.wake_producers();
        Ok(())
    }

    pub(crate) fn read_transcript(
        &self,
        terminal_id: TerminalId,
        offset: u64,
        limit: usize,
    ) -> Result<TranscriptRead, TranscriptError> {
        self.transcripts.read(terminal_id, offset, limit)
    }

    pub(crate) fn request_transcript(
        &self,
        terminal_id: TerminalId,
        offset: u64,
        limit: usize,
    ) -> Result<Option<super::TranscriptRequest>, TranscriptError> {
        self.transcripts.request_read(terminal_id, offset, limit)
    }

    pub(crate) fn shutdown_recording(&self) {
        self.transcripts.shutdown();
    }

    fn remove_drained_entry(inner: &mut StreamInner, terminal_id: TerminalId) {
        let has_chunks = inner
            .chunks
            .iter()
            .any(|chunk| chunk.terminal_id == terminal_id);
        let is_closed = inner
            .entries
            .get(&terminal_id)
            .is_some_and(|entry| entry.state != StreamState::Open);
        if is_closed && !has_chunks {
            inner.entries.remove(&terminal_id);
        }
    }

    fn lock_inner(&self) -> Result<MutexGuard<'_, StreamInner>, TerminalError> {
        self.inner.lock().map_err(|_| TerminalError::Poisoned)
    }
}

#[cfg(test)]
impl TerminalStream {
    pub(crate) fn for_test(
        capacity_bytes: usize,
        capacity_chunks: usize,
    ) -> Result<Self, TerminalError> {
        Self::new(
            capacity_bytes,
            capacity_chunks,
            Arc::new(TranscriptRecorder::temporary()?),
        )
    }
    pub(super) fn queued_chunk_count(&self) -> usize {
        self.lock_inner()
            .expect("stream should remain available")
            .chunks
            .len()
    }

    pub(crate) fn tracks_no_terminals(&self) -> bool {
        self.lock_inner()
            .expect("stream should remain available")
            .entries
            .is_empty()
    }
}

#[cfg(test)]
mod tests {
    use std::sync::{Arc, mpsc};
    use std::thread;
    use std::time::Duration;

    use super::*;

    const TEST_TIMEOUT: Duration = Duration::from_secs(2);

    #[test]
    fn finished_reader_waits_for_queued_boundaries_and_loss_disables_decoding() {
        let stream = TerminalStream::for_test(4096, 4).unwrap();
        let id = stream.open().unwrap();
        stream.integrate_shell(id, "test".into()).unwrap();
        assert!(
            stream
                .replay_position(id)
                .unwrap()
                .observe()
                .unwrap()
                .integrated_shell
        );
        stream
            .publish_blocking(id, b"\x1b]133;D;twine=test;1\x07".to_vec())
            .unwrap();
        stream.finish(id).unwrap();
        stream.next_chunk().unwrap();
        assert!(!stream.reader_finished(id));
        assert_eq!(
            stream.take_shell_observations().unwrap()[0].mark,
            super::super::ShellMark::CommandEnd(1)
        );
        assert!(stream.reader_finished(id));

        let id = stream.open().unwrap();
        stream.integrate_shell(id, "test".into()).unwrap();
        stream
            .publish_blocking(
                id,
                b"\x1b]133;L;twine=test\x07\x1b]133;C;twine=test;command=66616c7365\x07".to_vec(),
            )
            .unwrap();
        stream
            .publish_blocking(id, b"\x1b]133;A;twine=test\x07".to_vec())
            .unwrap();
        let observations = stream.take_shell_observations().unwrap();
        assert_eq!(observations.len(), 1);
        assert_eq!(observations[0].mark, super::super::ShellMark::Lost);
    }

    #[test]
    fn metadata_overflow_reports_loss_even_for_another_terminal() {
        let stream = TerminalStream::for_test(16384, 4).unwrap();
        let first = stream.open().unwrap();
        let second = stream.open().unwrap();
        stream.integrate_shell(first, "first".into()).unwrap();
        stream.integrate_shell(second, "second".into()).unwrap();
        let marks = b"\x1b]133;A;twine=first\x07".repeat(128);
        stream.publish_blocking(first, marks.clone()).unwrap();
        stream.publish_blocking(first, marks).unwrap();
        let output = b"\x1b]133;C;twine=second;command=66616c7365\x07output".to_vec();
        stream.publish_blocking(second, output.clone()).unwrap();
        let observations = stream.take_shell_observations().unwrap();
        assert!(
            observations.iter().any(
                |item| item.terminal_id == second && item.mark == super::super::ShellMark::Lost
            )
        );
        assert!(stream.take_shell_observations().unwrap().is_empty());
        stream.next_chunk().unwrap();
        stream.next_chunk().unwrap();
        assert_eq!(stream.next_chunk().unwrap().unwrap().bytes, output);
    }

    #[test]
    fn shell_anchor_keeps_resizes_at_its_exact_boundary() {
        let stream = TerminalStream::for_test(4096, 4).unwrap();
        let id = stream.open().unwrap();
        stream.integrate_shell(id, "test".into()).unwrap();
        let bytes = b"\x1b]133;C;twine=test;command=66616c7365\x07".to_vec();
        let boundary = bytes.len() as u64;
        stream
            .lock_inner()
            .unwrap()
            .entries
            .get_mut(&id)
            .unwrap()
            .reserved_offset = boundary;
        let size = TerminalSize {
            rows: 37,
            columns: 95,
            pixel_width: 950,
            pixel_height: 740,
        };
        stream.record_size(id, size).unwrap();
        stream.lock_inner().unwrap().observe_shell(
            &TerminalChunk {
                terminal_id: id,
                offset: 0,
                bytes,
            },
            true,
        );
        let observations = stream.take_shell_observations().unwrap();
        assert_eq!(observations[0].observation.byte_offset, boundary);
        assert_eq!(observations[0].observation.boundary_sizes, Some(vec![size]));
    }

    #[test]
    fn retained_output_counter_survives_finish_drain_and_cancel() {
        let stream = TerminalStream::for_test(16, 4).unwrap();
        let id = stream.open().unwrap();
        let counter = stream.output_position(id).unwrap();
        stream.publish_blocking(id, vec![1, 2, 3]).unwrap();
        stream.finish(id).unwrap();
        stream.next_chunk().unwrap();
        assert!(stream.tracks_no_terminals());
        assert_eq!(counter.load(Ordering::Acquire), 3);
        let id = stream.open().unwrap();
        let counter = stream.output_position(id).unwrap();
        stream.publish_blocking(id, vec![4, 5]).unwrap();
        stream.cancel(id).unwrap();
        assert_eq!(counter.load(Ordering::Acquire), 2);
    }

    #[test]
    fn empty_and_oversized_chunks_are_rejected() {
        let stream = TerminalStream::for_test(4, 2).expect("stream should initialize");
        let terminal_id = stream.open().expect("terminal should open");

        assert!(matches!(
            stream.publish_blocking(terminal_id, Vec::new()),
            Err(TerminalError::EmptyChunk)
        ));
        assert!(matches!(
            stream.publish_blocking(terminal_id, vec![0; 5]),
            Err(TerminalError::ChunkTooLarge {
                chunk_bytes: 5,
                capacity_bytes: 4,
            })
        ));
    }

    #[test]
    fn output_has_absolute_offsets_and_new_terminals_start_at_zero() {
        let stream = TerminalStream::for_test(8, 3).expect("stream should initialize");
        let first_id = stream.open().expect("first terminal should open");

        assert_eq!(
            stream
                .publish_blocking(first_id, vec![0, 1, 2])
                .expect("first chunk should fit"),
            0
        );
        assert_eq!(
            stream
                .publish_blocking(first_id, vec![3, 4])
                .expect("second chunk should fit"),
            3
        );
        let first = stream
            .next_chunk()
            .expect("read should succeed")
            .expect("first chunk should exist");
        assert_eq!(first.terminal_id, first_id);
        assert_eq!(first.offset, 0);
        assert_eq!(first.bytes, vec![0, 1, 2]);

        assert_eq!(
            stream
                .publish_blocking(first_id, vec![5])
                .expect("third chunk should fit"),
            5
        );
        stream
            .finish(first_id)
            .expect("first terminal should finish");
        let second = stream
            .next_chunk()
            .expect("read should succeed")
            .expect("second chunk should exist");
        assert_eq!(second.terminal_id, first_id);
        assert_eq!(second.offset, 3);
        assert_eq!(second.bytes, vec![3, 4]);
        let third = stream
            .next_chunk()
            .expect("read should succeed")
            .expect("third chunk should exist");
        assert_eq!(third.terminal_id, first_id);
        assert_eq!(third.offset, 5);
        assert_eq!(third.bytes, vec![5]);
        assert!(stream.tracks_no_terminals());

        let second_id = stream.open().expect("second terminal should open");
        assert_ne!(first_id, second_id);
        assert_eq!(
            stream
                .publish_blocking(second_id, vec![6])
                .expect("new terminal output should fit"),
            0
        );
        stream
            .cancel(second_id)
            .expect("second terminal should cancel");
    }

    #[test]
    fn finish_reclaims_terminals_before_or_after_draining_and_with_no_output() {
        let stream = TerminalStream::for_test(64, 2).expect("stream should initialize");

        let empty = stream.open().expect("empty terminal should open");
        stream.finish(empty).expect("empty terminal should finish");
        assert!(stream.tracks_no_terminals());

        for index in 0..128 {
            let terminal_id = stream.open().expect("terminal should open");
            stream
                .publish_blocking(terminal_id, vec![1])
                .expect("output should fit");
            if index % 2 == 0 {
                stream.finish(terminal_id).expect("terminal should finish");
                assert!(!stream.tracks_no_terminals());
            }
            let chunk = stream
                .next_chunk()
                .expect("read should succeed")
                .expect("chunk should exist");
            assert_eq!(chunk.terminal_id, terminal_id);
            assert_eq!(chunk.offset, 0);
            if index % 2 != 0 {
                assert!(!stream.tracks_no_terminals());
                stream.finish(terminal_id).expect("terminal should finish");
            }
            assert!(stream.tracks_no_terminals());
            assert!(matches!(
                stream.publish_blocking(terminal_id, vec![2]),
                Err(TerminalError::NotOpen { .. })
            ));
        }
    }

    #[test]
    fn blocked_publish_resumes_when_byte_or_chunk_capacity_is_read() {
        assert_publish_waits_for_read(5, 2, &[0, 1, 2, 3, 4], &[5]);
        assert_publish_waits_for_read(64, 1, &[0], &[1]);
    }

    fn assert_publish_waits_for_read(
        capacity_bytes: usize,
        capacity_chunks: usize,
        first_bytes: &[u8],
        second_bytes: &[u8],
    ) {
        let stream = Arc::new(
            TerminalStream::for_test(capacity_bytes, capacity_chunks)
                .expect("stream should initialize"),
        );
        let terminal_id = stream.open().expect("terminal should open");
        stream
            .publish_blocking(terminal_id, first_bytes.to_vec())
            .expect("first chunk should fit");

        let (result_receiver, publisher) =
            spawn_publish(&stream, terminal_id, second_bytes.to_vec());
        assert!(matches!(
            result_receiver.recv_timeout(Duration::from_millis(50)),
            Err(mpsc::RecvTimeoutError::Timeout)
        ));
        let first = stream
            .next_chunk()
            .expect("read should succeed")
            .expect("first chunk should exist");
        assert_eq!(first.terminal_id, terminal_id);
        assert_eq!(first.bytes, first_bytes);
        let expected_offset =
            u64::try_from(first_bytes.len()).expect("test chunk length should fit");
        assert_eq!(
            result_receiver
                .recv_timeout(TEST_TIMEOUT)
                .expect("publisher should resume after read")
                .expect("publish should succeed"),
            expected_offset
        );
        publisher.join().expect("publisher should not panic");

        stream.finish(terminal_id).expect("terminal should finish");
        let second = stream
            .next_chunk()
            .expect("read should succeed")
            .expect("second chunk should exist");
        assert_eq!(second.terminal_id, terminal_id);
        assert_eq!(second.offset, expected_offset);
        assert_eq!(second.bytes, second_bytes);
        assert!(stream.tracks_no_terminals());
    }

    #[test]
    fn cancelling_terminal_discards_output_and_wakes_publishers() {
        let stream = Arc::new(TerminalStream::for_test(4, 2).expect("stream should initialize"));
        let first = stream.open().expect("first terminal should open");
        let second = stream.open().expect("second terminal should open");
        stream
            .publish_blocking(first, vec![1, 2, 3, 4])
            .expect("first terminal should fill buffer");

        let (result_receiver, publisher) = spawn_publish(&stream, second, vec![5, 6, 7, 8]);
        assert!(matches!(
            result_receiver.recv_timeout(Duration::from_millis(50)),
            Err(mpsc::RecvTimeoutError::Timeout)
        ));
        stream.cancel(first).expect("first terminal should cancel");
        assert!(matches!(
            stream.publish_blocking(first, vec![9]),
            Err(TerminalError::NotOpen { .. })
        ));
        assert_eq!(
            result_receiver
                .recv_timeout(TEST_TIMEOUT)
                .expect("cancellation should release capacity")
                .expect("second terminal should publish"),
            0
        );
        publisher.join().expect("publisher should not panic");
        let chunk = stream
            .next_chunk()
            .expect("read should succeed")
            .expect("second terminal output should remain");
        assert_eq!(chunk.terminal_id, second);
        assert_eq!(chunk.bytes, vec![5, 6, 7, 8]);
        assert!(stream.next_chunk().expect("read should succeed").is_none());
        stream
            .cancel(second)
            .expect("second terminal should cancel");
        assert!(stream.tracks_no_terminals());

        let third = stream.open().expect("third terminal should open");
        stream
            .publish_blocking(third, vec![1, 2, 3, 4])
            .expect("third terminal should fill buffer");
        let (result_receiver, publisher) = spawn_publish(&stream, third, vec![5]);
        stream.cancel(third).expect("third terminal should cancel");
        assert!(matches!(
            result_receiver
                .recv_timeout(TEST_TIMEOUT)
                .expect("publisher should wake after cancellation"),
            Err(TerminalError::NotOpen { .. })
        ));
        publisher.join().expect("publisher should not panic");
        assert!(stream.next_chunk().expect("read should succeed").is_none());
        assert!(stream.tracks_no_terminals());
    }

    #[test]
    fn boundary_geometry_survives_live_entry_reclamation_and_overflow_is_explicit() {
        let stream = TerminalStream::for_test(64, 4).unwrap();
        let id = stream.open().unwrap();
        let position = stream.replay_position(id).unwrap();
        let size = |columns| TerminalSize {
            rows: 3,
            columns,
            pixel_width: 0,
            pixel_height: 0,
        };
        stream.record_size(id, size(10)).unwrap();
        stream.publish_blocking(id, b"output".to_vec()).unwrap();
        stream.record_size(id, size(5)).unwrap();
        stream.record_size(id, size(12)).unwrap();
        let observed = position.observe().unwrap();
        assert_eq!(observed.byte_offset, 6);
        assert_eq!(observed.boundary_sizes.unwrap(), vec![size(5), size(12)]);
        stream.finish(id).unwrap();
        stream.next_chunk().unwrap();
        assert!(stream.tracks_no_terminals());
        assert_eq!(
            position.observe().unwrap().boundary_sizes.unwrap(),
            vec![size(5), size(12)]
        );

        let id = stream.open().unwrap();
        let position = stream.replay_position(id).unwrap();
        for _ in 0..257 {
            stream.record_size(id, size(8)).unwrap();
        }
        assert!(position.observe().unwrap().boundary_sizes.is_none());
        stream.publish_blocking(id, b"new".to_vec()).unwrap();
        assert_eq!(position.observe().unwrap().boundary_sizes, Some(Vec::new()));
        let TranscriptRead::Output(page) = stream.read_transcript(id, 0, 3).unwrap() else {
            panic!("raw output remains available");
        };
        assert!(!page.replay_available);
    }

    fn spawn_publish(
        stream: &Arc<TerminalStream>,
        terminal_id: TerminalId,
        bytes: Vec<u8>,
    ) -> (
        mpsc::Receiver<Result<u64, TerminalError>>,
        thread::JoinHandle<()>,
    ) {
        let (started_sender, started_receiver) = mpsc::sync_channel(0);
        let (result_sender, result_receiver) = mpsc::channel();
        let publisher_stream = Arc::clone(stream);
        let publisher = thread::spawn(move || {
            started_sender
                .send(())
                .expect("test should receive publisher start");
            let result = publisher_stream.publish_blocking(terminal_id, bytes);
            result_sender
                .send(result)
                .expect("test should receive publish result");
        });
        started_receiver
            .recv_timeout(TEST_TIMEOUT)
            .expect("publisher should start");
        (result_receiver, publisher)
    }

    #[test]
    fn cancelling_live_delivery_preserves_output_already_accepted_for_recording() {
        let stream = Arc::new(TerminalStream::for_test(1, 1).unwrap());
        let id = stream.open().unwrap();
        let observed_offset = stream.output_position(id).unwrap();
        stream.publish_blocking(id, b"a".to_vec()).unwrap();
        let (result, publisher) = spawn_publish(&stream, id, b"b".to_vec());
        assert!(matches!(
            result.recv_timeout(Duration::from_millis(50)),
            Err(mpsc::RecvTimeoutError::Timeout)
        ));
        let TranscriptRead::Output(page) = stream.read_transcript(id, 0, 8).unwrap() else {
            panic!("accepted output should remain readable");
        };
        assert_eq!(page.bytes, b"ab");
        // The second byte is recorded while live delivery waits for capacity. Trace observations
        // must use that same reserved offset, without waiting for delivery or incrementing twice.
        assert_eq!(observed_offset.load(Ordering::Acquire), page.end_offset);
        assert_eq!(page.end_offset, 2);
        stream.cancel(id).unwrap();
        assert!(matches!(
            result.recv_timeout(TEST_TIMEOUT).unwrap(),
            Err(TerminalError::NotOpen { .. })
        ));
        publisher.join().unwrap();
        assert!(stream.next_chunk().unwrap().is_none());
        assert_eq!(observed_offset.load(Ordering::Acquire), 2);
        assert_eq!(
            stream.read_transcript(id, 0, 8).unwrap(),
            TranscriptRead::Output(page)
        );
    }

    #[test]
    fn recording_failure_does_not_stop_live_byte_delivery() {
        let directory = tempfile::tempdir().unwrap();
        let transcripts = Arc::new(TranscriptRecorder::open(directory.path()).unwrap());
        let stream = TerminalStream::new(32, 4, transcripts).unwrap();
        let id = stream.open().unwrap();
        std::fs::create_dir(directory.path().join("metadata.next")).unwrap();
        stream.publish_blocking(id, b"still live".to_vec()).unwrap();
        assert_eq!(stream.next_chunk().unwrap().unwrap().bytes, b"still live");
        assert!(matches!(
            stream.read_transcript(id, 0, 32),
            Err(TranscriptError::Unavailable { .. })
        ));
        assert_eq!(stream.publish_blocking(id, b" next".to_vec()).unwrap(), 10);
        assert_eq!(stream.next_chunk().unwrap().unwrap().offset, 10);
        stream.cancel(id).unwrap();
    }
}
