use std::collections::{HashMap, VecDeque};
use std::sync::{Condvar, Mutex, MutexGuard};

use super::{TerminalChunk, TerminalError, TerminalId};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum StreamState {
    Open,
    Finished,
}

#[derive(Debug)]
struct StreamEntry {
    next_offset: u64,
    state: StreamState,
}

#[derive(Debug)]
struct StreamInner {
    buffered_bytes: usize,
    chunks: VecDeque<TerminalChunk>,
    entries: HashMap<TerminalId, StreamEntry>,
    next_terminal_id: u64,
}

#[derive(Debug)]
pub(crate) struct TerminalStream {
    capacity_bytes: usize,
    capacity_chunks: usize,
    inner: Mutex<StreamInner>,
    space_available: Condvar,
}

impl TerminalStream {
    pub(crate) fn new(
        capacity_bytes: usize,
        capacity_chunks: usize,
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
                next_terminal_id: 1,
            }),
            space_available: Condvar::new(),
        })
    }

    pub(crate) fn open(&self) -> Result<TerminalId, TerminalError> {
        let mut inner = self.lock_inner()?;
        let terminal_id = TerminalId::from_value(inner.next_terminal_id);
        inner.next_terminal_id = inner
            .next_terminal_id
            .checked_add(1)
            .ok_or(TerminalError::TerminalIdOverflow)?;
        inner.entries.insert(
            terminal_id,
            StreamEntry {
                next_offset: 0,
                state: StreamState::Open,
            },
        );
        Ok(terminal_id)
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

        let mut inner = self.lock_inner()?;
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

        let entry = inner
            .entries
            .get_mut(&terminal_id)
            .ok_or(TerminalError::NotOpen { terminal_id })?;
        let offset = entry.next_offset;
        entry.next_offset = offset
            .checked_add(u64::try_from(chunk_bytes).map_err(|_| TerminalError::OffsetOverflow)?)
            .ok_or(TerminalError::OffsetOverflow)?;
        inner.buffered_bytes += chunk_bytes;
        inner.chunks.push_back(TerminalChunk {
            terminal_id,
            offset,
            bytes,
        });
        Ok(offset)
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
        if entry.state == StreamState::Open {
            entry.state = StreamState::Finished;
        }
        Self::remove_drained_entry(&mut inner, terminal_id);
        self.space_available.notify_all();
        Ok(())
    }

    pub(super) fn cancel(&self, terminal_id: TerminalId) -> Result<(), TerminalError> {
        let mut inner = self.lock_inner()?;
        if !inner.entries.contains_key(&terminal_id) {
            return Err(TerminalError::NotOpen { terminal_id });
        }
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
        Ok(())
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
    pub(super) fn queued_chunk_count(&self) -> usize {
        self.lock_inner()
            .expect("stream should remain available")
            .chunks
            .len()
    }

    pub(super) fn tracks_no_terminals(&self) -> bool {
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
    fn empty_and_oversized_chunks_are_rejected() {
        let stream = TerminalStream::new(4, 2).expect("stream should initialize");
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
        let stream = TerminalStream::new(8, 3).expect("stream should initialize");
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
        let stream = TerminalStream::new(64, 2).expect("stream should initialize");

        let empty = stream.open().expect("empty terminal should open");
        stream.finish(empty).expect("empty terminal should finish");
        assert!(stream.tracks_no_terminals());

        for index in 0..10_000 {
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
            TerminalStream::new(capacity_bytes, capacity_chunks).expect("stream should initialize"),
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
        let stream = Arc::new(TerminalStream::new(4, 2).expect("stream should initialize"));
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
}
