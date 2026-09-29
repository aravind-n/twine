use std::collections::{HashMap, VecDeque};
use std::sync::{Mutex, MutexGuard};

use thiserror::Error;

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub struct TerminalId(u64);

impl TerminalId {
    #[must_use]
    pub const fn value(self) -> u64 {
        self.0
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TerminalChunk {
    pub terminal_id: TerminalId,
    pub offset: u64,
    pub bytes: Vec<u8>,
}

#[derive(Debug)]
struct Inner {
    buffered_bytes: usize,
    chunks: VecDeque<TerminalChunk>,
    active_offsets: HashMap<TerminalId, u64>,
    next_terminal_id: u64,
}

#[derive(Debug)]
pub(crate) struct TerminalStream {
    capacity_bytes: usize,
    capacity_chunks: usize,
    inner: Mutex<Inner>,
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
            inner: Mutex::new(Inner {
                buffered_bytes: 0,
                chunks: VecDeque::new(),
                active_offsets: HashMap::new(),
                next_terminal_id: 1,
            }),
        })
    }

    pub(crate) fn open(&self) -> Result<TerminalId, TerminalError> {
        let mut inner = self.lock_inner()?;
        let terminal_id = TerminalId(inner.next_terminal_id);
        inner.next_terminal_id = inner
            .next_terminal_id
            .checked_add(1)
            .ok_or(TerminalError::TerminalIdOverflow)?;
        inner.active_offsets.insert(terminal_id, 0);
        Ok(terminal_id)
    }

    pub(crate) fn publish(
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
        if inner.chunks.len() == self.capacity_chunks {
            return Err(TerminalError::QueueFull {
                capacity_chunks: self.capacity_chunks,
            });
        }
        let available_bytes = self.capacity_bytes - inner.buffered_bytes;
        if chunk_bytes > available_bytes {
            return Err(TerminalError::BufferFull {
                requested_bytes: chunk_bytes,
                available_bytes,
            });
        }

        let offset = inner
            .active_offsets
            .get(&terminal_id)
            .copied()
            .ok_or(TerminalError::NotOpen { terminal_id })?;
        let next_offset = offset
            .checked_add(u64::try_from(chunk_bytes).map_err(|_| TerminalError::OffsetOverflow)?)
            .ok_or(TerminalError::OffsetOverflow)?;
        inner.active_offsets.insert(terminal_id, next_offset);
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
        }
        Ok(chunk)
    }

    pub(crate) fn close(&self, terminal_id: TerminalId) -> Result<(), TerminalError> {
        let mut inner = self.lock_inner()?;
        if !inner.active_offsets.contains_key(&terminal_id) {
            return Err(TerminalError::NotOpen { terminal_id });
        }
        if inner
            .chunks
            .iter()
            .any(|chunk| chunk.terminal_id == terminal_id)
        {
            return Err(TerminalError::PendingOutput { terminal_id });
        }
        inner.active_offsets.remove(&terminal_id);
        Ok(())
    }

    fn lock_inner(&self) -> Result<MutexGuard<'_, Inner>, TerminalError> {
        self.inner.lock().map_err(|_| TerminalError::Poisoned)
    }
}

#[derive(Debug, Error)]
pub enum TerminalError {
    #[error(
        "terminal output buffer is full: requested {requested_bytes} bytes, {available_bytes} available"
    )]
    BufferFull {
        requested_bytes: usize,
        available_bytes: usize,
    },
    #[error("terminal output chunk has {chunk_bytes} bytes, exceeding capacity {capacity_bytes}")]
    ChunkTooLarge {
        chunk_bytes: usize,
        capacity_bytes: usize,
    },
    #[error("terminal output chunks must not be empty")]
    EmptyChunk,
    #[error("terminal byte offset overflowed")]
    OffsetOverflow,
    #[error("terminal {terminal_id:?} is not open")]
    NotOpen { terminal_id: TerminalId },
    #[error("terminal {terminal_id:?} still has queued output")]
    PendingOutput { terminal_id: TerminalId },
    #[error("terminal output lock is poisoned")]
    Poisoned,
    #[error("terminal output queue reached its {capacity_chunks}-chunk capacity")]
    QueueFull { capacity_chunks: usize },
    #[error("terminal ID counter overflowed")]
    TerminalIdOverflow,
    #[error("terminal output capacity must be greater than zero")]
    ZeroCapacity,
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
        assert!(inner.active_offsets.is_empty());
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
}
