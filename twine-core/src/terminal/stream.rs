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

    #[cfg(test)]
    fn publish(&self, terminal_id: TerminalId, bytes: Vec<u8>) -> Result<u64, TerminalError> {
        self.publish_inner(terminal_id, bytes, false)
    }

    pub(super) fn publish_blocking(
        &self,
        terminal_id: TerminalId,
        bytes: Vec<u8>,
    ) -> Result<u64, TerminalError> {
        self.publish_inner(terminal_id, bytes, true)
    }

    fn publish_inner(
        &self,
        terminal_id: TerminalId,
        bytes: Vec<u8>,
        wait_for_space: bool,
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
            if !wait_for_space {
                if !chunk_space {
                    return Err(TerminalError::QueueFull {
                        capacity_chunks: self.capacity_chunks,
                    });
                }
                return Err(TerminalError::BufferFull {
                    requested_bytes: chunk_bytes,
                    available_bytes: self.capacity_bytes - inner.buffered_bytes,
                });
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

    #[cfg(test)]
    fn close(&self, terminal_id: TerminalId) -> Result<(), TerminalError> {
        let mut inner = self.lock_inner()?;
        if !inner.entries.contains_key(&terminal_id) {
            return Err(TerminalError::NotOpen { terminal_id });
        }
        if inner
            .chunks
            .iter()
            .any(|chunk| chunk.terminal_id == terminal_id)
        {
            return Err(TerminalError::PendingOutput { terminal_id });
        }
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
    use super::*;

    #[test]
    fn queue_is_bounded_by_chunk_count() {
        let stream = TerminalStream::new(64, 2).expect("stream should initialize");
        let terminal_id = stream.open().expect("terminal should open");

        stream
            .publish(terminal_id, vec![1])
            .expect("first chunk should fit");
        stream
            .publish(terminal_id, vec![2])
            .expect("second chunk should fit");
        assert!(matches!(
            stream.publish(terminal_id, vec![3]),
            Err(TerminalError::QueueFull { capacity_chunks: 2 })
        ));
    }

    #[test]
    fn empty_chunks_are_rejected() {
        let stream = TerminalStream::new(64, 2).expect("stream should initialize");
        let terminal_id = stream.open().expect("terminal should open");
        assert!(matches!(
            stream.publish(terminal_id, Vec::new()),
            Err(TerminalError::EmptyChunk)
        ));
    }

    #[test]
    fn closing_drained_terminals_reclaims_offset_state() {
        let stream = TerminalStream::new(64, 2).expect("stream should initialize");

        for _ in 0..10_000 {
            let terminal_id = stream.open().expect("terminal should open");
            stream
                .publish(terminal_id, vec![1])
                .expect("terminal output should fit");
            assert!(matches!(
                stream.close(terminal_id),
                Err(TerminalError::PendingOutput { .. })
            ));
            let chunk = stream
                .next_chunk()
                .expect("read should succeed")
                .expect("chunk should exist");
            assert_eq!(chunk.offset, 0);
            stream
                .close(terminal_id)
                .expect("drained terminal should close");
            assert!(matches!(
                stream.publish(terminal_id, vec![2]),
                Err(TerminalError::NotOpen { .. })
            ));
        }

        let inner = stream.lock_inner().expect("stream should remain available");
        assert!(inner.entries.is_empty());
    }

    #[test]
    fn newly_opened_terminal_gets_a_fresh_id_and_zero_offset() {
        let stream = TerminalStream::new(64, 2).expect("stream should initialize");
        let first = stream.open().expect("first terminal should open");
        stream
            .publish(first, vec![1])
            .expect("terminal output should fit");
        stream.next_chunk().expect("read should succeed");
        stream.close(first).expect("terminal should close");

        let second = stream.open().expect("second terminal should open");
        assert_ne!(first, second);
        assert_eq!(
            stream
                .publish(second, vec![2])
                .expect("new terminal output should fit"),
            0
        );
    }

    #[test]
    fn cancelling_terminal_discards_its_buffered_output() {
        let stream = TerminalStream::new(4, 2).expect("stream should initialize");
        let first = stream.open().expect("first terminal should open");
        let second = stream.open().expect("second terminal should open");
        stream
            .publish(first, vec![1, 2, 3, 4])
            .expect("first terminal should fill the queue");

        stream.cancel(first).expect("terminal should cancel");
        assert!(matches!(
            stream.publish(first, vec![5]),
            Err(TerminalError::NotOpen { .. })
        ));
        stream
            .publish(second, vec![6, 7, 8, 9])
            .expect("cancelled output should release queue capacity");
        assert_eq!(
            stream
                .next_chunk()
                .expect("output should be readable")
                .expect("second terminal output should remain")
                .terminal_id,
            second
        );
    }

    #[test]
    fn output_has_absolute_offsets_and_byte_backpressure() {
        let stream = TerminalStream::new(5, 16).expect("stream should initialize");
        let terminal_id = stream.open().expect("terminal should open");

        assert_eq!(
            stream
                .publish(terminal_id, vec![0, 1, 2])
                .expect("first chunk should fit"),
            0
        );
        assert_eq!(
            stream
                .publish(terminal_id, vec![3, 4])
                .expect("second chunk should fit"),
            3
        );
        assert!(matches!(
            stream.publish(terminal_id, vec![5]),
            Err(TerminalError::BufferFull { .. })
        ));

        let first = stream
            .next_chunk()
            .expect("read should succeed")
            .expect("chunk should exist");
        assert_eq!(first.terminal_id, terminal_id);
        assert_eq!(first.offset, 0);
        assert_eq!(first.bytes, vec![0, 1, 2]);

        assert_eq!(
            stream
                .publish(terminal_id, vec![5])
                .expect("space should be reusable"),
            5
        );

        assert!(matches!(
            stream.close(terminal_id),
            Err(TerminalError::PendingOutput { .. })
        ));
        while stream.next_chunk().expect("read should succeed").is_some() {}
        stream
            .close(terminal_id)
            .expect("drained terminal should close");
        assert!(matches!(
            stream.publish(terminal_id, vec![6]),
            Err(TerminalError::NotOpen { .. })
        ));

        let next_terminal_id = stream.open().expect("next terminal should open");
        assert_ne!(next_terminal_id, terminal_id);
        assert_eq!(
            stream
                .publish(next_terminal_id, vec![6])
                .expect("fresh terminal should start at zero"),
            0
        );
    }
}
